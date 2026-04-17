import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/cluster_domain/cluster_models.dart';
import '../../core/connectivity/cluster_connection.dart';
import '../../core/sync_cache/snapshot_store.dart';
import '../../core/theme/clusterorbit_theme.dart';
import 'topology_layout.dart';

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
                              child: _EntityDetailPanel(
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
                  painter: _OrbitBackdropPainter(
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
                    _ModeBadge(
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
                      _SummaryChip(
                          label: 'Nodes', value: '${snapshot.nodes.length}'),
                      const SizedBox(width: 12),
                      _SummaryChip(
                          label: 'Workloads',
                          value: '${snapshot.workloads.length}'),
                      const SizedBox(width: 12),
                      _SummaryChip(
                          label: 'Services',
                          value: '${snapshot.services.length}'),
                      const SizedBox(width: 12),
                      _SummaryChip(
                          label: 'Links', value: '${snapshot.links.length}'),
                      const SizedBox(width: 12),
                      _SummaryChip(
                          label: 'Alerts', value: '${snapshot.alerts.length}'),
                      const SizedBox(width: 24),
                      _FilterChip(
                        label: 'Nodes',
                        selected: filter.showNodes,
                        onChanged: (v) =>
                            onFilterChange(filter.copyWith(showNodes: v)),
                      ),
                      const SizedBox(width: 8),
                      _FilterChip(
                        label: 'Workloads',
                        selected: filter.showWorkloads,
                        onChanged: (v) =>
                            onFilterChange(filter.copyWith(showWorkloads: v)),
                      ),
                      const SizedBox(width: 8),
                      _FilterChip(
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
                          painter: _GridPainter(
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
                                    painter: _LinkPainter(
                                      layout: layout,
                                      accent: palette.accentCyan,
                                    ),
                                  ),
                                ),
                                for (final node in snapshot.nodes)
                                  if (layout.visibleNodeIds.contains(node.id))
                                    _CanvasNode(
                                      offset: layout.positions[node.id]!,
                                      onTap: () => onEntityTap(node),
                                      child: _NodeOrb(
                                        node: node,
                                        palette: palette,
                                        selected: selectedEntity == node,
                                      ),
                                    ),
                                for (final workload in snapshot.workloads)
                                  if (layout.visibleWorkloadIds
                                      .contains(workload.id))
                                    _CanvasNode(
                                      offset: layout.positions[workload.id]!,
                                      onTap: () => onEntityTap(workload),
                                      child: _WorkloadOrb(
                                        workload: workload,
                                        palette: palette,
                                        selected: selectedEntity == workload,
                                      ),
                                    ),
                                for (final service in snapshot.services)
                                  if (layout.visibleServiceIds
                                      .contains(service.id))
                                    _CanvasNode(
                                      offset: layout.positions[service.id]!,
                                      onTap: () => onEntityTap(service),
                                      child: _ServiceOrb(
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
                              child: _LegendCard(palette: palette))),
                      Positioned(
                          right: 16,
                          bottom: 16,
                          child: IgnorePointer(
                              child: _MiniStatusCard(snapshot: snapshot))),
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
                              child: _EntityDetailPanel(
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
                            child: _EntityDetailPanel(
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
            _MetricRow(
                label: 'Control planes',
                value: '${snapshot.controlPlaneCount}'),
            _MetricRow(label: 'Workers', value: '${snapshot.workerCount}'),
            _MetricRow(
                label: 'Unschedulable',
                value: '${snapshot.unschedulableNodeCount}'),
            _MetricRow(
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
                          _AlertTile(alert: alerts[index]),
                      separatorBuilder: (_, __) => const SizedBox(height: 12),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OrbitBackdropPainter extends CustomPainter {
  const _OrbitBackdropPainter({
    required this.accent,
    required this.secondary,
  });

  final Color accent;
  final Color secondary;

  @override
  void paint(Canvas canvas, Size size) {
    final orbitPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = accent.withValues(alpha: 0.12);
    final secondaryPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = secondary.withValues(alpha: 0.08);

    canvas.drawCircle(
      Offset(size.width * 0.16, size.height * 0.82),
      size.width * 0.28,
      orbitPaint,
    );
    canvas.drawCircle(
      Offset(size.width * 0.82, size.height * 0.18),
      size.width * 0.22,
      secondaryPaint,
    );
    canvas.drawCircle(
      Offset(size.width * 0.58, size.height * 0.52),
      size.width * 0.42,
      orbitPaint..color = accent.withValues(alpha: 0.06),
    );
  }

  @override
  bool shouldRepaint(covariant _OrbitBackdropPainter oldDelegate) {
    return oldDelegate.accent != accent || oldDelegate.secondary != secondary;
  }
}

class _GridPainter extends CustomPainter {
  const _GridPainter({
    required this.gridColor,
  });

  final Color gridColor;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = gridColor
      ..strokeWidth = 1;

    for (double x = 0; x <= size.width; x += 64) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double y = 0; y <= size.height; y += 64) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _GridPainter oldDelegate) {
    return oldDelegate.gridColor != gridColor;
  }
}

class _LinkPainter extends CustomPainter {
  const _LinkPainter({
    required this.layout,
    required this.accent,
  });

  final TopologyLayout layout;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 2
      ..color = accent.withValues(alpha: 0.22);

    for (final edge in layout.edges) {
      final path = Path()
        ..moveTo(edge.start.dx, edge.start.dy)
        ..cubicTo(
          edge.start.dx + 120,
          edge.start.dy,
          edge.end.dx - 120,
          edge.end.dy,
          edge.end.dx,
          edge.end.dy,
        );
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _LinkPainter oldDelegate) {
    return oldDelegate.layout != layout || oldDelegate.accent != accent;
  }
}

class _CanvasNode extends StatelessWidget {
  const _CanvasNode({
    required this.offset,
    required this.child,
    this.onTap,
  });

  final Offset offset;
  final Widget child;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: offset.dx,
      top: offset.dy,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: child,
      ),
    );
  }
}

class _NodeOrb extends StatelessWidget {
  const _NodeOrb({
    required this.node,
    required this.palette,
    this.selected = false,
  });

  final ClusterNode node;
  final ClusterOrbitPalette palette;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tint = _healthTint(node.health, palette);

    return Container(
      width: 132,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: selected ? 0.20 : 0.12),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: tint.withValues(alpha: selected ? 0.80 : 0.24),
          width: selected ? 2.5 : 1.0,
        ),
        boxShadow: [
          BoxShadow(
            color: tint.withValues(alpha: selected ? 0.28 : 0.14),
            blurRadius: selected ? 28 : 18,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(node.name, style: theme.textTheme.titleMedium),
          const SizedBox(height: 6),
          Text('${node.role.label} / ${node.zone}',
              style: theme.textTheme.bodyMedium),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _StatusDot(color: tint),
              Text(
                '${node.podCount} pods',
                style: theme.textTheme.bodySmall?.copyWith(color: Colors.white),
              ),
              if (!node.schedulable)
                Text(
                  'Cordoned',
                  style: theme.textTheme.bodySmall?.copyWith(color: tint),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _WorkloadOrb extends StatelessWidget {
  const _WorkloadOrb({
    required this.workload,
    required this.palette,
    this.selected = false,
  });

  final ClusterWorkload workload;
  final ClusterOrbitPalette palette;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tint = _healthTint(workload.health, palette);

    return Container(
      width: 132,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: selected ? 0.08 : 0.04),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: tint.withValues(alpha: selected ? 0.80 : 0.22),
          width: selected ? 2.5 : 1.0,
        ),
        boxShadow: selected
            ? [BoxShadow(color: tint.withValues(alpha: 0.22), blurRadius: 24)]
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(workload.name, style: theme.textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
            '${workload.kind.label} / ${workload.namespace}',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _StatusDot(color: tint),
              Text(
                '${workload.readyReplicas}/${workload.desiredReplicas} ready',
                style: theme.textTheme.bodySmall?.copyWith(color: Colors.white),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ServiceOrb extends StatelessWidget {
  const _ServiceOrb({
    required this.service,
    required this.palette,
    this.selected = false,
  });

  final ClusterService service;
  final ClusterOrbitPalette palette;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tint = _healthTint(service.health, palette);

    return Container(
      width: 128,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            palette.canvasGlow.withValues(alpha: selected ? 0.26 : 0.16),
            palette.accentCyan.withValues(alpha: selected ? 0.16 : 0.08),
          ],
        ),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: tint.withValues(alpha: selected ? 0.80 : 0.24),
          width: selected ? 2.5 : 1.0,
        ),
        boxShadow: selected
            ? [BoxShadow(color: tint.withValues(alpha: 0.22), blurRadius: 24)]
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(service.name, style: theme.textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
            '${service.exposure.label} / ${service.namespace}',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 10),
          Text(
            '${service.targetWorkloadIds.length} workload targets',
            style: theme.textTheme.bodySmall?.copyWith(color: Colors.white),
          ),
        ],
      ),
    );
  }
}

