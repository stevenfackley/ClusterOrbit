import 'package:flutter/material.dart';

import '../../core/cluster_domain/cluster_models.dart';

class ResourcesScreen extends StatelessWidget {
  const ResourcesScreen({super.key, this.snapshot, this.isLoading = false});

  final ClusterSnapshot? snapshot;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    final snapshot = this.snapshot;
    if (snapshot == null) {
      return const _EmptyResourcesState();
    }

    return DefaultTabController(
      length: 3,
      child: Column(
        children: [
          TabBar(
            tabs: [
              Tab(text: 'Nodes (${snapshot.nodes.length})'),
              Tab(text: 'Workloads (${snapshot.workloads.length})'),
              Tab(text: 'Services (${snapshot.services.length})'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                _NodeList(nodes: snapshot.nodes),
                _WorkloadList(workloads: snapshot.workloads),
                _ServiceList(services: snapshot.services),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyResourcesState extends StatelessWidget {
  const _EmptyResourcesState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          'No cluster snapshot yet. Resources will appear when a cluster is connected.',
          style: theme.textTheme.bodyLarge,
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

class _NodeList extends StatelessWidget {
  const _NodeList({required this.nodes});

  final List<ClusterNode> nodes;

  @override
  Widget build(BuildContext context) {
    if (nodes.isEmpty) {
      return const _EmptySection(label: 'No nodes reported.');
    }
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: nodes.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final node = nodes[i];
        return Card(
          child: ListTile(
            leading: _HealthDot(level: node.health),
            title: Text(node.name),
            subtitle: Text(
              '${node.role.label} · ${node.version} · ${node.zone}\n'
              '${node.podCount} pods · ${node.cpuCapacity} CPU · ${node.memoryCapacity}',
            ),
            isThreeLine: true,
            trailing:
                node.schedulable ? null : const Chip(label: Text('Cordoned')),
          ),
        );
      },
    );
  }
}

class _WorkloadList extends StatelessWidget {
  const _WorkloadList({required this.workloads});

  final List<ClusterWorkload> workloads;

  @override
  Widget build(BuildContext context) {
    if (workloads.isEmpty) {
      return const _EmptySection(label: 'No workloads reported.');
    }
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: workloads.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final w = workloads[i];
        return Card(
          child: ListTile(
            leading: _HealthDot(level: w.health),
            title: Text('${w.namespace} / ${w.name}'),
            subtitle: Text(
              '${w.kind.label} · ${w.readyReplicas}/${w.desiredReplicas} ready\n'
              '${w.images.isEmpty ? 'no image' : w.images.join(', ')}',
            ),
            isThreeLine: true,
          ),
        );
      },
    );
  }
}

class _ServiceList extends StatelessWidget {
  const _ServiceList({required this.services});

  final List<ClusterService> services;

  @override
  Widget build(BuildContext context) {
    if (services.isEmpty) {
      return const _EmptySection(label: 'No services reported.');
    }
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: services.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final s = services[i];
        final portLabels = s.ports
            .map((p) => '${p.port}->${p.targetPort}/${p.protocol}')
            .join(', ');
        return Card(
          child: ListTile(
            leading: _HealthDot(level: s.health),
            title: Text('${s.namespace} / ${s.name}'),
            subtitle: Text(
              '${s.exposure.label} · ${s.clusterIp ?? 'no ClusterIP'}\n'
              '${portLabels.isEmpty ? 'no ports' : portLabels}',
            ),
            isThreeLine: true,
          ),
        );
      },
    );
  }
}

class _EmptySection extends StatelessWidget {
  const _EmptySection({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Center(child: Text(label));
  }
}

class _HealthDot extends StatelessWidget {
  const _HealthDot({required this.level});

  final ClusterHealthLevel level;

  @override
  Widget build(BuildContext context) {
    final color = switch (level) {
      ClusterHealthLevel.healthy => Colors.green,
      ClusterHealthLevel.warning => Colors.amber,
      ClusterHealthLevel.critical => Colors.redAccent,
    };
    return Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
      ),
    );
  }
}
