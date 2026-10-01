import 'package:clusterorbit_mobile/core/cluster_domain/cluster_models.dart';
import 'package:clusterorbit_mobile/core/connectivity/cluster_connection.dart';
import 'package:clusterorbit_mobile/core/connectivity/sample_cluster_data.dart';
import 'package:clusterorbit_mobile/core/theme/clusterorbit_theme.dart';
import 'package:clusterorbit_mobile/features/topology/drain_progress_dialog.dart';
import 'package:clusterorbit_mobile/features/topology/entity_detail_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

/// A gateway mutation parked for two-person approval must read as pending:
/// no "Requested …" success text, not styled as success or failure, and no
/// drain progress dialog polling an approval id as if it were a job id.
void main() {
  final snapshot = SampleClusterData.snapshotFor(
      SampleClusterData.profilesFor(ConnectionMode.gateway).first);
  final theme = ClusterOrbitTheme.dark();
  final palette = theme.extension<ClusterOrbitPalette>()!;

  /// A gateway connection whose every mutation is parked as [requestId].
  RecordingClusterConnection parking(String op, String requestId) =>
      RecordingClusterConnection(mode: ConnectionMode.gateway)
        ..mutationError = ApprovalPendingException(
            PendingApproval(id: requestId, op: op, targetId: 'target'));

  Widget host(Object entity, ClusterConnection connection) => MaterialApp(
        theme: theme,
        home: Scaffold(
          body: EntityDetailPanel(
            entity: entity,
            palette: palette,
            onDismiss: () {},
            connection: connection,
            clusterId: snapshot.profile.id,
          ),
        ),
      );

  // The outcome is also echoed in a SnackBar; assert the panel's own line.
  Finder inPanel(String text) => find.descendant(
      of: find.byType(EntityDetailPanel), matching: find.text(text));

  testWidgets('a parked scale shows awaiting approval, not success',
      (tester) async {
    final connection = parking('scale', 'apr-scale');
    final deployment =
        snapshot.workloads.firstWhere((w) => w.kind == WorkloadKind.deployment);
    await tester.pumpWidget(host(deployment, connection));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Scale'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '3');
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();

    expect(connection.callsTo('scaleWorkload'), hasLength(1));
    final line =
        inPanel('Awaiting second-operator approval (request apr-scale)');
    expect(line, findsOneWidget);
    final color = tester.widget<Text>(line).style?.color;
    expect(color, palette.warning);
    expect(color, isNot(palette.accentTeal));
    expect(color, isNot(theme.colorScheme.error));
    expect(find.textContaining('Requested scale'), findsNothing);
    expect(find.textContaining('Scale failed'), findsNothing);
  });

  testWidgets('a parked drain shows awaiting approval and opens no dialog',
      (tester) async {
    final connection = parking('drain', 'apr-drain');
    await tester.pumpWidget(host(snapshot.nodes.first, connection));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Drain'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Drain'));
    await tester.pumpAndSettle();

    expect(connection.callsTo('startDrain'), hasLength(1));
    expect(inPanel('Awaiting second-operator approval (request apr-drain)'),
        findsOneWidget);
    expect(find.byType(DrainProgressDialog), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
    expect(connection.callsTo('drainStatus'), isEmpty);
    expect(find.textContaining('Started draining'), findsNothing);
  });
}
