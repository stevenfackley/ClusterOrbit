import 'package:flutter/material.dart';

import '../../core/cluster_domain/cluster_models.dart';

class ChangesScreen extends StatelessWidget {
  const ChangesScreen({super.key, this.snapshot, this.isLoading = false});

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
              'No snapshot yet. Drift will appear when a cluster is connected.'),
        ),
      );
    }

    final drift = snapshot.workloads
        .where((w) => w.readyReplicas != w.desiredReplicas)
        .toList()
      ..sort((a, b) => (b.desiredReplicas - b.readyReplicas)
          .compareTo(a.desiredReplicas - a.readyReplicas));

    final unschedulable = snapshot.nodes.where((n) => !n.schedulable).toList();

    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Snapshot', style: theme.textTheme.titleMedium),
                const SizedBox(height: 4),
                Text('Captured ${snapshot.generatedAt.toIso8601String()}'),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'Workload drift (${drift.length})',
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 4),
        Text(
          'Workloads where ready replicas do not match desired.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        if (drift.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('All workloads at desired replica count.'),
          )
        else
          for (final w in drift)
            Card(
              child: ListTile(
                leading: const Icon(Icons.sync_problem_outlined,
                    color: Colors.amber),
                title: Text('${w.namespace} / ${w.name}'),
                subtitle: Text(
                    '${w.kind.label} · ${w.readyReplicas}/${w.desiredReplicas} ready'),
              ),
            ),
        const SizedBox(height: 16),
        Text(
          'Unschedulable nodes (${unschedulable.length})',
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        if (unschedulable.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('All nodes are schedulable.'),
          )
        else
          for (final n in unschedulable)
            Card(
              child: ListTile(
                leading: const Icon(Icons.block_outlined, color: Colors.amber),
                title: Text(n.name),
                subtitle: Text('${n.role.label} · ${n.zone}'),
              ),
            ),
      ],
    );
  }
}
