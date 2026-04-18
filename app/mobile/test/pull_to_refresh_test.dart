import 'package:clusterorbit_mobile/core/cluster_domain/cluster_models.dart';
import 'package:clusterorbit_mobile/core/connectivity/sample_cluster_data.dart';
import 'package:clusterorbit_mobile/core/theme/clusterorbit_theme.dart';
import 'package:clusterorbit_mobile/features/alerts/alerts_screen.dart';
import 'package:clusterorbit_mobile/features/changes/changes_screen.dart';
import 'package:clusterorbit_mobile/features/resources/resources_screen.dart';
import 'package:clusterorbit_mobile/features/topology/topology_list_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child) => MaterialApp(
      theme: ClusterOrbitTheme.dark(),
      home: Scaffold(body: child),
    );

void main() {
  final profile = SampleClusterData.profilesFor(ConnectionMode.direct).first;
  final snapshot = SampleClusterData.snapshotFor(profile);

  testWidgets('AlertsScreen: swipe-down fires onRefresh', (tester) async {
    var calls = 0;
    await tester.pumpWidget(_wrap(AlertsScreen(
      snapshot: snapshot,
      onRefresh: () async => calls++,
    )));
    await tester.pumpAndSettle();

    await tester.fling(find.byType(ListView), const Offset(0, 400), 1500);
    await tester.pumpAndSettle();

    expect(calls, greaterThanOrEqualTo(1));
  });

  testWidgets('AlertsScreen empty-state is still refreshable', (tester) async {
    var calls = 0;
    await tester.pumpWidget(_wrap(AlertsScreen(
      snapshot: null,
      onRefresh: () async => calls++,
    )));
    await tester.pumpAndSettle();

    await tester.fling(find.byType(ListView), const Offset(0, 400), 1500);
    await tester.pumpAndSettle();

    expect(calls, greaterThanOrEqualTo(1));
  });

  testWidgets('TopologyListView: swipe-down fires onRefresh', (tester) async {
    var calls = 0;
    await tester.pumpWidget(_wrap(TopologyListView(
      snapshot: snapshot,
      onRefresh: () async => calls++,
    )));
    await tester.pumpAndSettle();

    await tester.fling(find.byType(ListView), const Offset(0, 400), 1500);
    await tester.pumpAndSettle();

    expect(calls, greaterThanOrEqualTo(1));
  });

  testWidgets('AlertsScreen without onRefresh has no RefreshIndicator',
      (tester) async {
    await tester.pumpWidget(_wrap(AlertsScreen(snapshot: snapshot)));
    await tester.pumpAndSettle();

    expect(find.byType(RefreshIndicator), findsNothing);
  });

  testWidgets('ResourcesScreen: swipe-down on Nodes tab fires onRefresh',
      (tester) async {
    var calls = 0;
    await tester.pumpWidget(_wrap(ResourcesScreen(
      snapshot: snapshot,
      onRefresh: () async => calls++,
    )));
    await tester.pumpAndSettle();

    await tester.fling(find.byType(ListView).first, const Offset(0, 400), 1500);
    await tester.pumpAndSettle();

    expect(calls, greaterThanOrEqualTo(1));
  });

  testWidgets('ResourcesScreen empty-state is still refreshable',
      (tester) async {
    var calls = 0;
    await tester.pumpWidget(_wrap(ResourcesScreen(
      snapshot: null,
      onRefresh: () async => calls++,
    )));
    await tester.pumpAndSettle();

    await tester.fling(find.byType(ListView), const Offset(0, 400), 1500);
    await tester.pumpAndSettle();

    expect(calls, greaterThanOrEqualTo(1));
  });

  testWidgets('ChangesScreen: swipe-down fires onRefresh', (tester) async {
    var calls = 0;
    await tester.pumpWidget(_wrap(ChangesScreen(
      snapshot: snapshot,
      onRefresh: () async => calls++,
    )));
    await tester.pumpAndSettle();

    await tester.fling(find.byType(ListView), const Offset(0, 400), 1500);
    await tester.pumpAndSettle();

    expect(calls, greaterThanOrEqualTo(1));
  });

  testWidgets('ChangesScreen empty-state is still refreshable', (tester) async {
    var calls = 0;
    await tester.pumpWidget(_wrap(ChangesScreen(
      snapshot: null,
      onRefresh: () async => calls++,
    )));
    await tester.pumpAndSettle();

    await tester.fling(find.byType(ListView), const Offset(0, 400), 1500);
    await tester.pumpAndSettle();

    expect(calls, greaterThanOrEqualTo(1));
  });

  testWidgets('ChangesScreen without onRefresh has no RefreshIndicator',
      (tester) async {
    await tester.pumpWidget(_wrap(ChangesScreen(snapshot: snapshot)));
    await tester.pumpAndSettle();

    expect(find.byType(RefreshIndicator), findsNothing);
  });
}
