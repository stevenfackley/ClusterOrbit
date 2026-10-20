import 'package:clusterorbit_mobile/core/cluster_domain/cluster_models.dart';
import 'package:clusterorbit_mobile/core/connectivity/cluster_connection.dart';
import 'package:clusterorbit_mobile/core/connectivity/cluster_connection_factory.dart';
import 'package:clusterorbit_mobile/core/connectivity/sample_cluster_data.dart';
import 'package:clusterorbit_mobile/core/theme/clusterorbit_theme.dart';
import 'package:clusterorbit_mobile/features/topology/entity_detail_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

/// The panel offers exactly the actions the connection supports, instead of
/// inferring them from its mode.
void main() {
  final snapshot = SampleClusterData.snapshotFor(
      SampleClusterData.profilesFor(ConnectionMode.direct).first);
  final node = snapshot.nodes.first;
  final deployment =
      snapshot.workloads.firstWhere((w) => w.kind == WorkloadKind.deployment);
  const actions = ['Cordon', 'Uncordon', 'Drain', 'Scale', 'Restart'];
  const noActionsLine = 'Actions are available on live connections';

  Future<void> showPanel(
    WidgetTester tester,
    Object entity,
    ClusterConnection connection,
  ) async {
    final theme = ClusterOrbitTheme.dark();
    await tester.pumpWidget(MaterialApp(
      theme: theme,
      home: Scaffold(
        body: SingleChildScrollView(
          child: EntityDetailPanel(
            entity: entity,
            palette: theme.extension<ClusterOrbitPalette>()!,
            onDismiss: () {},
            connection: connection,
            clusterId: snapshot.profile.id,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  for (final (label, entity) in [('node', node), ('deployment', deployment)]) {
    testWidgets('sample data: a $label offers no actions, and says why',
        (tester) async {
      await showPanel(tester, entity, const SampleClusterConnection());

      for (final action in actions) {
        expect(find.text(action), findsNothing, reason: action);
      }
      expect(find.text(noActionsLine), findsOneWidget);
    });
  }

  testWidgets('gateway: all four actions are offered', (tester) async {
    final gateway = RecordingClusterConnection(mode: ConnectionMode.gateway);

    await showPanel(tester, node, gateway);
    expect(find.text('Cordon'), findsOneWidget);
    expect(find.text('Drain'), findsOneWidget);

    await showPanel(tester, deployment, gateway);
    expect(find.text('Scale'), findsOneWidget);
    expect(find.text('Restart'), findsOneWidget);
    expect(find.text(noActionsLine), findsNothing);
  });

  testWidgets('actions follow supportedOperations, not the mode',
      (tester) async {
    await showPanel(
      tester,
      node,
      RecordingClusterConnection(
        mode: ConnectionMode.gateway,
        supportedOperations: const {ClusterOperation.cordon},
      ),
    );
    expect(find.text('Cordon'), findsOneWidget);
    expect(find.text('Drain'), findsNothing);

    await showPanel(
      tester,
      deployment,
      RecordingClusterConnection(
        supportedOperations: const {ClusterOperation.restart},
      ),
    );
    expect(find.text('Restart'), findsOneWidget);
    expect(find.text('Scale'), findsNothing);
    expect(find.text(noActionsLine), findsNothing);
  });
}
