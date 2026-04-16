import 'package:flutter/material.dart';

class ClusterOrbitTheme {
  static const Color _space = Color(0xFF09111F);
  static const Color _surface = Color(0xFF111B2C);
  static const Color _panel = Color(0xFF162238);
  static const Color _teal = Color(0xFF49D8D0);
  static const Color _cyan = Color(0xFF82E8FF);
  static const Color _indigo = Color(0xFF778DFF);
  static const Color _danger = Color(0xFFFF6F7A);
  static const Color _warning = Color(0xFFFFB86B);

  static ThemeData dark() {
    const scheme = ColorScheme.dark(
      primary: _teal,
      secondary: _cyan,
      tertiary: _indigo,
      surface: _surface,
      error: _danger,
    );

    return ThemeData(
      colorScheme: scheme,
      scaffoldBackgroundColor: _space,
      useMaterial3: true,
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      cardTheme: CardThemeData(
        color: _panel.withValues(alpha: 0.88),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: BorderSide(color: Colors.white.withValues(alpha: 0.06)),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: Colors.white.withValues(alpha: 0.06),
        selectedColor: _teal.withValues(alpha: 0.16),
        labelStyle: const TextStyle(color: Colors.white),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: _surface.withValues(alpha: 0.92),
        indicatorColor: _teal.withValues(alpha: 0.16),
        labelTextStyle: WidgetStateProperty.all(
          const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      textTheme: const TextTheme(
        headlineMedium: TextStyle(
          fontSize: 28,
          fontWeight: FontWeight.w700,
          color: Colors.white,
        ),
        titleLarge: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: Colors.white,
        ),
        bodyLarge: TextStyle(
          fontSize: 16,
          color: Color(0xFFD0D8E6),
        ),
        bodyMedium: TextStyle(
          fontSize: 14,
          color: Color(0xFFB6C0D3),
        ),
      ),
      extensions: const <ThemeExtension<dynamic>>[
        ClusterOrbitPalette(
          canvasGlow: _indigo,
          accentTeal: _teal,
          accentCyan: _cyan,
          warning: _warning,
          panel: _panel,
        ),
      ],
    );
  }

  static ThemeData light() {
    return ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: _indigo),
    );
  }
}

@immutable
class ClusterOrbitPalette extends ThemeExtension<ClusterOrbitPalette> {
  const ClusterOrbitPalette({
    required this.canvasGlow,
    required this.accentTeal,
    required this.accentCyan,
    required this.warning,
    required this.panel,
  });

  final Color canvasGlow;
  final Color accentTeal;
  final Color accentCyan;
  final Color warning;
  final Color panel;

  @override
  ClusterOrbitPalette copyWith({
    Color? canvasGlow,
    Color? accentTeal,
    Color? accentCyan,
    Color? warning,
    Color? panel,
  }) {
    return ClusterOrbitPalette(
      canvasGlow: canvasGlow ?? this.canvasGlow,
      accentTeal: accentTeal ?? this.accentTeal,
      accentCyan: accentCyan ?? this.accentCyan,
      warning: warning ?? this.warning,
      panel: panel ?? this.panel,
    );
  }

  @override
  ClusterOrbitPalette lerp(
      ThemeExtension<ClusterOrbitPalette>? other, double t) {
    if (other is! ClusterOrbitPalette) {
      return this;
    }

    return ClusterOrbitPalette(
      canvasGlow: Color.lerp(canvasGlow, other.canvasGlow, t) ?? canvasGlow,
      accentTeal: Color.lerp(accentTeal, other.accentTeal, t) ?? accentTeal,
      accentCyan: Color.lerp(accentCyan, other.accentCyan, t) ?? accentCyan,
      warning: Color.lerp(warning, other.warning, t) ?? warning,
      panel: Color.lerp(panel, other.panel, t) ?? panel,
    );
  }
}
