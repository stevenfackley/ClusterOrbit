import 'package:clusterorbit_mobile/core/cluster_domain/cluster_models.dart';
import 'package:clusterorbit_mobile/core/connectivity/sample_cluster_data.dart';
import 'package:clusterorbit_mobile/core/theme/clusterorbit_theme.dart';
import 'package:clusterorbit_mobile/features/topology/entity_detail_panel.dart';
import 'package:clusterorbit_mobile/features/topology/topology_orbs.dart';
import 'package:clusterorbit_mobile/features/topology/topology_workspace.dart';
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

  Future<void> showPhoneMap(WidgetTester tester) async {
    final toggle = find.byKey(const ValueKey('phone-view-toggle'));
    await tester.tap(find.descendant(of: toggle, matching: find.text('Map')));
    await tester.pumpAndSettle();
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

  testWidgets('map overlays: left off a portrait phone canvas', (tester) async {
    setSurface(tester, const Size(390, 844));
    await pumpClusterOrbitApp(tester);
    await showPhoneMap(tester);

    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(find.byType(LegendCard), findsNothing);
    expect(find.byType(MiniStatusCard), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('map overlays: side by side inside a tablet canvas',
      (tester) async {
    setSurface(tester, const Size(1280, 800));
    await pumpClusterOrbitApp(tester);

    final canvas = tester.getRect(find.byType(InteractiveViewer));
    final legend = tester.getRect(find.byType(LegendCard));
    final status = tester.getRect(find.byType(MiniStatusCard));
    expect(legend.overlaps(status), isFalse);
    for (final card in [legend, status]) {
      expect(canvas.contains(card.topLeft), isTrue, reason: '$card');
      expect(canvas.contains(card.bottomRight - const Offset(1, 1)), isTrue,
          reason: '$card');
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'phone map: the header is one badge and the filter chips, so the '
      'canvas gets the height', (tester) async {
    setSurface(tester, const Size(390, 844));
    await pumpClusterOrbitApp(tester);
    await showPhoneMap(tester);

    final workspace = find.byType(TopologyWorkspace);
    expect(find.descendant(of: workspace, matching: find.text('Cluster Map')),
        findsNothing,
        reason: 'the AppBar already says it');
    expect(find.byType(SummaryChip), findsNothing);
    expect(find.byType(ModeBadge), findsOneWidget);
    for (final (label, count) in [
      ('Nodes', snapshot.nodes.length),
      ('Workloads', snapshot.workloads.length),
      ('Services', snapshot.services.length),
    ]) {
      expect(find.widgetWithText(FilterChip, '$label $count'), findsOneWidget);
    }

    // 406 tall under the title row and the five summary chips.
    expect(tester.getSize(find.byType(InteractiveViewer)).height,
        greaterThan(430));
    expect(tester.takeException(), isNull);
  });
}
