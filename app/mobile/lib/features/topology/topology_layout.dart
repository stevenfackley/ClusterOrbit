import 'dart:math' as math;
import 'dart:ui';

import '../../core/cluster_domain/cluster_models.dart';

/// Orb geometry shared by [TopologyLayout] and the orb widgets: the layout
/// reserves exactly this box per orb and each orb sizes itself to it.
abstract final class OrbMetrics {
  static const double nodeWidth = 132;
  static const double workloadWidth = 132;
  static const double serviceWidth = 128;

  /// Fits the tallest labelled orb (title, subtitle, status row, selected
  /// border) at [maxTextScale].
  static const double height = 148;

  /// Text scale the canvas clamps to so content never outgrows [height].
  /// The map zooms to 1.8x, and the list view carries full-scale text.
  static const double maxTextScale = 1.5;
}

/// Pure-logic layout engine for the topology canvas.
///
/// Lives outside the widget so it can be tested independently and reused by
/// future views (e.g. a retained-scene engine).
class TopologyLayout {
  const TopologyLayout({
    required this.positions,
    required this.edges,
    required this.canvasWidth,
    required this.canvasHeight,
    required this.visibleNodeIds,
    required this.visibleWorkloadIds,
    required this.visibleServiceIds,
  });

  final Map<String, Offset> positions;
  final List<TopologyEdge> edges;
  final double canvasWidth;
  final double canvasHeight;

  /// Subset of snapshot entity IDs that passed the filter.
  final Set<String> visibleNodeIds;
  final Set<String> visibleWorkloadIds;
  final Set<String> visibleServiceIds;

  static TopologyLayout build(
    ClusterSnapshot snapshot, {
    TopologyFilter filter = const TopologyFilter(),
  }) {
    const leftMargin = 56.0;
    const rightMargin = 56.0;
    const topMargin = 32.0;
    // Room under the last row so it can be panned clear of the legend.
    const bottomMargin = 92.0;
    // Between neighbouring orbs on both axes, and between control planes
    // and workers.
    const orbGap = 16.0;
    // Between lanes that edges have to cross.
    const laneGap = 64.0;
    const rowPitch = OrbMetrics.height + orbGap;

    final controlPlanes = !filter.showNodes
        ? const <ClusterNode>[]
        : (snapshot.nodes
            .where((node) => node.role == ClusterNodeRole.controlPlane)
            .toList()
          ..sort((a, b) => _compareKeys([a.name, a.id], [b.name, b.id])));
    final workers = !filter.showNodes
        ? const <ClusterNode>[]
        : (snapshot.nodes
            .where((node) => node.role == ClusterNodeRole.worker)
            .toList()
          ..sort((a, b) => _compareKeys([a.name, a.id], [b.name, b.id])));
    final workloads = !filter.showWorkloads
        ? const <ClusterWorkload>[]
        : ([...snapshot.workloads]..sort((a, b) => _compareKeys(
            [a.name, a.namespace, a.id], [b.name, b.namespace, b.id])));
    final services = !filter.showServices
        ? const <ClusterService>[]
        : ([...snapshot.services]..sort((a, b) => _compareKeys(
            [a.name, a.namespace, a.id], [b.name, b.namespace, b.id])));

    final positions = <String, Offset>{};
    // Each lane starts where the previous non-empty lane ends, so lanes never
    // overlap however many columns a lane fills.
    var laneRight = leftMargin;
    var placedAny = false;
    var rows = 1;
    void placeLane(
      List<String> ids, {
      required double width,
      int columns = 1,
      double gapBefore = laneGap,
    }) {
      if (ids.isEmpty) return;
      final left = placedAny ? laneRight + gapBefore : leftMargin;
      for (var i = 0; i < ids.length; i++) {
        positions[ids[i]] = Offset(
          left + (i % columns) * (width + orbGap),
          topMargin + (i ~/ columns) * rowPitch,
        );
      }
      final used = math.min(columns, ids.length);
      laneRight = left + used * width + (used - 1) * orbGap;
      rows = math.max(rows, (ids.length / columns).ceil());
      placedAny = true;
    }

    placeLane([for (final n in controlPlanes) n.id],
        width: OrbMetrics.nodeWidth);
    placeLane(
      [for (final n in workers) n.id],
      width: OrbMetrics.nodeWidth,
      columns: 4,
      gapBefore: orbGap,
    );
    placeLane(
      [for (final w in workloads) w.id],
      width: OrbMetrics.workloadWidth,
      columns: 2,
    );
    placeLane([for (final s in services) s.id], width: OrbMetrics.serviceWidth);

    final visibleNodeIds = {
      for (final n in controlPlanes) n.id,
      for (final n in workers) n.id,
    };
    final visibleWorkloadIds = {for (final w in workloads) w.id};
    final visibleServiceIds = {for (final s in services) s.id};

    double widthOf(String id) => visibleServiceIds.contains(id)
        ? OrbMetrics.serviceWidth
        : visibleWorkloadIds.contains(id)
            ? OrbMetrics.workloadWidth
            : OrbMetrics.nodeWidth;

    // Edges run left to right whatever the link direction: from the trailing
    // edge of the left-hand orb to the leading edge of the right-hand one.
    final edges = <TopologyEdge>[];
    for (final link in snapshot.links) {
      final a = positions[link.sourceId];
      final b = positions[link.targetId];
      if (a == null || b == null) continue;
      final (left, right, leftWidth) = a.dx <= b.dx
          ? (a, b, widthOf(link.sourceId))
          : (b, a, widthOf(link.targetId));
      edges.add(TopologyEdge(
        start: _connectionPoint(left, width: leftWidth),
        end: _connectionPoint(right, width: 0, trailing: false),
      ));
    }

    return TopologyLayout(
      positions: positions,
      edges: edges,
      canvasWidth: laneRight + rightMargin,
      canvasHeight: topMargin + rows * rowPitch - orbGap + bottomMargin,
      visibleNodeIds: visibleNodeIds,
      visibleWorkloadIds: visibleWorkloadIds,
      visibleServiceIds: visibleServiceIds,
    );
  }

  /// Name first, then namespace and id as tie-breaks, so equal names land
  /// in the same order on every refresh.
  static int _compareKeys(List<String> a, List<String> b) {
    for (var i = 0; i < a.length; i++) {
      final order = a[i].compareTo(b[i]);
      if (order != 0) return order;
    }
    return 0;
  }

  static Offset _connectionPoint(
    Offset topLeft, {
    required double width,
    bool trailing = true,
  }) {
    return Offset(topLeft.dx + (trailing ? width : 0), topLeft.dy + 42);
  }
}

class TopologyEdge {
  const TopologyEdge({
    required this.start,
    required this.end,
  });

  final Offset start;
  final Offset end;
}

/// Which entity kinds are visible on the canvas. Immutable.
class TopologyFilter {
  const TopologyFilter({
    this.showNodes = true,
    this.showWorkloads = true,
    this.showServices = true,
  });

  final bool showNodes;
  final bool showWorkloads;
  final bool showServices;

  TopologyFilter copyWith({
    bool? showNodes,
    bool? showWorkloads,
    bool? showServices,
  }) =>
      TopologyFilter(
        showNodes: showNodes ?? this.showNodes,
        showWorkloads: showWorkloads ?? this.showWorkloads,
        showServices: showServices ?? this.showServices,
      );

  @override
  bool operator ==(Object other) =>
      other is TopologyFilter &&
      other.showNodes == showNodes &&
      other.showWorkloads == showWorkloads &&
      other.showServices == showServices;

  @override
  int get hashCode => Object.hash(showNodes, showWorkloads, showServices);
}
