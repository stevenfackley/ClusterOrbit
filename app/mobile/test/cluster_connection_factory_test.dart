import 'dart:io';

import 'package:clusterorbit_mobile/core/cluster_domain/cluster_models.dart';
import 'package:clusterorbit_mobile/core/connectivity/cluster_connection_factory.dart';
import 'package:clusterorbit_mobile/core/connectivity/kubeconfig_repository.dart';
import 'package:clusterorbit_mobile/core/connectivity/kubernetes_snapshot_loader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('defaults to direct connection when environment is empty', () {
    final connection = ClusterConnectionFactory.fromEnvironment(const {});

    expect(connection, isA<DirectClusterConnection>());
  });

  test('direct connection reads cluster metadata from kubeconfig', () async {
    final tempDir = await Directory.systemTemp.createTemp('clusterorbit_test');
    addTearDown(() async => tempDir.delete(recursive: true));

    final kubeconfig = File('${tempDir.path}${Platform.pathSeparator}config');
    await kubeconfig.writeAsString('''
apiVersion: v1
clusters:
  - cluster:
      server: https://prod.example.internal:6443
    name: prod-cluster
  - cluster:
      server: https://dev.example.internal:6443
    name: dev-cluster
contexts:
  - context:
      cluster: dev-cluster
      namespace: default
      user: dev-user
    name: dev
  - context:
      cluster: prod-cluster
      namespace: kube-system
      user: prod-user
    name: prod-admin
users:
  - name: prod-user
    user:
      token: abc123
current-context: prod-admin
''');

    final connection = ClusterConnectionFactory.fromEnvironment({
      'CLUSTERORBIT_CONNECTION_MODE': 'direct',
      'CLUSTERORBIT_KUBECONFIG': kubeconfig.path,
    });

    expect(connection, isA<DirectClusterConnection>());

    final clusters = await connection.listClusters();

    expect(clusters, hasLength(2));
    expect(clusters.first.id, 'prod-admin');
    expect(clusters.first.name, 'prod-cluster');
    expect(clusters.first.apiServerHost, 'prod.example.internal');
    expect(clusters.first.environmentLabel, 'Production');
  });

  test('direct connection uses live snapshot loader when kubeconfig resolves',
      () async {
    final tempDir = await Directory.systemTemp.createTemp('clusterorbit_test');
    addTearDown(() async => tempDir.delete(recursive: true));

    final kubeconfig = File('${tempDir.path}${Platform.pathSeparator}config');
    await kubeconfig.writeAsString('''
apiVersion: v1
clusters:
  - cluster:
      server: https://prod.example.internal:6443
    name: prod-cluster
contexts:
  - context:
      cluster: prod-cluster
      user: prod-user
    name: prod-admin
users:
  - name: prod-user
    user:
      token: abc123
current-context: prod-admin
''');

    final connection = DirectClusterConnection(
      repository: KubeconfigRepository(environment: {
        'CLUSTERORBIT_KUBECONFIG': kubeconfig.path,
      }),
      snapshotLoader: KubernetesSnapshotLoader(
        transport: _FakeKubernetesTransport({
          'https://prod.example.internal:6443/api/v1/nodes': _listResponse([
            {
              'metadata': {
                'name': 'cp-1',
                'labels': {'node-role.kubernetes.io/control-plane': ''},
              },
              'spec': {'unschedulable': false},
              'status': {
                'nodeInfo': {'kubeletVersion': 'v1.32.3'},
                'conditions': [
                  {'type': 'Ready', 'status': 'True'},
                ],
              },
            },
          ]),
          'https://prod.example.internal:6443/api/v1/pods': _listResponse([]),
          'https://prod.example.internal:6443/api/v1/services':
              _listResponse([]),
          'https://prod.example.internal:6443/apis/apps/v1/deployments':
              _listResponse([]),
          'https://prod.example.internal:6443/apis/apps/v1/daemonsets':
              _listResponse([]),
          'https://prod.example.internal:6443/apis/apps/v1/statefulsets':
              _listResponse([]),
          'https://prod.example.internal:6443/apis/batch/v1/jobs':
              _listResponse([]),
          'https://prod.example.internal:6443/apis/apps/v1/replicasets':
              _listResponse([]),
        }),
      ),
    );

    final snapshot = await connection.loadSnapshot('prod-admin');

    expect(snapshot.profile.id, 'prod-admin');
    expect(snapshot.profile.name, 'prod-cluster');
    expect(snapshot.profile.apiServerHost, 'prod.example.internal');
    expect(snapshot.nodes, hasLength(1));
    expect(snapshot.nodes.first.role, ClusterNodeRole.controlPlane);
  });

  test('builds gateway connection from environment', () async {
    final connection = ClusterConnectionFactory.fromEnvironment(const {
      'CLUSTERORBIT_CONNECTION_MODE': 'gateway',
      'CLUSTERORBIT_GATEWAY_URL': 'https://gateway.example.internal',
    });

    expect(connection, isA<GatewayClusterConnection>());

    final clusters = await connection.listClusters();
    final snapshot = await connection.loadSnapshot(clusters.first.id);

    expect(snapshot.profile.connectionMode, ConnectionMode.gateway);
    expect(snapshot.profile.apiServerHost, 'https://gateway.example.internal');
    expect(snapshot.controlPlaneCount, 3);
    expect(snapshot.workerCount, 39);
    expect(snapshot.alerts.length, 5);
  });
}

Map<String, dynamic> _listResponse(List<Map<String, dynamic>> items) => {
      'kind': 'List',
      'items': items,
    };

final class _FakeKubernetesTransport implements KubernetesTransport {
  _FakeKubernetesTransport(this._responses);

  final Map<String, Map<String, dynamic>> _responses;

  @override
  Future<Map<String, dynamic>> getJson(KubernetesRequest request) async {
    final response = _responses[request.uri.toString()];
    if (response == null) {
      throw StateError('Missing fake response for ${request.uri}');
    }
    return response;
  }
}
