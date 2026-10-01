import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

void main() {
  testWidgets(
      'tablet layout shows rail with counts instead of bottom navigation',
      (tester) async {
    await pumpClusterOrbitApp(tester, size: const Size(1366, 1024));

    expect(find.byType(NavigationBar), findsNothing);
    expect(find.text('ClusterOrbit'), findsOneWidget);
    expect(find.text('Inspector'), findsNothing);
    expect(find.text('Open change preview'), findsNothing);
    expect(find.text('3 clusters'), findsOneWidget);
    expect(find.text('42 nodes'), findsOneWidget);
    expect(find.text('3 control planes'), findsOneWidget);
    expect(find.text('39 workers'), findsOneWidget);
    expect(find.text('1 unschedulable'), findsOneWidget);
    expect(find.text('5 alerts'), findsOneWidget);

    await resetTestSurface(tester);
  });

  testWidgets('tablet rail changes selected section', (tester) async {
    await pumpClusterOrbitApp(tester, size: const Size(1366, 1024));

    await tester.tap(find.widgetWithText(FilledButton, 'Resources'));
    await tester.pumpAndSettle();
    // Resources now renders tabs over the real snapshot data.
    expect(find.textContaining('Nodes ('), findsOneWidget);
    expect(find.textContaining('Workloads ('), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Alerts'));
    await tester.pumpAndSettle();
    // Sample snapshot provides alerts; verify one rendered.
    expect(find.text('API latency elevated'), findsOneWidget);

    await resetTestSurface(tester);
  });

  testWidgets('tablet rail scrolls instead of overflowing with the keyboard up',
      (tester) async {
    await pumpClusterOrbitApp(tester, size: const Size(1024, 768));
    await tester.tap(find.widgetWithText(FilledButton, 'Resources'));
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 360);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // Chips live at the bottom of the scrollable rail; they stay reachable.
    await tester.scrollUntilVisible(
      find.text('5 alerts'),
      100,
      scrollable: find
          .descendant(
            of: find.byType(Card).first,
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.text('5 alerts'), findsOneWidget);

    tester.view.resetViewInsets();
    await resetTestSurface(tester);
  });
}
