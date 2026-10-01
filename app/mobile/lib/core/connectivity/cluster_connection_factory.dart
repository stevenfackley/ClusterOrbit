import 'package:flutter_dotenv/flutter_dotenv.dart';

import '../cluster_domain/cluster_models.dart';
import '../cluster_domain/saved_connection.dart';
import 'cluster_connection.dart';
import 'gateway_cluster_connection.dart';
import 'kubeconfig_repository.dart';
import 'kubernetes_event_loader.dart';
import 'kubernetes_snapshot_loader.dart';
import 'kubernetes_workload_scaler.dart';
import 'sample_cluster_data.dart';

// Callers build gateway connections through this file; keep them importable
// from here now that the implementation lives in its own file.
export 'gateway_cluster_connection.dart';

final class ClusterConnectionFactory {
  const ClusterConnectionFactory._();

  static ClusterConnection fromEnvironment([Map<String, String>? env]) {
    final environment = env ?? _safeDotEnv();
    final mode = ConnectionModeLabel.fromEnvironment(
      environment['CLUSTERORBIT_CONNECTION_MODE'],
    );

    return switch (mode) {
      ConnectionMode.direct => DirectClusterConnection(
          repository: KubeconfigRepository(environment: environment),
        ),
      ConnectionMode.gateway => GatewayClusterConnection(
          gatewayBaseUrl: environment['CLUSTERORBIT_GATEWAY_URL'] ?? '',
          token: environment['CLUSTERORBIT_GATEWAY_TOKEN'] ?? '',
        ),
    };
  }

  /// Build a [ClusterConnection] from a user-saved entry. Used by the app
  /// gate to wire the active connection for the shell.
  ///
  /// - `sample`: in-process fake data; no I/O.
  /// - `gateway`: HTTP-backed; a missing or invalid URL fails every call
  ///   with a [GatewayException] instead of serving sample data.
  /// - `direct`: kubeconfig provided by the saved entry (or env if null).
  static ClusterConnection fromSavedConnection(SavedConnection saved) {
    return switch (saved.kind) {
      SavedConnectionKind.sample => const SampleClusterConnection(),
      SavedConnectionKind.gateway => GatewayClusterConnection(
          gatewayBaseUrl: saved.gatewayUrl ?? '',
          token: saved.gatewayToken ?? '',
        ),
      SavedConnectionKind.direct => DirectClusterConnection(
          repository: KubeconfigRepository(
            environment: {
              if (saved.kubeconfigContext != null)
                'CLUSTERORBIT_CONTEXT': saved.kubeconfigContext!,
            },
          ),
        ),
    };
  }

  static Map<String, String> _safeDotEnv() {
    try {
      return dotenv.env;
    } catch (_) {
      return const {};
    }
  }
}

final class DirectClusterConnection implements ClusterConnection {
  DirectClusterConnection({
    KubeconfigRepository? repository,
    KubernetesSnapshotLoader? snapshotLoader,
    KubernetesEventLoader? eventLoader,
    KubernetesWorkloadScaler? workloadScaler,
    KubernetesNodeCordoner? nodeCordoner,
  })  : _repository = repository ?? KubeconfigRepository(),
        _snapshotLoader = snapshotLoader ?? KubernetesSnapshotLoader(),
        _eventLoader = eventLoader ?? KubernetesEventLoader(),
        _workloadScaler = workloadScaler ?? KubernetesWorkloadScaler(),
        _nodeCordoner = nodeCordoner ?? KubernetesNodeCordoner();

  final KubeconfigRepository _repository;
  final KubernetesSnapshotLoader _snapshotLoader;
  final KubernetesEventLoader _eventLoader;
  final KubernetesWorkloadScaler _workloadScaler;
  final KubernetesNodeCordoner _nodeCordoner;

  @override
  ConnectionMode get mode => ConnectionMode.direct;

  @override
  Future<List<ClusterProfile>> listClusters() async {
    final kubeconfigProfiles = await _repository.loadProfiles();
    if (kubeconfigProfiles.isNotEmpty) {
      return kubeconfigProfiles;
    }

    return SampleClusterData.profilesFor(mode);
  }

  @override
  Future<ClusterSnapshot> loadSnapshot(String clusterId) async {
    final profile = await _resolveCluster(clusterId);
    final resolvedCluster = await _repository.loadResolvedCluster(clusterId);
    if (resolvedCluster == null) {
      return SampleClusterData.snapshotFor(profile);
    }

    return _snapshotLoader.loadSnapshot(resolvedCluster);
  }

  @override
  Future<List<ClusterEvent>> loadEvents({
    required String clusterId,
    required TopologyEntityKind kind,
    required String objectName,
    String? namespace,
    int limit = 5,
  }) async {
    final resolvedCluster = await _repository.loadResolvedCluster(clusterId);
    if (resolvedCluster == null) {
      return SampleClusterData.eventsFor(kind: kind, objectName: objectName)
          .take(limit)
          .toList();
    }

    return _eventLoader.loadEvents(
      cluster: resolvedCluster,
      objectName: objectName,
      namespace: kind == TopologyEntityKind.node ? null : namespace,
      limit: limit,
    );
  }

