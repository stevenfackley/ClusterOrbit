import 'package:clusterorbit_mobile/core/cluster_domain/cluster_models.dart';
import 'package:clusterorbit_mobile/core/connectivity/sample_cluster_data.dart';
import 'package:clusterorbit_mobile/features/topology/topology_layout.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  ClusterSnapshot sampleSnapshot() {
    final profile = SampleClusterData.profilesFor(ConnectionMode.direct).first;
    return SampleClusterData.snapshotFor(profile);
  }

  test('default filter places every node, workload, and service', () {
    final snapshot = sampleSnapshot();

    final layout = TopologyLayout.build(snapshot, canvasHeight: 800);

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
      canvasHeight: 800,
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
      canvasHeight: 800,
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

  test('canvasHeight clamps to a sensible minimum usable area', () {
    final snapshot = sampleSnapshot();
    // A tiny canvas should not produce negative vertical steps.
    final layout = TopologyLayout.build(snapshot, canvasHeight: 100);
    for (final pos in layout.positions.values) {
      expect(pos.dy, greaterThanOrEqualTo(0.0));
    }
  });
}
