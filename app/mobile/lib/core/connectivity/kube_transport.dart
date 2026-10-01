import 'dart:convert';
import 'dart:io';

import 'kubeconfig_repository.dart';

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

final class HttpKubernetesTransport implements KubernetesTransport {
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
      context: _buildSecurityContext(request.tls, request.auth),
    );
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

      final response = await httpRequest.close();
      final responseBody = await response.transform(utf8.decoder).join();
      if (response.statusCode >= 400) {
        throw HttpException(
          'Kubernetes API request failed with status ${response.statusCode}: $responseBody',
          uri: request.uri,
        );
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

  SecurityContext? _buildSecurityContext(
    KubeconfigTlsConfig tls,
    KubeconfigAuth auth,
  ) {
    final hasCustomContext = tls.certificateAuthorityData != null ||
        (auth.clientCertificateData != null && auth.clientKeyData != null);
    if (!hasCustomContext) {
      return null;
    }

    final context = SecurityContext();
    if (tls.certificateAuthorityData != null) {
      context.setTrustedCertificatesBytes(tls.certificateAuthorityData!);
    }
    if (auth.clientCertificateData != null && auth.clientKeyData != null) {
      context.useCertificateChainBytes(auth.clientCertificateData!);
      context.usePrivateKeyBytes(auth.clientKeyData!);
    }
    return context;
  }
}
