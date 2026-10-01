import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/cluster_domain/cluster_models.dart';
import '../../core/connectivity/cluster_connection.dart';
import '../../core/connectivity/connection_errors.dart';
import '../../core/sync_cache/snapshot_store.dart';

/// Owns the async session state for the OrbitShell: cluster list, active
/// cluster, current snapshot, load/refresh flags, and the relative-time
/// ticker that drives "Updated Xm ago" in the AppBar.
///
/// Produced to decouple the shell widget from the data plumbing. The shell
/// should only own navigation state (selected tab); everything that changes
/// because of cache/live fetches lives here.
class ClusterSessionController extends ChangeNotifier {
  ClusterSessionController({
    required ClusterConnection connection,
    required SnapshotStore store,
    Duration cacheMaxAge = const Duration(minutes: 10),
    Duration relativeTimeTick = const Duration(seconds: 30),
    Duration? autoRefreshInterval,
  })  : _connection = connection,
        _store = store,
        _cacheMaxAge = cacheMaxAge {
    _relativeTimeTicker = Timer.periodic(relativeTimeTick, (_) {
      if (_lastRefreshedAt != null) notifyListeners();
    });
    if (autoRefreshInterval != null && autoRefreshInterval > Duration.zero) {
      _autoRefreshTimer = Timer.periodic(autoRefreshInterval, (_) {
        if (_disposed || _isLoading || _isRefreshing) return;
        if (_selectedCluster == null) {
          // A failed bootstrap retries on the next tick. An empty cluster
          // list is not an error and waits for a manual refresh.
          if (_loadError != null) retry();
          return;
        }
        // Fire-and-forget; refresh() is safe to call and self-gated.
        refresh();
      });
    }
  }

  final ClusterConnection _connection;
  final SnapshotStore _store;
  final Duration _cacheMaxAge;
  Timer? _relativeTimeTicker;
  Timer? _autoRefreshTimer;
  bool _disposed = false;

  /// Bumped by every [bootstrap] and [cycleCluster]. Each async load
  /// captures it up front and drops its result if it changed meanwhile, so
  /// a slow response for the previous cluster can't land on the current one.
  int _generation = 0;

  List<ClusterProfile> _clusters = const [];
  ClusterProfile? _selectedCluster;
  ClusterSnapshot? _snapshot;
  Object? _loadError;
  Object? _staleError;
  bool _isLoading = true;
  bool _isRefreshing = false;
  DateTime? _lastRefreshedAt;

  ClusterConnection get connection => _connection;
  SnapshotStore get store => _store;
  List<ClusterProfile> get clusters => _clusters;
  ClusterProfile? get selectedCluster => _selectedCluster;
  ClusterSnapshot? get snapshot => _snapshot;
  Object? get loadError => _loadError;
  bool get isLoading => _isLoading;
  bool get isRefreshing => _isRefreshing;
  DateTime? get lastRefreshedAt => _lastRefreshedAt;

  /// Why the live fetch behind an on-screen cached snapshot failed; null
  /// while the data is live. The cache's age is [lastRefreshedAt].
  Object? get staleError => _staleError;

  /// The live cluster list came back empty: nothing to show, yet not a
  /// failure. Tells "no clusters" apart from a failed connection, which
  /// leaves nothing selected too but sets [loadError].
  bool get hasNoClusters =>
      !_isLoading && _loadError == null && _selectedCluster == null;

  bool _isCurrent(int gen) => !_disposed && gen == _generation;

  /// Load cache first (if fresh), then live-fetch the first cluster.
  /// Safe to call once in initState.
  Future<void> bootstrap() async {
    final gen = ++_generation;
    var cacheShown = false;

    try {
      final cachedProfiles = await _store.loadProfiles(maxAge: _cacheMaxAge);
      if (cachedProfiles.isNotEmpty) {
        cacheShown = await _showCached(
          gen,
          cachedProfiles.first,
          clusters: cachedProfiles,
        );
      }
    } catch (_) {
      // Cache read failure is non-fatal — fall through to live fetch.
    }

    final List<ClusterProfile> clusters;
    try {
      clusters = await _connection.listClusters();
    } catch (error) {
      _fail(gen, error, cacheShown: cacheShown);
      return;
    }
    if (!_isCurrent(gen)) return;

    if (clusters.isEmpty) {
      _isLoading = false;
      _isRefreshing = false;
      notifyListeners();
      return;
    }

    await _activate(
      gen,
      clusters.first,
      clusters: clusters,
      cacheShown: cacheShown,
    );
  }

  /// Re-runs [bootstrap] from scratch, superseding any load in flight. The
  /// way out of a failed bootstrap, which leaves no cluster to refresh.
  Future<void> retry() {
    if (_disposed) return Future.value();
    _loadError = null;
    _staleError = null;
    _isLoading = true;
    notifyListeners();
    return bootstrap();
  }

