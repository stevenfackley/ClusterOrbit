import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/cluster_domain/cluster_models.dart';
import '../../core/connectivity/cluster_connection.dart';
import '../../core/sync_cache/snapshot_store.dart';
import '../../core/theme/clusterorbit_theme.dart';
import 'entity_detail_panel.dart';
import 'topology_layout.dart';
import 'topology_orbs.dart';
import 'topology_painters.dart';

class TopologyScreen extends StatefulWidget {
  const TopologyScreen({
    super.key,
    required this.snapshot,
    required this.isLoading,
    required this.error,
    this.connection,
    this.clusterId,
    this.store,
  });

  final ClusterSnapshot? snapshot;
  final bool isLoading;
  final Object? error;
  final ClusterConnection? connection;
  final String? clusterId;
  final SnapshotStore? store;

  @override
  State<TopologyScreen> createState() => _TopologyScreenState();
}

class _TopologyScreenState extends State<TopologyScreen> {
  Object? _selectedEntity;
  TopologyFilter _filter = const TopologyFilter();
  final TransformationController _viewport = TransformationController();

  @override
  void dispose() {
    _viewport.dispose();
    super.dispose();
  }

  void _onEntityTap(Object entity) {
    setState(() {
      _selectedEntity = _selectedEntity == entity ? null : entity;
    });
  }

  void _clearSelection() {
    setState(() => _selectedEntity = null);
  }

  void _setFilter(TopologyFilter next) {
    setState(() => _filter = next);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.extension<ClusterOrbitPalette>()!;
    final clusterSnapshot = widget.snapshot;

    if (widget.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (widget.error != null || clusterSnapshot == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Cluster Map', style: theme.textTheme.headlineSmall),
                    const SizedBox(height: 12),
                    Text(
                      'The topology workspace could not be loaded. Direct and gateway connections both feed this canvas once a snapshot is available.',
                      style: theme.textTheme.bodyLarge,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 1180;
        final isLandscape =
            MediaQuery.orientationOf(context) == Orientation.landscape;
        final canvasHeight = math.max(520.0, constraints.maxHeight - 40);
        final layout = TopologyLayout.build(
          clusterSnapshot,
          canvasHeight: canvasHeight,
          filter: _filter,
        );

        final workspace = _TopologyWorkspace(
          snapshot: clusterSnapshot,
          layout: layout,
          canvasHeight: canvasHeight,
          palette: palette,
          selectedEntity: _selectedEntity,
          onEntityTap: _onEntityTap,
          onDismiss: _clearSelection,
          showPortraitPanel: !isWide && !isLandscape,
          connection: widget.connection,
          clusterId: widget.clusterId,
          store: widget.store,
          filter: _filter,
          onFilterChange: _setFilter,
          viewport: _viewport,
        );

        if (isWide) {
          return Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 10,
                  child: workspace,
                ),
                const SizedBox(width: 20),
                SizedBox(
                  width: 312,
                  child: _TopologySidebar(
                    snapshot: clusterSnapshot,
                    palette: palette,
                    selectedEntity: _selectedEntity,
                    onDismiss: _clearSelection,
                    connection: widget.connection,
                    clusterId: widget.clusterId,
                    store: widget.store,
                  ),
                ),
              ],
            ),
          );
        } else if (isLandscape) {
          return Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: workspace),
                AnimatedSize(
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeInOut,
                  child: _selectedEntity != null
                      ? SizedBox(
                          width: 260,
                          child: Padding(
                            padding: const EdgeInsets.only(left: 16),
                            child: SingleChildScrollView(
                              child: EntityDetailPanel(
                                entity: _selectedEntity!,
                                palette: palette,
                                onDismiss: _clearSelection,
                                connection: widget.connection,
                                clusterId: widget.clusterId,
                                store: widget.store,
                                profileId: widget.clusterId,
                              ),
                            ),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          );
        } else {
          // Phone portrait: panel rendered inside _TopologyWorkspace's Stack
          return Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [Expanded(child: workspace)],
            ),
          );
        }
      },
    );
  }
}

class _TopologyWorkspace extends StatelessWidget {
  const _TopologyWorkspace({
    required this.snapshot,
    required this.layout,
    required this.canvasHeight,
    required this.palette,
    required this.selectedEntity,
    required this.onEntityTap,
    required this.onDismiss,
    required this.showPortraitPanel,
    required this.connection,
    required this.clusterId,
    required this.store,
    required this.filter,
    required this.onFilterChange,
    required this.viewport,
  });

