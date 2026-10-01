import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/cluster_domain/cluster_models.dart';
import '../../core/connectivity/cluster_connection.dart';
import '../../core/sync_cache/snapshot_store.dart';

/// Recent events for one topology entity at a time: cached events first
/// (when a store is given), then a live fetch, then a live re-fetch every
/// [pollInterval] until another entity is loaded or this is disposed.
class EntityEventsController extends ChangeNotifier {
  EntityEventsController({
    this.pollInterval = const Duration(seconds: 30),
    this.cacheMaxAge = const Duration(minutes: 5),
  });

  final Duration pollInterval;
  final Duration cacheMaxAge;

  List<ClusterEvent>? _events;
  bool _isSupported = false;
  bool _isLoading = false;
  bool _isRefreshing = false;
  Object? _error;
  Timer? _pollTimer;
  bool _disposed = false;

  /// Bumped by every [load]; responses for an older generation are dropped.
  int _generation = 0;
  _EntityRef? _ref;
  ClusterConnection? _connection;
  String? _clusterId;
  SnapshotStore? _store;
  String? _profileId;

  /// Null until the first cached or live events arrive.
  List<ClusterEvent>? get events => _events;

  /// False without a connection and cluster: there is nothing to load.
  bool get isSupported => _isSupported;

  /// Loading with nothing to show yet.
  bool get isLoading => _isLoading;

  /// A live fetch is under way while events are already shown.
  bool get isRefreshing => _isRefreshing;

  /// The first load's failure; later failures keep the events shown.
  Object? get error => _error;

  /// Starts over for [entity], dropping the previous entity's events and
  /// any of its fetches still in flight.
  void load({
    required Object entity,
    required ClusterConnection? connection,
    required String? clusterId,
    SnapshotStore? store,
    String? profileId,
  }) {
    _pollTimer?.cancel();
    _pollTimer = null;
    final generation = ++_generation;
    _ref = _entityRef(entity);
    _connection = connection;
    _clusterId = clusterId;
    _store = store;
    _profileId = profileId;
    _events = null;
    _isRefreshing = false;
    _error = null;

    final ref = _ref;
    if (connection == null || clusterId == null || ref == null) {
      _isSupported = false;
      _isLoading = false;
      notifyListeners();
      return;
    }

    _isSupported = true;
    _isLoading = true;
    notifyListeners();

    unawaited(_loadCachedThenLive(generation, ref));
    _pollTimer = Timer.periodic(pollInterval, (_) {
      unawaited(_refreshLive(generation, ref));
    });
  }

  /// Re-fetches live events now.
  Future<void> refresh() async {
    final ref = _ref;
    if (!_isSupported || ref == null) return;
    await _refreshLive(_generation, ref);
  }

  @override
  void dispose() {
    _disposed = true;
    _pollTimer?.cancel();
    super.dispose();
  }

  bool _isCurrent(int generation) => !_disposed && generation == _generation;

  Future<void> _loadCachedThenLive(int generation, _EntityRef ref) async {
    final store = _store;
    final profileId = _profileId;

    if (store != null && profileId != null) {
      try {
        final cached = await store.loadEvents(
          profileId: profileId,
          kind: ref.kind,
          objectName: ref.name,
          namespace: ref.namespace,
          maxAge: cacheMaxAge,
        );
        if (!_isCurrent(generation)) return;
        if (cached != null) {
          _events = cached;
          _isLoading = false;
          _isRefreshing = true;
          _error = null;
          notifyListeners();
        }
      } catch (_) {
        // Cache read failure is non-fatal — fall through to live fetch.
      }
    }

    await _refreshLive(generation, ref);
  }

  Future<void> _refreshLive(int generation, _EntityRef ref) async {
    final connection = _connection;
    final clusterId = _clusterId;
    if (connection == null || clusterId == null) return;

    if (_isCurrent(generation) && _events != null) {
      _isRefreshing = true;
      notifyListeners();
    }

    try {
      final events = await connection.loadEvents(
        clusterId: clusterId,
        kind: ref.kind,
        objectName: ref.name,
        namespace: ref.namespace,
      );
      if (!_isCurrent(generation)) return;

      final store = _store;
      final profileId = _profileId;
      if (store != null && profileId != null) {
        try {
          await store.saveEvents(
            profileId: profileId,
            kind: ref.kind,
            objectName: ref.name,
            namespace: ref.namespace,
            events: events,
          );
        } catch (_) {
          // Cache write failure is non-fatal.
        }
      }

      if (!_isCurrent(generation)) return;
      _events = events;
      _isLoading = false;
      _isRefreshing = false;
      _error = null;
      notifyListeners();
    } catch (error) {
      if (!_isCurrent(generation)) return;
      _isLoading = false;
      _isRefreshing = false;
      if (_events == null) _error = error;
      notifyListeners();
    }
  }

  static _EntityRef? _entityRef(Object entity) => switch (entity) {
        ClusterNode n => _EntityRef(TopologyEntityKind.node, n.name, null),
        ClusterWorkload w =>
          _EntityRef(TopologyEntityKind.workload, w.name, w.namespace),
        ClusterService s =>
          _EntityRef(TopologyEntityKind.service, s.name, s.namespace),
        _ => null,
      };
}

class _EntityRef {
  const _EntityRef(this.kind, this.name, this.namespace);
  final TopologyEntityKind kind;
  final String name;
  final String? namespace;
}
