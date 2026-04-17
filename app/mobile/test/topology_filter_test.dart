import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

void main() {
  Future<void> tapChip(WidgetTester tester, String label) async {
    final chip = find.widgetWithText(FilterChip, label);
    await tester.ensureVisible(chip);
    await tester.pumpAndSettle();
    await tester.tap(chip);
    await tester.pumpAndSettle();
  }

  testWidgets('toggling Workloads chip hides workload orbs', (tester) async {
    await pumpClusterOrbitApp(tester, size: const Size(1280, 900));

    // Workload orb text is rendered while the filter is on.
    expect(find.text('Deployment / platform'), findsWidgets);

    await tapChip(tester, 'Workloads');

    expect(find.text('Deployment / platform'), findsNothing);

    // Turning it back on restores them.
    await tapChip(tester, 'Workloads');
    expect(find.text('Deployment / platform'), findsWidgets);

    await resetTestSurface(tester);
  });

  testWidgets('toggling Nodes chip hides node orbs', (tester) async {
    await pumpClusterOrbitApp(tester, size: const Size(1280, 900));

    expect(find.text('cp-1.dev-orbit'), findsOneWidget);

    await tapChip(tester, 'Nodes');

    expect(find.text('cp-1.dev-orbit'), findsNothing);

    await resetTestSurface(tester);
  });

  testWidgets('viewport TransformationController survives rebuilds',
      (tester) async {
    await pumpClusterOrbitApp(tester, size: const Size(1280, 900));

    expect(find.byType(InteractiveViewer), findsOneWidget);
    await tapChip(tester, 'Services');
    expect(find.byType(InteractiveViewer), findsOneWidget);

    await resetTestSurface(tester);
  });
}
