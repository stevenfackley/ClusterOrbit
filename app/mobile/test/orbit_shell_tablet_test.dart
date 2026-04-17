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
    // Resources now renders tabs over the real snapshot data.
    expect(find.textContaining('Nodes ('), findsOneWidget);
    expect(find.textContaining('Workloads ('), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Alerts'));
    await tester.pumpAndSettle();
    // Sample snapshot provides alerts; verify one rendered.
    expect(find.text('API latency elevated'), findsOneWidget);

    await resetTestSurface(tester);
  });
}
