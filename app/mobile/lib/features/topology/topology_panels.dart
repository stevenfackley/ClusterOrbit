import 'package:flutter/material.dart';

import '../../core/cluster_domain/cluster_models.dart';
import '../../core/connectivity/cluster_connection.dart';
import '../../core/sync_cache/snapshot_store.dart';
import '../../core/theme/clusterorbit_theme.dart';
import 'entity_detail_panel.dart';
import 'topology_orbs.dart';

/// Tablet/wide-layout right rail: flight-deck metrics over either the
/// alerts or, while an entity is selected, its detail panel. Owns layout,
/// not data.
class TopologySidebar extends StatelessWidget {
  const TopologySidebar({
    super.key,
    required this.snapshot,
    required this.palette,
    required this.selectedEntity,
    required this.onDismiss,
    required this.connection,
    required this.clusterId,
    required this.store,
  });

  final ClusterSnapshot snapshot;
  final ClusterOrbitPalette palette;
  final Object? selectedEntity;
  final VoidCallback onDismiss;
  final ClusterConnection? connection;
  final String? clusterId;
  final SnapshotStore? store;

  @override
  Widget build(BuildContext context) {
    final alerts = snapshot.alerts.take(4).toList();
    return LayoutBuilder(
      builder: (context, constraints) => Column(
        children: [
          // Natural height up to half the rail; scrolls past that.
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: constraints.maxHeight / 2),
            child: SingleChildScrollView(
              primary: false,
              child: _InsightPanel(snapshot: snapshot),
            ),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: selectedEntity == null
                ? _AlertPanel(alerts: alerts)
                : SingleChildScrollView(
                    child: EntityDetailPanel(
                      entity: selectedEntity!,
                      palette: palette,
                      onDismiss: onDismiss,
                      connection: connection,
                      clusterId: clusterId,
                      store: store,
                      profileId: clusterId,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _InsightPanel extends StatelessWidget {
  const _InsightPanel({required this.snapshot});

  final ClusterSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Flight Deck', style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              '${snapshot.profile.apiServerHost} / ${snapshot.profile.environmentLabel}',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 18),
            MetricRow(
                label: 'Control planes',
                value: '${snapshot.controlPlaneCount}'),
            MetricRow(label: 'Workers', value: '${snapshot.workerCount}'),
            MetricRow(
                label: 'Unschedulable',
                value: '${snapshot.unschedulableNodeCount}'),
            MetricRow(
                label: 'Critical alerts', value: '${snapshot.criticalCount}'),
          ],
        ),
      ),
    );
  }
}

class _AlertPanel extends StatelessWidget {
  const _AlertPanel({required this.alerts});

  final List<ClusterAlert> alerts;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Priority Alerts', style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              'The canvas stays read-only for now, so this rail is the fast path to what needs attention.',
              style: theme.textTheme.bodyMedium,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 16),
            Expanded(
              child: alerts.isEmpty
                  ? Center(
                      child: Text(
                        'No active alerts in this snapshot.',
                        style: theme.textTheme.bodyMedium,
                      ),
                    )
                  : ListView.separated(
                      itemCount: alerts.length,
                      itemBuilder: (context, index) =>
                          AlertTile(alert: alerts[index]),
                      separatorBuilder: (_, __) => const SizedBox(height: 12),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
