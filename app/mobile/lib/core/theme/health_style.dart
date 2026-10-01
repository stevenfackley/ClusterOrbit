import 'package:flutter/material.dart';

import '../cluster_domain/cluster_models.dart';
import 'clusterorbit_theme.dart';

/// The one place a [ClusterHealthLevel] maps to a color, icon and label, so
/// health is never shown by color alone.
extension HealthStyle on ClusterHealthLevel {
  Color color(ClusterOrbitPalette palette) => switch (this) {
        ClusterHealthLevel.healthy => palette.accentTeal,
        ClusterHealthLevel.warning => palette.warning,
        ClusterHealthLevel.critical => palette.danger,
      };

  IconData get icon => switch (this) {
        ClusterHealthLevel.healthy => Icons.check_circle_outline,
        ClusterHealthLevel.warning => Icons.warning_amber_outlined,
        ClusterHealthLevel.critical => Icons.error_outline,
      };

  String get label => switch (this) {
        ClusterHealthLevel.healthy => 'Healthy',
        ClusterHealthLevel.warning => 'Warning',
        ClusterHealthLevel.critical => 'Critical',
      };
}
