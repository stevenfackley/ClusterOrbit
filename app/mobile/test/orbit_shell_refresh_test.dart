import 'dart:async';

import 'package:clusterorbit_mobile/app/clusterorbit_app.dart';
import 'package:clusterorbit_mobile/core/cluster_domain/cluster_models.dart';
import 'package:clusterorbit_mobile/core/connectivity/cluster_connection.dart';
import 'package:clusterorbit_mobile/core/connectivity/sample_cluster_data.dart';
import 'package:clusterorbit_mobile/core/sync_cache/snapshot_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'shows Refreshing badge while live fetch runs after cache shown',
    (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1366, 1024);

      final profiles = SampleClusterData.profilesFor(ConnectionMode.direct);
      final cachedSnapshot = SampleClusterData.snapshotFor(profiles.first);
      final liveCompleter = Completer<ClusterSnapshot>();

      final connection = _ControllableConnection(
        profiles: profiles,
        loadSnapshotFuture: () => liveCompleter.future,
      );
      final store = _CachedStore(profiles: profiles, snapshot: cachedSnapshot);

      await tester.pumpWidget(ClusterOrbitApp(
        connection: connection,
        store: store,
      ));
      // Flush cache read but not the awaiting live call.
      await tester.pump();
      await tester.pump();

      expect(find.text('Refreshing'), findsOneWidget);

      // Complete the live fetch, badge should disappear.
      liveCompleter.complete(cachedSnapshot);
      await tester.pumpAndSettle();

      expect(find.text('Refreshing'), findsNothing);

      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      await tester.pump();
    },
  );
}

final class _ControllableConnection implements ClusterConnection {
  _ControllableConnection({
    required this.profiles,
    required this.loadSnapshotFuture,
  });

  final List<ClusterProfile> profiles;
  final Future<ClusterSnapshot> Function() loadSnapshotFuture;

  @override
  ConnectionMode get mode => ConnectionMode.direct;

  @override
  Future<List<ClusterProfile>> listClusters() async => profiles;

  @override
  Future<ClusterSnapshot> loadSnapshot(String clusterId) =>
      loadSnapshotFuture();

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
