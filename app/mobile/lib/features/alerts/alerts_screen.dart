import 'package:flutter/material.dart';

import '../../core/cluster_domain/cluster_models.dart';
import '../../core/theme/clusterorbit_theme.dart';
import '../../core/theme/health_style.dart';
import '../../shared/widgets/refreshable.dart';
import 'alert_detail_sheet.dart';

class AlertsScreen extends StatelessWidget {
  const AlertsScreen({
    super.key,
    this.snapshot,
    this.isLoading = false,
    this.error,
    this.onRefresh,
  });

  final ClusterSnapshot? snapshot;
  final bool isLoading;
  final Object? error;
  final Future<void> Function()? onRefresh;

  @override
  Widget build(BuildContext context) {
    final snapshot = this.snapshot;
    if (snapshot == null) {
      return NoSnapshotView(
        isLoading: isLoading,
        error: error,
        onRefresh: onRefresh,
        emptyMessage:
            'No snapshot yet. Alerts will appear when a cluster is connected.',
      );
    }

    final palette = Theme.of(context).extension<ClusterOrbitPalette>()!;
    final alerts = [...snapshot.alerts]..sort((a, b) {
        final aPri = _priority(a.level);
        final bPri = _priority(b.level);
        return bPri.compareTo(aPri);
      });

    if (alerts.isEmpty) {
      final theme = Theme.of(context);
      return MaybeRefreshIndicator(
        onRefresh: onRefresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(24),
          children: [
            const SizedBox(height: 80),
            Icon(
              Icons.check_circle_outline,
              size: 48,
              color: ClusterHealthLevel.healthy
                  .color(palette)
                  .withValues(alpha: 0.8),
            ),
            const SizedBox(height: 12),
            Text(
              'All clear — no active alerts in this snapshot.',
              style: theme.textTheme.bodyLarge,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    return MaybeRefreshIndicator(
        onRefresh: onRefresh,
        child: ListView.separated(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          itemCount: alerts.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, i) {
            final a = alerts[i];
            return Card(
              child: ListTile(
                leading: Icon(
                  a.level.icon,
                  color: a.level.color(palette),
                  semanticLabel: a.level.label,
                ),
                title: Text(a.title),
                subtitle: Text('${a.summary}\nScope: ${a.scope}'),
                isThreeLine: true,
                onTap: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  useSafeArea: true,
                  showDragHandle: true,
                  builder: (_) => AlertDetailSheet(alert: a),
                ),
              ),
            );
          },
        ));
  }

  int _priority(ClusterHealthLevel level) => switch (level) {
        ClusterHealthLevel.critical => 2,
        ClusterHealthLevel.warning => 1,
        ClusterHealthLevel.healthy => 0,
      };
}
