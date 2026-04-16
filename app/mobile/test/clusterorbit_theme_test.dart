import 'package:clusterorbit_mobile/core/theme/clusterorbit_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('dark theme uses expected scaffold and material settings', () {
    final theme = ClusterOrbitTheme.dark();
    final palette = theme.extension<ClusterOrbitPalette>();

    expect(theme.useMaterial3, isTrue);
    expect(theme.scaffoldBackgroundColor, const Color(0xFF09111F));
    expect(theme.colorScheme.primary, const Color(0xFF49D8D0));
    expect(palette, isNotNull);
    expect(palette!.panel, const Color(0xFF162238));
  });

  test('palette copyWith and lerp preserve values correctly', () {
    const base = ClusterOrbitPalette(
      canvasGlow: Color(0xFF000001),
      accentTeal: Color(0xFF000002),
      accentCyan: Color(0xFF000003),
      warning: Color(0xFF000004),
      panel: Color(0xFF000005),
    );
    const target = ClusterOrbitPalette(
      canvasGlow: Color(0xFF100001),
      accentTeal: Color(0xFF100002),
      accentCyan: Color(0xFF100003),
      warning: Color(0xFF100004),
      panel: Color(0xFF100005),
    );

    final copied = base.copyWith(panel: const Color(0xFFABCDEF));
    final lerped = base.lerp(target, 1);

    expect(copied.panel, const Color(0xFFABCDEF));
    expect(copied.accentTeal, base.accentTeal);
    expect(lerped.canvasGlow, target.canvasGlow);
    expect(lerped.warning, target.warning);
  });
}
