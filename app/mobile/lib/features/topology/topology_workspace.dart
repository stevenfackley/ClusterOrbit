import 'package:flutter/material.dart';

import '../../core/cluster_domain/cluster_models.dart';
import '../../core/connectivity/cluster_connection.dart';
import '../../core/sync_cache/snapshot_store.dart';
import '../../core/theme/clusterorbit_theme.dart';
import 'entity_detail_panel.dart';
import 'topology_layout.dart';
import 'topology_orbs.dart';
import 'topology_painters.dart';

/// The main canvas widget: header, summary chips, filter row, and the
/// pan/zoom Stack that hosts orbs + links. Shared between wide, landscape,
/// and portrait layouts.
class TopologyWorkspace extends StatelessWidget {
  const TopologyWorkspace({
    super.key,
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
                            child: ListenableBuilder(
                              listenable: viewport,
                              builder: (context, _) {
                                final scale =
                                    viewport.value.getMaxScaleOnAxis();
                                final showLabels = scale >= 0.9;
                                return Stack(
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
                                      if (layout.visibleNodeIds
                                          .contains(node.id))
                                        CanvasNode(
                                          offset: layout.positions[node.id]!,
                                          onTap: () => onEntityTap(node),
                                          child: NodeOrb(
                                            node: node,
                                            palette: palette,
                                            selected: selectedEntity == node,
                                            showLabels: showLabels,
                                          ),
                                        ),
                                    for (final workload in snapshot.workloads)
                                      if (layout.visibleWorkloadIds
                                          .contains(workload.id))
                                        CanvasNode(
                                          offset:
                                              layout.positions[workload.id]!,
                                          onTap: () => onEntityTap(workload),
                                          child: WorkloadOrb(
                                            workload: workload,
                                            palette: palette,
                                            selected:
                                                selectedEntity == workload,
                                            showLabels: showLabels,
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
                                            showLabels: showLabels,
                                          ),
                                        ),
                                  ],
                                );
                              },
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
        );
      }),
    );
  }
}
