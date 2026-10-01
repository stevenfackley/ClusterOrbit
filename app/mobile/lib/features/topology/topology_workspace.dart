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

/// The main canvas widget: header, summary chips, filter row, and the
/// pan/zoom Stack that hosts orbs + links. Shared between wide, landscape,
/// and portrait layouts.
class TopologyWorkspace extends StatelessWidget {
  const TopologyWorkspace({
    super.key,
    required this.snapshot,
    required this.layout,
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
            Positioned.fill(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!compact)
                    // Header and chips take what they need, up to half the
                    // card; past that (huge text) they scroll, not overflow.
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: constraints.maxHeight / 2,
                      ),
                      child: SingleChildScrollView(
                        primary: false,
                        padding: const EdgeInsets.fromLTRB(24, 22, 24, 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _header(theme, constraints.maxWidth),
                            const SizedBox(height: 12),
                            _chips(),
                          ],
                        ),
                      ),
                    ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(28),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.14),
                            border: Border.all(
                                color: Colors.white.withValues(alpha: 0.06)),
                          ),
                          child: Stack(
                            children: [
                              Positioned.fill(
                                child: CustomPaint(
                                  painter: TopologyGridPainter(
                                    gridColor:
                                        Colors.white.withValues(alpha: 0.03),
                                  ),
                                ),
                              ),
                              Positioned.fill(
                                child: _TopologyCanvas(
                                  snapshot: snapshot,
                                  layout: layout,
                                  palette: palette,
                                  selectedEntity: selectedEntity,
                                  onEntityTap: onEntityTap,
                                  viewport: viewport,
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
                                      child:
                                          MiniStatusCard(snapshot: snapshot))),
                              if (showPortraitPanel && selectedEntity != null)
                                // Up to 60% of the canvas, on its bottom edge.
                                Positioned.fill(
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.end,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      const Spacer(flex: 2),
                                      Flexible(
                                        flex: 3,
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
                                    ],
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      }),
    );
  }

  Widget _header(ThemeData theme, double width) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Cluster Map',
                style: theme.textTheme.headlineMedium,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              // Too long to be worth its height on narrow cards.
              if (width >= 600) ...[
                const SizedBox(height: 8),
                Text(
                  'Machine-first topology canvas for ${snapshot.profile.name}. Pan and zoom to inspect placement, workload fan-out, and service attachment.',
                  style: theme.textTheme.bodyLarge,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          ),
        ),
        const SizedBox(width: 16),
        // Natural width, capped so the title keeps most of the row.
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: width * 0.4),
          child: ModeBadge(
            label: '${snapshot.profile.connectionMode.label} mode',
            tint: palette.accentTeal,
          ),
        ),
      ],
    );
  }

  Widget _chips() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          SummaryChip(label: 'Nodes', value: '${snapshot.nodes.length}'),
          const SizedBox(width: 12),
          SummaryChip(
              label: 'Workloads', value: '${snapshot.workloads.length}'),
          const SizedBox(width: 12),
          SummaryChip(label: 'Services', value: '${snapshot.services.length}'),
          const SizedBox(width: 12),
          SummaryChip(label: 'Links', value: '${snapshot.links.length}'),
          const SizedBox(width: 12),
          SummaryChip(label: 'Alerts', value: '${snapshot.alerts.length}'),
          const SizedBox(width: 24),
          TopologyFilterChip(
            label: 'Nodes',
            selected: filter.showNodes,
            onChanged: (v) => onFilterChange(filter.copyWith(showNodes: v)),
          ),
          const SizedBox(width: 8),
          TopologyFilterChip(
            label: 'Workloads',
            selected: filter.showWorkloads,
            onChanged: (v) => onFilterChange(filter.copyWith(showWorkloads: v)),
          ),
          const SizedBox(width: 8),
          TopologyFilterChip(
            label: 'Services',
            selected: filter.showServices,
            onChanged: (v) => onFilterChange(filter.copyWith(showServices: v)),
          ),
        ],
      ),
    );
  }
}

/// The pan/zoom viewer over the full-size canvas of links and orbs.
class _TopologyCanvas extends StatelessWidget {
  const _TopologyCanvas({
    required this.snapshot,
    required this.layout,
    required this.palette,
    required this.selectedEntity,
    required this.onEntityTap,
    required this.viewport,
  });

  final ClusterSnapshot snapshot;
  final TopologyLayout layout;
  final ClusterOrbitPalette palette;
  final Object? selectedEntity;
  final void Function(Object) onEntityTap;
  final TransformationController viewport;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      if (box.biggest.isEmpty) return const SizedBox.shrink();
      // Allow zooming out until the whole canvas fits, but open at 1:1: on a
      // phone the fit scale is far below the label threshold.
      final fitScale = math.min(
        box.maxWidth / layout.canvasWidth,
        box.maxHeight / layout.canvasHeight,
      );
      final minScale = math.min(0.8, fitScale);
      // InteractiveViewer stops zooming out once the boundary no longer
      // covers the viewport, so pad the boundary enough to reach minScale.
      final boundaryMargin = EdgeInsets.symmetric(
        horizontal:
            math.max(24.0, (box.maxWidth / minScale - layout.canvasWidth) / 2),
        vertical: math.max(
            24.0, (box.maxHeight / minScale - layout.canvasHeight) / 2),
      );

      return InteractiveViewer(
        transformationController: viewport,
        // The canvas keeps its own size; the viewport pans over it.
        constrained: false,
        minScale: minScale,
        maxScale: 1.8,
        boundaryMargin: boundaryMargin,
        child: SizedBox(
          width: layout.canvasWidth,
          height: layout.canvasHeight,
          child: ListenableBuilder(
            listenable: viewport,
            builder: (context, _) {
              final scale = viewport.value.getMaxScaleOnAxis();
              final showLabels = scale >= 0.9;
              // Orbs have a fixed height; cap text so it fits (see
              // OrbMetrics.maxTextScale).
              return MediaQuery.withClampedTextScaling(
                maxScaleFactor: OrbMetrics.maxTextScale,
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
                          selected: selectedEntity == node,
                          child: NodeOrb(
                            node: node,
                            palette: palette,
                            selected: selectedEntity == node,
                            showLabels: showLabels,
                          ),
                        ),
                    for (final workload in snapshot.workloads)
                      if (layout.visibleWorkloadIds.contains(workload.id))
                        CanvasNode(
                          offset: layout.positions[workload.id]!,
                          onTap: () => onEntityTap(workload),
                          selected: selectedEntity == workload,
                          child: WorkloadOrb(
                            workload: workload,
                            palette: palette,
                            selected: selectedEntity == workload,
                            showLabels: showLabels,
                          ),
                        ),
                    for (final service in snapshot.services)
                      if (layout.visibleServiceIds.contains(service.id))
                        CanvasNode(
                          offset: layout.positions[service.id]!,
                          onTap: () => onEntityTap(service),
                          selected: selectedEntity == service,
                          child: ServiceOrb(
                            service: service,
                            palette: palette,
                            selected: selectedEntity == service,
                            showLabels: showLabels,
                          ),
                        ),
                  ],
                ),
              );
            },
          ),
        ),
      );
    });
  }
}
