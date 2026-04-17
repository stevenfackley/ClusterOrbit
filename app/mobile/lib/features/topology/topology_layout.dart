import 'dart:math' as math;
import 'dart:ui';

import '../../core/cluster_domain/cluster_models.dart';

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
    required double canvasHeight,
    TopologyFilter filter = const TopologyFilter(),
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

    final controlPlanes = !filter.showNodes
        ? const <ClusterNode>[]
        : (snapshot.nodes
            .where((node) => node.role == ClusterNodeRole.controlPlane)
            .toList()
          ..sort((a, b) => a.name.compareTo(b.name)));
    final workers = !filter.showNodes
        ? const <ClusterNode>[]
        : (snapshot.nodes
            .where((node) => node.role == ClusterNodeRole.worker)
            .toList()
          ..sort((a, b) => a.name.compareTo(b.name)));
    final workloads = !filter.showWorkloads
        ? const <ClusterWorkload>[]
        : ([...snapshot.workloads]..sort((a, b) => a.name.compareTo(b.name)));
    final services = !filter.showServices
        ? const <ClusterService>[]
        : ([...snapshot.services]..sort((a, b) => a.name.compareTo(b.name)));

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

    final edges = <TopologyEdge>[
      for (final link in snapshot.links)
        if (positions.containsKey(link.sourceId) &&
            positions.containsKey(link.targetId))
          TopologyEdge(
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

    return TopologyLayout(
      positions: positions,
      edges: edges,
      canvasWidth: infrastructureWidth + workloadWidth + serviceLeft,
      canvasHeight: canvasHeight,
      visibleNodeIds: {
        for (final n in controlPlanes) n.id,
        for (final n in workers) n.id,
      },
      visibleWorkloadIds: {for (final w in workloads) w.id},
      visibleServiceIds: {for (final s in services) s.id},
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
