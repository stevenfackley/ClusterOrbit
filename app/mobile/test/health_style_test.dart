import 'dart:ui' show Tristate;

import 'package:clusterorbit_mobile/core/cluster_domain/cluster_models.dart';
import 'package:clusterorbit_mobile/core/connectivity/sample_cluster_data.dart';
import 'package:clusterorbit_mobile/core/theme/clusterorbit_theme.dart';
import 'package:clusterorbit_mobile/core/theme/health_style.dart';
import 'package:clusterorbit_mobile/features/resources/resources_screen.dart';
import 'package:clusterorbit_mobile/features/topology/topology_orbs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _palette = ClusterOrbitPalette(
  canvasGlow: Color(0xFF000001),
  accentTeal: Color(0xFF000002),
  accentCyan: Color(0xFF000003),
  warning: Color(0xFF000004),
  panel: Color(0xFF000005),
  danger: Color(0xFF000006),
);

void main() {
  test('HealthStyle colors come from the palette', () {
    expect(ClusterHealthLevel.healthy.color(_palette), _palette.accentTeal);
    expect(ClusterHealthLevel.warning.color(_palette), _palette.warning);
    expect(ClusterHealthLevel.critical.color(_palette), _palette.danger);
    expect(healthTint(ClusterHealthLevel.critical, _palette), _palette.danger);
  });

  test('each level has a distinct icon and label', () {
    final levels = ClusterHealthLevel.values;
    expect(levels.map((l) => l.icon).toSet().length, levels.length);
    expect(levels.map((l) => l.label).toSet().length, levels.length);
  });

  test('palette danger defaults to the dark theme red and survives lerp', () {
    final dark = ClusterOrbitTheme.dark().extension<ClusterOrbitPalette>()!;
    const legacy = ClusterOrbitPalette(
      canvasGlow: Color(0xFF000001),
      accentTeal: Color(0xFF000002),
      accentCyan: Color(0xFF000003),
      warning: Color(0xFF000004),
      panel: Color(0xFF000005),
    );
    expect(legacy.danger, dark.danger);
    expect(_palette.copyWith(danger: Colors.red).danger, Colors.red);
    expect(legacy.lerp(_palette, 1).danger, _palette.danger);
  });

  testWidgets('Resources health indicator is labelled for screen readers',
      (tester) async {
    final handle = tester.ensureSemantics();
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1280, 900);
    addTearDown(tester.view.reset);
    final profile = SampleClusterData.profilesFor(ConnectionMode.direct).first;
    final snapshot = SampleClusterData.snapshotFor(profile);
    await tester.pumpWidget(MaterialApp(
      theme: ClusterOrbitTheme.dark(),
      home: Scaffold(body: ResourcesScreen(snapshot: snapshot)),
    ));
    await tester.pumpAndSettle();

    final first = snapshot.nodes.first.health;
    expect(find.bySemanticsLabel(RegExp(first.label)), findsWidgets);
    handle.dispose();
  });

  testWidgets('CanvasNode exposes button and selected semantics',
      (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Stack(
          children: [
            CanvasNode(
              offset: Offset.zero,
              selected: true,
              onTap: () {},
              child: const SizedBox(width: 60, height: 60),
            ),
          ],
        ),
      ),
    ));

    final data =
        tester.getSemantics(find.byType(CanvasNode)).getSemanticsData();
    expect(data.flagsCollection.isButton, isTrue);
    expect(data.flagsCollection.isSelected, Tristate.isTrue);
    handle.dispose();
  });
}
