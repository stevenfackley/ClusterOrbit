import 'package:clusterorbit_mobile/core/cluster_domain/cluster_models.dart';
import 'package:clusterorbit_mobile/core/connectivity/cluster_connection.dart';
import 'package:clusterorbit_mobile/core/connectivity/sample_cluster_data.dart';
import 'package:clusterorbit_mobile/core/theme/clusterorbit_theme.dart';
import 'package:clusterorbit_mobile/features/topology/entity_detail_panel.dart';
import 'package:clusterorbit_mobile/features/topology/topology_list_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

void main() {
  final profile = SampleClusterData.profilesFor(ConnectionMode.direct).first;
  final snapshot = SampleClusterData.snapshotFor(profile);

  Widget buildListView() => MaterialApp(
        theme: ClusterOrbitTheme.dark(),
        home: Scaffold(
          body: TopologyListView(
            snapshot: snapshot,
            connection: TestClusterConnection(),
            clusterId: profile.id,
          ),
        ),
      );

  // ── section headers ─────────────────────────────────────────────────────

  testWidgets('renders three section headers', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(400, 820);

    await tester.pumpWidget(buildListView());
    await tester.pumpAndSettle();

    // Nodes is visible at the top.
    expect(find.text('Nodes'), findsOneWidget);

    // Workloads and Services sections are below the expanded nodes list —
    // scroll until each header is in view before asserting.
    await tester.scrollUntilVisible(
      find.text('Workloads'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Workloads'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('Services'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Services'), findsOneWidget);

    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    await tester.pump();
  });

  // ── node row content ────────────────────────────────────────────────────

  testWidgets('a node row shows name and role badge', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(400, 820);

    await tester.pumpWidget(buildListView());
    await tester.pumpAndSettle();

    // cp-1.dev-orbit is in sample data (control-plane node)
    expect(find.text('cp-1.dev-orbit'), findsOneWidget);
    // Role badge text for control plane
    expect(find.text('Control plane'), findsWidgets);

    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    await tester.pump();
  });

  // ── node row tap → bottom sheet ─────────────────────────────────────────

  testWidgets('tapping a node row opens EntityDetailPanel sheet',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(400, 820);

    await tester.pumpWidget(buildListView());
    await tester.pumpAndSettle();

    await tester.tap(find.text('cp-1.dev-orbit'));
    await tester.pumpAndSettle();

    expect(find.byType(EntityDetailPanel), findsOneWidget);
    // Node detail shows K8s Version field
    expect(find.text('K8s Version'), findsOneWidget);

    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    await tester.pump();
  });

  // ── the detail sheet follows the list ───────────────────────────────────

  Future<void> pumpList(
    WidgetTester tester,
    ClusterSnapshot snapshot, {
    ClusterConnection? connection,
  }) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(400, 820);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: ClusterOrbitTheme.dark(),
      home: Scaffold(
        body: TopologyListView(
          snapshot: snapshot,
          connection: connection ?? TestClusterConnection(),
          clusterId: snapshot.profile.id,
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('the detail sheet shows the refreshed entity', (tester) async {
    await pumpList(tester, snapshot);
    await tester.tap(find.text('cp-1.dev-orbit'));
    await tester.pumpAndSettle();
    expect(find.text('Cordon'), findsOneWidget);

    await pumpList(tester, refreshedSnapshot(snapshot, cordon: 'cp-1'));

    expect(find.text('Uncordon'), findsOneWidget);
    expect(find.text('Cordon'), findsNothing);
  });

  testWidgets('a cluster switch closes the detail sheet', (tester) async {
    await pumpList(tester, snapshot);
    await tester.tap(find.text('cp-1.dev-orbit'));
    await tester.pumpAndSettle();
    expect(find.byType(EntityDetailPanel), findsOneWidget);

    // Staging has a cp-1 too; the sheet must not carry over to it.
    final staging = SampleClusterData.snapshotFor(
        SampleClusterData.profilesFor(ConnectionMode.direct)[1]);
    await pumpList(tester, staging);

    expect(find.byType(EntityDetailPanel), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the detail sheet closes when its entity is removed',
      (tester) async {
    await pumpList(tester, snapshot);
    await tester.tap(find.text('cp-1.dev-orbit'));
    await tester.pumpAndSettle();

    await pumpList(tester, refreshedSnapshot(snapshot, drop: 'cp-1'));

    expect(find.byType(EntityDetailPanel), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a failed action is reported inside the sheet, not under it',
      (tester) async {
    final connection = RecordingClusterConnection()
      ..mutationError = StateError('forbidden');
    await pumpList(tester, snapshot, connection: connection);
    await tester.tap(find.text('cp-1.dev-orbit'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Cordon'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Cordon'));
    await tester.pumpAndSettle();

    final failure = find.text('Cordon failed: Bad state: forbidden');
    // Once inline in the sheet, once in the SnackBar beneath it.
    expect(failure, findsNWidgets(2));
    expect(
      find
          .descendant(of: find.byType(EntityDetailPanel), matching: failure)
          .hitTestable(),
      findsOneWidget,
    );
  });

  testWidgets('the detail sheet closes with the list', (tester) async {
    await pumpList(tester, snapshot);
    await tester.tap(find.text('cp-1.dev-orbit'));
    await tester.pumpAndSettle();

    await tester.pumpWidget(MaterialApp(
      theme: ClusterOrbitTheme.dark(),
      home: const Scaffold(body: SizedBox()),
    ));
    await tester.pumpAndSettle();

    expect(find.byType(EntityDetailPanel), findsNothing);
    expect(tester.takeException(), isNull);
  });

  // ── phone-portrait toggle in TopologyScreen ─────────────────────────────

  testWidgets(
      'phone portrait: defaults to list, tapping Map shows InteractiveViewer',
      (tester) async {
    await pumpClusterOrbitApp(tester, size: const Size(400, 820));

    // List view is default — no InteractiveViewer yet
    expect(find.byType(InteractiveViewer), findsNothing);
    expect(find.text('Nodes'), findsOneWidget);

    // Switch to map — scope to the toggle to avoid the nav-bar "Map" label.
    final toggle = find.byKey(const ValueKey('phone-view-toggle'));
    await tester.tap(find.descendant(of: toggle, matching: find.text('Map')));
    await tester.pumpAndSettle();

    expect(find.byType(InteractiveViewer), findsOneWidget);

    await resetTestSurface(tester);
  });

  testWidgets('phone portrait: toggling back to List hides InteractiveViewer',
      (tester) async {
    await pumpClusterOrbitApp(tester, size: const Size(400, 820));

    final toggle = find.byKey(const ValueKey('phone-view-toggle'));
    await tester.tap(find.descendant(of: toggle, matching: find.text('Map')));
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget);

    await tester.tap(find.descendant(of: toggle, matching: find.text('List')));
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsNothing);
    expect(find.text('Nodes'), findsOneWidget);

    await resetTestSurface(tester);
  });
}
