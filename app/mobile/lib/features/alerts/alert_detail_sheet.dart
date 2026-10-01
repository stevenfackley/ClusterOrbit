import 'package:flutter/material.dart';

import '../../core/cluster_domain/cluster_models.dart';
import '../../core/theme/clusterorbit_theme.dart';
import '../../core/theme/health_style.dart';

String _nextSteps(ClusterHealthLevel level) => switch (level) {
      ClusterHealthLevel.critical =>
        'Investigate immediately. Check audit log for related events.',
      ClusterHealthLevel.warning => 'Review when convenient. Not blocking.',
      ClusterHealthLevel.healthy => 'No action required.',
    };

class AlertDetailSheet extends StatelessWidget {
  const AlertDetailSheet({super.key, required this.alert});

  final ClusterAlert alert;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final levelColor =
        alert.level.color(theme.extension<ClusterOrbitPalette>()!);

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header
          Row(
            children: [
              Icon(
                alert.level.icon,
                color: levelColor,
                size: 28,
                semanticLabel: alert.level.label,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  alert.title,
                  style: theme.textTheme.titleLarge,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Metadata chips
          Wrap(
            spacing: 8,
            children: [
              Chip(
                label: Text(alert.level.name.toUpperCase()),
                backgroundColor: levelColor.withValues(alpha: 0.15),
                labelStyle: TextStyle(color: levelColor, fontSize: 12),
              ),
              Chip(
                label: Text('Scope: ${alert.scope}'),
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Summary
          Text('Summary', style: theme.textTheme.labelLarge),
          const SizedBox(height: 4),
          Text(alert.summary, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 16),

          // Recommended next steps
          Text('Recommended next steps', style: theme.textTheme.labelLarge),
          const SizedBox(height: 4),
          Text(_nextSteps(alert.level), style: theme.textTheme.bodyMedium),
        ],
      ),
    );
  }
}
