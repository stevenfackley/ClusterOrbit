import 'dart:convert';
import 'dart:io';

import 'package:clusterorbit_mobile/core/cluster_domain/cluster_models.dart';
import 'package:clusterorbit_mobile/core/connectivity/cluster_connection.dart';
import 'package:clusterorbit_mobile/core/connectivity/cluster_connection_factory.dart';
import 'package:clusterorbit_mobile/core/connectivity/kubeconfig_repository.dart';
import 'package:clusterorbit_mobile/core/connectivity/kubernetes_snapshot_loader.dart';
import 'package:clusterorbit_mobile/core/connectivity/kubernetes_workload_scaler.dart';
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

  test('gateway connection falls back to sample data when url is empty',
      () async {
    final connection = ClusterConnectionFactory.fromEnvironment(const {
      'CLUSTERORBIT_CONNECTION_MODE': 'gateway',
    });

    expect(connection, isA<GatewayClusterConnection>());

    final clusters = await connection.listClusters();
    final snapshot = await connection.loadSnapshot(clusters.first.id);

    expect(snapshot.profile.connectionMode, ConnectionMode.gateway);
    expect(snapshot.nodes, isNotEmpty);
  });

  test('gateway connection fetches clusters over HTTP with token header',
      () async {
    final fake = _FakeGatewayHttpClient({
      'https://gateway.example.internal/v1/clusters': [
        {
          'id': 'remote-alpha',
          'name': 'Alpha',
          'apiServerHost': 'https://gateway.example.internal',
          'environmentLabel': 'Production',
          'connectionMode': 'gateway',
        },
      ],
    });

    final connection = GatewayClusterConnection(
      gatewayBaseUrl: 'https://gateway.example.internal',
      token: 's3cret',
      httpClient: fake,
    );

    final clusters = await connection.listClusters();

    expect(clusters, hasLength(1));
    expect(clusters.first.id, 'remote-alpha');
    expect(fake.lastHeaders['X-ClusterOrbit-Token'], 's3cret');
  });

  test('gateway connection decodes snapshot and events responses', () async {
    final profileJson = {
      'id': 'remote-alpha',
      'name': 'Alpha',
      'apiServerHost': 'https://gateway.example.internal',
      'environmentLabel': 'Production',
      'connectionMode': 'gateway',
    };
    final nodeJson = {
      'id': 'node-1',
      'name': 'worker-1',
      'role': 'worker',
      'version': 'v1.30.0',
      'zone': 'us-east-1a',
      'podCount': 12,
      'schedulable': true,
      'health': 'healthy',
      'cpuCapacity': '8 cores',
      'memoryCapacity': '32 GiB',
      'osImage': 'Ubuntu 22.04',
    };
    final snapshotJson = {
      'profile': profileJson,
      'generatedAt': 1700000000000,
      'nodes': [nodeJson],
      'workloads': <Map<String, dynamic>>[],
      'services': <Map<String, dynamic>>[],
      'alerts': <Map<String, dynamic>>[],
      'links': <Map<String, dynamic>>[],
    };
    final eventJson = {
      'type': 'normal',
      'reason': 'Synced',
      'message': 'Reconciliation complete for worker-1',
      'lastTimestamp': 1700000000000,
      'count': 1,
      'sourceComponent': null,
    };
    final fake = _FakeGatewayHttpClient({
      'https://gateway.example.internal/v1/clusters/remote-alpha/snapshot':
          snapshotJson,
      'https://gateway.example.internal/v1/clusters/remote-alpha/events?kind=node&objectName=worker-1&limit=5':
          [eventJson],
    });

    final connection = GatewayClusterConnection(
      gatewayBaseUrl: 'https://gateway.example.internal/',
      token: '',
      httpClient: fake,
    );

    final snapshot = await connection.loadSnapshot('remote-alpha');
    expect(snapshot.profile.id, 'remote-alpha');
    expect(snapshot.nodes.single.name, 'worker-1');
    expect(fake.lastHeaders.containsKey('X-ClusterOrbit-Token'), isFalse);

    final events = await connection.loadEvents(
      clusterId: 'remote-alpha',
      kind: TopologyEntityKind.node,
      objectName: 'worker-1',
    );
    expect(events, hasLength(1));
    expect(events.single.reason, 'Synced');
  });

  test('gateway scaleWorkload POSTs to correct URL with replicas body',
      () async {
    final fake = _FakeGatewayHttpClient(const {});
    final connection = GatewayClusterConnection(
      gatewayBaseUrl: 'https://gateway.example.internal/',
      token: 's3cret',
      httpClient: fake,
    );

    await connection.scaleWorkload(
      clusterId: 'remote-alpha',
      workloadId: 'deployment:platform/api',
      replicas: 4,
    );

    expect(
      fake.lastPostUrl.toString(),
      'https://gateway.example.internal/v1/clusters/remote-alpha/workloads/deployment:platform%2Fapi/scale',
    );
    expect(fake.lastPostBody, {'replicas': 4});
    expect(fake.lastHeaders['X-ClusterOrbit-Token'], 's3cret');
  });

  test('gateway scaleWorkload rejects negative replicas locally', () async {
    final connection = GatewayClusterConnection(
      gatewayBaseUrl: 'https://gateway.example.internal/',
      httpClient: _FakeGatewayHttpClient(const {}),
    );

    expect(
      () => connection.scaleWorkload(
        clusterId: 'x',
        workloadId: 'deployment:ns/name',
        replicas: -1,
      ),
      throwsA(isA<ArgumentError>()),
    );
  });

  test(
      'direct scaleWorkload PATCHes apps/v1 scale subresource with merge-patch body',
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
    final transport = _RecordingTransport();
    final connection = DirectClusterConnection(
      repository: KubeconfigRepository(environment: {
        'CLUSTERORBIT_KUBECONFIG': kubeconfig.path,
      }),
      workloadScaler: KubernetesWorkloadScaler(transport: transport),
    );

    await connection.scaleWorkload(
      clusterId: 'prod-admin',
      workloadId: 'deployment:platform/api',
      replicas: 5,
    );

    expect(transport.lastUri.toString(),
        'https://prod.example.internal:6443/apis/apps/v1/namespaces/platform/deployments/api/scale');
    expect(transport.lastContentType, 'application/merge-patch+json');
    expect(jsonDecode(utf8.decode(transport.lastBody!)), {
      'spec': {'replicas': 5}
    });
  });

  test('direct scaleWorkload rejects unsupported kind', () async {
    final scaler = KubernetesWorkloadScaler(transport: _RecordingTransport());
    expect(
      () => scaler.scaleWorkload(
        cluster: const KubeconfigResolvedCluster(
          profile: ClusterProfile(
            id: 'x',
            name: 'x',
            apiServerHost: 'x',
            environmentLabel: 'x',
            connectionMode: ConnectionMode.direct,
          ),
          server: 'https://x',
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
        ),
        workloadId: 'daemonSet:kube-system/fluentd',
        replicas: 3,
      ),
      throwsA(isA<UnsupportedWorkloadKindException>()),
    );
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

  @override
  Future<Map<String, dynamic>> patchJson(
    KubernetesRequest request, {
    required String contentType,
    required List<int> body,
  }) async {
    throw UnimplementedError();
  }
}

final class _RecordingTransport implements KubernetesTransport {
  Uri? lastUri;
  String? lastContentType;
  List<int>? lastBody;

  @override
  Future<Map<String, dynamic>> getJson(KubernetesRequest request) async =>
      const {};

  @override
  Future<Map<String, dynamic>> patchJson(
    KubernetesRequest request, {
    required String contentType,
    required List<int> body,
  }) async {
    lastUri = request.uri;
    lastContentType = contentType;
    lastBody = body;
    return const {};
  }
}

final class _FakeGatewayHttpClient implements GatewayHttpClient {
  _FakeGatewayHttpClient(this._responses);

  final Map<String, dynamic> _responses;
  Map<String, String> lastHeaders = const {};
  Uri? lastPostUrl;
  Map<String, dynamic>? lastPostBody;

  @override
  Future<dynamic> getJson(Uri url,
      {Map<String, String> headers = const {}}) async {
    lastHeaders = Map.of(headers);
    final key = url.toString();
    if (!_responses.containsKey(key)) {
      throw StateError('Missing fake response for $key');
    }
    return _responses[key];
  }

  @override
  Future<dynamic> postJson(
    Uri url, {
    Map<String, String> headers = const {},
    required Map<String, dynamic> body,
  }) async {
    lastHeaders = Map.of(headers);
    lastPostUrl = url;
    lastPostBody = Map.of(body);
    return _responses[url.toString()];
  }
}
