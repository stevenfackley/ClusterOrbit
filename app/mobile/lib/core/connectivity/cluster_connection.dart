import '../cluster_domain/cluster_models.dart';

abstract interface class ClusterConnection {
  ConnectionMode get mode;

  Future<List<ClusterProfile>> listClusters();

  Future<ClusterSnapshot> loadSnapshot(String clusterId);

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

  /// Trigger a rolling restart of a workload (kubectl rollout restart).
  ///
  /// [workloadId] is the topology workload id (`{kind}:{namespace}/{name}`).
  /// `deployment`, `statefulSet`, and `daemonSet` are supported; other kinds
  /// throw [UnsupportedWorkloadKindException]. Implementations throw on
  /// backend failure so the caller can surface the error.
  Future<void> restartWorkload({
    required String clusterId,
    required String workloadId,
  });

  /// Toggle a node's schedulability (cordon / uncordon).
  ///
  /// [schedulable] false cordons the node (sets `spec.unschedulable=true`);
  /// true uncordons it. [nodeId] is the topology node id (the node name).
  /// This does not evict running pods — draining is a separate operation.
  /// Implementations throw on backend failure.
  Future<void> setNodeSchedulable({
    required String clusterId,
    required String nodeId,
    required bool schedulable,
  });

  /// Start an async drain of a node (cordon + evict pods).
  ///
  /// Cordons [nodeId] then evicts all evictable pods (skipping DaemonSet,
  /// mirror/static, and completed pods). The returned [DrainJob] carries the
  /// job id to poll with [drainStatus]; the drain runs in the background.
  /// Only the gateway backend supports this; others throw
  /// [UnsupportedError]. Implementations throw on backend failure.
  Future<DrainJob> startDrain({
    required String clusterId,
    required String nodeId,
  });

  /// Poll the status of a previously started drain job.
  ///
  /// [jobId] comes from the [DrainJob] returned by [startDrain]. The returned
  /// job reports the current [DrainPhase] plus evicted/skipped/remaining
  /// counts. Implementations throw on backend failure.
  Future<DrainJob> drainStatus({
    required String clusterId,
    required String nodeId,
    required String jobId,
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

/// A mutation the gateway parked for a second operator's approval instead of
/// executing it (the gateway's `PendingRequest`).
class PendingApproval {
  const PendingApproval({
    required this.id,
    required this.op,
    required this.targetId,
    this.expiresAt,
  });

  factory PendingApproval.fromJson(Map<String, dynamic> json) {
    final expiresAt = json['expiresAt'];
    return PendingApproval(
      id: json['id'] as String? ?? '',
      op: json['op'] as String? ?? '',
      targetId: json['targetId'] as String? ?? '',
      expiresAt: expiresAt is num && expiresAt > 0
          ? DateTime.fromMillisecondsSinceEpoch(expiresAt.toInt(), isUtc: true)
          : null,
    );
  }

  /// Approval request id (`apr-…`), not a drain job id.
  final String id;

  /// `scale`, `restart`, `cordon` or `drain`.
  final String op;
  final String targetId;
  final DateTime? expiresAt;
}

/// Thrown by a mutation the backend accepted but did not execute: it waits
/// for a second operator to approve [pending]. Not a failure, and not a
/// success either; callers should say so rather than report the change done.
class ApprovalPendingException implements Exception {
  const ApprovalPendingException(this.pending);
  final PendingApproval pending;

  @override
  String toString() =>
      'ApprovalPendingException: ${pending.op} of ${pending.targetId} '
      'awaits approval (${pending.id})';
}
