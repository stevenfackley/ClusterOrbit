import 'package:clusterorbit_mobile/core/cluster_domain/cluster_models.dart';
import 'package:clusterorbit_mobile/core/connectivity/cluster_connection.dart';
import 'package:clusterorbit_mobile/core/connectivity/kube_transport.dart';
import 'package:clusterorbit_mobile/core/connectivity/kubeconfig_repository.dart';
import 'package:clusterorbit_mobile/core/connectivity/kubernetes_workload_scaler.dart';
import 'package:flutter_test/flutter_test.dart';

/// Which workload kinds Direct mode scales and restarts, and the apps/v1
/// collection each one patches. The detail panel offers the same kinds.
void main() {
  const base = 'https://cluster.example.internal:6443/apis/apps/v1/namespaces';

  // (kind in the id, scale collection or null, restart collection or null)
  for (final (kind, scales, restarts) in [
    ('deployment', 'deployments', 'deployments'),
    ('statefulSet', 'statefulsets', 'statefulsets'),
    ('daemonSet', null, 'daemonsets'),
    ('job', null, null),
    ('cronJob', null, null),
  ]) {
    test(
        '$kind: scale ${scales ?? 'refused'}, restart ${restarts ?? 'refused'}',
        () async {
      final transport = _RecordingTransport();
      final scaler = KubernetesWorkloadScaler(transport: transport);
      final id = '$kind:platform/api';

      final scale =
          scaler.scaleWorkload(cluster: _cluster, workloadId: id, replicas: 2);
      if (scales == null) {
        await expectLater(scale, _unsupported(kind));
      } else {
        await scale;
        expect(
            transport.uris.last.toString(), '$base/platform/$scales/api/scale');
      }

      final restart = scaler.restartWorkload(cluster: _cluster, workloadId: id);
      if (restarts == null) {
        await expectLater(restart, _unsupported(kind));
      } else {
        await restart;
        expect(transport.uris.last.toString(), '$base/platform/$restarts/api');
      }

      expect(transport.uris,
          hasLength([scales, restarts].whereType<String>().length));
    });
  }

  test('a slash in the name stays in the name', () async {
    final transport = _RecordingTransport();
    await KubernetesWorkloadScaler(transport: transport).restartWorkload(
        cluster: _cluster, workloadId: 'deployment:platform/api/v2');
    expect(transport.uris.single.toString(),
        '$base/platform/deployments/api%2Fv2');
  });

  for (final id in [
    'deployment',
    ':platform/api',
    'deployment:',
    'deployment:platform',
    'deployment:/api',
    'deployment:platform/',
  ]) {
    test('a malformed id "$id" is an ArgumentError before any request',
        () async {
      final transport = _RecordingTransport();
      final scaler = KubernetesWorkloadScaler(transport: transport);

      await expectLater(
        scaler.scaleWorkload(cluster: _cluster, workloadId: id, replicas: 1),
        throwsArgumentError,
      );
      await expectLater(
        scaler.restartWorkload(cluster: _cluster, workloadId: id),
        throwsArgumentError,
      );
      expect(transport.uris, isEmpty);
    });
  }
}

Matcher _unsupported(String kind) => throwsA(
      isA<UnsupportedWorkloadKindException>()
          .having((e) => e.kind, 'kind', kind),
    );

const _cluster = KubeconfigResolvedCluster(
  profile: ClusterProfile(
    id: 'c',
    name: 'c',
    apiServerHost: 'cluster.example.internal',
    environmentLabel: 'Dev',
    connectionMode: ConnectionMode.direct,
  ),
  server: 'https://cluster.example.internal:6443',
  namespace: null,
  auth: KubeconfigAuth(
    bearerToken: null,
    basicUsername: null,
    basicPassword: null,
    clientCertificateData: null,
    clientKeyData: null,
  ),
  tls: KubeconfigTlsConfig(
    insecureSkipTlsVerify: false,
    certificateAuthorityData: null,
  ),
);

final class _RecordingTransport implements KubernetesTransport {
  final List<Uri> uris = [];

  @override
  Future<Map<String, dynamic>> getJson(KubernetesRequest request) async {
    throw UnimplementedError();
  }

  @override
  Future<Map<String, dynamic>> patchJson(
    KubernetesRequest request, {
    required String contentType,
    required List<int> body,
  }) async {
    uris.add(request.uri);
    return const {};
  }
}