  @override
  Future<void> scaleWorkload({
    required String clusterId,
    required String workloadId,
    required int replicas,
  }) async {
    final resolvedCluster = await _repository.loadResolvedCluster(clusterId);
    if (resolvedCluster == null) {
      throw StateError(
        'No resolvable kubeconfig for cluster $clusterId — scale is unsupported in sample-only mode.',
      );
    }
    await _workloadScaler.scaleWorkload(
      cluster: resolvedCluster,
      workloadId: workloadId,
      replicas: replicas,
    );
  }

  @override
  Future<void> restartWorkload({
    required String clusterId,
    required String workloadId,
  }) async {
    final resolvedCluster = await _repository.loadResolvedCluster(clusterId);
    if (resolvedCluster == null) {
      throw StateError(
        'No resolvable kubeconfig for cluster $clusterId — restart is unsupported in sample-only mode.',
      );
    }
    await _workloadScaler.restartWorkload(
      cluster: resolvedCluster,
      workloadId: workloadId,
    );
  }

  @override
  Future<void> setNodeSchedulable({
    required String clusterId,
    required String nodeId,
    required bool schedulable,
  }) async {
    final resolvedCluster = await _repository.loadResolvedCluster(clusterId);
    if (resolvedCluster == null) {
      throw StateError(
        'No resolvable kubeconfig for cluster $clusterId — cordon is unsupported in sample-only mode.',
      );
    }
    await _nodeCordoner.setSchedulable(
      cluster: resolvedCluster,
      nodeId: nodeId,
      schedulable: schedulable,
    );
  }

  @override
  Future<DrainJob> startDrain({
    required String clusterId,
    required String nodeId,
  }) async {
    throw UnsupportedError(
      'Direct mode does not support node drain — connect through the gateway to drain nodes.',
    );
  }

  @override
  Future<DrainJob> drainStatus({
    required String clusterId,
    required String nodeId,
    required String jobId,
  }) async {
    throw UnsupportedError(
      'Direct mode does not support node drain — connect through the gateway to drain nodes.',
    );
  }

  Future<ClusterProfile> _resolveCluster(String clusterId) async {
    final profiles = await listClusters();
    return profiles.firstWhere(
      (profile) => profile.id == clusterId,
      orElse: () => profiles.first,
    );
  }
}

/// Sample-only connection. Returns the bundled demo cluster data with no
/// network I/O. Used when the user explicitly picks "Sample data" in
/// onboarding, so the app remains fully functional offline and a new user
/// can see what the UI looks like before wiring a real cluster.
final class SampleClusterConnection implements ClusterConnection {
  const SampleClusterConnection();

  @override
  ConnectionMode get mode => ConnectionMode.direct;

  @override
  Future<List<ClusterProfile>> listClusters() async =>
      SampleClusterData.profilesFor(mode);

  @override
  Future<ClusterSnapshot> loadSnapshot(String clusterId) async {
    final profiles = SampleClusterData.profilesFor(mode);
    final profile = profiles.firstWhere(
      (p) => p.id == clusterId,
      orElse: () => profiles.first,
    );
    return SampleClusterData.snapshotFor(profile);
  }

  @override
  Future<List<ClusterEvent>> loadEvents({
    required String clusterId,
    required TopologyEntityKind kind,
    required String objectName,
    String? namespace,
    int limit = 5,
  }) async =>
      SampleClusterData.eventsFor(kind: kind, objectName: objectName)
          .take(limit)
          .toList();

  @override
  Future<void> scaleWorkload({
    required String clusterId,
    required String workloadId,
    required int replicas,
  }) async {
    throw StateError(
      'Sample connection does not support mutations — add a real connection to scale workloads.',
    );
  }

  @override
  Future<void> restartWorkload({
    required String clusterId,
    required String workloadId,
  }) async {
    throw StateError(
      'Sample connection does not support mutations — add a real connection to restart workloads.',
    );
  }

  @override
  Future<void> setNodeSchedulable({
    required String clusterId,
    required String nodeId,
    required bool schedulable,
  }) async {
    throw StateError(
      'Sample connection does not support mutations — add a real connection to cordon nodes.',
    );
  }

  @override
  Future<DrainJob> startDrain({
    required String clusterId,
    required String nodeId,
  }) async {
    throw StateError(
      'Sample connection does not support mutations — add a real connection to drain nodes.',
    );
  }

  @override
  Future<DrainJob> drainStatus({
    required String clusterId,
    required String nodeId,
    required String jobId,
  }) async {
    throw StateError(
      'Sample connection does not support mutations — add a real connection to drain nodes.',
    );
  }
}
