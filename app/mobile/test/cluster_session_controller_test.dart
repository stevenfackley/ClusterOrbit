import 'dart:async';

import 'package:clusterorbit_mobile/core/cluster_domain/cluster_models.dart';
import 'package:clusterorbit_mobile/core/connectivity/cluster_connection.dart';
import 'package:clusterorbit_mobile/core/connectivity/sample_cluster_data.dart';
import 'package:clusterorbit_mobile/core/sync_cache/snapshot_store.dart';
import 'package:clusterorbit_mobile/shared/state/cluster_session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ClusterSessionController.bootstrap', () {
    test('populates clusters + snapshot from live fetch', () async {
      final profiles = SampleClusterData.profilesFor(ConnectionMode.direct);
      final connection = _FakeConnection(profiles: profiles);
      final controller = ClusterSessionController(
        connection: connection,
        store: _EmptyStore(),
      );
      addTearDown(controller.dispose);

      expect(controller.isLoading, isTrue);
      await controller.bootstrap();

      expect(controller.isLoading, isFalse);
      expect(controller.isRefreshing, isFalse);
      expect(controller.clusters, equals(profiles));
      expect(controller.selectedCluster, equals(profiles.first));
      expect(controller.snapshot, isNotNull);
      expect(controller.lastRefreshedAt, isNotNull);
      expect(controller.loadError, isNull);
    });

    test('shows cache first, then live — isRefreshing bridges the gap',
        () async {
      final profiles = SampleClusterData.profilesFor(ConnectionMode.direct);
      final cachedSnapshot = SampleClusterData.snapshotFor(profiles.first);
      final liveCompleter = Completer<ClusterSnapshot>();

      final connection = _FakeConnection(
        profiles: profiles,
        loadSnapshotOverride: () => liveCompleter.future,
      );
      final store = _CachedStore(profiles: profiles, snapshot: cachedSnapshot);
      final controller = ClusterSessionController(
        connection: connection,
        store: store,
      );
      addTearDown(controller.dispose);

      final bootstrapFuture = controller.bootstrap();

      // Drain microtasks so the cache read + notify finishes.
      await Future<void>.delayed(Duration.zero);
      expect(controller.snapshot, equals(cachedSnapshot));
      expect(controller.isLoading, isFalse);
      expect(controller.isRefreshing, isTrue);

      liveCompleter.complete(cachedSnapshot);
      await bootstrapFuture;

      expect(controller.isRefreshing, isFalse);
      expect(controller.lastRefreshedAt, isNotNull);
    });

    test('cache preserved when live fetch errors after cache was shown',
        () async {
      final profiles = SampleClusterData.profilesFor(ConnectionMode.direct);
      final cachedSnapshot = SampleClusterData.snapshotFor(profiles.first);

      final connection = _FakeConnection(
        profiles: profiles,
        loadSnapshotOverride: () =>
            Future<ClusterSnapshot>.error(StateError('network down')),
      );
      final store = _CachedStore(profiles: profiles, snapshot: cachedSnapshot);
      final controller = ClusterSessionController(
        connection: connection,
        store: store,
      );
      addTearDown(controller.dispose);

      await controller.bootstrap();

      expect(controller.snapshot, equals(cachedSnapshot));
      expect(controller.isRefreshing, isFalse);
      expect(controller.loadError, isNull,
          reason: 'swallow live error when cache is visible');
    });

    test('loadError set when live fails and no cache available', () async {
      final profiles = SampleClusterData.profilesFor(ConnectionMode.direct);
      final connection = _FakeConnection(
        profiles: profiles,
        loadSnapshotOverride: () =>
            Future<ClusterSnapshot>.error(StateError('boom')),
      );
      final controller = ClusterSessionController(
        connection: connection,
        store: _EmptyStore(),
      );
      addTearDown(controller.dispose);

      await controller.bootstrap();

      expect(controller.loadError, isA<StateError>());
      expect(controller.isLoading, isFalse);
      expect(controller.isRefreshing, isFalse);
      expect(controller.snapshot, isNull);
    });

    test('empty cluster list leaves state idle without crashing', () async {
      final connection = _FakeConnection(profiles: const []);
      final controller = ClusterSessionController(
        connection: connection,
        store: _EmptyStore(),
      );
      addTearDown(controller.dispose);

      await controller.bootstrap();

      expect(controller.clusters, isEmpty);
      expect(controller.selectedCluster, isNull);
      expect(controller.snapshot, isNull);
      expect(controller.isRefreshing, isFalse);
      expect(controller.isLoading, isFalse,
          reason: 'must clear loading when there is nothing to load');
    });
  });

  group('ClusterSessionController.refresh', () {
    test('reloads snapshot + updates lastRefreshedAt', () async {
      final profiles = SampleClusterData.profilesFor(ConnectionMode.direct);
      final connection = _FakeConnection(profiles: profiles);
      final controller = ClusterSessionController(
        connection: connection,
        store: _EmptyStore(),
      );
      addTearDown(controller.dispose);

      await controller.bootstrap();
      final before = controller.lastRefreshedAt!;
      connection.loadSnapshotCallCount = 0;

      // Small wait so lastRefreshedAt changes measurably.
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final error = await controller.refresh();

      expect(error, isNull);
      expect(connection.loadSnapshotCallCount, 1);
      expect(controller.lastRefreshedAt!.isAfter(before), isTrue);
    });

    test('returns error string on failure; snapshot preserved', () async {
      final profiles = SampleClusterData.profilesFor(ConnectionMode.direct);
      var shouldFail = false;
      final connection = _FakeConnection(
        profiles: profiles,
        loadSnapshotOverride: () {
          if (shouldFail) {
            return Future<ClusterSnapshot>.error(StateError('offline'));
          }
          return Future.value(SampleClusterData.snapshotFor(profiles.first));
        },
      );
      final controller = ClusterSessionController(
        connection: connection,
        store: _EmptyStore(),
      );
      addTearDown(controller.dispose);

      await controller.bootstrap();
      final preRefreshSnapshot = controller.snapshot;

      shouldFail = true;
      final error = await controller.refresh();

      expect(error, contains('offline'));
      expect(controller.snapshot, same(preRefreshSnapshot));
      expect(controller.isRefreshing, isFalse);
    });

    test('no-op when no cluster selected', () async {
      final controller = ClusterSessionController(
        connection: _FakeConnection(profiles: const []),
        store: _EmptyStore(),
      );
      addTearDown(controller.dispose);

      final error = await controller.refresh();
      expect(error, isNull);
    });
  });

  group('ClusterSessionController.cycleCluster', () {
    test('advances selected cluster and loads new snapshot', () async {
      final profiles = SampleClusterData.profilesFor(ConnectionMode.direct);
      final connection = _FakeConnection(profiles: profiles);
      final controller = ClusterSessionController(
        connection: connection,
        store: _EmptyStore(),
      );
      addTearDown(controller.dispose);

      await controller.bootstrap();
      expect(controller.selectedCluster, equals(profiles.first));

      await controller.cycleCluster();
      expect(controller.selectedCluster, equals(profiles[1]));
      expect(controller.snapshot, isNotNull);
      expect(controller.isLoading, isFalse);
    });

    test('wraps around at end of cluster list', () async {
      final profiles = SampleClusterData.profilesFor(ConnectionMode.direct);
      final connection = _FakeConnection(profiles: profiles);
      final controller = ClusterSessionController(
        connection: connection,
        store: _EmptyStore(),
      );
      addTearDown(controller.dispose);

      await controller.bootstrap();
      for (var i = 0; i < profiles.length; i++) {
        await controller.cycleCluster();
      }
      expect(controller.selectedCluster, equals(profiles.first));
    });

    test('no-op when fewer than 2 clusters', () async {
      final single = [
        SampleClusterData.profilesFor(ConnectionMode.direct).first
      ];
      final connection = _FakeConnection(profiles: single);
      final controller = ClusterSessionController(
        connection: connection,
        store: _EmptyStore(),
      );
      addTearDown(controller.dispose);

      await controller.bootstrap();
      final before = controller.selectedCluster;
      await controller.cycleCluster();
      expect(controller.selectedCluster, same(before));
    });
  });

  group('autoRefreshInterval', () {
    test('fires periodic refresh while idle', () async {
      final profiles = SampleClusterData.profilesFor(ConnectionMode.direct);
      final connection = _FakeConnection(profiles: profiles);
      final controller = ClusterSessionController(
        connection: connection,
        store: _EmptyStore(),
        autoRefreshInterval: const Duration(milliseconds: 20),
      );
      addTearDown(controller.dispose);

      await controller.bootstrap();
      final baseline = connection.loadSnapshotCallCount;

      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(
        connection.loadSnapshotCallCount,
        greaterThan(baseline),
        reason: 'auto-refresh should have triggered loadSnapshot at least once',
      );
    });

    test('null interval disables auto-refresh', () async {
      final profiles = SampleClusterData.profilesFor(ConnectionMode.direct);
      final connection = _FakeConnection(profiles: profiles);
      final controller = ClusterSessionController(
        connection: connection,
        store: _EmptyStore(),
      );
      addTearDown(controller.dispose);

      await controller.bootstrap();
      final baseline = connection.loadSnapshotCallCount;

      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(connection.loadSnapshotCallCount, equals(baseline));
    });

    test('does not fire before cluster is selected', () async {
      // Bootstrap fails → no selected cluster → timer should not refresh.
      final connection = _FakeConnection(profiles: const []);
      final controller = ClusterSessionController(
        connection: connection,
        store: _EmptyStore(),
        autoRefreshInterval: const Duration(milliseconds: 20),
      );
      addTearDown(controller.dispose);

      await controller.bootstrap();
      final baseline = connection.loadSnapshotCallCount;

      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(connection.loadSnapshotCallCount, equals(baseline));
    });
  });

  test('notifyListeners fires on bootstrap completion', () async {
    final profiles = SampleClusterData.profilesFor(ConnectionMode.direct);
    final connection = _FakeConnection(profiles: profiles);
    final controller = ClusterSessionController(
      connection: connection,
      store: _EmptyStore(),
    );
    addTearDown(controller.dispose);

    var notifyCount = 0;
    controller.addListener(() => notifyCount++);

    await controller.bootstrap();
    expect(notifyCount, greaterThan(0));
  });
}