class _LegendCard extends StatelessWidget {
  const _LegendCard({
    required this.palette,
  });

  final ClusterOrbitPalette palette;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.24),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Legend',
              style: theme.textTheme.titleSmall?.copyWith(color: Colors.white),
            ),
            const SizedBox(height: 10),
            _LegendRow(label: 'Healthy', color: palette.accentTeal),
            _LegendRow(label: 'Warning', color: palette.warning),
            const _LegendRow(label: 'Critical', color: Color(0xFFFF6F7A)),
          ],
        ),
      ),
    );
  }
}

class _MiniStatusCard extends StatelessWidget {
  const _MiniStatusCard({
    required this.snapshot,
  });

  final ClusterSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.24),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Map status',
              style: theme.textTheme.titleSmall?.copyWith(color: Colors.white),
            ),
            const SizedBox(height: 8),
            Text(
              '${snapshot.warningCount} warnings / ${snapshot.criticalCount} critical',
              style: theme.textTheme.bodySmall?.copyWith(color: Colors.white),
            ),
            const SizedBox(height: 4),
            Text(snapshot.profile.apiServerHost,
                style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

class _ModeBadge extends StatelessWidget {
  const _ModeBadge({
    required this.label,
    required this.tint,
  });

  final String label;
  final Color tint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: tint.withValues(alpha: 0.28)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Text(
          label,
          style: theme.textTheme.bodyMedium?.copyWith(color: Colors.white),
        ),
      ),
    );
  }
}

