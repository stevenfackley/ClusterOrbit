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
    'shows "Updated just now" after successful live fetch',
    (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1366, 1024);

      final profiles = SampleClusterData.profilesFor(ConnectionMode.direct);
      final snapshot = SampleClusterData.snapshotFor(profiles.first);
      final connection = _CountingConnection(
        profiles: profiles,
        snapshot: snapshot,
      );
      final store = _NoopStore();

      await tester.pumpWidget(ClusterOrbitApp(
        connection: connection,
        store: store,
      ));
      await tester.pumpAndSettle();

      expect(find.textContaining('Updated'), findsOneWidget);
      expect(find.text('Refreshing'), findsNothing);

      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      await tester.pump();
    },
  );

  testWidgets(
    'tapping the Updated indicator triggers a new loadSnapshot call',
    (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1366, 1024);

      final profiles = SampleClusterData.profilesFor(ConnectionMode.direct);
      final snapshot = SampleClusterData.snapshotFor(profiles.first);
      final connection = _CountingConnection(
        profiles: profiles,
        snapshot: snapshot,
      );
      final store = _NoopStore();

      await tester.pumpWidget(ClusterOrbitApp(
        connection: connection,
        store: store,
      ));
      await tester.pumpAndSettle();

      final initialCalls = connection.loadSnapshotCalls;
      expect(initialCalls, greaterThanOrEqualTo(1));

      await tester.tap(find.byIcon(Icons.refresh));
      await tester.pumpAndSettle();

      expect(connection.loadSnapshotCalls, initialCalls + 1);

      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      await tester.pump();
    },
  );
}

final class _CountingConnection implements ClusterConnection {
  _CountingConnection({required this.profiles, required this.snapshot});

  final List<ClusterProfile> profiles;
  final ClusterSnapshot snapshot;
  int loadSnapshotCalls = 0;

  @override
  ConnectionMode get mode => ConnectionMode.direct;

  @override
  Future<List<ClusterProfile>> listClusters() async => profiles;

  @override
  Future<ClusterSnapshot> loadSnapshot(String clusterId) async {
    loadSnapshotCalls++;
    return snapshot;
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

final class _NoopStore implements SnapshotStore {
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
