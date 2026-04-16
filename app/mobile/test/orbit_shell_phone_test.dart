import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

void main() {
  testWidgets('phone layout shows bottom navigation and cluster switcher',
      (tester) async {
    await pumpClusterOrbitApp(tester, size: const Size(390, 844));

    expect(find.text('Switch Cluster'), findsOneWidget);
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
    expect(
        find.text(
            'Resource details, config views, events, logs, and future diff-aware editing flows will live here.'),
        findsOneWidget);

    await tester.tap(find.text('Changes'));
    await tester.pumpAndSettle();
    expect(
        find.text(
            'The changes view will track drafts, recent mutations, approvals, and rollback-friendly previews.'),
        findsOneWidget);

    await tester.tap(find.text('Alerts'));
    await tester.pumpAndSettle();
    expect(
        find.text(
            'Operational health summaries, node pressure, and prioritized issue overlays will be summarized in this area.'),
        findsOneWidget);

    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(
        find.text(
            'Cluster profiles, connection modes, caching, theme tuning, and security preferences will be managed here.'),
        findsOneWidget);

    await resetTestSurface(tester);
  });
}
