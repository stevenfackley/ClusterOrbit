import 'package:clusterorbit_mobile/core/cluster_domain/cluster_models.dart';
import 'package:clusterorbit_mobile/core/connectivity/sample_cluster_data.dart';
import 'package:clusterorbit_mobile/core/theme/clusterorbit_theme.dart';
import 'package:clusterorbit_mobile/features/alerts/alerts_screen.dart';
import 'package:clusterorbit_mobile/features/changes/changes_screen.dart';
import 'package:clusterorbit_mobile/features/resources/resources_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ClusterSnapshot _sampleSnapshot() {
  final profile = SampleClusterData.profilesFor(ConnectionMode.direct).first;
  return SampleClusterData.snapshotFor(profile);
}

Widget _wrap(Widget child) => MaterialApp(
      theme: ClusterOrbitTheme.dark(),
      home: Scaffold(body: child),
    );

void main() {
  group('ResourcesScreen', () {
    testWidgets('renders Nodes tab count from snapshot', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1280, 900);
      await tester
          .pumpWidget(_wrap(ResourcesScreen(snapshot: _sampleSnapshot())));
      await tester.pumpAndSettle();

      // 3 control plane + 39 worker = 42
      expect(find.text('Nodes (42)'), findsOneWidget);
      expect(find.text('Workloads (18)'), findsOneWidget);
      expect(find.text('Services (12)'), findsOneWidget);

      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    testWidgets('empty state when snapshot is null', (tester) async {
      await tester.pumpWidget(_wrap(const ResourcesScreen()));
      await tester.pumpAndSettle();
      expect(find.textContaining('No cluster snapshot yet'), findsOneWidget);
    });
  });

  group('AlertsScreen', () {
    testWidgets('renders alerts sorted critical first', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1280, 900);
      await tester.pumpWidget(_wrap(AlertsScreen(snapshot: _sampleSnapshot())));
      await tester.pumpAndSettle();

      expect(find.text('API latency elevated'), findsOneWidget);
      expect(find.text('Node drain in progress'), findsOneWidget);

      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    testWidgets('empty snapshot shows placeholder', (tester) async {
      await tester.pumpWidget(_wrap(const AlertsScreen()));
      await tester.pumpAndSettle();
      expect(find.textContaining('No snapshot yet'), findsOneWidget);
    });
  });

  group('ChangesScreen', () {
    testWidgets('shows workload drift section', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1280, 900);
      await tester
          .pumpWidget(_wrap(ChangesScreen(snapshot: _sampleSnapshot())));
      await tester.pumpAndSettle();

      // Sample has one workload with drift: workloads[5] readyReplicas = desired - 1
      expect(find.textContaining('Workload drift (1)'), findsOneWidget);
      // Sample has one unschedulable node: workers[6]
      expect(find.textContaining('Unschedulable nodes (1)'), findsOneWidget);

      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  });
}
