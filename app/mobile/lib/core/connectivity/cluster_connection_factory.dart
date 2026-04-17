import 'dart:convert';
import 'dart:io';

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
          gatewayBaseUrl: environment['CLUSTERORBIT_GATEWAY_URL'] ?? '',
          token: environment['CLUSTERORBIT_GATEWAY_TOKEN'] ?? '',
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

/// HTTP-backed gateway connection.
///
/// When [gatewayBaseUrl] is empty or unparseable the connection falls back
/// to sample data so the app remains usable without a live gateway. A
/// configured base URL triggers real HTTP calls that add the token header
/// when [token] is non-empty.
final class GatewayClusterConnection implements ClusterConnection {
  GatewayClusterConnection({
    required this.gatewayBaseUrl,
    this.token = '',
    GatewayHttpClient? httpClient,
  }) : _httpClient = httpClient ?? const _DartIoGatewayHttpClient();

  static const _tokenHeader = 'X-ClusterOrbit-Token';

  final String gatewayBaseUrl;
  final String token;
  final GatewayHttpClient _httpClient;

  @override
  ConnectionMode get mode => ConnectionMode.gateway;

  @override
  Future<List<ClusterProfile>> listClusters() async {
    final base = _parseBase();
    if (base == null) return SampleClusterData.profilesFor(mode);

    final body = await _httpClient.getJson(
      base.resolve('v1/clusters'),
      headers: _headers(),
    );
    final list = body as List<dynamic>;
    return list
        .map((p) => ClusterProfile.fromJson(p as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<ClusterSnapshot> loadSnapshot(String clusterId) async {
    final base = _parseBase();
    if (base == null) {
      final profile = await _resolveSampleCluster(clusterId);
      return SampleClusterData.snapshotFor(profile);
    }
    final body = await _httpClient.getJson(
      base.resolve('v1/clusters/$clusterId/snapshot'),
      headers: _headers(),
    );
    return ClusterSnapshot.fromJson(body as Map<String, dynamic>);
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
    final base = _parseBase();
    if (base == null) {
      return SampleClusterData.eventsFor(kind: kind, objectName: objectName)
          .take(limit)
          .toList();
    }
    final query = <String, String>{
      'kind': kind.name,
      'objectName': objectName,
      'limit': '$limit',
      if (namespace != null && namespace.isNotEmpty) 'namespace': namespace,
    };
    final body = await _httpClient.getJson(
      base.resolve('v1/clusters/$clusterId/events').replace(
            queryParameters: query,
          ),
      headers: _headers(),
    );
    final list = body as List<dynamic>;
    return list
        .map((e) => ClusterEvent.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Uri? _parseBase() {
    if (gatewayBaseUrl.isEmpty) return null;
    final trimmed =
        gatewayBaseUrl.endsWith('/') ? gatewayBaseUrl : '$gatewayBaseUrl/';
    try {
      return Uri.parse(trimmed);
    } catch (_) {
      return null;
    }
  }

  Map<String, String> _headers() => {
        if (token.isNotEmpty) _tokenHeader: token,
      };

  Future<ClusterProfile> _resolveSampleCluster(String clusterId) async {
    final profiles = SampleClusterData.profilesFor(mode);
    return profiles.firstWhere(
      (profile) => profile.id == clusterId,
      orElse: () => profiles.first,
    );
  }
}

/// Abstraction over HTTP GETs so tests can inject deterministic responses
/// without standing up a real server.
abstract interface class GatewayHttpClient {
  Future<dynamic> getJson(Uri url, {Map<String, String> headers});
}

final class _DartIoGatewayHttpClient implements GatewayHttpClient {
  const _DartIoGatewayHttpClient();

  @override
  Future<dynamic> getJson(Uri url,
      {Map<String, String> headers = const {}}) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(url);
      headers.forEach(request.headers.set);
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw GatewayException(
          'Gateway request failed (${response.statusCode}) for $url',
        );
      }
      final body = await response.transform(utf8.decoder).join();
      return body.isEmpty ? null : jsonDecode(body);
    } finally {
      client.close(force: true);
    }
  }
}

class GatewayException implements Exception {
  GatewayException(this.message);
  final String message;

  @override
  String toString() => 'GatewayException: $message';
}
