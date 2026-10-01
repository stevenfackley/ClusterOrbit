import 'dart:async';

import 'package:clusterorbit_mobile/core/cluster_domain/cluster_models.dart';
import 'package:clusterorbit_mobile/core/connectivity/cluster_connection.dart';
import 'package:clusterorbit_mobile/core/connectivity/gateway_cluster_connection.dart';
import 'package:clusterorbit_mobile/core/connectivity/sample_cluster_data.dart';
import 'package:clusterorbit_mobile/core/theme/clusterorbit_theme.dart';
import 'package:clusterorbit_mobile/features/topology/entity_detail_panel.dart';
import 'package:clusterorbit_mobile/features/topology/topology_layout.dart';
import 'package:clusterorbit_mobile/features/topology/topology_list_view.dart';
import 'package:clusterorbit_mobile/features/topology/topology_orbs.dart';
import 'package:clusterorbit_mobile/features/topology/topology_panels.dart';
import 'package:clusterorbit_mobile/features/topology/topology_screen.dart';
import 'package:clusterorbit_mobile/features/topology/topology_workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

/// Pumps [TopologyScreen] on its own, without the shell, over [snapshot]
/// (the sample snapshot by default).
Future<void> pumpTopologyScreen(
  WidgetTester tester, {
  required Size size,
  ClusterConnection? connection,
  ClusterSnapshot? snapshot,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  final profile = SampleClusterData.profilesFor(ConnectionMode.direct).first;

  await tester.pumpWidget(
    MaterialApp(
      theme: ClusterOrbitTheme.dark(),
      home: Scaffold(
        body: TopologyScreen(
          snapshot: snapshot ?? SampleClusterData.snapshotFor(profile),
          isLoading: false,
          error: null,
          connection: connection,
          clusterId: profile.id,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// The canvas orb of the entity of [kind] with [id].
Finder orb(String kind, String id) => find.byKey(ValueKey('$kind:$id'));

/// [text] inside the entity detail panel.
Finder inPanel(String text) => find.descendant(
    of: find.byType(EntityDetailPanel), matching: find.text(text));

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

    await tester.tap(orb('node', 'cp-1'));
    await tester.pumpAndSettle();

    expect(inPanel('cp-1.dev-orbit'), findsOneWidget);
    expect(inPanel('use1-a'), findsOneWidget);
    expect(find.text('K8s Version'), findsOneWidget);
    // Flight Deck still visible alongside detail
    expect(find.text('Flight Deck'), findsOneWidget);

    await resetTestSurface(tester);
  });

  testWidgets('tablet: tapping same node again deselects', (tester) async {
    await pumpClusterOrbitApp(tester, size: const Size(1280, 900));

    await tester.tap(orb('node', 'cp-1'));
    await tester.pumpAndSettle();
    expect(inPanel('cp-1.dev-orbit'), findsOneWidget);

    await tester.tap(orb('node', 'cp-1'));
    await tester.pumpAndSettle();
    expect(find.text('K8s Version'), findsNothing);

    await resetTestSurface(tester);
  });

  testWidgets('tablet: dismiss button clears selection', (tester) async {
    await pumpClusterOrbitApp(tester, size: const Size(1280, 900));

    await tester.tap(orb('node', 'cp-1'));
    await tester.pumpAndSettle();
    expect(inPanel('cp-1.dev-orbit'), findsOneWidget);

    await tester.tap(find.byTooltip('Dismiss'));
    await tester.pumpAndSettle();
    expect(find.text('K8s Version'), findsNothing);

    await resetTestSurface(tester);
  });

  testWidgets('tablet: tapping a workload shows workload fields',
      (tester) async {
    await pumpClusterOrbitApp(tester, size: const Size(1280, 900));

    // workload-1, a Deployment, shares its name with the service service-1.
    final workload = orb('workload', 'workload-1');
    await panUntilHitTestable(tester, workload);
    await tester.tap(workload);
    await tester.pumpAndSettle();

    // Namespace label only appears in workload and service detail panels
    expect(find.text('Namespace'), findsOneWidget);
    // Replicas label is specific to workload detail
    expect(find.text('Replicas'), findsOneWidget);
    expect(inPanel('ghcr.io/clusterorbit/service-1:v0.1.0'), findsOneWidget);

    await resetTestSurface(tester);
  });

  testWidgets('tablet: tapping a service shows service fields', (tester) async {
    await pumpTopologyScreen(tester, size: const Size(1400, 900));

    final service = orb('service', 'service-1');
    await panUntilHitTestable(tester, service);
    await tester.tap(service);
    await tester.pumpAndSettle();

    expect(find.text('Exposure'), findsOneWidget);
    expect(find.text('Port'), findsOneWidget);
    expect(inPanel('10.96.0.1'), findsOneWidget);

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

      await tester.tap(orb('node', 'cp-1'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Priority Alerts'), findsNothing);
      expect(inPanel('cp-1.dev-orbit'), findsOneWidget);
      final cordon = find.text('Cordon');
      await tester.ensureVisible(cordon);
      await tester.pumpAndSettle();
      expect(cordon.hitTestable(), findsOneWidget);
      expectHeaderAboveCanvas(tester);
      expect(tester.takeException(), isNull);

      await resetTestSurface(tester);
    });
  }

  testWidgets(
      'a short 932x430 window gets the landscape layout, not the sidebar',
      (tester) async {
    // A desktop window: real phones this wide have side insets that keep
    // the pane under 900.
    tester.view.padding = FakeViewPadding.zero;
    tester.view.viewPadding = FakeViewPadding.zero;
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
    await pumpClusterOrbitApp(tester, size: const Size(932, 430));

    expect(find.byType(TopologySidebar), findsNothing);
    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(tester.takeException(), isNull);

    await resetTestSurface(tester);
  });

  testWidgets('phone map at 390x700: header ends above the canvas',
      (tester) async {
    await pumpTopologyScreen(tester, size: const Size(390, 700));
    await showPhoneMap(tester);

    expect(find.byType(TopologySidebar), findsNothing);
    expectHeaderAboveCanvas(tester);
    // Too narrow for the long description.
    expect(find.textContaining('Machine-first topology canvas'), findsNothing);

    await tester.tap(orb('node', 'cp-1'));
    await tester.pumpAndSettle();
    expect(inPanel('cp-1.dev-orbit'), findsOneWidget);
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

    await tester.tap(orb('node', 'cp-1'));
    await tester.pumpAndSettle();

    expect(inPanel('cp-1.dev-orbit'), findsOneWidget);
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

    await tester.tap(orb('node', 'cp-1'));
    await tester.pumpAndSettle();

    expect(inPanel('cp-1.dev-orbit'), findsOneWidget);

    await resetTestSurface(tester);
  });

  testWidgets('phone portrait: dismiss button clears bottom panel',
      (tester) async {
    await pumpClusterOrbitApp(tester, size: const Size(390, 844));

    // Default is list view — switch to map first.
    final toggle = find.byKey(const ValueKey('phone-view-toggle'));
    await tester.tap(find.descendant(of: toggle, matching: find.text('Map')));
    await tester.pumpAndSettle();

    await tester.tap(orb('node', 'cp-1'));
    await tester.pumpAndSettle();
    expect(inPanel('cp-1.dev-orbit'), findsOneWidget);

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

    final lastService = orb('service', 'service-12');
    expect(lastService.hitTestable(), findsNothing);
    await panUntilHitTestable(tester, lastService);
    expect(lastService.hitTestable(), findsOneWidget);

    await tester.tap(lastService);
    await tester.pumpAndSettle();
    expect(inPanel('service-12'), findsOneWidget);
    expect(find.text('Exposure'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await resetTestSurface(tester);
  });

  // ── phone landscape (844×390) ────────────────────────────────────────────

  testWidgets('phone landscape: tapping a node shows right panel',
      (tester) async {
    await pumpClusterOrbitApp(tester, size: const Size(844, 390));

    await tester.tap(orb('node', 'cp-1'));
    await tester.pumpAndSettle();

    expect(inPanel('cp-1.dev-orbit'), findsOneWidget);

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

    await tester.tap(orb('node', 'cp-1'));
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

    // workload-1 is a Deployment.
    final workload = orb('workload', 'workload-1');
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

    expect(calls, [
      ['dev-orbit', 'workload-1', 7],
    ]);

    await resetTestSurface(tester);
  });

  // ── soft keyboard ───────────────────────────────────────────────────────

  // An iPad in portrait gets the phone layout. The keyboard the Scale dialog
  // raises shrinks the pane to wider than tall, which must not flip it to
  // the landscape layout and tear down the panel that opened the dialog.
  for (final host in const ['list', 'map']) {
    testWidgets('$host host at 820x1180: Scale survives the soft keyboard',
        (tester) async {
      final connection = RecordingClusterConnection();
      await pumpClusterOrbitApp(tester,
          size: const Size(820, 1180), connection: connection);
      addTearDown(tester.view.resetViewInsets);

      if (host == 'list') {
        final row = find.descendant(
          of: find.byKey(const ValueKey('workloads-section')),
          matching: find.text('service-1'),
        );
        await tester.scrollUntilVisible(row, 200,
            scrollable: find
                .descendant(
                    of: find.byType(TopologyListView),
                    matching: find.byType(Scrollable))
                .first);
        await tester.ensureVisible(row);
        await tester.pumpAndSettle();
        await tester.tap(row);
      } else {
        await showPhoneMap(tester);
        final workload = orb('workload', 'workload-1');
        await panUntilHitTestable(tester, workload);
        await tester.tap(workload);
      }
      await tester.pumpAndSettle();
      final scale = find.widgetWithText(TextButton, 'Scale');
      await tester.ensureVisible(scale);
      await tester.pumpAndSettle();
      await tester.tap(scale);
      await tester.pumpAndSettle();

      tester.view.viewInsets = const FakeViewPadding(bottom: 320);
      await tester.pumpAndSettle();
      expect(find.byType(EntityDetailPanel), findsOneWidget);
      await tester.enterText(find.byType(TextField), '5');
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();

      expect(connection.callsTo('scaleWorkload'), [
        ['scaleWorkload', 'dev-orbit', 'workload-1', 5],
      ]);
      expect(tester.takeException(), isNull);

      await resetTestSurface(tester);
    });
  }

  // ── mutation flows (sidebar, 1400×900) ────────────────────────────────

  /// Selects [target], panning to it first, and taps its [action] button.
  Future<void> openAction(
      WidgetTester tester, Finder target, String action) async {
    await panUntilHitTestable(tester, target);
    await tester.tap(target);
    await tester.pumpAndSettle();
    final button = find.widgetWithText(TextButton, action);
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  Future<void> confirm(WidgetTester tester, String action) async {
    await tester.tap(find.widgetWithText(FilledButton, action));
    await tester.pumpAndSettle();
  }

  testWidgets('cordon: cancel does nothing, confirm cordons this node',
      (tester) async {
    final connection = RecordingClusterConnection();
    await pumpTopologyScreen(tester,
        size: const Size(1400, 900), connection: connection);

    await openAction(tester, orb('node', 'cp-1'), 'Cordon');
    // A direct connection doesn't support drain.
    expect(inPanel('Drain'), findsNothing);
    expect(find.text('Cordon cp-1.dev-orbit?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(connection.callsTo('setNodeSchedulable'), isEmpty);

    await tester.tap(find.widgetWithText(TextButton, 'Cordon'));
    await tester.pumpAndSettle();
    await confirm(tester, 'Cordon');

    expect(connection.callsTo('setNodeSchedulable'), [
      ['setNodeSchedulable', 'dev-orbit', 'cp-1', false],
    ]);
    expect(
      inPanel('Requested cordon of cp-1.dev-orbit. '
          'Refresh to see applied state.'),
      findsOneWidget,
    );

    await resetTestSurface(tester);
  });

  testWidgets(
      'cordon: actions wait for the request, and its outcome stays off '
      'the node selected meanwhile', (tester) async {
    final gate = Completer<void>();
    final connection = RecordingClusterConnection()
      ..mutationGate = gate
      ..mutationError = StateError('forbidden');
    await pumpTopologyScreen(tester,
        size: const Size(1400, 900), connection: connection);

    await openAction(tester, orb('node', 'cp-1'), 'Cordon');
    await confirm(tester, 'Cordon');
    final cordon = find.widgetWithText(TextButton, 'Cordon');
    expect(tester.widget<TextButton>(cordon).onPressed, isNull,
        reason: 'no duplicate submit while the request is in flight');

    final other = orb('node', 'cp-2');
    await panUntilHitTestable(tester, other);
    await tester.tap(other);
    await tester.pumpAndSettle();
    expect(inPanel('cp-2.dev-orbit'), findsOneWidget);

    gate.complete();
    await tester.pumpAndSettle();

    expect(connection.callsTo('setNodeSchedulable'), [
      ['setNodeSchedulable', 'dev-orbit', 'cp-1', false],
    ]);
    const outcome = 'Cordon failed: Bad state: forbidden';
    expect(inPanel(outcome), findsNothing);
    expect(find.text(outcome), findsOneWidget, reason: 'the SnackBar says so');
    expect(tester.widget<TextButton>(cordon).onPressed, isNotNull);

    await resetTestSurface(tester);
  });

  testWidgets('uncordon: confirm makes a cordoned node schedulable',
      (tester) async {
    final connection = RecordingClusterConnection();
    final profile = SampleClusterData.profilesFor(ConnectionMode.direct).first;
    await pumpTopologyScreen(
      tester,
      size: const Size(1400, 900),
      connection: connection,
      snapshot: refreshedSnapshot(SampleClusterData.snapshotFor(profile),
          cordon: 'cp-1'),
    );

    await openAction(tester, orb('node', 'cp-1'), 'Uncordon');
    expect(find.text('This allows new pods to be scheduled on cp-1.dev-orbit.'),
        findsOneWidget);
    await confirm(tester, 'Uncordon');

    expect(connection.callsTo('setNodeSchedulable'), [
      ['setNodeSchedulable', 'dev-orbit', 'cp-1', true],
    ]);
    expect(
      inPanel('Requested uncordon of cp-1.dev-orbit. '
          'Refresh to see applied state.'),
      findsOneWidget,
    );

    await resetTestSurface(tester);
  });

  testWidgets('restart: confirm restarts this workload', (tester) async {
    final connection = RecordingClusterConnection();
    await pumpTopologyScreen(tester,
        size: const Size(1400, 900), connection: connection);

    await openAction(tester, orb('workload', 'workload-1'), 'Restart');
    expect(find.text('Restart service-1?'), findsOneWidget);
    await confirm(tester, 'Restart');

    expect(connection.callsTo('restartWorkload'), [
      ['restartWorkload', 'dev-orbit', 'workload-1'],
    ]);
    expect(
      inPanel('Requested rolling restart of service-1. '
          'Refresh to see applied state.'),
      findsOneWidget,
    );

    await resetTestSurface(tester);
  });

  testWidgets('scale: a failure is reported in the panel', (tester) async {
    final connection = RecordingClusterConnection()
      ..mutationError = StateError('quota exceeded');
    await pumpTopologyScreen(tester,
        size: const Size(1400, 900), connection: connection);

    await openAction(tester, orb('workload', 'workload-1'), 'Scale');
    await tester.enterText(find.byType(TextField), '5');
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();

    expect(connection.callsTo('scaleWorkload'), [
      ['scaleWorkload', 'dev-orbit', 'workload-1', 5],
    ]);
    expect(inPanel('Scale failed: Bad state: quota exceeded'), findsOneWidget);

    await resetTestSurface(tester);
  });

  testWidgets('restart: a gateway refusal reads as its user message',
      (tester) async {
    final connection = RecordingClusterConnection()
      ..mutationError = GatewayException.fromResponse(
        403,
        Uri.parse('https://gw.example.test/v1/clusters/dev-orbit/restart'),
        '{"error": "namespace not allowed"}',
      );
    await pumpTopologyScreen(tester,
        size: const Size(1400, 900), connection: connection);

    await openAction(tester, orb('workload', 'workload-1'), 'Restart');
    await confirm(tester, 'Restart');

    expect(
      inPanel('Restart failed: Not allowed by the gateway: '
          'namespace not allowed'),
      findsOneWidget,
    );
    expect(find.textContaining('gw.example.test'), findsNothing);

    await resetTestSurface(tester);
  });

  testWidgets('drain: confirm starts a job and follows it to the end',
      (tester) async {
    DrainJob job(DrainPhase phase) => DrainJob(
          id: 'drain-1',
          nodeId: 'cp-1',
          phase: phase,
          evicted: const [],
          skipped: const [],
          remaining: phase.isTerminal ? 0 : 4,
        );
    final connection = RecordingClusterConnection(mode: ConnectionMode.gateway)
      ..drainJob = job(DrainPhase.running)
      ..onDrainStatus = () async => job(DrainPhase.succeeded);
    await pumpTopologyScreen(tester,
        size: const Size(1400, 900), connection: connection);

    await openAction(tester, orb('node', 'cp-1'), 'Drain');
    expect(find.text('Drain cp-1.dev-orbit?'), findsOneWidget);
    // Not pumpAndSettle: the progress dialog spins until the job ends.
    await tester.tap(find.widgetWithText(FilledButton, 'Drain'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(connection.callsTo('startDrain'), [
      ['startDrain', 'dev-orbit', 'cp-1'],
    ]);
    expect(find.text('Draining cp-1.dev-orbit'), findsOneWidget);
    expect(find.text('Remaining: 4'), findsOneWidget);

    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Phase: Drained'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    expect(find.text('Draining cp-1.dev-orbit'), findsNothing);
    expect(inPanel('Started draining cp-1.dev-orbit.'), findsOneWidget);

    await resetTestSurface(tester);
  });

  testWidgets('events: a failed load says so in the panel', (tester) async {
    final connection = RecordingClusterConnection()
      ..onLoadEvents = () async => throw StateError('events forbidden');
    await pumpTopologyScreen(tester,
        size: const Size(1400, 900), connection: connection);

    await tester.tap(orb('node', 'cp-1'));
    await tester.pumpAndSettle();

    expect(inPanel('Could not load events'), findsOneWidget);
    expect(inPanel('No recent events'), findsNothing);

    await resetTestSurface(tester);
  });
}
