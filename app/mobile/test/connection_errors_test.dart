import 'dart:async';
import 'dart:io';

import 'package:clusterorbit_mobile/core/connectivity/connection_errors.dart';
import 'package:clusterorbit_mobile/core/connectivity/gateway_cluster_connection.dart';
import 'package:clusterorbit_mobile/core/connectivity/kube_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final url = Uri.parse('https://api.example.test/v1/clusters');

  test('a gateway failure reads as its user message, without the URL', () {
    final message = readableError(
        GatewayException.fromResponse(401, url, '{"error": "token expired"}'));

    expect(message, 'Gateway rejected the access token: token expired');
  });

  test('a Kubernetes API failure reads as its user message', () {
    final message = readableError(KubernetesApiException.fromResponse(
        403, url, '{"kind": "Status", "message": "nodes is forbidden"}'));

    expect(message, 'Forbidden by the cluster: nodes is forbidden');
  });

  test('a timeout reads as a sentence, without the raw duration', () {
    final message = readableError(
        TimeoutException('Future not completed', const Duration(seconds: 30)));

    expect(message, 'The server did not respond in time');
  });

  test('a network failure reads as unreachable, without the socket detail', () {
    final message = readableError(const SocketException('Connection refused',
        osError: OSError('Connection refused', 111), port: 443));

    expect(message, 'Could not reach the server');
  });

  test('a TLS failure reads as a failed handshake', () {
    final message = readableError(const HandshakeException(
        'CERTIFICATE_VERIFY_FAILED: unable to get local issuer certificate'));

    expect(message, 'TLS handshake with the server failed');
  });

  test('any other error keeps its own text', () {
    expect(
        readableError(StateError('no kubeconfig')), 'Bad state: no kubeconfig');
  });
}
