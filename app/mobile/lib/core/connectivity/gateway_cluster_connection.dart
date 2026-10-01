import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../cluster_domain/cluster_models.dart';
import 'cluster_connection.dart';

/// HTTP-backed gateway connection.
///
/// Every call goes to [gatewayBaseUrl] and adds the token header when [token]
/// is non-empty. A missing or invalid base URL fails each call with a
/// [GatewayException] rather than serving sample data, so a misconfigured
/// gateway cannot pass for a working one. A mutation the gateway parks for
/// two-person approval throws [ApprovalPendingException].
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
  Set<ClusterOperation> get supportedOperations => const {
        ClusterOperation.scale,
        ClusterOperation.restart,
        ClusterOperation.cordon,
        ClusterOperation.drain,
      };

  @override
  Future<List<ClusterProfile>> listClusters() async {
    final body = await _httpClient.getJson(
      _endpoint(['v1', 'clusters']),
      headers: _headers(),
    );
    final list = body as List<dynamic>;
    return list
        .map((p) => ClusterProfile.fromJson(p as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<ClusterSnapshot> loadSnapshot(String clusterId) async {
    final body = await _httpClient.getJson(
      _endpoint(['v1', 'clusters', clusterId, 'snapshot']),
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
    final query = <String, String>{
      'kind': kind.name,
      'objectName': objectName,
      'limit': '$limit',
      if (namespace != null && namespace.isNotEmpty) 'namespace': namespace,
    };
    final body = await _httpClient.getJson(
      _endpoint(['v1', 'clusters', clusterId, 'events'], query: query),
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
    final target = _endpoint([
      'v1',
      'clusters',
      clusterId,
      'workloads',
      workloadId,
      'scale',
    ]);
    await _mutate(target, {'replicas': replicas});
  }

  @override
  Future<void> restartWorkload({
    required String clusterId,
    required String workloadId,
  }) async {
    final target = _endpoint([
      'v1',
      'clusters',
      clusterId,
      'workloads',
      workloadId,
      'restart',
    ]);
    await _mutate(target, const <String, dynamic>{});
  }

  @override
  Future<void> setNodeSchedulable({
    required String clusterId,
    required String nodeId,
    required bool schedulable,
  }) async {
    final target = _endpoint([
      'v1',
      'clusters',
      clusterId,
      'nodes',
      nodeId,
      schedulable ? 'uncordon' : 'cordon',
    ]);
    await _mutate(target, const <String, dynamic>{});
  }

  @override
  Future<DrainJob> startDrain({
    required String clusterId,
    required String nodeId,
  }) async {
    final target = _endpoint([
      'v1',
      'clusters',
      clusterId,
      'nodes',
      nodeId,
      'drain',
    ]);
    final body = await _mutate(target, const <String, dynamic>{});
    return DrainJob.fromJson(body as Map<String, dynamic>);
  }

  @override
  Future<DrainJob> drainStatus({
    required String clusterId,
    required String nodeId,
    required String jobId,
  }) async {
    final target = _endpoint([
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

  /// Builds a gateway URL from path segments: the base URL's own path is
  /// kept and every segment (cluster ids, workload ids with `/`) is
  /// percent-encoded rather than interpolated into a path string. Throws a
  /// [GatewayException] when the base URL is missing or invalid.
  Uri _endpoint(List<String> segments, {Map<String, String>? query}) {
    if (gatewayBaseUrl.trim().isEmpty) {
      throw GatewayException('Gateway URL is not configured.');
    }
    final base = Uri.tryParse(gatewayBaseUrl.trim());
    if (base == null || base.host.isEmpty) {
      throw GatewayException('Gateway URL "$gatewayBaseUrl" is not valid.');
    }
    return base.replace(
      pathSegments: [
        ...base.pathSegments.where((s) => s.isNotEmpty),
        ...segments,
      ],
      queryParameters: query,
    );
  }

  /// POSTs a mutation. A gated mutation comes back as 202 with a
  /// PendingRequest body; a started drain is also 202, but a DrainJob never
  /// carries `op`, so that key tells them apart.
  Future<dynamic> _mutate(Uri target, Map<String, dynamic> body) async {
    final response = await _httpClient.postJson(
      target,
      headers: _headers(),
      body: body,
    );
    final json = response.body;
    if (response.statusCode == HttpStatus.accepted &&
        json is Map<String, dynamic> &&
        json.containsKey('op')) {
      throw ApprovalPendingException(PendingApproval.fromJson(json));
    }
    return json;
  }

  Map<String, String> _headers() => {
        if (token.isNotEmpty) _tokenHeader: token,
      };
}

/// A 2xx gateway answer: the status (a mutation can be 200 or 202) and the
/// decoded JSON body, null when empty.
typedef GatewayResponse = ({int statusCode, dynamic body});

/// Abstraction over HTTP GETs/POSTs so tests can inject deterministic
/// responses without standing up a real server. Non-2xx answers throw
/// [GatewayException].
abstract interface class GatewayHttpClient {
  Future<dynamic> getJson(Uri url, {Map<String, String> headers});

  Future<GatewayResponse> postJson(
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
  Future<dynamic> getJson(Uri url,
          {Map<String, String> headers = const {}}) async =>
      (await _send(url, method: 'GET', headers: headers, body: null)).body;

  @override
  Future<GatewayResponse> postJson(
    Uri url, {
    Map<String, String> headers = const {},
    required Map<String, dynamic> body,
  }) =>
      _send(url, method: 'POST', headers: headers, body: body);

  Future<GatewayResponse> _send(
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
        throw GatewayException.fromResponse(
            response.statusCode, url, responseBody);
      }
      return (
        statusCode: response.statusCode,
        body: responseBody.isEmpty ? null : jsonDecode(responseBody),
      );
    } finally {
      client.close(force: true);
    }
  }
}

/// A failed gateway call: a non-2xx response ([statusCode] set) or a base
/// URL that cannot be used ([statusCode] null).
class GatewayException implements Exception {
  GatewayException(this.message, {this.statusCode, this.serverMessage});

  /// Wraps a non-2xx response; the gateway explains failures as
  /// `{"error": "..."}`, which becomes [serverMessage].
  factory GatewayException.fromResponse(int statusCode, Uri url, String body) =>
      GatewayException(
        'Gateway request failed ($statusCode) for $url: $body',
        statusCode: statusCode,
        serverMessage: _errorField(body),
      );

  /// Full diagnostic text, including the URL and raw body. For logs; show
  /// [userMessage] to people.
  final String message;
  final int? statusCode;
  final String? serverMessage;

  /// Short text for a snackbar or banner: no URL, no raw JSON.
  String get userMessage {
    final status = statusCode;
    if (status == null) return message;
    final reason = switch (status) {
      401 => 'Gateway rejected the access token',
      403 => 'Not allowed by the gateway',
      404 => 'Not found on the gateway',
      429 => 'Gateway rate limit reached',
      >= 500 => 'Gateway error ($status)',
      _ => 'Gateway request failed ($status)',
    };
    return serverMessage == null ? reason : '$reason: $serverMessage';
  }

  static String? _errorField(String body) {
    try {
      final decoded = jsonDecode(body);
      final error = decoded is Map ? decoded['error'] : null;
      return error is String && error.isNotEmpty ? error : null;
    } on FormatException {
      return null;
    }
  }

  @override
  String toString() => 'GatewayException: $message';
}
