import '../../core/cluster_domain/cluster_models.dart';

/// Identifies a topology entity across snapshots. Every refresh builds new
/// entity objects, so a selection is held by kind and id (unique per kind
/// within one snapshot), never by object reference.
typedef TopologyEntityKey = ({TopologyEntityKind kind, String id});

TopologyEntityKey? topologyEntityKey(Object entity) => switch (entity) {
      ClusterNode n => (kind: TopologyEntityKind.node, id: n.id),
      ClusterWorkload w => (kind: TopologyEntityKind.workload, id: w.id),
      ClusterService s => (kind: TopologyEntityKind.service, id: s.id),
      _ => null,
    };

/// The entity [key] names in [snapshot], or null if the snapshot lacks it.
Object? resolveTopologyEntity(
  ClusterSnapshot snapshot,
  TopologyEntityKey key,
) =>
    switch (key.kind) {
      TopologyEntityKind.node =>
        snapshot.nodes.where((n) => n.id == key.id).firstOrNull,
      TopologyEntityKind.workload =>
        snapshot.workloads.where((w) => w.id == key.id).firstOrNull,
      TopologyEntityKind.service =>
        snapshot.services.where((s) => s.id == key.id).firstOrNull,
    };