class _SummaryChip extends StatelessWidget {
  const _SummaryChip({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: 132,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 8),
          Text(value, style: theme.textTheme.headlineSmall),
        ],
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onChanged,
  });

  final String label;
  final bool selected;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FilterChip(
      label: Text(label),
      selected: selected,
      onSelected: onChanged,
      showCheckmark: true,
      labelStyle: theme.textTheme.bodySmall?.copyWith(
        color: selected ? theme.colorScheme.onPrimary : Colors.white70,
      ),
      backgroundColor: Colors.white.withValues(alpha: 0.04),
      selectedColor: theme.colorScheme.primary.withValues(alpha: 0.5),
      side: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
    );
  }
}

class _MetricRow extends StatelessWidget {
  const _MetricRow({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        children: [
          Expanded(child: Text(label, style: theme.textTheme.bodyLarge)),
          Text(value, style: theme.textTheme.titleMedium),
        ],
      ),
    );
  }
}

class _AlertTile extends StatelessWidget {
  const _AlertTile({
    required this.alert,
  });

  final ClusterAlert alert;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.extension<ClusterOrbitPalette>()!;
    final tint = _healthTint(alert.level, palette);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: tint.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(alert.title, style: theme.textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(alert.summary, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 8),
          Text(alert.scope, style: theme.textTheme.labelLarge),
        ],
      ),
    );
  }
}

class _LegendRow extends StatelessWidget {
  const _LegendRow({
    required this.label,
    required this.color,
  });

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _StatusDot(color: color),
          const SizedBox(width: 8),
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(color: Colors.white),
          ),
        ],
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({
    required this.color,
  });

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

Color _healthTint(ClusterHealthLevel level, ClusterOrbitPalette palette) {
  switch (level) {
    case ClusterHealthLevel.healthy:
      return palette.accentTeal;
    case ClusterHealthLevel.warning:
      return palette.warning;
    case ClusterHealthLevel.critical:
      return const Color(0xFFFF6F7A);
  }
}

class _EntityDetailPanel extends StatefulWidget {
  const _EntityDetailPanel({
    required this.entity,
    required this.palette,
    required this.onDismiss,
    required this.connection,
    required this.clusterId,
    this.store,
    this.profileId,
  });

  final Object entity;
  final ClusterOrbitPalette palette;
  final VoidCallback onDismiss;
  final ClusterConnection? connection;
  final String? clusterId;
  final SnapshotStore? store;
  final String? profileId;

  @override
  State<_EntityDetailPanel> createState() => _EntityDetailPanelState();
}

class _EntityDetailPanelState extends State<_EntityDetailPanel> {
  static const _pollInterval = Duration(seconds: 30);
  static const _eventCacheMaxAge = Duration(minutes: 5);

