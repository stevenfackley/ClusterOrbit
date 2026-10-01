import 'package:clusterorbit_mobile/core/cluster_domain/cluster_models.dart';
import 'package:clusterorbit_mobile/core/connectivity/sample_cluster_data.dart';
import 'package:clusterorbit_mobile/core/theme/clusterorbit_theme.dart';
import 'package:clusterorbit_mobile/features/topology/entity_detail_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'real_fonts.dart';
import 'test_helpers.dart';

/// Topology layout checks that depend on text metrics, measured with the
/// real Roboto rather than the 1em-per-glyph test font.
void main() {
  setUpAll(loadRoboto);

  final snapshot = SampleClusterData.snapshotFor(
      SampleClusterData.profilesFor(ConnectionMode.direct).first);

  void setSurface(WidgetTester tester, Size size) {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = size;
    tester.view.padding = FakeViewPadding.zero;
    tester.view.viewPadding = FakeViewPadding.zero;
    addTearDown(tester.view.reset);
  }

  testWidgets(
      'scale dialog: the replica field stays reachable with the keyboard up '
      'on a landscape phone', (tester) async {
    setSurface(tester, const Size(844, 390));
    final deployment =
        snapshot.workloads.firstWhere((w) => w.kind == WorkloadKind.deployment);
    final theme = ClusterOrbitTheme.dark();
    await tester.pumpWidget(MaterialApp(
      theme: theme,
      home: Scaffold(
        body: SingleChildScrollView(
          child: EntityDetailPanel(
            entity: deployment,
            palette: theme.extension<ClusterOrbitPalette>()!,
            onDismiss: () {},
            connection: RecordingClusterConnection(),
            clusterId: snapshot.profile.id,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    final scale = find.widgetWithText(TextButton, 'Scale');
    await tester.ensureVisible(scale);
    await tester.pumpAndSettle();
    await tester.tap(scale);
    await tester.pumpAndSettle();

    tester.view.viewInsets = const FakeViewPadding(bottom: 200);
    await tester.pumpAndSettle();

    final field = find.byType(TextField);
    expect(find.text('Current: ${deployment.desiredReplicas}'), findsOneWidget);
    final scrollables = find.descendant(
        of: find.byType(AlertDialog), matching: find.byType(Scrollable));
    expect(scrollables, findsWidgets,
        reason: 'the dialog content scrolls instead of collapsing');
    final viewport = tester.state<ScrollableState>(scrollables.first);
    expect(viewport.position.viewportDimension,
        greaterThanOrEqualTo(tester.getSize(field).height));

    await tester.ensureVisible(field);
    await tester.pumpAndSettle();
    expect(field.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
