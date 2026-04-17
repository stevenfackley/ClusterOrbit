import 'package:flutter_dotenv/flutter_dotenv.dart';

import '../cluster_domain/cluster_models.dart';
import 'cluster_connection.dart';
import 'kubeconfig_repository.dart';
import 'kubernetes_event_loader.dart';
import 'kubernetes_snapshot_loader.dart';
import 'sample_cluster_data.dart';

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
          gatewayBaseUrl: environment['CLUSTERORBIT_GATEWAY_URL'] ??
              'https://gateway.local',
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
  })  : _repository = repository ?? KubeconfigRepository(),
        _snapshotLoader = snapshotLoader ?? KubernetesSnapshotLoader(),
        _eventLoader = eventLoader ?? KubernetesEventLoader();

  final KubeconfigRepository _repository;
  final KubernetesSnapshotLoader _snapshotLoader;
  final KubernetesEventLoader _eventLoader;

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
  Stream<ClusterSnapshot> watchSnapshot(String clusterId) async* {
    yield await loadSnapshot(clusterId);
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

  Future<ClusterProfile> _resolveCluster(String clusterId) async {
    final profiles = await listClusters();
    return profiles.firstWhere(
      (profile) => profile.id == clusterId,
      orElse: () => profiles.first,
    );
  }
}

final class GatewayClusterConnection implements ClusterConnection {
  GatewayClusterConnection({
    required this.gatewayBaseUrl,
  });

  final String gatewayBaseUrl;

  @override
  ConnectionMode get mode => ConnectionMode.gateway;

  @override
  Future<List<ClusterProfile>> listClusters() async =>
      SampleClusterData.profilesFor(mode);

  @override
  Future<ClusterSnapshot> loadSnapshot(String clusterId) async {
    final profile = await _resolveCluster(clusterId);
    return SampleClusterData.snapshotFor(
      ClusterProfile(
        id: profile.id,
        name: profile.name,
        apiServerHost: gatewayBaseUrl,
        environmentLabel: profile.environmentLabel,
        connectionMode: profile.connectionMode,
      ),
    );
  }

  @override
  Stream<ClusterSnapshot> watchSnapshot(String clusterId) async* {
    yield await loadSnapshot(clusterId);
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

  Future<ClusterProfile> _resolveCluster(String clusterId) async {
    final profiles = await listClusters();
    return profiles.firstWhere(
      (profile) => profile.id == clusterId,
      orElse: () => profiles.first,
    );
  }
}
