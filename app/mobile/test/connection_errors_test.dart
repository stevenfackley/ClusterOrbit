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

  test('any other error keeps its own text', () {
    expect(
        readableError(StateError('no kubeconfig')), 'Bad state: no kubeconfig');
  });
}
