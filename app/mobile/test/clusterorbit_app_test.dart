import 'package:clusterorbit_mobile/app/clusterorbit_app.dart';
import 'package:clusterorbit_mobile/core/theme/clusterorbit_theme.dart';
import 'package:clusterorbit_mobile/shared/widgets/orbit_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

void main() {
  testWidgets('MaterialApp uses ClusterOrbit identity and the dark theme',
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
    expect(app.theme, isNotNull);
    expect(app.theme!.brightness, Brightness.dark);
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

  testWidgets('forwards autoRefreshInterval to the shell', (tester) async {
    await tester.pumpWidget(
      ClusterOrbitApp(
        connection: TestClusterConnection(),
        store: const NoOpSnapshotStore(),
        autoRefreshInterval: const Duration(seconds: 5),
      ),
    );

    final shell = tester.widget<OrbitShell>(find.byType(OrbitShell));
    expect(shell.autoRefreshInterval, const Duration(seconds: 5));
  });

  testWidgets('pumpClusterOrbitApp mounts the shell without auto-refresh',
      (tester) async {
    await pumpClusterOrbitApp(tester);

    final shell = tester.widget<OrbitShell>(find.byType(OrbitShell));
    expect(shell.autoRefreshInterval, isNull);
  });
}