final class _FakeConnection implements ClusterConnection {
  _FakeConnection({
    required this.profiles,
    this.loadSnapshotOverride,
  });

  final List<ClusterProfile> profiles;
  final Future<ClusterSnapshot> Function()? loadSnapshotOverride;
  int loadSnapshotCallCount = 0;

  @override
  ConnectionMode get mode => ConnectionMode.direct;

  @override
  Future<List<ClusterProfile>> listClusters() async => profiles;

  @override
  Future<ClusterSnapshot> loadSnapshot(String clusterId) {
    loadSnapshotCallCount++;
    if (loadSnapshotOverride != null) return loadSnapshotOverride!();
    final profile = profiles.firstWhere(
      (p) => p.id == clusterId,
      orElse: () => profiles.first,
    );
    return Future.value(SampleClusterData.snapshotFor(profile));
  }

  @override
  Stream<ClusterSnapshot> watchSnapshot(String clusterId) async* {
    yield await loadSnapshot(clusterId);
  }

  @override
  Future<List<ClusterEvent>> loadEvents({
    required String clusterId,
    required TopologyEntityKind kind,
    required String objectName,
    String? namespace,
    int limit = 5,
  }) async =>
      const [];

  @override
  Future<void> scaleWorkload({
    required String clusterId,
    required String workloadId,
    required int replicas,
  }) async {}
}