  /// Re-fetch the snapshot for the currently selected cluster, or [retry]
  /// the bootstrap when none is selected. Returns an error string if the
  /// refresh failed and no-ops if one is already in flight, so callers can
  /// surface a SnackBar without peeking at state.
  Future<String?> refresh() async {
    if (_isRefreshing || _disposed) return null;
    final cluster = _selectedCluster;
    if (cluster == null) {
      // Bootstrap is still running: let it finish rather than restart it.
      if (_isLoading) return null;
      await retry();
      final error = _loadError;
      return error == null || _disposed
          ? null
          : 'Refresh failed: ${readableError(error)}';
    }

    final gen = _generation;
    // A cluster switch meanwhile makes the result stale. The switch then
    // owns _isRefreshing, so a stale result must not touch it either.
    bool isStale() => !_isCurrent(gen) || _selectedCluster?.id != cluster.id;

    _isRefreshing = true;
    notifyListeners();

    final ClusterSnapshot snapshot;
    try {
      snapshot = await _connection.loadSnapshot(cluster.id);
    } catch (error) {
      if (isStale()) return null;
      _isRefreshing = false;
      notifyListeners();
      return 'Refresh failed: ${readableError(error)}';
    }
    if (isStale()) return null;

    _snapshot = snapshot;
    _loadError = null;
    _staleError = null;
    _isRefreshing = false;
    _lastRefreshedAt = DateTime.now();
    notifyListeners();
    await _persist(snapshot);
    return null;
  }

  /// Advance to the next cluster in the list (wrapping). Loads cache then
  /// live for the target cluster in the same cache-then-live pattern as
  /// [bootstrap].
  Future<void> cycleCluster() async {
    final current = _selectedCluster;
    if (_clusters.length < 2 || _isLoading || current == null) return;

    final gen = ++_generation;
    final currentIndex = _clusters.indexOf(current);
    final nextCluster = _clusters[(currentIndex + 1) % _clusters.length];

    // Nothing of the previous cluster may stay on screen under the next
    // cluster's name.
    _selectedCluster = nextCluster;
    _snapshot = null;
    _lastRefreshedAt = null;
    _loadError = null;
    _staleError = null;
    _isLoading = true;
    notifyListeners();

    final cacheShown = await _showCached(gen, nextCluster);
    await _activate(gen, nextCluster, cacheShown: cacheShown);
  }

  /// Shows [target]'s cached snapshot (and [clusters], when given) if the
  /// cache holds a fresh one, dated by when it was cached. Returns whether
  /// it did.
  Future<bool> _showCached(
    int gen,
    ClusterProfile target, {
    List<ClusterProfile>? clusters,
  }) async {
    final SnapshotCacheEntry? cached;
    try {
      cached = await _store.loadSnapshotEntry(target.id, maxAge: _cacheMaxAge);
    } catch (_) {
      // Cache read failure is non-fatal — fall through to live fetch.
      return false;
    }
    if (cached == null || !_isCurrent(gen)) return false;

    if (clusters != null) _clusters = clusters;
    _selectedCluster = target;
    _snapshot = cached.snapshot;
    _lastRefreshedAt = cached.cachedAt;
    _loadError = null;
    _staleError = null;
    _isLoading = false;
    _isRefreshing = true;
    notifyListeners();
    return true;
  }

  /// Live-fetches [target]'s snapshot and makes it (with [clusters], when
  /// given) the session state. The one load path behind [bootstrap] and
  /// [cycleCluster]; with [cacheShown], a failed fetch keeps the cached
  /// snapshot on screen and reports [staleError] instead of [loadError].
  Future<void> _activate(
    int gen,
    ClusterProfile target, {
    List<ClusterProfile>? clusters,
    required bool cacheShown,
  }) async {
    final ClusterSnapshot snapshot;
    try {
      snapshot = await _connection.loadSnapshot(target.id);
    } catch (error) {
      // Keep the live list and the failed cluster selected, so Switch
      // Cluster can move past it and Retry re-targets it rather than
      // re-running bootstrap into the same cluster. With cache shown, the
      // cached list and selection already allow that.
      if (clusters != null && !cacheShown && _isCurrent(gen)) {
        _clusters = clusters;
        _selectedCluster = target;
      }
      _fail(gen, error, cacheShown: cacheShown);
      return;
    }
    if (!_isCurrent(gen)) return;

    if (clusters != null) _clusters = clusters;
    _selectedCluster = target;
    _snapshot = snapshot;
    _loadError = null;
    _staleError = null;
    _isLoading = false;
    _isRefreshing = false;
    _lastRefreshedAt = DateTime.now();
    notifyListeners();
    await _persist(snapshot, clusters: clusters);
  }

  /// Caches a live result that is already on screen. Best-effort: the cache
  /// only speeds up the next start, so a failed write must not turn a
  /// successful fetch into an error.
  Future<void> _persist(
    ClusterSnapshot snapshot, {
    List<ClusterProfile>? clusters,
  }) async {
    try {
      if (clusters != null) await _store.saveProfiles(clusters);
      await _store.saveSnapshot(snapshot);
    } catch (error) {
      debugPrint('ClusterOrbit: snapshot cache write failed: $error');
    }
  }

  void _fail(int gen, Object error, {required bool cacheShown}) {
    if (!_isCurrent(gen)) return;
    if (cacheShown) {
      _staleError = error;
    } else {
      _loadError = error;
    }
    _isLoading = false;
    _isRefreshing = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _relativeTimeTicker?.cancel();
    _autoRefreshTimer?.cancel();
    super.dispose();
  }
}
