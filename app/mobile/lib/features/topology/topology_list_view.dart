import 'package:flutter/material.dart';

import '../../core/cluster_domain/cluster_models.dart';
import '../../core/connectivity/cluster_connection.dart';
import '../../core/sync_cache/snapshot_store.dart';
import '../../core/theme/clusterorbit_theme.dart';
import 'entity_detail_panel.dart';
import 'topology_orbs.dart';

/// Phone-first scrollable list of nodes, workloads, and services grouped into
/// collapsible sections.  Tapping any row opens [EntityDetailPanel] in a
/// modal bottom-sheet.
class TopologyListView extends StatelessWidget {
  const TopologyListView({
    super.key,
    required this.snapshot,
    this.connection,
    this.clusterId,
    this.store,
    this.onRefresh,
  });

  final ClusterSnapshot snapshot;
  final ClusterConnection? connection;
  final String? clusterId;
  final SnapshotStore? store;
  final Future<void> Function()? onRefresh;

  @override
  Widget build(BuildContext context) {
    final list = ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        _NodeSection(
          nodes: snapshot.nodes,
          connection: connection,
          clusterId: clusterId,
          store: store,
        ),
        _WorkloadSection(
          workloads: snapshot.workloads,
          connection: connection,
          clusterId: clusterId,
          store: store,
        ),
        _ServiceSection(
          services: snapshot.services,
          connection: connection,
          clusterId: clusterId,
          store: store,
        ),
      ],
    );
    if (onRefresh == null) return list;
    return RefreshIndicator(onRefresh: onRefresh!, child: list);
  }
}

// ── helpers ─────────────────────────────────────────────────────────────────

void _openDetail(
  BuildContext context,
  Object entity, {
  required ClusterConnection? connection,
  required String? clusterId,
  required SnapshotStore? store,
}) {
  final palette = Theme.of(context).extension<ClusterOrbitPalette>()!;
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    backgroundColor: palette.panel,
    builder: (_) => SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
      child: EntityDetailPanel(
        entity: entity,
        palette: palette,
        onDismiss: () => Navigator.of(context).pop(),
        connection: connection,
        clusterId: clusterId,
        store: store,
        profileId: clusterId,
      ),
    ),
  );
}

Color _healthColor(ClusterHealthLevel level) => switch (level) {
      ClusterHealthLevel.healthy => const Color(0xFF49D8D0),
      ClusterHealthLevel.warning => const Color(0xFFFFB86B),
      ClusterHealthLevel.critical => const Color(0xFFFF6F7A),
    };

Widget _badge(String label, Color bg) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
      ),
    );

// ── Nodes ────────────────────────────────────────────────────────────────────

class _NodeSection extends StatelessWidget {
  const _NodeSection({
    required this.nodes,
    required this.connection,
    required this.clusterId,
    required this.store,
  });

  final List<ClusterNode> nodes;
  final ClusterConnection? connection;
  final String? clusterId;
  final SnapshotStore? store;

  @override
  Widget build(BuildContext context) {
    final byRole = <ClusterNodeRole, List<ClusterNode>>{};
    for (final n in nodes) {
      byRole.putIfAbsent(n.role, () => []).add(n);
    }

    return ExpansionTile(
      key: const ValueKey('nodes-section'),
      initiallyExpanded: true,
      title: Text(
        'Nodes',
        style: Theme.of(context).textTheme.titleMedium,
      ),
      subtitle: Text('${nodes.length} total'),
      children: [
        for (final role in ClusterNodeRole.values)
          if (byRole.containsKey(role)) ...[
            _GroupHeader(label: role.label),
            for (final node in byRole[role]!)
              _NodeRow(
                node: node,
                connection: connection,
                clusterId: clusterId,
                store: store,
              ),
          ],
      ],
    );
  }
}

class _NodeRow extends StatelessWidget {
  const _NodeRow({
    required this.node,
    required this.connection,
    required this.clusterId,
    required this.store,
  });

  final ClusterNode node;
  final ClusterConnection? connection;
  final String? clusterId;
  final SnapshotStore? store;

  @override
  Widget build(BuildContext context) {
    final healthColor = _healthColor(node.health);
    return ListTile(
      dense: true,
      leading: StatusDot(color: healthColor),
      title: Text(node.name, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        node.schedulable ? 'Ready' : 'Unschedulable',
        style: TextStyle(
          color: node.schedulable ? Colors.white54 : const Color(0xFFFFB86B),
        ),
      ),
      trailing: _badge(
        node.role.label,
        node.role == ClusterNodeRole.controlPlane
            ? const Color(0xFF778DFF).withValues(alpha: 0.72)
            : Colors.white.withValues(alpha: 0.12),
      ),
      onTap: () => _openDetail(
        context,
        node,
        connection: connection,
        clusterId: clusterId,
        store: store,
      ),
    );
  }
}

