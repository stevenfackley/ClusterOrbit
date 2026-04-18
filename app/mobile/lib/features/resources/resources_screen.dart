import 'package:flutter/material.dart';

import '../../core/cluster_domain/cluster_models.dart';

class ResourcesScreen extends StatefulWidget {
  const ResourcesScreen({
    super.key,
    this.snapshot,
    this.isLoading = false,
    this.onRefresh,
  });

  final ClusterSnapshot? snapshot;
  final bool isLoading;
  final Future<void> Function()? onRefresh;

  @override
  State<ResourcesScreen> createState() => _ResourcesScreenState();
}

class _ResourcesScreenState extends State<ResourcesScreen> {
  final _queryController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _queryController.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    setState(() => _query = value.trim().toLowerCase());
  }

  void _clearQuery() {
    _queryController.clear();
    setState(() => _query = '');
  }

  Widget _refreshWrap(Widget child) {
    if (widget.onRefresh == null) return child;
    return RefreshIndicator(onRefresh: widget.onRefresh!, child: child);
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = widget.snapshot;
    if (snapshot == null) {
      return _refreshWrap(const _EmptyResourcesState());
    }

    final q = _query;
    final filteredNodes =
        q.isEmpty ? snapshot.nodes : snapshot.nodes.where(_matchNode).toList();
    final filteredWorkloads = q.isEmpty
        ? snapshot.workloads
        : snapshot.workloads.where(_matchWorkload).toList();
    final filteredServices = q.isEmpty
        ? snapshot.services
        : snapshot.services.where(_matchService).toList();

    return DefaultTabController(
      length: 3,
      child: Column(
        children: [
          _SearchField(
            controller: _queryController,
            onChanged: _onQueryChanged,
            onClear: _clearQuery,
            hasQuery: q.isNotEmpty,
          ),
          TabBar(
            tabs: [
              Tab(
                  text: _tabLabel('Nodes', filteredNodes.length,
                      snapshot.nodes.length, q.isNotEmpty)),
              Tab(
                  text: _tabLabel('Workloads', filteredWorkloads.length,
                      snapshot.workloads.length, q.isNotEmpty)),
              Tab(
                  text: _tabLabel('Services', filteredServices.length,
                      snapshot.services.length, q.isNotEmpty)),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                _refreshWrap(
                    _NodeList(nodes: filteredNodes, hasQuery: q.isNotEmpty)),
                _refreshWrap(_WorkloadList(
                    workloads: filteredWorkloads, hasQuery: q.isNotEmpty)),
                _refreshWrap(_ServiceList(
                    services: filteredServices, hasQuery: q.isNotEmpty)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  bool _matchNode(ClusterNode n) => n.name.toLowerCase().contains(_query);

  bool _matchWorkload(ClusterWorkload w) =>
      w.name.toLowerCase().contains(_query) ||
      w.namespace.toLowerCase().contains(_query);

  bool _matchService(ClusterService s) =>
      s.name.toLowerCase().contains(_query) ||
      s.namespace.toLowerCase().contains(_query);

  static String _tabLabel(String label, int shown, int total, bool filtering) {
    if (!filtering) return '$label ($total)';
    return '$label ($shown/$total)';
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.controller,
    required this.onChanged,
    required this.onClear,
    required this.hasQuery,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;
  final bool hasQuery;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        decoration: InputDecoration(
          isDense: true,
          prefixIcon: const Icon(Icons.search, size: 20),
          hintText: 'Filter by name or namespace',
          suffixIcon: hasQuery
              ? IconButton(
                  icon: const Icon(Icons.clear, size: 18),
                  onPressed: onClear,
                  tooltip: 'Clear filter',
                )
              : null,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }
}

class _EmptyResourcesState extends StatelessWidget {
  const _EmptyResourcesState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(24),
      children: [
        const SizedBox(height: 120),
        Text(
          'No cluster snapshot yet. Resources will appear when a cluster is connected.',
          style: theme.textTheme.bodyLarge,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

class _NodeList extends StatelessWidget {
  const _NodeList({required this.nodes, required this.hasQuery});

  final List<ClusterNode> nodes;
  final bool hasQuery;

  @override
  Widget build(BuildContext context) {
    if (nodes.isEmpty) {
      return _EmptySection(
        label: hasQuery ? 'No nodes match the filter.' : 'No nodes reported.',
      );
    }
    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
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
  const _WorkloadList({required this.workloads, required this.hasQuery});

  final List<ClusterWorkload> workloads;
  final bool hasQuery;

  @override
  Widget build(BuildContext context) {
    if (workloads.isEmpty) {
      return _EmptySection(
        label: hasQuery
            ? 'No workloads match the filter.'
            : 'No workloads reported.',
      );
    }
    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
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
  const _ServiceList({required this.services, required this.hasQuery});

  final List<ClusterService> services;
  final bool hasQuery;

  @override
  Widget build(BuildContext context) {
    if (services.isEmpty) {
      return _EmptySection(
        label: hasQuery
            ? 'No services match the filter.'
            : 'No services reported.',
      );
    }
    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
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
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(24),
      children: [
        const SizedBox(height: 80),
        Center(child: Text(label)),
      ],
    );
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
