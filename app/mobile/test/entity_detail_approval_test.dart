import 'package:clusterorbit_mobile/core/cluster_domain/cluster_models.dart';
import 'package:clusterorbit_mobile/core/connectivity/cluster_connection.dart';
import 'package:clusterorbit_mobile/core/connectivity/sample_cluster_data.dart';
import 'package:clusterorbit_mobile/core/theme/clusterorbit_theme.dart';
import 'package:clusterorbit_mobile/features/topology/entity_detail_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A gateway mutation parked for two-person approval must read as pending:
/// no "Requested …" success text and no drain progress dialog polling an
/// approval id as if it were a job id.
void main() {
  final snapshot = SampleClusterData.snapshotFor(
      SampleClusterData.profilesFor(ConnectionMode.gateway).first);

  Widget host(Object entity) {
    final theme = ClusterOrbitTheme.dark();
    return MaterialApp(
      theme: theme,
      home: Scaffold(
        body: EntityDetailPanel(
          entity: entity,
          palette: theme.extension<ClusterOrbitPalette>()!,
          onDismiss: () {},
          connection: const _ParkingConnection(),
          clusterId: snapshot.profile.id,
        ),
      ),
    );
  }

  testWidgets('a parked scale shows awaiting approval, not success',
      (tester) async {
    final deployment =
        snapshot.workloads.firstWhere((w) => w.kind == WorkloadKind.deployment);
    await tester.pumpWidget(host(deployment));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Scale'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '3');
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();

    expect(find.text('Awaiting second-operator approval (apr-scale)'),
        findsOneWidget);
    expect(find.textContaining('Requested scale'), findsNothing);
  });

  testWidgets('a parked drain shows awaiting approval and opens no dialog',
      (tester) async {
    await tester.pumpWidget(host(snapshot.nodes.first));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Drain'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Drain'));
    await tester.pumpAndSettle();

    expect(find.text('Awaiting second-operator approval (apr-drain)'),
        findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
  });
}

/// Gateway-mode connection whose every mutation is parked for approval.
final class _ParkingConnection implements ClusterConnection {
  const _ParkingConnection();

  Never _park(String op, String targetId) => throw ApprovalPendingException(
      PendingApproval(id: 'apr-$op', op: op, targetId: targetId));

  @override
  ConnectionMode get mode => ConnectionMode.gateway;

  @override
  Future<List<ClusterProfile>> listClusters() async =>
      SampleClusterData.profilesFor(mode);

  @override
  Future<ClusterSnapshot> loadSnapshot(String clusterId) async =>
      SampleClusterData.snapshotFor(SampleClusterData.profilesFor(mode).first);

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
  }) async =>
      _park('scale', workloadId);

  @override
  Future<void> restartWorkload({
    required String clusterId,
    required String workloadId,
  }) async =>
      _park('restart', workloadId);

  @override
  Future<void> setNodeSchedulable({
    required String clusterId,
    required String nodeId,
    required bool schedulable,
  }) async =>
      _park('cordon', nodeId);

  @override
  Future<DrainJob> startDrain({
    required String clusterId,
    required String nodeId,
  }) async =>
      _park('drain', nodeId);

  @override
  Future<DrainJob> drainStatus({
    required String clusterId,
    required String nodeId,
    required String jobId,
  }) async =>
      throw StateError('no drain job exists for $jobId');
}