// ── Workloads ────────────────────────────────────────────────────────────────

class _WorkloadSection extends StatelessWidget {
  const _WorkloadSection({
    required this.workloads,
    required this.connection,
    required this.clusterId,
    required this.store,
  });

  final List<ClusterWorkload> workloads;
  final ClusterConnection? connection;
  final String? clusterId;
  final SnapshotStore? store;

  @override
  Widget build(BuildContext context) {
    final byNs = <String, List<ClusterWorkload>>{};
    for (final w in workloads) {
      byNs.putIfAbsent(w.namespace, () => []).add(w);
    }
    final namespaces = byNs.keys.toList()..sort();

    return ExpansionTile(
      key: const ValueKey('workloads-section'),
      initiallyExpanded: true,
      title: Text(
        'Workloads',
        style: Theme.of(context).textTheme.titleMedium,
      ),
      subtitle: Text('${workloads.length} total'),
      children: [
        for (final ns in namespaces) ...[
          _GroupHeader(label: ns),
          for (final w in byNs[ns]!)
            _WorkloadRow(
              workload: w,
              connection: connection,
              clusterId: clusterId,
              store: store,
            ),
        ],
      ],
    );
  }
}

class _WorkloadRow extends StatelessWidget {
  const _WorkloadRow({
    required this.workload,
    required this.connection,
    required this.clusterId,
    required this.store,
  });

  final ClusterWorkload workload;
  final ClusterConnection? connection;
  final String? clusterId;
  final SnapshotStore? store;

  @override
  Widget build(BuildContext context) {
    final healthColor = _healthColor(workload.health);
    return ListTile(
      dense: true,
      leading: StatusDot(color: healthColor),
      title: Text(workload.name, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${workload.readyReplicas}/${workload.desiredReplicas} ready',
      ),
      trailing: _badge(
        workload.kind.label,
        Colors.white.withValues(alpha: 0.12),
      ),
      onTap: () => _openDetail(
        context,
        workload,
        connection: connection,
        clusterId: clusterId,
        store: store,
      ),
    );
  }
}

// ── Services ─────────────────────────────────────────────────────────────────

class _ServiceSection extends StatelessWidget {
  const _ServiceSection({
    required this.services,
    required this.connection,
    required this.clusterId,
    required this.store,
  });

  final List<ClusterService> services;
  final ClusterConnection? connection;
  final String? clusterId;
  final SnapshotStore? store;

  @override
  Widget build(BuildContext context) {
    final byExposure = <ServiceExposure, List<ClusterService>>{};
    for (final s in services) {
      byExposure.putIfAbsent(s.exposure, () => []).add(s);
    }

    return ExpansionTile(
      key: const ValueKey('services-section'),
      initiallyExpanded: true,
      title: Text(
        'Services',
        style: Theme.of(context).textTheme.titleMedium,
      ),
      subtitle: Text('${services.length} total'),
      children: [
        for (final exposure in ServiceExposure.values)
          if (byExposure.containsKey(exposure)) ...[
            _GroupHeader(label: exposure.label),
            for (final svc in byExposure[exposure]!)
              _ServiceRow(
                service: svc,
                connection: connection,
                clusterId: clusterId,
                store: store,
              ),
          ],
      ],
    );
  }
}

class _ServiceRow extends StatelessWidget {
  const _ServiceRow({
    required this.service,
    required this.connection,
    required this.clusterId,
    required this.store,
  });

  final ClusterService service;
  final ClusterConnection? connection;
  final String? clusterId;
  final SnapshotStore? store;

  @override
  Widget build(BuildContext context) {
    final healthColor = _healthColor(service.health);
    return ListTile(
      dense: true,
      leading: StatusDot(color: healthColor),
      title: Text(service.name, overflow: TextOverflow.ellipsis),
      subtitle: Text(service.namespace),
      trailing: _badge(
        service.exposure.label,
        Colors.white.withValues(alpha: 0.12),
      ),
      onTap: () => _openDetail(
        context,
        service,
        connection: connection,
        clusterId: clusterId,
        store: store,
      ),
    );
  }
}

// ── Shared ───────────────────────────────────────────────────────────────────

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Text(
        label.toUpperCase(),
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Colors.white38,
              letterSpacing: 1.0,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}