final class _EmptyStore implements SnapshotStore {
  @override
  Future<List<ClusterProfile>> loadProfiles({Duration? maxAge}) async =>
      const [];

  @override
  Future<void> saveProfiles(List<ClusterProfile> profiles) async {}

  @override
  Future<ClusterSnapshot?> loadSnapshot(
    String profileId, {
    Duration? maxAge,
  }) async =>
      null;

  @override
  Future<void> saveSnapshot(ClusterSnapshot snapshot) async {}

  @override
  Future<List<ClusterEvent>?> loadEvents({
    required String profileId,
    required TopologyEntityKind kind,
    required String objectName,
    String? namespace,
    Duration? maxAge,
  }) async =>
      null;

  @override
  Future<void> saveEvents({
    required String profileId,
    required TopologyEntityKind kind,
    required String objectName,
    String? namespace,
    required List<ClusterEvent> events,
  }) async {}
}

final class _CachedStore implements SnapshotStore {
  _CachedStore({required this.profiles, required this.snapshot});

  final List<ClusterProfile> profiles;
  final ClusterSnapshot snapshot;

  @override
  Future<List<ClusterProfile>> loadProfiles({Duration? maxAge}) async =>
      profiles;

  @override
  Future<void> saveProfiles(List<ClusterProfile> profiles) async {}

  @override
  Future<ClusterSnapshot?> loadSnapshot(
    String profileId, {
    Duration? maxAge,
  }) async =>
      snapshot;

  @override
  Future<void> saveSnapshot(ClusterSnapshot snapshot) async {}

  @override
  Future<List<ClusterEvent>?> loadEvents({
    required String profileId,
    required TopologyEntityKind kind,
    required String objectName,
    String? namespace,
    Duration? maxAge,
  }) async =>
      null;

  @override
  Future<void> saveEvents({
    required String profileId,
    required TopologyEntityKind kind,
    required String objectName,
    String? namespace,
    required List<ClusterEvent> events,
  }) async {}
}
