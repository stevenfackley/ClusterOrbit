import 'package:flutter/material.dart';

import '../../core/cluster_domain/cluster_models.dart';
import '../../core/theme/clusterorbit_theme.dart';

/// Tints an entity by its health level using the active palette.
Color healthTint(ClusterHealthLevel level, ClusterOrbitPalette palette) {
  switch (level) {
    case ClusterHealthLevel.healthy:
      return palette.accentTeal;
    case ClusterHealthLevel.warning:
      return palette.warning;
    case ClusterHealthLevel.critical:
      return const Color(0xFFFF6F7A);
  }
}

/// Positions an orb on the canvas at [offset] and wires tap handling.
class CanvasNode extends StatelessWidget {
  const CanvasNode({
    super.key,
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

class NodeOrb extends StatelessWidget {
  const NodeOrb({
    super.key,
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
    final tint = healthTint(node.health, palette);

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
              StatusDot(color: tint),
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

class WorkloadOrb extends StatelessWidget {
  const WorkloadOrb({
    super.key,
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
    final tint = healthTint(workload.health, palette);

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
              StatusDot(color: tint),
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

class ServiceOrb extends StatelessWidget {
  const ServiceOrb({
    super.key,
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
    final tint = healthTint(service.health, palette);

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

class LegendCard extends StatelessWidget {
  const LegendCard({super.key, required this.palette});

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
            LegendRow(label: 'Healthy', color: palette.accentTeal),
            LegendRow(label: 'Warning', color: palette.warning),
            const LegendRow(label: 'Critical', color: Color(0xFFFF6F7A)),
          ],
        ),
      ),
    );
  }
}

class MiniStatusCard extends StatelessWidget {
  const MiniStatusCard({super.key, required this.snapshot});

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

class ModeBadge extends StatelessWidget {
  const ModeBadge({super.key, required this.label, required this.tint});

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

class SummaryChip extends StatelessWidget {
  const SummaryChip({super.key, required this.label, required this.value});

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

/// Wraps Material's [FilterChip] with ClusterOrbit styling.
class TopologyFilterChip extends StatelessWidget {
  const TopologyFilterChip({
    super.key,
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

class MetricRow extends StatelessWidget {
  const MetricRow({super.key, required this.label, required this.value});

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

class AlertTile extends StatelessWidget {
  const AlertTile({super.key, required this.alert});

  final ClusterAlert alert;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.extension<ClusterOrbitPalette>()!;
    final tint = healthTint(alert.level, palette);

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

class LegendRow extends StatelessWidget {
  const LegendRow({super.key, required this.label, required this.color});

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
          StatusDot(color: color),
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

class StatusDot extends StatelessWidget {
  const StatusDot({super.key, required this.color});

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
