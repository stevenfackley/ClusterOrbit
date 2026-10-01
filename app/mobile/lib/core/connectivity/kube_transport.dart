import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'kubeconfig_repository.dart';

/// Builds a Kubernetes API URL by appending [segments] to [server]'s own
/// path, so a path-routed API server (Rancher's `/k8s/clusters/<id>`, an
/// auth proxy) keeps its prefix. Each segment is percent-encoded.
Uri kubeApiUri(
  String server,
  List<String> segments, {
  Map<String, String>? queryParameters,
}) {
  final base = Uri.parse(server);
  return base.replace(
    pathSegments: [
      ...base.pathSegments.where((s) => s.isNotEmpty),
      ...segments,
    ],
    queryParameters: queryParameters,
  );
}

final class KubernetesRequest {
  const KubernetesRequest({
    required this.uri,
    required this.auth,
    required this.tls,
  });

  final Uri uri;
  final KubeconfigAuth auth;
  final KubeconfigTlsConfig tls;
}

abstract interface class KubernetesTransport {
  Future<Map<String, dynamic>> getJson(KubernetesRequest request);

  /// Send a JSON-body PATCH. [contentType] is typically
  /// `application/merge-patch+json` for K8s merge patches.
  Future<Map<String, dynamic>> patchJson(
    KubernetesRequest request, {
    required String contentType,
    required List<int> body,
  });
}

/// dart:io [KubernetesTransport]. Every call is bounded: [connectionTimeout]
/// caps the connect and [responseTimeout] caps waiting for the response
/// headers and, separately, reading the body, so a hung API server surfaces
/// as a [TimeoutException] instead of freezing the caller.
final class HttpKubernetesTransport implements KubernetesTransport {
  const HttpKubernetesTransport({
    this.connectionTimeout = const Duration(seconds: 10),
    this.responseTimeout = const Duration(seconds: 30),
  });

  final Duration connectionTimeout;
  final Duration responseTimeout;

  @override
  Future<Map<String, dynamic>> getJson(KubernetesRequest request) =>
      _send(request, method: 'GET', contentType: null, body: null);

  @override
  Future<Map<String, dynamic>> patchJson(
    KubernetesRequest request, {
    required String contentType,
    required List<int> body,
  }) =>
      _send(request, method: 'PATCH', contentType: contentType, body: body);

  Future<Map<String, dynamic>> _send(
    KubernetesRequest request, {
    required String method,
    required String? contentType,
    required List<int>? body,
  }) async {
    final client = HttpClient(
      context: kubeSecurityContext(request.tls, request.auth),
    )..connectionTimeout = connectionTimeout;
    if (request.tls.insecureSkipTlsVerify) {
      client.badCertificateCallback = (_, __, ___) => true;
    }

    try {
      final httpRequest = await client.openUrl(method, request.uri);
      httpRequest.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (contentType != null) {
        httpRequest.headers.set(HttpHeaders.contentTypeHeader, contentType);
      }
      if (request.auth.bearerToken != null &&
          request.auth.bearerToken!.isNotEmpty) {
        httpRequest.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer ${request.auth.bearerToken}',
        );
      } else if (request.auth.basicUsername != null &&
          request.auth.basicPassword != null) {
        final token = base64Encode(
          utf8.encode(
              '${request.auth.basicUsername}:${request.auth.basicPassword}'),
        );
        httpRequest.headers.set(
          HttpHeaders.authorizationHeader,
          'Basic $token',
        );
      }
      if (body != null) {
        httpRequest.add(body);
      }

      final response = await httpRequest.close().timeout(responseTimeout);
      final responseBody = await response
          .transform(utf8.decoder)
          .join()
          .timeout(responseTimeout);
      if (response.statusCode >= 400) {
        throw KubernetesApiException.fromResponse(
            response.statusCode, request.uri, responseBody);
      }

      if (responseBody.isEmpty) {
        return const {};
      }
      final decoded = jsonDecode(responseBody);
      if (decoded is! Map) {
        throw const FormatException(
            'Kubernetes API response was not an object');
      }

      return decoded.map((key, value) => MapEntry('$key', value));
    } finally {
      client.close(force: true);
    }
  }
}

/// A non-2xx answer from the Kubernetes API. Still an [HttpException]
/// ([message] keeps the raw body for logs); [serverMessage] is the
/// `Status.message` the API server explains failures with.
class KubernetesApiException extends HttpException {
  const KubernetesApiException(
    super.message, {
    super.uri,
    required this.statusCode,
    this.serverMessage,
  });

  factory KubernetesApiException.fromResponse(
    int statusCode,
    Uri uri,
    String body,
  ) =>
      KubernetesApiException(
        'Kubernetes API request failed with status $statusCode: $body',
        uri: uri,
        statusCode: statusCode,
        serverMessage: _statusMessage(body),
      );

  final int statusCode;
  final String? serverMessage;

  /// Short text for a snackbar or banner: no URL, no raw JSON.
  String get userMessage {
    final reason = switch (statusCode) {
      401 => 'Kubernetes API rejected the credentials',
      403 => 'Forbidden by the cluster',
      404 => 'Not found on the cluster',
      409 => 'Conflicting change on the cluster; refresh and retry',
      >= 500 => 'Kubernetes API error ($statusCode)',
      _ => 'Kubernetes API request failed ($statusCode)',
    };
    return serverMessage == null ? reason : '$reason: $serverMessage';
  }

  static String? _statusMessage(String body) {
    try {
      final decoded = jsonDecode(body);
      final message = decoded is Map ? decoded['message'] : null;
      return message is String && message.isNotEmpty ? message : null;
    } on FormatException {
      return null;
    }
  }
}

/// TLS context for a kubeconfig cluster, or null when the platform default
/// suffices. An explicit `certificate-authority-data` replaces the system
/// trust store; a client certificate alone keeps it, so an API server with a
/// publicly-trusted certificate still verifies. [create] is a test seam.
SecurityContext? kubeSecurityContext(
  KubeconfigTlsConfig tls,
  KubeconfigAuth auth, {
  SecurityContext Function({bool withTrustedRoots}) create =
      SecurityContext.new,
}) {
  final hasCustomContext = tls.certificateAuthorityData != null ||
      (auth.clientCertificateData != null && auth.clientKeyData != null);
  if (!hasCustomContext) {
    return null;
  }

  final context =
      create(withTrustedRoots: tls.certificateAuthorityData == null);
  if (tls.certificateAuthorityData != null) {
    context.setTrustedCertificatesBytes(tls.certificateAuthorityData!);
  }
  if (auth.clientCertificateData != null && auth.clientKeyData != null) {
    context.useCertificateChainBytes(auth.clientCertificateData!);
    context.usePrivateKeyBytes(auth.clientKeyData!);
  }
  return context;
}
