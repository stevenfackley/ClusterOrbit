import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/cluster_domain/cluster_models.dart';
import '../../core/theme/clusterorbit_theme.dart';

class TopologyScreen extends StatefulWidget {
  const TopologyScreen({
    super.key,
    required this.snapshot,
    required this.isLoading,
    required this.error,
  });

  final ClusterSnapshot? snapshot;
  final bool isLoading;
  final Object? error;

  @override
  State<TopologyScreen> createState() => _TopologyScreenState();
}

class _TopologyScreenState extends State<TopologyScreen> {
  Object? _selectedEntity;

  void _onEntityTap(Object entity) {
    setState(() {
      _selectedEntity = _selectedEntity == entity ? null : entity;
    });
  }

  void _clearSelection() {
    setState(() => _selectedEntity = null);
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
        final layout = _TopologyLayout.build(
          clusterSnapshot,
          canvasHeight: canvasHeight,
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
  });

  final ClusterSnapshot snapshot;
  final _TopologyLayout layout;
  final double canvasHeight;
  final ClusterOrbitPalette palette;
  final Object? selectedEntity;
  final void Function(Object) onEntityTap;
  final VoidCallback onDismiss;
  final bool showPortraitPanel;

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
                          child: _EntityDetailPanel(
                            entity: selectedEntity!,
                            palette: palette,
                            onDismiss: onDismiss,
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
    this.compact = false,
  });

  final ClusterSnapshot snapshot;
  final ClusterOrbitPalette palette;
  final Object? selectedEntity;
  final VoidCallback onDismiss;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final alerts = snapshot.alerts.take(compact ? 2 : 4).toList();
    return compact
        ? Row(
            children: [
              Expanded(child: _InsightPanel(snapshot: snapshot)),
              const SizedBox(width: 16),
              Expanded(child: _AlertPanel(alerts: alerts)),
            ],
          )
        : Column(
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
                                constraints:
                                    const BoxConstraints(maxHeight: 320),
                                child: SingleChildScrollView(
                                  child: _EntityDetailPanel(
                                    entity: selectedEntity!,
                                    palette: palette,
                                    onDismiss: onDismiss,
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

  final _TopologyLayout layout;
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
            _LegendRow(label: 'Critical', color: const Color(0xFFFF6F7A)),
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

class _TopologyLayout {
  const _TopologyLayout({
    required this.positions,
    required this.edges,
    required this.canvasWidth,
    required this.canvasHeight,
  });

  final Map<String, Offset> positions;
  final List<_TopologyEdge> edges;
  final double canvasWidth;
  final double canvasHeight;

  static _TopologyLayout build(
    ClusterSnapshot snapshot, {
    required double canvasHeight,
  }) {
    const leftMargin = 56.0;
    const topMargin = 32.0;
    const bottomMargin = 92.0;
    const nodeWidth = 132.0;
    const workloadWidth = 132.0;
    const serviceWidth = 128.0;
    const infrastructureWidth = 360.0;
    const workloadLeft = 470.0;
    const serviceLeft = 790.0;

    final controlPlanes = snapshot.nodes
        .where((node) => node.role == ClusterNodeRole.controlPlane)
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    final workers = snapshot.nodes
        .where((node) => node.role == ClusterNodeRole.worker)
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    final workloads = [...snapshot.workloads]
      ..sort((a, b) => a.name.compareTo(b.name));
    final services = [...snapshot.services]
      ..sort((a, b) => a.name.compareTo(b.name));

    final positions = <String, Offset>{};
    final usableHeight =
        math.max(280.0, canvasHeight - topMargin - bottomMargin);

    final controlPlaneStep = usableHeight / math.max(controlPlanes.length, 1);
    for (var i = 0; i < controlPlanes.length; i++) {
      positions[controlPlanes[i].id] = Offset(
        leftMargin,
        topMargin + (i * controlPlaneStep),
      );
    }

    const workerColumns = 4;
    final workerRows = math.max(1, (workers.length / workerColumns).ceil());
    final workerRowStep = usableHeight / workerRows;
    for (var i = 0; i < workers.length; i++) {
      final row = i ~/ workerColumns;
      final column = i % workerColumns;
      positions[workers[i].id] = Offset(
        leftMargin + 148 + (column * 80),
        topMargin + (row * workerRowStep),
      );
    }

    const workloadColumns = 2;
    final workloadRows =
        math.max(1, (workloads.length / workloadColumns).ceil());
    final workloadRowStep = usableHeight / workloadRows;
    for (var i = 0; i < workloads.length; i++) {
      final row = i ~/ workloadColumns;
      final column = i % workloadColumns;
      positions[workloads[i].id] = Offset(
        workloadLeft + (column * 154),
        topMargin + (row * workloadRowStep),
      );
    }

    final serviceRows = math.max(1, services.length);
    final serviceRowStep = usableHeight / serviceRows;
    for (var i = 0; i < services.length; i++) {
      positions[services[i].id] = Offset(
        serviceLeft,
        topMargin + (i * serviceRowStep),
      );
    }

    final edges = <_TopologyEdge>[
      for (final link in snapshot.links)
        if (positions.containsKey(link.sourceId) &&
            positions.containsKey(link.targetId))
          _TopologyEdge(
            start: _connectionPoint(
              positions[link.sourceId]!,
              width: link.sourceId.startsWith('service:')
                  ? serviceWidth
                  : nodeWidth,
            ),
            end: _connectionPoint(
              positions[link.targetId]!,
              width: link.targetId.startsWith('service:')
                  ? serviceWidth
                  : workloadWidth,
              trailing: false,
            ),
          ),
    ];

    return _TopologyLayout(
      positions: positions,
      edges: edges,
      canvasWidth: infrastructureWidth + workloadWidth + serviceLeft,
      canvasHeight: canvasHeight,
    );
  }

  static Offset _connectionPoint(
    Offset topLeft, {
    required double width,
    bool trailing = true,
  }) {
    return Offset(topLeft.dx + (trailing ? width : 0), topLeft.dy + 42);
  }
}

class _TopologyEdge {
  const _TopologyEdge({
    required this.start,
    required this.end,
  });

  final Offset start;
  final Offset end;
}

class _EntityDetailPanel extends StatelessWidget {
  const _EntityDetailPanel({
    required this.entity,
    required this.palette,
    required this.onDismiss,
  });

  final Object entity;
  final ClusterOrbitPalette palette;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: palette.panel.withValues(alpha: 0.96),
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
              IconButton(
                onPressed: onDismiss,
                icon: const Icon(Icons.close, size: 18, color: Colors.white),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                tooltip: 'Dismiss',
              ),
            ],
          ),
          const SizedBox(height: 12),
          ..._buildFields(theme),
        ],
      ),
    );
  }

  Widget _buildTitle(ThemeData theme) {
    final (name, badge) = switch (entity) {
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

  List<Widget> _buildFields(ThemeData theme) => switch (entity) {
        ClusterNode n => _nodeFields(n, theme),
        ClusterWorkload w => _workloadFields(w, theme),
        ClusterService s => _serviceFields(s, theme),
        _ => const [],
      };

  List<Widget> _nodeFields(ClusterNode n, ThemeData theme) {
    final tint = _healthTint(n.health, palette);
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
    final tint = _healthTint(w.health, palette);
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
    ];
  }

  List<Widget> _serviceFields(ClusterService s, ThemeData theme) {
    final tint = _healthTint(s.health, palette);
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
