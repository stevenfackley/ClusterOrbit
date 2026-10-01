import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../cluster_domain/cluster_models.dart';
import 'cluster_connection.dart';
import 'sample_cluster_data.dart';

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
  }) : _httpClient = httpClient ?? const DartIoGatewayHttpClient();

  static const _tokenHeader = 'X-ClusterOrbit-Token';

  final String gatewayBaseUrl;
  final String token;
  final GatewayHttpClient _httpClient;

  @override
  ConnectionMode get mode => ConnectionMode.gateway;

  @override
  Future<List<ClusterProfile>> listClusters() async {
    if (_parseBase() == null) return SampleClusterData.profilesFor(mode);

    final body = await _httpClient.getJson(
      _endpoint('list', ['v1', 'clusters']),
      headers: _headers(),
    );
    final list = body as List<dynamic>;
    return list
        .map((p) => ClusterProfile.fromJson(p as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<ClusterSnapshot> loadSnapshot(String clusterId) async {
    if (_parseBase() == null) {
      final profile = await _resolveSampleCluster(clusterId);
      return SampleClusterData.snapshotFor(profile);
    }
    final body = await _httpClient.getJson(
      _endpoint('snapshot', ['v1', 'clusters', clusterId, 'snapshot']),
      headers: _headers(),
    );
    return ClusterSnapshot.fromJson(body as Map<String, dynamic>);
  }

  @override
  Future<List<ClusterEvent>> loadEvents({
    required String clusterId,
    required TopologyEntityKind kind,
    required String objectName,
    String? namespace,
    int limit = 5,
  }) async {
    if (_parseBase() == null) {
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
      _endpoint('events', ['v1', 'clusters', clusterId, 'events'],
          query: query),
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
    final target = _endpoint('scale', [
      'v1',
      'clusters',
      clusterId,
      'workloads',
      workloadId,
      'scale',
    ]);
    await _httpClient.postJson(
      target,
      headers: _headers(),
      body: {'replicas': replicas},
    );
  }

  @override
  Future<void> restartWorkload({
    required String clusterId,
    required String workloadId,
  }) async {
    final target = _endpoint('restart', [
      'v1',
      'clusters',
      clusterId,
      'workloads',
      workloadId,
      'restart',
    ]);
    await _httpClient.postJson(
      target,
      headers: _headers(),
      body: const <String, dynamic>{},
    );
  }

  @override
  Future<void> setNodeSchedulable({
    required String clusterId,
    required String nodeId,
    required bool schedulable,
  }) async {
    final target = _endpoint('cordon', [
      'v1',
      'clusters',
      clusterId,
      'nodes',
      nodeId,
      schedulable ? 'uncordon' : 'cordon',
    ]);
    await _httpClient.postJson(
      target,
      headers: _headers(),
      body: const <String, dynamic>{},
    );
  }

  @override
  Future<DrainJob> startDrain({
    required String clusterId,
    required String nodeId,
  }) async {
    final target = _endpoint('drain', [
      'v1',
      'clusters',
      clusterId,
      'nodes',
      nodeId,
      'drain',
    ]);
    final body = await _httpClient.postJson(
      target,
      headers: _headers(),
      body: const <String, dynamic>{},
    );
    return DrainJob.fromJson(body as Map<String, dynamic>);
  }

  @override
  Future<DrainJob> drainStatus({
    required String clusterId,
    required String nodeId,
    required String jobId,
  }) async {
    final target = _endpoint('drain', [
      'v1',
      'clusters',
      clusterId,
      'nodes',
      nodeId,
      'drain',
      jobId,
    ]);
    final body = await _httpClient.getJson(target, headers: _headers());
    return DrainJob.fromJson(body as Map<String, dynamic>);
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

  /// Builds a gateway URL from path segments: the base URL's own path is
  /// kept and every segment (cluster ids, workload ids with `/`) is
  /// percent-encoded rather than interpolated into a path string.
  Uri _endpoint(
    String op,
    List<String> segments, {
    Map<String, String>? query,
  }) {
    final base = _parseBase();
    if (base == null) {
      throw StateError(
        'Gateway base URL is not configured — $op is unsupported in sample-only mode.',
      );
    }
    return base.replace(
      pathSegments: [
        ...base.pathSegments.where((s) => s.isNotEmpty),
        ...segments,
      ],
      queryParameters: query,
    );
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

/// dart:io [GatewayHttpClient]. Every call is bounded: [connectionTimeout]
/// caps the connect and [responseTimeout] caps waiting for the response
/// headers and, separately, reading the body, so a hung gateway surfaces as a
/// [TimeoutException] instead of freezing refresh.
final class DartIoGatewayHttpClient implements GatewayHttpClient {
  const DartIoGatewayHttpClient({
    this.connectionTimeout = const Duration(seconds: 10),
    this.responseTimeout = const Duration(seconds: 30),
  });

  final Duration connectionTimeout;
  final Duration responseTimeout;

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
    final client = HttpClient()..connectionTimeout = connectionTimeout;
    try {
      final request = await client.openUrl(method, url);
      headers.forEach(request.headers.set);
      if (body != null) {
        request.headers.set(
            HttpHeaders.contentTypeHeader, 'application/json; charset=utf-8');
        request.add(utf8.encode(jsonEncode(body)));
      }
      final response = await request.close().timeout(responseTimeout);
      final responseBody = await response
          .transform(utf8.decoder)
          .join()
          .timeout(responseTimeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw GatewayException(
          'Gateway request failed (${response.statusCode}) for $url: $responseBody',
        );
      }
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
