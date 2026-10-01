import 'package:clusterorbit_mobile/core/cluster_domain/cluster_models.dart';
import 'package:clusterorbit_mobile/core/connectivity/sample_cluster_data.dart';
import 'package:clusterorbit_mobile/features/topology/topology_layout.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  ClusterSnapshot sampleSnapshot() {
    final profile = SampleClusterData.profilesFor(ConnectionMode.direct).first;
    return SampleClusterData.snapshotFor(profile);
  }

  test('default filter places every node, workload, and service', () {
    final snapshot = sampleSnapshot();

    final layout = TopologyLayout.build(snapshot);

    expect(layout.visibleNodeIds.length, snapshot.nodes.length);
    expect(layout.visibleWorkloadIds.length, snapshot.workloads.length);
    expect(layout.visibleServiceIds.length, snapshot.services.length);
    for (final node in snapshot.nodes) {
      expect(layout.positions.containsKey(node.id), isTrue,
          reason: 'expected position for node ${node.id}');
    }
  });

  test('showNodes=false hides nodes and any edges anchored to nodes', () {
    final snapshot = sampleSnapshot();

    final layout = TopologyLayout.build(
      snapshot,
      filter: const TopologyFilter(showNodes: false),
    );

    expect(layout.visibleNodeIds, isEmpty);
    expect(layout.visibleWorkloadIds.length, snapshot.workloads.length);
    for (final node in snapshot.nodes) {
      expect(layout.positions.containsKey(node.id), isFalse);
    }
    // Edges require both endpoints to have positions — any edge that touched
    // a node should be gone.
    final nodeIds = snapshot.nodes.map((n) => n.id).toSet();
    final linksAnchoredToNodes = snapshot.links
        .where(
            (l) => nodeIds.contains(l.sourceId) || nodeIds.contains(l.targetId))
        .length;
    expect(layout.edges.length, snapshot.links.length - linksAnchoredToNodes);
  });

  test('showWorkloads=false hides workloads only', () {
    final snapshot = sampleSnapshot();

    final layout = TopologyLayout.build(
      snapshot,
      filter: const TopologyFilter(showWorkloads: false),
    );

    expect(layout.visibleWorkloadIds, isEmpty);
    expect(layout.visibleNodeIds.length, snapshot.nodes.length);
    expect(layout.visibleServiceIds.length, snapshot.services.length);
  });

  test('TopologyFilter equality and copyWith', () {
    const a = TopologyFilter();
    const b = TopologyFilter();
    expect(a, equals(b));
    expect(a.hashCode, equals(b.hashCode));

    final c = a.copyWith(showServices: false);
    expect(c.showServices, isFalse);
    expect(c.showNodes, isTrue);
    expect(c, isNot(equals(a)));
  });

  Rect orbRect(TopologyLayout layout, String id) {
    final width = layout.visibleServiceIds.contains(id)
        ? OrbMetrics.serviceWidth
        : layout.visibleWorkloadIds.contains(id)
            ? OrbMetrics.workloadWidth
            : OrbMetrics.nodeWidth;
    return layout.positions[id]! & Size(width, OrbMetrics.height);
  }

  test('no two orbs overlap and every orb fits the canvas', () {
    final snapshot = sampleSnapshot();
    expect(snapshot.controlPlaneCount, 3);
    expect(snapshot.workerCount, 39);
    expect(snapshot.workloads, hasLength(18));
    expect(snapshot.services, hasLength(12));

    final layout = TopologyLayout.build(snapshot);
    final ids = layout.positions.keys.toList();
    final canvas = Offset.zero & Size(layout.canvasWidth, layout.canvasHeight);

    for (var i = 0; i < ids.length; i++) {
      final a = orbRect(layout, ids[i]);
      expect(canvas.intersect(a), a, reason: '${ids[i]} leaves the canvas');
      for (var j = i + 1; j < ids.length; j++) {
        final b = orbRect(layout, ids[j]);
        expect(a.overlaps(b), isFalse,
            reason: '${ids[i]} $a overlaps ${ids[j]} $b');
      }
    }
  });

  test('every edge runs left to right from orb edge to orb edge', () {
    final snapshot = sampleSnapshot();

    final layout = TopologyLayout.build(snapshot);

    // Default filter keeps every link, so edges line up with links.
    expect(layout.edges, hasLength(snapshot.links.length));
    for (var i = 0; i < snapshot.links.length; i++) {
      final link = snapshot.links[i];
      final edge = layout.edges[i];
      final source = orbRect(layout, link.sourceId);
      final target = orbRect(layout, link.targetId);
      final (left, right) =
          source.left <= target.left ? (source, target) : (target, source);
      final label = '${link.sourceId} -> ${link.targetId}';
      expect(edge.start.dx, left.right, reason: label);
      expect(edge.end.dx, right.left, reason: label);
      expect(edge.start.dx, lessThanOrEqualTo(edge.end.dx));
    }
  });

  test('equal names sort the same whatever the input order', () {
    final snapshot = sampleSnapshot();
    ClusterWorkload web(String namespace) => ClusterWorkload(
          id: 'deployment:$namespace/web',
          namespace: namespace,
          name: 'web',
          kind: WorkloadKind.deployment,
          desiredReplicas: 1,
          readyReplicas: 1,
          nodeIds: const [],
          health: ClusterHealthLevel.healthy,
          images: const [],
        );
    ClusterSnapshot withWorkloads(List<ClusterWorkload> workloads) =>
        ClusterSnapshot(
          profile: snapshot.profile,
          generatedAt: snapshot.generatedAt,
          nodes: snapshot.nodes,
          workloads: workloads,
          services: const [],
          alerts: const [],
          links: const [],
        );

    final forward =
        TopologyLayout.build(withWorkloads([web('apps'), web('platform')]));
    final reversed =
        TopologyLayout.build(withWorkloads([web('platform'), web('apps')]));

    expect(reversed.positions, forward.positions);
    expect(forward.positions['deployment:apps/web']!.dx,
        lessThan(forward.positions['deployment:platform/web']!.dx));
  });

  test('hiding a lane closes the gap it leaves', () {
    final snapshot = sampleSnapshot();

    final all = TopologyLayout.build(snapshot);
    final noNodes = TopologyLayout.build(
      snapshot,
      filter: const TopologyFilter(showNodes: false),
    );

    expect(noNodes.canvasWidth, lessThan(all.canvasWidth));
    final firstWorkload = noNodes.positions[snapshot.workloads.first.id]!;
    expect(firstWorkload.dx,
        lessThan(all.positions[snapshot.workloads.first.id]!.dx));
  });
}
