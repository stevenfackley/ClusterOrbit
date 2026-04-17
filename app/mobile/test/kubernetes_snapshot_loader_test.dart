import 'package:clusterorbit_mobile/core/cluster_domain/cluster_models.dart';
import 'package:clusterorbit_mobile/core/connectivity/kubeconfig_repository.dart';
import 'package:clusterorbit_mobile/core/connectivity/kubernetes_snapshot_loader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('snapshot loader maps nodes workloads services and alerts', () async {
    final loader = KubernetesSnapshotLoader(
      transport: _FakeKubernetesTransport({
        'https://cluster.example.internal:6443/api/v1/nodes': _listResponse([
          {
            'metadata': {
              'name': 'cp-1',
              'labels': {
                'node-role.kubernetes.io/control-plane': '',
                'topology.kubernetes.io/zone': 'use1-a',
              },
            },
            'spec': {'unschedulable': false},
            'status': {
              'nodeInfo': {
                'kubeletVersion': 'v1.32.3',
                'osImage': 'Ubuntu 22.04.3 LTS',
              },
              'capacity': {
                'cpu': '4',
                'memory': '16Gi',
              },
              'conditions': [
                {'type': 'Ready', 'status': 'True'},
              ],
            },
          },
          {
            'metadata': {
              'name': 'worker-1',
              'labels': {
                'topology.kubernetes.io/zone': 'use1-b',
              },
            },
            'spec': {'unschedulable': true},
            'status': {
              'nodeInfo': {
                'kubeletVersion': 'v1.32.3',
                'osImage': 'Ubuntu 22.04.3 LTS',
              },
              'capacity': {
                'cpu': '8',
                'memory': '32Gi',
              },
              'conditions': [
                {'type': 'Ready', 'status': 'True'},
                {'type': 'MemoryPressure', 'status': 'True'},
              ],
            },
          },
        ]),
        'https://cluster.example.internal:6443/api/v1/pods': _listResponse([
          {
            'metadata': {
              'name': 'api-7d9cc6c6df-a',
              'namespace': 'apps',
              'labels': {'app': 'api'},
              'ownerReferences': [
                {'kind': 'ReplicaSet', 'name': 'api-7d9cc6c6df'},
              ],
            },
            'spec': {'nodeName': 'worker-1'},
            'status': {
              'phase': 'Running',
              'containerStatuses': [
                {'restartCount': 0},
              ],
            },
          },
          {
            'metadata': {
              'name': 'api-7d9cc6c6df-b',
              'namespace': 'apps',
              'labels': {'app': 'api'},
              'ownerReferences': [
                {'kind': 'ReplicaSet', 'name': 'api-7d9cc6c6df'},
              ],
            },
            'spec': {'nodeName': 'cp-1'},
            'status': {
              'phase': 'Pending',
              'containerStatuses': [
                {'restartCount': 0},
              ],
            },
          },
          {
            'metadata': {
              'name': 'agent-worker-1',
              'namespace': 'platform',
              'labels': {'app': 'agent'},
              'ownerReferences': [
                {'kind': 'DaemonSet', 'name': 'agent'},
              ],
            },
            'spec': {'nodeName': 'worker-1'},
            'status': {
              'phase': 'Running',
              'containerStatuses': [
                {'restartCount': 1},
              ],
            },
          },
        ]),
        'https://cluster.example.internal:6443/api/v1/services': _listResponse([
          {
            'metadata': {
              'name': 'api',
              'namespace': 'apps',
            },
            'spec': {
              'type': 'LoadBalancer',
              'clusterIP': '10.96.0.100',
              'selector': {'app': 'api'},
              'ports': [
                {
                  'name': 'http',
                  'port': 80,
                  'targetPort': 8080,
                  'protocol': 'TCP'
                },
              ],
            },
          },
          {
            'metadata': {
              'name': 'orphan',
              'namespace': 'apps',
            },
            'spec': {
              'type': 'ClusterIP',
              'selector': {'app': 'missing'},
              'ports': [
                {'port': 80, 'targetPort': 8080, 'protocol': 'TCP'},
              ],
            },
          },
        ]),
        'https://cluster.example.internal:6443/apis/apps/v1/deployments':
            _listResponse([
          {
            'metadata': {'name': 'api', 'namespace': 'apps'},
            'spec': {
              'replicas': 2,
              'template': {
                'spec': {
                  'containers': [
                    {'name': 'api', 'image': 'nginx:1.25'},
                  ],
                },
              },
            },
            'status': {'readyReplicas': 1},
          },
        ]),
        'https://cluster.example.internal:6443/apis/apps/v1/daemonsets':
            _listResponse([
          {
            'metadata': {'name': 'agent', 'namespace': 'platform'},
            'status': {'desiredNumberScheduled': 1, 'numberReady': 1},
          },
        ]),
        'https://cluster.example.internal:6443/apis/apps/v1/statefulsets':
            _listResponse([]),
        'https://cluster.example.internal:6443/apis/batch/v1/jobs':
            _listResponse([]),
        'https://cluster.example.internal:6443/apis/apps/v1/replicasets':
            _listResponse([
          {
            'metadata': {'name': 'api-7d9cc6c6df', 'namespace': 'apps'},
            'metadata.ownerReferences': [],
          },
          {
            'metadata': {
              'name': 'api-7d9cc6c6df',
              'namespace': 'apps',
              'ownerReferences': [
                {'kind': 'Deployment', 'name': 'api'},
              ],
            },
          },
        ]),
      }),
    );

    final snapshot = await loader.loadSnapshot(
      const KubeconfigResolvedCluster(
        profile: ClusterProfile(
          id: 'prod-admin',
          name: 'prod-cluster',
          apiServerHost: 'cluster.example.internal',
          environmentLabel: 'Production',
          connectionMode: ConnectionMode.direct,
        ),
        server: 'https://cluster.example.internal:6443',
        namespace: 'default',
        auth: KubeconfigAuth(
          bearerToken: 'abc123',
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
    );

    expect(snapshot.nodes, hasLength(2));
    expect(snapshot.nodes.firstWhere((node) => node.id == 'cp-1').role,
        ClusterNodeRole.controlPlane);
    expect(
        snapshot.nodes.firstWhere((node) => node.id == 'worker-1').podCount, 2);

    expect(snapshot.workloads, hasLength(2));
    final apiWorkload =
        snapshot.workloads.firstWhere((workload) => workload.name == 'api');
    expect(apiWorkload.kind, WorkloadKind.deployment);
    expect(apiWorkload.readyReplicas, 1);
    expect(apiWorkload.desiredReplicas, 2);
    expect(apiWorkload.nodeIds, containsAll(['cp-1', 'worker-1']));

    final agentWorkload =
        snapshot.workloads.firstWhere((workload) => workload.name == 'agent');
    expect(agentWorkload.kind, WorkloadKind.daemonSet);
    expect(agentWorkload.nodeIds, ['worker-1']);

    expect(snapshot.services, hasLength(2));
    final apiService =
        snapshot.services.firstWhere((service) => service.name == 'api');
    expect(apiService.exposure, ServiceExposure.loadBalancer);
    expect(apiService.targetWorkloadIds, [apiWorkload.id]);

    final orphanService =
        snapshot.services.firstWhere((service) => service.name == 'orphan');
    expect(orphanService.health, ClusterHealthLevel.warning);

    expect(
        snapshot.links.any((link) =>
            link.sourceId == 'worker-1' && link.targetId == apiWorkload.id),
        isTrue);
    expect(
        snapshot.links.any((link) =>
            link.sourceId == apiService.id && link.targetId == apiWorkload.id),
        isTrue);
    expect(snapshot.alerts.any((alert) => alert.scope == 'Node lifecycle'),
        isTrue);
    expect(snapshot.alerts.any((alert) => alert.scope == 'Workload health'),
        isTrue);
    expect(snapshot.alerts.any((alert) => alert.scope == 'Service routing'),
        isTrue);

    // Node enrichment
    final cp1 = snapshot.nodes.firstWhere((n) => n.id == 'cp-1');
    expect(cp1.cpuCapacity, '4');
    expect(cp1.memoryCapacity, '16Gi');
    expect(cp1.osImage, 'Ubuntu 22.04.3 LTS');

    // Workload images
    expect(apiWorkload.images, ['nginx:1.25']);

    // Service clusterIp
    expect(apiService.clusterIp, '10.96.0.100');
    expect(orphanService.clusterIp, isNull);
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
