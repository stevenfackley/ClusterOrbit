import 'package:clusterorbit_mobile/core/cluster_domain/cluster_models.dart';
import 'package:clusterorbit_mobile/core/connectivity/sample_cluster_data.dart';
import 'package:clusterorbit_mobile/core/theme/clusterorbit_theme.dart';
import 'package:clusterorbit_mobile/features/topology/topology_layout.dart';
import 'package:clusterorbit_mobile/features/topology/topology_orbs.dart';
import 'package:clusterorbit_mobile/features/topology/topology_panels.dart';
import 'package:clusterorbit_mobile/features/topology/topology_screen.dart';
import 'package:clusterorbit_mobile/features/topology/topology_workspace.dart';
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

/// Drags the map in short, slow strokes (no fling) until [target]'s center
/// is hit-testable.
Future<void> panUntilHitTestable(WidgetTester tester, Finder target) async {
  final viewer = find.byType(InteractiveViewer);
  for (var i = 0; i < 40; i++) {
    if (target.hitTestable().evaluate().isNotEmpty) return;
    final viewport = tester.getRect(viewer);
    final delta = viewport.center - tester.getCenter(target);
    final step = Offset(
      delta.dx.clamp(-120.0, 120.0),
      delta.dy.clamp(-120.0, 120.0),
    );
    final gesture = await tester.startGesture(viewport.center);
    await gesture.moveBy(step / 2);
    await gesture.moveBy(step / 2);
    await tester.pump(const Duration(milliseconds: 300));
    await gesture.up();
    await tester.pumpAndSettle();
  }
}

/// Every part of the workspace header (title, description, badge, chips)
/// ends above the map viewport.
void expectHeaderAboveCanvas(WidgetTester tester) {
  final canvasTop = tester.getRect(find.byType(InteractiveViewer)).top;
  final parts = [
    find.descendant(
      of: find.byType(TopologyWorkspace),
      matching: find.text('Cluster Map'),
    ),
    find.textContaining('Machine-first topology canvas'),
    find.byType(ModeBadge),
    find.byType(SummaryChip),
    find.byType(TopologyFilterChip),
  ];
  for (final part in parts) {
    for (final element in part.evaluate()) {
      final box = element.renderObject! as RenderBox;
      final bottom = box.localToGlobal(Offset(0, box.size.height)).dy;
      expect(bottom, lessThanOrEqualTo(canvasTop), reason: '${element.widget}');
    }
  }
}

