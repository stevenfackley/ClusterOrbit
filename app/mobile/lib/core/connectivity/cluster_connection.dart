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

  /// Scale a workload to the requested replica count.
  ///
  /// [workloadId] is the topology workload id (`{kind}:{namespace}/{name}`).
  /// Only `deployment` and `statefulSet` kinds are scalable; other kinds
  /// throw [UnsupportedWorkloadKindException]. Implementations throw on
  /// backend failure so the caller can surface the error.
  Future<void> scaleWorkload({
    required String clusterId,
    required String workloadId,
    required int replicas,
  });
}

/// Thrown when `scaleWorkload` is called on a workload kind the backend does
/// not support (e.g. DaemonSet, Job).
class UnsupportedWorkloadKindException implements Exception {
  UnsupportedWorkloadKindException(this.kind);
  final String kind;

  @override
  String toString() => 'UnsupportedWorkloadKindException: $kind';
}
