import 'dart:ui';

import 'package:clusterorbit_mobile/app/clusterorbit_app.dart';
import 'package:clusterorbit_mobile/core/cluster_domain/cluster_models.dart';
import 'package:clusterorbit_mobile/core/connectivity/cluster_connection.dart';
import 'package:clusterorbit_mobile/core/connectivity/sample_cluster_data.dart';
import 'package:clusterorbit_mobile/core/sync_cache/snapshot_store.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> pumpClusterOrbitApp(
  WidgetTester tester, {
  Size? size,
  ClusterConnection? connection,
}) async {
  if (size != null) {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = size;
  }

  await tester.pumpWidget(
    ClusterOrbitApp(
      connection: connection ?? TestClusterConnection(),
      store: const NoOpSnapshotStore(),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> resetTestSurface(WidgetTester tester) async {
  tester.view.resetPhysicalSize();
  tester.view.resetDevicePixelRatio();
  await tester.pump();
}

final class TestClusterConnection implements ClusterConnection {
  TestClusterConnection({
    List<ClusterEvent>? events,
    this.onScale,
  }) : _events = events;

  final List<ClusterEvent>? _events;
  final void Function(String clusterId, String workloadId, int replicas)?
      onScale;
  final List<ClusterProfile> _profiles =
      SampleClusterData.profilesFor(ConnectionMode.direct);

  @override
  ConnectionMode get mode => ConnectionMode.direct;

  @override
  Future<List<ClusterProfile>> listClusters() async => _profiles;

  @override
  Future<ClusterSnapshot> loadSnapshot(String clusterId) async {
    final profile = _profiles.firstWhere(
      (item) => item.id == clusterId,
      orElse: () => _profiles.first,
    );
    return SampleClusterData.snapshotFor(profile);
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
  }) async {
    if (_events != null) {
      return _events.take(limit).toList();
    }
    return SampleClusterData.eventsFor(kind: kind, objectName: objectName)
        .take(limit)
        .toList();
  }

  @override
  Future<void> scaleWorkload({
    required String clusterId,
    required String workloadId,
    required int replicas,
  }) async {
    onScale?.call(clusterId, workloadId, replicas);
  }
}

/// No-op store used in widget tests — prevents any SQLite I/O during test runs.
final class NoOpSnapshotStore implements SnapshotStore {
  const NoOpSnapshotStore();

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
