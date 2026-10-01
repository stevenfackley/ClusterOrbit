import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/cluster_domain/cluster_models.dart';
import '../../core/connectivity/cluster_connection.dart';
import '../../core/sync_cache/snapshot_store.dart';
import '../../core/theme/clusterorbit_theme.dart';
import '../../core/theme/health_style.dart';
import 'entity_detail_panel.dart';
import 'topology_orbs.dart';
import 'topology_selection.dart';

/// Phone-first scrollable list of nodes, workloads, and services grouped into
/// collapsible sections.  Tapping any row opens [EntityDetailPanel] in a
/// modal bottom-sheet.
class TopologyListView extends StatefulWidget {
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
  State<TopologyListView> createState() => _TopologyListViewState();
}

/// The detail sheet is a route of its own, outside this subtree. It follows
/// this view live: a refresh updates the entity it shows, and a cluster
/// switch, the entity's removal, or this view going away closes it, so it
/// can never act on an entity that is no longer on screen.
class _TopologyListViewState extends State<TopologyListView> {
  /// This view's latest inputs, which the open sheet builds from.
  late final ValueNotifier<TopologyListView> _latest = ValueNotifier(widget);
  _OpenSheet? _sheet;

  @override
  void didUpdateWidget(TopologyListView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // After this frame: the sheet's route can't change mid-build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final sheet = _sheet;
      if (sheet != null &&
          (widget.clusterId != sheet.clusterId ||
              resolveTopologyEntity(widget.snapshot, sheet.key) == null)) {
        _closeSheet();
      }
      _latest.value = widget;
    });
  }

  @override
  void dispose() {
    final sheet = _sheet;
    // The navigator can't change while this tree is unmounting.
    if (sheet != null) scheduleMicrotask(() => _remove(sheet.route));
    _latest.dispose();
    super.dispose();
  }

  void _closeSheet() {
    final sheet = _sheet;
    _sheet = null;
    if (sheet != null) _remove(sheet.route);
  }

  static void _remove(Route<void> route) {
    if (route.isActive) route.navigator?.removeRoute(route);
  }

  Future<void> _openDetail(Object entity) async {
    final key = topologyEntityKey(entity);
    if (key == null) return;
    final clusterId = widget.clusterId;
    final palette = Theme.of(context).extension<ClusterOrbitPalette>()!;
    ModalRoute<void>? route;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      backgroundColor: palette.panel,
      builder: (sheetContext) {
        if (route == null) {
          // First build: register the route so this view can close it.
          route = ModalRoute.of(sheetContext);
          _sheet = (route: route!, key: key, clusterId: clusterId);
        }
        return ValueListenableBuilder<TopologyListView>(
          valueListenable: _latest,
          builder: (_, view, __) => SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
            child: EntityDetailPanel(
              entity: resolveTopologyEntity(view.snapshot, key) ?? entity,
              palette: palette,
              onDismiss: () => Navigator.of(sheetContext).pop(),
              connection: view.connection,
              clusterId: view.clusterId,
              store: view.store,
              profileId: view.clusterId,
            ),
          ),
        );
      },
    );
    if (_sheet?.route == route) _sheet = null;
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = widget.snapshot;
    final list = ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        _NodeSection(nodes: snapshot.nodes, onOpen: _openDetail),
        _WorkloadSection(workloads: snapshot.workloads, onOpen: _openDetail),
        _ServiceSection(services: snapshot.services, onOpen: _openDetail),
      ],
    );
    final onRefresh = widget.onRefresh;
    if (onRefresh == null) return list;
    return RefreshIndicator(onRefresh: onRefresh, child: list);
  }
}

typedef _OpenSheet = ({
  ModalRoute<void> route,
  TopologyEntityKey key,
  String? clusterId,
});

// ── helpers ─────────────────────────────────────────────────────────────────

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
    required this.onOpen,
  });

  final List<ClusterNode> nodes;
  final ValueChanged<Object> onOpen;

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
                onOpen: onOpen,
              ),
          ],
      ],
    );
  }
}

class _NodeRow extends StatelessWidget {
  const _NodeRow({
    required this.node,
    required this.onOpen,
  });

  final ClusterNode node;
  final ValueChanged<Object> onOpen;

  @override
  Widget build(BuildContext context) {
    final healthColor = node.health.color(
      Theme.of(context).extension<ClusterOrbitPalette>()!,
    );
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
      onTap: () => onOpen(node),
    );
  }
}

// ── Workloads ────────────────────────────────────────────────────────────────

class _WorkloadSection extends StatelessWidget {
  const _WorkloadSection({
    required this.workloads,
    required this.onOpen,
  });

  final List<ClusterWorkload> workloads;
  final ValueChanged<Object> onOpen;

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
              onOpen: onOpen,
            ),
        ],
      ],
    );
  }
}

class _WorkloadRow extends StatelessWidget {
  const _WorkloadRow({
    required this.workload,
    required this.onOpen,
  });

  final ClusterWorkload workload;
  final ValueChanged<Object> onOpen;

  @override
  Widget build(BuildContext context) {
    final healthColor = workload.health.color(
      Theme.of(context).extension<ClusterOrbitPalette>()!,
    );
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
      onTap: () => onOpen(workload),
    );
  }
}

// ── Services ─────────────────────────────────────────────────────────────────

class _ServiceSection extends StatelessWidget {
  const _ServiceSection({
    required this.services,
    required this.onOpen,
  });

  final List<ClusterService> services;
  final ValueChanged<Object> onOpen;

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
                onOpen: onOpen,
              ),
          ],
      ],
    );
  }
}

class _ServiceRow extends StatelessWidget {
  const _ServiceRow({
    required this.service,
    required this.onOpen,
  });

  final ClusterService service;
  final ValueChanged<Object> onOpen;

  @override
  Widget build(BuildContext context) {
    final healthColor = service.health.color(
      Theme.of(context).extension<ClusterOrbitPalette>()!,
    );
    return ListTile(
      dense: true,
      leading: StatusDot(color: healthColor),
      title: Text(service.name, overflow: TextOverflow.ellipsis),
      subtitle: Text(service.namespace),
      trailing: _badge(
        service.exposure.label,
        Colors.white.withValues(alpha: 0.12),
      ),
      onTap: () => onOpen(service),
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
