import 'package:flutter/material.dart';

import '../../core/cluster_domain/cluster_models.dart';

// Level helpers — duplicated from alerts_screen.dart intentionally (no public API).
IconData _icon(ClusterHealthLevel level) => switch (level) {
      ClusterHealthLevel.critical => Icons.error_outline,
      ClusterHealthLevel.warning => Icons.warning_amber_outlined,
      ClusterHealthLevel.healthy => Icons.check_circle_outline,
    };

Color _color(ClusterHealthLevel level) => switch (level) {
      ClusterHealthLevel.critical => Colors.redAccent,
      ClusterHealthLevel.warning => Colors.amber,
      ClusterHealthLevel.healthy => Colors.green,
    };

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
    final levelColor = _color(alert.level);

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header
          Row(
            children: [
              Icon(_icon(alert.level), color: levelColor, size: 28),
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
          const SizedBox(height: 24),

          // Action buttons — STUBS only, not wired to any backend
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _stubAction(context, 'Acknowledge'),
                  child: const Text('Acknowledge'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _stubAction(context, 'Silence for 1h'),
                  child: const Text('Silence for 1h'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // TODO: wire to real backend action (see roadmap)
  void _stubAction(BuildContext context, String label) {
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '$label is not yet wired — see roadmap',
        ),
      ),
    );
  }
}
