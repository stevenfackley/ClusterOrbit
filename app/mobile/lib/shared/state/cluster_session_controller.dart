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

  /// Load cache first (if fresh), then live-fetch the first cluster.
  /// Safe to call once in initState.
  Future<void> bootstrap() async {
    bool cacheShown = false;

    try {
      final cachedProfiles = await _store.loadProfiles(maxAge: _cacheMaxAge);
      if (cachedProfiles.isNotEmpty) {
        final cachedSnapshot = await _store.loadSnapshot(
          cachedProfiles.first.id,
          maxAge: _cacheMaxAge,
        );
        if (cachedSnapshot != null && !_disposed) {
          _clusters = cachedProfiles;
          _selectedCluster = cachedProfiles.first;
          _snapshot = cachedSnapshot;
          _loadError = null;
          _isLoading = false;
          _isRefreshing = true;
          notifyListeners();
          cacheShown = true;
        }
      }
    } catch (_) {
      // Cache read failure is non-fatal — fall through to live fetch.
    }

    try {
      final clusters = await _connection.listClusters();
      if (clusters.isEmpty) {
        if (!_disposed) {
          _isLoading = false;
          _isRefreshing = false;
          notifyListeners();
        }
        return;
      }

      final selectedCluster = clusters.first;
      final snapshot = await _connection.loadSnapshot(selectedCluster.id);

      await _store.saveProfiles(clusters);
      await _store.saveSnapshot(snapshot);

      if (_disposed) return;

      _clusters = clusters;
      _selectedCluster = selectedCluster;
      _snapshot = snapshot;
      _loadError = null;
      _isLoading = false;
      _isRefreshing = false;
      _lastRefreshedAt = DateTime.now();
      notifyListeners();
    } catch (error) {
      if (_disposed) return;

      if (cacheShown) {
        _isRefreshing = false;
        notifyListeners();
        return;
      }

      _loadError = error;
      _isLoading = false;
      _isRefreshing = false;
      notifyListeners();
    }
  }

  /// Re-fetch the snapshot for the currently selected cluster. Returns an
  /// error string if the refresh failed and no-ops if one is already in
  /// flight, so callers can surface a SnackBar without peeking at state.
  Future<String?> refresh() async {
    final cluster = _selectedCluster;
    if (cluster == null || _isRefreshing || _disposed) return null;

    _isRefreshing = true;
    notifyListeners();

    try {
      final snapshot = await _connection.loadSnapshot(cluster.id);
      await _store.saveSnapshot(snapshot);

      if (_disposed) return null;
      _snapshot = snapshot;
      _loadError = null;
      _isRefreshing = false;
      _lastRefreshedAt = DateTime.now();
      notifyListeners();
      return null;
    } catch (error) {
      if (_disposed) return null;
      _isRefreshing = false;
      notifyListeners();
      return 'Refresh failed: $error';
    }
  }

  /// Advance to the next cluster in the list (wrapping). Loads cache then
  /// live for the target cluster in the same cache-then-live pattern as
  /// [bootstrap].
  Future<void> cycleCluster() async {
    if (_clusters.length < 2 || _isLoading || _selectedCluster == null) {
      return;
    }

    final currentIndex = _clusters.indexOf(_selectedCluster!);
    final nextCluster = _clusters[(currentIndex + 1) % _clusters.length];

    _isLoading = true;
    _selectedCluster = nextCluster;
    notifyListeners();

    bool cacheShown = false;
    try {
      final cachedSnapshot = await _store.loadSnapshot(
        nextCluster.id,
        maxAge: _cacheMaxAge,
      );
      if (cachedSnapshot != null && !_disposed) {
        _snapshot = cachedSnapshot;
        _loadError = null;
        _isLoading = false;
        _isRefreshing = true;
        notifyListeners();
        cacheShown = true;
      }
    } catch (_) {
      // Non-fatal — fall through to live fetch.
    }

    try {
      final snapshot = await _connection.loadSnapshot(nextCluster.id);
      await _store.saveSnapshot(snapshot);

      if (_disposed) return;

      _snapshot = snapshot;
      _loadError = null;
      _isLoading = false;
      _isRefreshing = false;
      _lastRefreshedAt = DateTime.now();
      notifyListeners();
    } catch (error) {
      if (_disposed) return;

      if (cacheShown) {
        _isRefreshing = false;
        notifyListeners();
        return;
      }

      _loadError = error;
      _isLoading = false;
      _isRefreshing = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _relativeTimeTicker?.cancel();
    _autoRefreshTimer?.cancel();
    super.dispose();
  }
}
