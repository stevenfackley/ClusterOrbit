import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/cluster_domain/cluster_models.dart';
import '../../core/connectivity/cluster_connection.dart';
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
        if (_selectedCluster == null) return;
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

  /// Re-fetch the snapshot for the currently selected cluster. Returns an
  /// error string if the refresh failed and no-ops if one is already in
  /// flight, so callers can surface a SnackBar without peeking at state.
  Future<String?> refresh() async {
    final cluster = _selectedCluster;
    if (cluster == null || _isRefreshing || _disposed) return null;

    final gen = _generation;
    // A cluster switch meanwhile makes the result stale. The switch then
    // owns _isRefreshing, so a stale result must not touch it either.
    bool isStale() => !_isCurrent(gen) || _selectedCluster?.id != cluster.id;

    _isRefreshing = true;
    notifyListeners();

    try {
      final snapshot = await _connection.loadSnapshot(cluster.id);
      await _store.saveSnapshot(snapshot);

      if (isStale()) return null;
      _snapshot = snapshot;
      _loadError = null;
      _isRefreshing = false;
      _lastRefreshedAt = DateTime.now();
      notifyListeners();
      return null;
    } catch (error) {
      if (isStale()) return null;
      _isRefreshing = false;
      notifyListeners();
      return 'Refresh failed: $error';
    }
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
    _isLoading = true;
    notifyListeners();

    final cacheShown = await _showCached(gen, nextCluster);
    await _activate(gen, nextCluster, cacheShown: cacheShown);
  }

  /// Shows [target]'s cached snapshot (and [clusters], when given) if the
  /// cache holds a fresh one. Returns whether it did.
  Future<bool> _showCached(
    int gen,
    ClusterProfile target, {
    List<ClusterProfile>? clusters,
  }) async {
    final ClusterSnapshot? cached;
    try {
      cached = await _store.loadSnapshot(target.id, maxAge: _cacheMaxAge);
    } catch (_) {
      // Cache read failure is non-fatal — fall through to live fetch.
      return false;
    }
    if (cached == null || !_isCurrent(gen)) return false;

    if (clusters != null) _clusters = clusters;
    _selectedCluster = target;
    _snapshot = cached;
    _loadError = null;
    _isLoading = false;
    _isRefreshing = true;
    notifyListeners();
    return true;
  }

  /// Live-fetches [target]'s snapshot and makes it (with [clusters], when
  /// given) the session state. The one load path behind [bootstrap] and
  /// [cycleCluster]; with [cacheShown], a failed fetch keeps the cached
  /// snapshot on screen instead of raising [loadError].
  Future<void> _activate(
    int gen,
    ClusterProfile target, {
    List<ClusterProfile>? clusters,
    required bool cacheShown,
  }) async {
    try {
      final snapshot = await _connection.loadSnapshot(target.id);
      if (clusters != null) await _store.saveProfiles(clusters);
      await _store.saveSnapshot(snapshot);

      if (!_isCurrent(gen)) return;
      if (clusters != null) _clusters = clusters;
      _selectedCluster = target;
      _snapshot = snapshot;
      _loadError = null;
      _isLoading = false;
      _isRefreshing = false;
      _lastRefreshedAt = DateTime.now();
      notifyListeners();
    } catch (error) {
      _fail(gen, error, cacheShown: cacheShown);
    }
  }

  void _fail(int gen, Object error, {required bool cacheShown}) {
    if (!_isCurrent(gen)) return;
    if (!cacheShown) _loadError = error;
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
