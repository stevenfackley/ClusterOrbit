import '../cluster_domain/cluster_models.dart';

abstract interface class ClusterConnection {
  ConnectionMode get mode;

  Future<List<ClusterProfile>> listClusters();

  Future<ClusterSnapshot> loadSnapshot(String clusterId);

  Stream<ClusterSnapshot> watchSnapshot(String clusterId);

  /// Fetch the most recent events for a single entity.
  ///
  /// [namespace] must be null for node-scoped lookups and non-null for
  /// workloads and services. Returned events are ordered newest-first and
  /// limited to [limit] entries.
  Future<List<ClusterEvent>> loadEvents({
    required String clusterId,
    required TopologyEntityKind kind,
    required String objectName,
    String? namespace,
    int limit = 5,
  });
}