Future<void> showPhoneMap(WidgetTester tester) async {
  final toggle = find.byKey(const ValueKey('phone-view-toggle'));
  await tester.tap(find.descendant(of: toggle, matching: find.text('Map')));
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
    final workload = find.text('Deployment / platform').first;
    await panUntilHitTestable(tester, workload);
    await tester.tap(workload);
    await tester.pumpAndSettle();

    // Namespace label only appears in workload and service detail panels
    expect(find.text('Namespace'), findsOneWidget);
    // Replicas label is specific to workload detail
    expect(find.text('Replicas'), findsOneWidget);

    await resetTestSurface(tester);
  });

  testWidgets('tablet: tapping a service shows service fields', (tester) async {
    await pumpTopologyScreen(tester, size: const Size(1400, 900));

    final service = find.text('ClusterIP / platform').first;
    await panUntilHitTestable(tester, service);
    await tester.tap(service);
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

  // ── breakpoints and header layout ─────────────────────────────────────

  for (final size in const [Size(1280, 800), Size(1366, 1024)]) {
    testWidgets(
        'shell at ${size.width.toInt()}x${size.height.toInt()}: '
        'sidebar layout, detail replaces alerts', (tester) async {
      await pumpClusterOrbitApp(tester, size: size);

      expect(find.byType(TopologySidebar), findsOneWidget);
      expect(find.text('Priority Alerts'), findsOneWidget);
      expectHeaderAboveCanvas(tester);

      await tester.tap(find.text('cp-1.dev-orbit'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Priority Alerts'), findsNothing);
      expect(find.text('K8s Version'), findsOneWidget);
      final cordon = find.text('Cordon');
      await tester.ensureVisible(cordon);
      await tester.pumpAndSettle();
      expect(cordon.hitTestable(), findsOneWidget);
      expectHeaderAboveCanvas(tester);
      expect(tester.takeException(), isNull);

      await resetTestSurface(tester);
    });
  }

  testWidgets('phone map at 390x700: header ends above the canvas',
      (tester) async {
    await pumpTopologyScreen(tester, size: const Size(390, 700));
    await showPhoneMap(tester);

    expect(find.byType(TopologySidebar), findsNothing);
    expectHeaderAboveCanvas(tester);
    // Too narrow for the long description.
    expect(find.textContaining('Machine-first topology canvas'), findsNothing);

    await tester.tap(find.text('cp-1.dev-orbit'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Dismiss').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);

    await resetTestSurface(tester);
  });

  testWidgets('phone map survives text scale 2.0', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await pumpTopologyScreen(tester, size: const Size(390, 600));
    await showPhoneMap(tester);

    expect(tester.takeException(), isNull);
    expect(find.byType(InteractiveViewer), findsOneWidget);

    await resetTestSurface(tester);
  });

  testWidgets('landscape detail floats over the map instead of shrinking it',
      (tester) async {
    await pumpClusterOrbitApp(tester, size: const Size(844, 390));
    final before = tester.getRect(find.byType(InteractiveViewer));

    await tester.tap(find.text('cp-1.dev-orbit'));
    await tester.pumpAndSettle();

    expect(find.text('K8s Version'), findsOneWidget);
    expect(tester.getRect(find.byType(InteractiveViewer)), before);
    expect(tester.takeException(), isNull);

    await resetTestSurface(tester);
  });

  // ── pan / zoom ─────────────────────────────────────────────────────────

  testWidgets('panning leaves the orbs alone; zooming out hides labels',
      (tester) async {
    await pumpClusterOrbitApp(tester, size: const Size(1280, 800));
    final viewer = find.byType(InteractiveViewer);
    NodeOrb firstOrb() => tester.widget<NodeOrb>(find.byType(NodeOrb).first);
    final before = firstOrb();
    expect(before.showLabels, isTrue);

    final pan = await tester.startGesture(tester.getCenter(viewer));
    await pan.moveBy(const Offset(-40, -40));
    await pan.moveBy(const Offset(-40, -40));
    await tester.pump(const Duration(milliseconds: 300));
    await pan.up();
    await tester.pumpAndSettle();
    // Same widget instance: the pan never rebuilt the orb layer.
    expect(identical(firstOrb(), before), isTrue);

    final center = tester.getCenter(viewer);
    final left = await tester.startGesture(center - const Offset(120, 0));
    final right = await tester.startGesture(center + const Offset(120, 0));
    for (var i = 0; i < 4; i++) {
      await left.moveBy(const Offset(25, 0));
      await right.moveBy(const Offset(-25, 0));
      await tester.pump();
    }
    await left.up();
    await right.up();
    await tester.pumpAndSettle();
    expect(firstOrb().showLabels, isFalse);

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

  testWidgets('phone map: the last service can be panned to and selected',
      (tester) async {
    await pumpClusterOrbitApp(tester, size: const Size(390, 700));
    final toggle = find.byKey(const ValueKey('phone-view-toggle'));
    await tester.tap(find.descendant(of: toggle, matching: find.text('Map')));
    await tester.pumpAndSettle();

    final lastService = find.byType(ServiceOrb).last;
    expect(lastService.hitTestable(), findsNothing);
    await panUntilHitTestable(tester, lastService);
    expect(lastService.hitTestable(), findsOneWidget);

    await tester.tap(lastService);
    await tester.pumpAndSettle();
    expect(find.text('Exposure'), findsOneWidget);
    expect(tester.takeException(), isNull);

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
    final workload = find.text('Deployment / platform').first;
    await panUntilHitTestable(tester, workload);
    await tester.tap(workload);
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
