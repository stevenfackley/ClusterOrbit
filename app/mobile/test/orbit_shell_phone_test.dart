import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

void main() {
  testWidgets('phone layout shows bottom navigation and cluster switcher',
      (tester) async {
    await pumpClusterOrbitApp(tester, size: const Size(390, 844));

    expect(find.byTooltip('Switch cluster'), findsOneWidget);
    expect(find.text('Map'), findsOneWidget);
    expect(find.text('Resources'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);

    await resetTestSurface(tester);
  });

  testWidgets('phone navigation switches between top-level sections',
      (tester) async {
    await pumpClusterOrbitApp(tester, size: const Size(390, 844));

    expect(find.text('Cluster Map'), findsWidgets);

    await tester.tap(find.text('Resources'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Nodes ('), findsOneWidget);

    await tester.tap(find.text('Changes'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Workload drift'), findsOneWidget);

    await tester.tap(find.text('Alerts'));
    await tester.pumpAndSettle();
    expect(find.text('API latency elevated'), findsOneWidget);

    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(
        find.text(
            'Cluster profiles, connection modes, caching, theme tuning, and security preferences will be managed here.'),
        findsOneWidget);

    await resetTestSurface(tester);
  });
}