  List<ClusterEvent>? _events;
  bool _eventsSupported = false;
  bool _isLoadingEvents = false;
  bool _isRefreshingEvents = false;
  Object? _eventsError;
  Timer? _pollTimer;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _startLoadForCurrentEntity();
  }

  @override
  void didUpdateWidget(_EntityDetailPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.entity, widget.entity) ||
        oldWidget.connection != widget.connection ||
        oldWidget.clusterId != widget.clusterId ||
        oldWidget.store != widget.store ||
        oldWidget.profileId != widget.profileId) {
      _startLoadForCurrentEntity();
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  void _startLoadForCurrentEntity() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _loadGeneration++;
    final generation = _loadGeneration;

    final connection = widget.connection;
    final clusterId = widget.clusterId;
    final ref = _entityRef(widget.entity);
    if (connection == null || clusterId == null || ref == null) {
      _events = null;
      _eventsSupported = false;
      _isLoadingEvents = false;
      _isRefreshingEvents = false;
      _eventsError = null;
      return;
    }

    _events = null;
    _eventsSupported = true;
    _isLoadingEvents = true;
    _isRefreshingEvents = false;
    _eventsError = null;

    unawaited(_loadEvents(generation: generation, ref: ref));

    _pollTimer = Timer.periodic(_pollInterval, (_) {
      if (!mounted) return;
      unawaited(_refreshLiveEvents(generation: generation, ref: ref));
    });
  }

  Future<void> _loadEvents({
    required int generation,
    required _EntityRef ref,
  }) async {
    final store = widget.store;
    final profileId = widget.profileId;

    if (store != null && profileId != null) {
      try {
        final cached = await store.loadEvents(
          profileId: profileId,
          kind: ref.kind,
          objectName: ref.name,
          namespace: ref.namespace,
          maxAge: _eventCacheMaxAge,
        );
        if (!mounted || generation != _loadGeneration) return;
        if (cached != null) {
          setState(() {
            _events = cached;
            _isLoadingEvents = false;
            _isRefreshingEvents = true;
            _eventsError = null;
          });
        }
      } catch (_) {
        // Cache read failure is non-fatal — fall through to live fetch.
      }
    }

    await _refreshLiveEvents(generation: generation, ref: ref);
  }

  Future<void> _refreshLiveEvents({
    required int generation,
    required _EntityRef ref,
  }) async {
    final connection = widget.connection;
    final clusterId = widget.clusterId;
    if (connection == null || clusterId == null) return;

    if (mounted && generation == _loadGeneration && _events != null) {
      setState(() => _isRefreshingEvents = true);
    }

    try {
      final events = await connection.loadEvents(
        clusterId: clusterId,
        kind: ref.kind,
        objectName: ref.name,
        namespace: ref.namespace,
      );
      if (!mounted || generation != _loadGeneration) return;

      final store = widget.store;
      final profileId = widget.profileId;
      if (store != null && profileId != null) {
        try {
          await store.saveEvents(
            profileId: profileId,
            kind: ref.kind,
            objectName: ref.name,
            namespace: ref.namespace,
            events: events,
          );
        } catch (_) {
          // Cache write failure is non-fatal.
        }
      }

      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _events = events;
        _isLoadingEvents = false;
        _isRefreshingEvents = false;
        _eventsError = null;
      });
    } catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _isLoadingEvents = false;
        _isRefreshingEvents = false;
        if (_events == null) _eventsError = error;
      });
    }
  }

  void _onManualRefresh() {
    final ref = _entityRef(widget.entity);
    if (ref == null) return;
    unawaited(
      _refreshLiveEvents(generation: _loadGeneration, ref: ref),
    );
  }

  static _EntityRef? _entityRef(Object entity) => switch (entity) {
        ClusterNode n => _EntityRef(TopologyEntityKind.node, n.name, null),
        ClusterWorkload w =>
          _EntityRef(TopologyEntityKind.workload, w.name, w.namespace),
        ClusterService s =>
          _EntityRef(TopologyEntityKind.service, s.name, s.namespace),
        _ => null,
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: widget.palette.panel.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.40),
            blurRadius: 24,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(child: _buildTitle(theme)),
              if (_eventsSupported)
                IconButton(
                  onPressed: _isLoadingEvents || _isRefreshingEvents
                      ? null
                      : _onManualRefresh,
                  icon:
                      const Icon(Icons.refresh, size: 18, color: Colors.white),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  tooltip: 'Refresh events',
                ),
              if (_eventsSupported) const SizedBox(width: 8),
              IconButton(
                onPressed: widget.onDismiss,
                icon: const Icon(Icons.close, size: 18, color: Colors.white),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                tooltip: 'Dismiss',
              ),
            ],
          ),
          const SizedBox(height: 12),
          ..._buildFields(theme),
          if (_eventsSupported) ...[
            const SizedBox(height: 16),
            Divider(color: Colors.white.withValues(alpha: 0.12), height: 1),
            const SizedBox(height: 12),
            Row(
              children: [
                Text('Recent Events', style: theme.textTheme.titleSmall),
                if (_isRefreshingEvents) ...[
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        Colors.white.withValues(alpha: 0.60),
                      ),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 8),
            _EventList(
              isLoading: _isLoadingEvents,
              error: _eventsError,
              events: _events,
              palette: widget.palette,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildTitle(ThemeData theme) {
    final (name, badge) = switch (widget.entity) {
      ClusterNode n => (n.name, n.role.label),
      ClusterWorkload w => (w.name, w.kind.label),
      ClusterService s => (s.name, s.exposure.label),
      _ => ('Unknown', ''),
    };
    return Row(
      children: [
        Expanded(
          child: Text(
            name,
            style: theme.textTheme.titleMedium,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              badge,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(color: Colors.white70),
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _buildFields(ThemeData theme) => switch (widget.entity) {
        ClusterNode n => _nodeFields(n, theme),
        ClusterWorkload w => _workloadFields(w, theme),
        ClusterService s => _serviceFields(s, theme),
        _ => const [],
      };

  List<Widget> _nodeFields(ClusterNode n, ThemeData theme) {
    final tint = _healthTint(n.health, widget.palette);
    return [
      _DetailRow(label: 'Role', value: n.role.label, theme: theme),
      _DetailRow(label: 'Zone', value: n.zone, theme: theme),
      _DetailRow(label: 'K8s Version', value: n.version, theme: theme),
      _DetailRow(label: 'OS', value: n.osImage, theme: theme),
      _DetailRow(label: 'CPU', value: n.cpuCapacity, theme: theme),
      _DetailRow(label: 'Memory', value: n.memoryCapacity, theme: theme),
      _DetailRow(label: 'Pod Count', value: '${n.podCount}', theme: theme),
      _DetailRow(
          label: 'Schedulable',
          value: n.schedulable ? 'Yes' : 'Cordoned',
          theme: theme),
      _DetailStatusRow(
          label: 'Health', value: n.health.name, tint: tint, theme: theme),
    ];
  }

  List<Widget> _workloadFields(ClusterWorkload w, ThemeData theme) {
    final tint = _healthTint(w.health, widget.palette);
    final isScalable =
        w.kind == WorkloadKind.deployment || w.kind == WorkloadKind.statefulSet;
    return [
      _DetailRow(label: 'Namespace', value: w.namespace, theme: theme),
      _DetailRow(label: 'Kind', value: w.kind.label, theme: theme),
      _DetailRow(
          label: 'Replicas',
          value: '${w.readyReplicas} / ${w.desiredReplicas} ready',
          theme: theme),
      _DetailRow(
          label: 'Nodes',
          value: '${w.nodeIds.length} placement(s)',
          theme: theme),
      for (final image in w.images)
        _DetailRow(label: 'Image', value: image, theme: theme),
      _DetailStatusRow(
          label: 'Health', value: w.health.name, tint: tint, theme: theme),
      if (isScalable &&
          widget.connection != null &&
          widget.clusterId != null) ...[
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => _onScalePressed(w),
            icon: const Icon(Icons.tune, size: 16),
            label: const Text('Scale'),
            style: TextButton.styleFrom(
              foregroundColor: Colors.white,
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              backgroundColor: Colors.white.withValues(alpha: 0.08),
            ),
          ),
        ),
      ],
    ];
  }

  Future<void> _onScalePressed(ClusterWorkload w) async {
    final connection = widget.connection;
    final clusterId = widget.clusterId;
    if (connection == null || clusterId == null) return;

    final replicas = await showDialog<int>(
      context: context,
      builder: (ctx) => _ScaleDialog(
        workloadName: w.name,
        currentReplicas: w.desiredReplicas,
      ),
    );
    if (replicas == null || !mounted) return;

    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await connection.scaleWorkload(
        clusterId: clusterId,
        workloadId: w.id,
        replicas: replicas,
      );
      messenger?.showSnackBar(
        SnackBar(
          content: Text(
              'Requested scale of ${w.name} to $replicas replica(s). Refresh to see applied state.'),
        ),
      );
    } catch (e) {
      messenger?.showSnackBar(
        SnackBar(content: Text('Scale failed: $e')),
      );
    }
  }

  List<Widget> _serviceFields(ClusterService s, ThemeData theme) {
    final tint = _healthTint(s.health, widget.palette);
    return [
      _DetailRow(label: 'Namespace', value: s.namespace, theme: theme),
      _DetailRow(label: 'Exposure', value: s.exposure.label, theme: theme),
      if (s.clusterIp != null)
        _DetailRow(label: 'Cluster IP', value: s.clusterIp!, theme: theme),
      _DetailRow(
          label: 'Targets',
          value: '${s.targetWorkloadIds.length} workload(s)',
          theme: theme),
      for (final p in s.ports)
        _DetailRow(
          label: 'Port',
          value:
              '${p.port} → ${p.targetPort} / ${p.protocol}${p.name != null ? ' (${p.name})' : ''}',
          theme: theme,
        ),
      _DetailStatusRow(
          label: 'Health', value: s.health.name, tint: tint, theme: theme),
    ];
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.label,
    required this.value,
    required this.theme,
  });

  final String label;
  final String value;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(color: Colors.white54),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodySmall?.copyWith(color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}

class _DetailStatusRow extends StatelessWidget {
  const _DetailStatusRow({
    required this.label,
    required this.value,
    required this.tint,
    required this.theme,
  });

  final String label;
  final String value;
  final Color tint;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(color: Colors.white54),
            ),
          ),
          _StatusDot(color: tint),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodySmall?.copyWith(color: tint),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _EntityRef {
  const _EntityRef(this.kind, this.name, this.namespace);
  final TopologyEntityKind kind;
  final String name;
  final String? namespace;
}

class _EventList extends StatelessWidget {
  const _EventList({
    required this.isLoading,
    required this.error,
    required this.events,
    required this.palette,
  });

  final bool isLoading;
  final Object? error;
  final List<ClusterEvent>? events;
  final ClusterOrbitPalette palette;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (isLoading && events == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (error != null && events == null) {
      return Text(
        'Could not load events',
        style: theme.textTheme.bodySmall?.copyWith(color: Colors.white60),
      );
    }
    final list = events ?? const <ClusterEvent>[];
    if (list.isEmpty) {
      return Text(
        'No recent events',
        style: theme.textTheme.bodySmall?.copyWith(color: Colors.white60),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final event in list)
          _EventRow(event: event, palette: palette, theme: theme),
      ],
    );
  }
}

class _EventRow extends StatelessWidget {
  const _EventRow({
    required this.event,
    required this.palette,
    required this.theme,
  });

  final ClusterEvent event;
  final ClusterOrbitPalette palette;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final tint = event.type == ClusterEventType.warning
        ? palette.warning
        : palette.accentTeal;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 5),
            child: _StatusDot(color: tint),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        event.reason,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: Colors.white),
                      ),
                    ),
                    Text(
                      _relativeTime(event.lastTimestamp),
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: Colors.white54),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  event.message,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: Colors.white70),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _relativeTime(DateTime ts) {
    final diff = DateTime.now().toUtc().difference(ts.toUtc());
    if (diff.inSeconds < 60) return '${diff.inSeconds}s';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m';
    if (diff.inHours < 24) return '${diff.inHours}h';
    return '${diff.inDays}d';
  }
}

class _ScaleDialog extends StatefulWidget {
  const _ScaleDialog({
    required this.workloadName,
    required this.currentReplicas,
  });

  final String workloadName;
  final int currentReplicas;

  @override
  State<_ScaleDialog> createState() => _ScaleDialogState();
}

class _ScaleDialogState extends State<_ScaleDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: '${widget.currentReplicas}',
  );
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final parsed = int.tryParse(_controller.text.trim());
    if (parsed == null || parsed < 0) {
      setState(() => _error = 'Enter a non-negative integer');
      return;
    }
    Navigator.of(context).pop(parsed);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Scale ${widget.workloadName}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Current replicas: ${widget.currentReplicas}'),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            keyboardType: TextInputType.number,
            autofocus: true,
            decoration: InputDecoration(
              labelText: 'Desired replicas',
              errorText: _error,
              border: const OutlineInputBorder(),
            ),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('Apply'),
        ),
      ],
    );
  }
}
