import 'package:clusterorbit_mobile/app/clusterorbit_app.dart';
import 'package:clusterorbit_mobile/core/theme/clusterorbit_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

void main() {
  testWidgets('MaterialApp uses ClusterOrbit identity and dark mode',
      (tester) async {
    await tester.pumpWidget(
      ClusterOrbitApp(
        connection: TestClusterConnection(),
        store: const NoOpSnapshotStore(),
      ),
    );

    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));

    expect(app.title, 'ClusterOrbit');
    expect(app.debugShowCheckedModeBanner, isFalse);
    expect(app.themeMode, ThemeMode.dark);
    expect(app.darkTheme, isNotNull);
    expect(app.theme, isNotNull);
  });

  testWidgets('dark theme exposes ClusterOrbit palette extension',
      (tester) async {
    await tester.pumpWidget(
      ClusterOrbitApp(
        connection: TestClusterConnection(),
        store: const NoOpSnapshotStore(),
      ),
    );

    final context = tester.element(find.byType(Scaffold).first);
    final palette = Theme.of(context).extension<ClusterOrbitPalette>();

    expect(palette, isNotNull);
    expect(palette!.accentTeal, const Color(0xFF49D8D0));
    expect(palette.canvasGlow, const Color(0xFF778DFF));
  });
}
