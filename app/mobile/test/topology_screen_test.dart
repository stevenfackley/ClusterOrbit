import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

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
    await pumpClusterOrbitApp(tester, size: const Size(1280, 900));

    // Before tap: name appears once (in orb only)
    expect(find.text('cp-1.dev-orbit'), findsOneWidget);

    await tester.tap(find.text('cp-1.dev-orbit'));
    await tester.pumpAndSettle();

    // After tap: name appears in orb AND detail panel header
    expect(find.text('cp-1.dev-orbit'), findsNWidgets(2));
    // K8s Version label only ever appears in the node detail panel
    expect(find.text('K8s Version'), findsOneWidget);
    // Flight Deck summary still visible alongside detail
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
    await pumpClusterOrbitApp(tester, size: const Size(1280, 900));

    // Find service by its orb subtitle
    await tester.tap(find.text('ClusterIP / platform').first);
    await tester.pumpAndSettle();

    // Exposure label only appears in service detail panel
    expect(find.text('Exposure'), findsOneWidget);
    // Port label appears for each port entry
    expect(find.text('Port'), findsOneWidget);

    await resetTestSurface(tester);
  });

  // ── phone portrait (390×844) ────────────────────────────────────────────

  testWidgets('phone portrait: tapping a node shows bottom panel',
      (tester) async {
    await pumpClusterOrbitApp(tester, size: const Size(390, 844));

    await tester.tap(find.text('cp-1.dev-orbit'));
    await tester.pumpAndSettle();

    expect(find.text('K8s Version'), findsOneWidget);

    await resetTestSurface(tester);
  });

  testWidgets('phone portrait: dismiss button clears bottom panel',
      (tester) async {
    await pumpClusterOrbitApp(tester, size: const Size(390, 844));

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
}
