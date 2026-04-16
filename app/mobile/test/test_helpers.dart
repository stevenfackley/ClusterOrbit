import 'dart:ui';

import 'package:clusterorbit_mobile/app/clusterorbit_app.dart';
import 'package:clusterorbit_mobile/core/cluster_domain/cluster_models.dart';
import 'package:clusterorbit_mobile/core/connectivity/cluster_connection.dart';
import 'package:clusterorbit_mobile/core/connectivity/sample_cluster_data.dart';
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
    ClusterOrbitApp(connection: connection ?? TestClusterConnection()),
  );
  await tester.pumpAndSettle();
}

Future<void> resetTestSurface(WidgetTester tester) async {
  tester.view.resetPhysicalSize();
  tester.view.resetDevicePixelRatio();
  await tester.pump();
}

final class TestClusterConnection implements ClusterConnection {
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
}
