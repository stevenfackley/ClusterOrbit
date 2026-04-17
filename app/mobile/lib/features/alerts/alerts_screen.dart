import 'package:flutter/material.dart';

import '../../core/cluster_domain/cluster_models.dart';

class AlertsScreen extends StatelessWidget {
  const AlertsScreen({super.key, this.snapshot, this.isLoading = false});

  final ClusterSnapshot? snapshot;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    final snapshot = this.snapshot;
    if (snapshot == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
              'No snapshot yet. Alerts will appear when a cluster is connected.'),
        ),
      );
    }

    final alerts = [...snapshot.alerts]..sort((a, b) {
        final aPri = _priority(a.level);
        final bPri = _priority(b.level);
        return bPri.compareTo(aPri);
      });

    if (alerts.isEmpty) {
      final theme = Theme.of(context);
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.check_circle_outline,
                size: 48,
                color: Colors.green.withValues(alpha: 0.8),
              ),
              const SizedBox(height: 12),
              Text(
                'All clear — no active alerts in this snapshot.',
                style: theme.textTheme.bodyLarge,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: alerts.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final a = alerts[i];
        return Card(
          child: ListTile(
            leading: Icon(
              _icon(a.level),
              color: _color(a.level),
            ),
            title: Text(a.title),
            subtitle: Text('${a.summary}\nScope: ${a.scope}'),
            isThreeLine: true,
            trailing: Chip(
              label: Text(a.level.name),
              backgroundColor: _color(a.level).withValues(alpha: 0.15),
            ),
          ),
        );
      },
    );
  }

  int _priority(ClusterHealthLevel level) => switch (level) {
        ClusterHealthLevel.critical => 2,
        ClusterHealthLevel.warning => 1,
        ClusterHealthLevel.healthy => 0,
      };

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
}
