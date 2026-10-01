import 'package:clusterorbit_mobile/core/cluster_domain/cluster_models.dart';
import 'package:clusterorbit_mobile/core/connectivity/sample_cluster_data.dart';
import 'package:clusterorbit_mobile/core/theme/clusterorbit_theme.dart';
import 'package:clusterorbit_mobile/features/topology/topology_layout.dart';
import 'package:clusterorbit_mobile/features/topology/topology_orbs.dart';
import 'package:clusterorbit_mobile/features/topology/topology_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

/// Pumps [TopologyScreen] on its own, without the shell, over the sample
/// snapshot.
Future<void> pumpTopologyScreen(WidgetTester tester,
    {required Size size}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  final profile = SampleClusterData.profilesFor(ConnectionMode.direct).first;

  await tester.pumpWidget(
    MaterialApp(
      theme: ClusterOrbitTheme.dark(),
      home: Scaffold(
        body: TopologyScreen(
          snapshot: SampleClusterData.snapshotFor(profile),
          isLoading: false,
          error: null,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('topology screen renders interactive canvas with live entities',
      (tester) async {
    await pumpClusterOrbitApp(tester, size: const Size(1280, 900));

    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(find.text('Cluster Map'), findsNWidgets(3));
    expect(find.text('Map status'), findsOneWidget);
    expect(find.text('Legend'), findsOneWidget);
    expect(find.text('Direct mode'), findsOneWidget);

    await resetTestSurface(tester);
  });

  // ── tablet (1280×900, isWide = true) ───────────────────────────────────

  testWidgets('tablet: tapping a node shows detail in sidebar column',
      (tester) async {
    await pumpTopologyScreen(tester, size: const Size(1400, 900));

    // Sidebar is visible when isWide = true
    expect(find.text('Flight Deck'), findsOneWidget);

    await tester.tap(find.text('cp-1.dev-orbit'));
    await tester.pumpAndSettle();

    // Name appears in orb AND detail panel header
    expect(find.text('cp-1.dev-orbit'), findsNWidgets(2));
    expect(find.text('K8s Version'), findsOneWidget);
    // Flight Deck still visible alongside detail
    expect(find.text('Flight Deck'), findsOneWidget);

    await resetTestSurface(tester);
  });

  testWidgets('tablet: tapping same node again deselects', (tester) async {
    await pumpClusterOrbitApp(tester, size: const Size(1280, 900));

    await tester.tap(find.text('cp-1.dev-orbit'));
    await tester.pumpAndSettle();
    expect(find.text('K8s Version'), findsOneWidget);

    await tester.tap(find.text('cp-1.dev-orbit').first);
    await tester.pumpAndSettle();
    expect(find.text('K8s Version'), findsNothing);

    await resetTestSurface(tester);
  });

  testWidgets('tablet: dismiss button clears selection', (tester) async {
    await pumpClusterOrbitApp(tester, size: const Size(1280, 900));

    await tester.tap(find.text('cp-1.dev-orbit'));
    await tester.pumpAndSettle();
    expect(find.text('K8s Version'), findsOneWidget);

    await tester.tap(find.byTooltip('Dismiss'));
    await tester.pumpAndSettle();
    expect(find.text('K8s Version'), findsNothing);

    await resetTestSurface(tester);
  });

  testWidgets('tablet: tapping a workload shows workload fields',
      (tester) async {
    await pumpClusterOrbitApp(tester, size: const Size(1280, 900));

    // Find workload by its orb subtitle (kind / namespace) to avoid
    // ambiguity with the service also named service-1
    await tester.tap(find.text('Deployment / platform').first);
    await tester.pumpAndSettle();

    // Namespace label only appears in workload and service detail panels
    expect(find.text('Namespace'), findsOneWidget);
    // Replicas label is specific to workload detail
    expect(find.text('Replicas'), findsOneWidget);

    await resetTestSurface(tester);
  });

  testWidgets('tablet: tapping a service shows service fields', (tester) async {
    // The service lane sits right of the workload grid; this surface shows it
    // without panning.
    await pumpTopologyScreen(tester, size: const Size(1920, 1080));

    await tester.tap(find.text('ClusterIP / platform').first);
    await tester.pumpAndSettle();

    expect(find.text('Exposure'), findsOneWidget);
    expect(find.text('Port'), findsOneWidget);

    await resetTestSurface(tester);
  });

  testWidgets('orbs keep their layout size at large text scales',
      (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await pumpTopologyScreen(tester, size: const Size(1100, 800));

    expect(tester.takeException(), isNull);
    void expectSize(Type orb, double width) {
      final elements = find.byType(orb).evaluate();
      expect(elements, isNotEmpty);
      for (final element in elements) {
        expect((element.renderObject! as RenderBox).size,
            Size(width, OrbMetrics.height));
      }
    }

    expectSize(NodeOrb, OrbMetrics.nodeWidth);
    expectSize(WorkloadOrb, OrbMetrics.workloadWidth);
    expectSize(ServiceOrb, OrbMetrics.serviceWidth);

    await resetTestSurface(tester);
  });

  // ── phone portrait (390×844) ────────────────────────────────────────────

  testWidgets('phone portrait: tapping a node shows bottom panel',
      (tester) async {
    await pumpClusterOrbitApp(tester, size: const Size(390, 844));

    // Default is list view — switch to map first.
    final toggle = find.byKey(const ValueKey('phone-view-toggle'));
    await tester.tap(find.descendant(of: toggle, matching: find.text('Map')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('cp-1.dev-orbit'));
    await tester.pumpAndSettle();

    expect(find.text('K8s Version'), findsOneWidget);

    await resetTestSurface(tester);
  });

  testWidgets('phone portrait: dismiss button clears bottom panel',
      (tester) async {
    await pumpClusterOrbitApp(tester, size: const Size(390, 844));

    // Default is list view — switch to map first.
    final toggle = find.byKey(const ValueKey('phone-view-toggle'));
    await tester.tap(find.descendant(of: toggle, matching: find.text('Map')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('cp-1.dev-orbit'));
    await tester.pumpAndSettle();
    expect(find.text('K8s Version'), findsOneWidget);

    await tester.tap(find.byTooltip('Dismiss'));
    await tester.pumpAndSettle();
    expect(find.text('K8s Version'), findsNothing);

    await resetTestSurface(tester);
  });

  // ── phone landscape (844×390) ────────────────────────────────────────────

  testWidgets('phone landscape: tapping a node shows right panel',
      (tester) async {
    await pumpClusterOrbitApp(tester, size: const Size(844, 390));

    await tester.tap(find.text('cp-1.dev-orbit'));
    await tester.pumpAndSettle();

    expect(find.text('K8s Version'), findsOneWidget);

    await resetTestSurface(tester);
  });

  testWidgets('phone landscape: right panel absent when nothing selected',
      (tester) async {
    await pumpClusterOrbitApp(tester, size: const Size(844, 390));

    expect(find.text('K8s Version'), findsNothing);

    await resetTestSurface(tester);
  });

  // ── event stream ────────────────────────────────────────────────────────

  testWidgets('tablet: selected node shows Recent Events from connection',
      (tester) async {
    await pumpClusterOrbitApp(tester, size: const Size(1280, 900));

    await tester.tap(find.text('cp-1.dev-orbit'));
    await tester.pumpAndSettle();

    // Header appears in the detail panel
    expect(find.text('Recent Events'), findsOneWidget);
    // Sample event for a node (from SampleClusterData.eventsFor)
    expect(find.text('NodeReady'), findsOneWidget);

    await resetTestSurface(tester);
  });

  // ── scale mutation ──────────────────────────────────────────────────────

  testWidgets(
      'tablet: scale button on deployment opens dialog and calls connection',
      (tester) async {
    final calls = <List<Object>>[];
    final connection = TestClusterConnection(
      onScale: (clusterId, workloadId, replicas) =>
          calls.add([clusterId, workloadId, replicas]),
    );

    await pumpClusterOrbitApp(
      tester,
      size: const Size(1280, 900),
      connection: connection,
    );

    // Tap a Deployment (service-1 via its kind/namespace subtitle)
    await tester.tap(find.text('Deployment / platform').first);
    await tester.pumpAndSettle();

    expect(find.text('Scale'), findsOneWidget);
    await tester.tap(find.text('Scale'));
    await tester.pumpAndSettle();

    // Dialog open — change value to 7 and apply
    expect(find.text('Desired replicas'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '7');
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();

    expect(calls, hasLength(1));
    expect(calls.single[2], 7);

    await resetTestSurface(tester);
  });
}