  final ClusterSnapshot snapshot;
  final TopologyLayout layout;
  final double canvasHeight;
  final ClusterOrbitPalette palette;
  final Object? selectedEntity;
  final void Function(Object) onEntityTap;
  final VoidCallback onDismiss;
  final bool showPortraitPanel;
  final ClusterConnection? connection;
  final String? clusterId;
  final SnapshotStore? store;
  final TopologyFilter filter;
  final ValueChanged<TopologyFilter> onFilterChange;
  final TransformationController viewport;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(builder: (context, constraints) {
        final compact = constraints.maxHeight < 300;
        final canvasTop = compact ? 0.0 : 188.0;
        return Stack(
          children: [
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      palette.panel.withValues(alpha: 0.96),
                      const Color(0xFF0D1727),
                    ],
                  ),
                ),
              ),
            ),
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: OrbitBackdropPainter(
                    accent: palette.canvasGlow,
                    secondary: palette.accentCyan,
                  ),
                ),
              ),
            ),
            if (!compact)
              Positioned(
                top: 22,
                left: 24,
                right: 24,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Cluster Map',
                              style: theme.textTheme.headlineMedium),
                          const SizedBox(height: 8),
                          Text(
                            'Machine-first topology canvas for ${snapshot.profile.name}. Pan and zoom to inspect placement, workload fan-out, and service attachment.',
                            style: theme.textTheme.bodyLarge,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 16),
                    ModeBadge(
                      label: '${snapshot.profile.connectionMode.label} mode',
                      tint: palette.accentTeal,
                    ),
                  ],
                ),
              ),
            if (!compact)
              Positioned(
                top: 96,
                left: 24,
                right: 24,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      SummaryChip(
                          label: 'Nodes', value: '${snapshot.nodes.length}'),
                      const SizedBox(width: 12),
                      SummaryChip(
                          label: 'Workloads',
                          value: '${snapshot.workloads.length}'),
                      const SizedBox(width: 12),
                      SummaryChip(
                          label: 'Services',
                          value: '${snapshot.services.length}'),
                      const SizedBox(width: 12),
                      SummaryChip(
                          label: 'Links', value: '${snapshot.links.length}'),
                      const SizedBox(width: 12),
                      SummaryChip(
                          label: 'Alerts', value: '${snapshot.alerts.length}'),
                      const SizedBox(width: 24),
                      TopologyFilterChip(
                        label: 'Nodes',
                        selected: filter.showNodes,
                        onChanged: (v) =>
                            onFilterChange(filter.copyWith(showNodes: v)),
                      ),
                      const SizedBox(width: 8),
                      TopologyFilterChip(
                        label: 'Workloads',
                        selected: filter.showWorkloads,
                        onChanged: (v) =>
                            onFilterChange(filter.copyWith(showWorkloads: v)),
                      ),
                      const SizedBox(width: 8),
                      TopologyFilterChip(
                        label: 'Services',
                        selected: filter.showServices,
                        onChanged: (v) =>
                            onFilterChange(filter.copyWith(showServices: v)),
                      ),
                    ],
                  ),
                ),
              ),
            Positioned.fill(
              top: canvasTop,
              left: 16,
              right: 16,
              bottom: 16,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(28),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.14),
                    border:
                        Border.all(color: Colors.white.withValues(alpha: 0.06)),
                  ),
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: CustomPaint(
                          painter: TopologyGridPainter(
                            gridColor: Colors.white.withValues(alpha: 0.03),
                          ),
                        ),
                      ),
                      Positioned.fill(
                        child: InteractiveViewer(
                          transformationController: viewport,
                          constrained: true,
                          minScale: 0.8,
                          maxScale: 1.8,
                          boundaryMargin: const EdgeInsets.all(24),
                          child: SizedBox(
                            width: layout.canvasWidth,
                            height: layout.canvasHeight,
                            child: Stack(
                              children: [
                                Positioned.fill(
                                  child: CustomPaint(
                                    painter: TopologyLinkPainter(
                                      layout: layout,
                                      accent: palette.accentCyan,
                                    ),
                                  ),
                                ),
                                for (final node in snapshot.nodes)
                                  if (layout.visibleNodeIds.contains(node.id))
                                    CanvasNode(
                                      offset: layout.positions[node.id]!,
                                      onTap: () => onEntityTap(node),
                                      child: NodeOrb(
                                        node: node,
                                        palette: palette,
                                        selected: selectedEntity == node,
                                      ),
                                    ),
                                for (final workload in snapshot.workloads)
                                  if (layout.visibleWorkloadIds
                                      .contains(workload.id))
                                    CanvasNode(
                                      offset: layout.positions[workload.id]!,
                                      onTap: () => onEntityTap(workload),
                                      child: WorkloadOrb(
                                        workload: workload,
                                        palette: palette,
                                        selected: selectedEntity == workload,
                                      ),
                                    ),
                                for (final service in snapshot.services)
                                  if (layout.visibleServiceIds
                                      .contains(service.id))
                                    CanvasNode(
                                      offset: layout.positions[service.id]!,
                                      onTap: () => onEntityTap(service),
                                      child: ServiceOrb(
                                        service: service,
                                        palette: palette,
                                        selected: selectedEntity == service,
                                      ),
                                    ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                          left: 16,
                          bottom: 16,
                          child: IgnorePointer(
                              child: LegendCard(palette: palette))),
                      Positioned(
                          right: 16,
                          bottom: 16,
                          child: IgnorePointer(
                              child: MiniStatusCard(snapshot: snapshot))),
                      if (showPortraitPanel && selectedEntity != null)
                        Positioned(
                          bottom: 0,
                          left: 0,
                          right: 0,
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxHeight: constraints.maxHeight * 0.6,
                            ),
                            child: SingleChildScrollView(
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
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ); // Stack
      }), // LayoutBuilder
    ); // Card
  }
}

class _TopologySidebar extends StatelessWidget {
  const _TopologySidebar({
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
    return Column(
      children: [
        _InsightPanel(snapshot: snapshot),
        const SizedBox(height: 16),
        Expanded(
          child: Column(
            children: [
              Expanded(child: _AlertPanel(alerts: alerts)),
              AnimatedSize(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeInOut,
                child: selectedEntity != null
                    ? Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 320),
                          child: SingleChildScrollView(
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
                      )
                    : const SizedBox.shrink(),
              ),
            ],
          ),
        ),
      ],
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
