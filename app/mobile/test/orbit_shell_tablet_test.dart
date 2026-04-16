import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

void main() {
  testWidgets(
      'tablet layout shows rail and inspector instead of bottom navigation',
      (tester) async {
    await pumpClusterOrbitApp(tester, size: const Size(1366, 1024));

    expect(find.byType(NavigationBar), findsNothing);
    expect(find.text('ClusterOrbit'), findsOneWidget);
    expect(find.text('Inspector'), findsOneWidget);
    expect(find.text('Open change preview'), findsOneWidget);
    expect(find.text('3 clusters'), findsOneWidget);
    expect(find.text('42 nodes'), findsOneWidget);
    expect(find.text('5 alerts'), findsOneWidget);

    await resetTestSurface(tester);
  });

  testWidgets('tablet rail changes selected section', (tester) async {
    await pumpClusterOrbitApp(tester, size: const Size(1366, 1024));

    await tester.tap(find.widgetWithText(FilledButton, 'Resources'));
    await tester.pumpAndSettle();
    expect(find.text('Resources'), findsWidgets);
    expect(
        find.text(
            'Resource details, config views, events, logs, and future diff-aware editing flows will live here.'),
        findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Alerts'));
    await tester.pumpAndSettle();
    expect(find.text('Alerts'), findsWidgets);
    expect(
        find.text(
            'Operational health summaries, node pressure, and prioritized issue overlays will be summarized in this area.'),
        findsOneWidget);

    await resetTestSurface(tester);
  });
}
