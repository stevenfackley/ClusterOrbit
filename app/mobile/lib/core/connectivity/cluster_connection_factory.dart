import 'dart:convert';
import 'dart:io';

import 'package:flutter_dotenv/flutter_dotenv.dart';

import '../cluster_domain/cluster_models.dart';
import '../cluster_domain/saved_connection.dart';
import 'cluster_connection.dart';
import 'kubeconfig_repository.dart';
import 'kubernetes_event_loader.dart';
import 'kubernetes_snapshot_loader.dart';
import 'kubernetes_workload_scaler.dart';
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

  /// Build a [ClusterConnection] from a user-saved entry. Used by the app
  /// gate to wire the active connection for the shell.
  ///
  /// - `sample`: in-process fake data; no I/O.
  /// - `gateway`: HTTP-backed, sample-fallback when URL is empty/unparseable.
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
  })  : _repository = repository ?? KubeconfigRepository(),
        _snapshotLoader = snapshotLoader ?? KubernetesSnapshotLoader(),
        _eventLoader = eventLoader ?? KubernetesEventLoader(),
        _workloadScaler = workloadScaler ?? KubernetesWorkloadScaler();

  final KubeconfigRepository _repository;
  final KubernetesSnapshotLoader _snapshotLoader;
  final KubernetesEventLoader _eventLoader;
  final KubernetesWorkloadScaler _workloadScaler;

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

  @override
  Future<void> scaleWorkload({
    required String clusterId,
    required String workloadId,
    required int replicas,
  }) async {
    if (replicas < 0) {
      throw ArgumentError.value(
          replicas, 'replicas', 'must be a non-negative integer');
    }
    final base = _parseBase();
    if (base == null) {
      throw StateError(
        'Gateway base URL is not configured — scale is unsupported in sample-only mode.',
      );
    }
    // workloadId contains `/` so we can't use Uri.resolve after encoding.
    // Build the URI directly from path segments.
    final target = base.replace(
      pathSegments: [
        ...base.pathSegments.where((s) => s.isNotEmpty),
        'v1',
        'clusters',
        clusterId,
        'workloads',
        workloadId,
        'scale',
      ],
    );
    await _httpClient.postJson(
      target,
      headers: _headers(),
      body: {'replicas': replicas},
    );
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

/// Abstraction over HTTP GETs/POSTs so tests can inject deterministic
/// responses without standing up a real server.
abstract interface class GatewayHttpClient {
  Future<dynamic> getJson(Uri url, {Map<String, String> headers});

  Future<dynamic> postJson(
    Uri url, {
    Map<String, String> headers,
    required Map<String, dynamic> body,
  });
}

final class _DartIoGatewayHttpClient implements GatewayHttpClient {
  const _DartIoGatewayHttpClient();

  @override
  Future<dynamic> getJson(Uri url, {Map<String, String> headers = const {}}) =>
      _send(url, method: 'GET', headers: headers, body: null);

  @override
  Future<dynamic> postJson(
    Uri url, {
    Map<String, String> headers = const {},
    required Map<String, dynamic> body,
  }) =>
      _send(url, method: 'POST', headers: headers, body: body);

  Future<dynamic> _send(
    Uri url, {
    required String method,
    required Map<String, String> headers,
    required Map<String, dynamic>? body,
  }) async {
    final client = HttpClient();
    try {
      final request = await client.openUrl(method, url);
      headers.forEach(request.headers.set);
      if (body != null) {
        request.headers.set(
            HttpHeaders.contentTypeHeader, 'application/json; charset=utf-8');
        request.add(utf8.encode(jsonEncode(body)));
      }
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final errBody = await response.transform(utf8.decoder).join();
        throw GatewayException(
          'Gateway request failed (${response.statusCode}) for $url: $errBody',
        );
      }
      final responseBody = await response.transform(utf8.decoder).join();
      return responseBody.isEmpty ? null : jsonDecode(responseBody);
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
