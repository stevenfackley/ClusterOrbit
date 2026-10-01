import 'package:clusterorbit_mobile/core/cluster_domain/cluster_models.dart';
import 'package:clusterorbit_mobile/core/connectivity/kube_transport.dart';
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

  test('snapshot loader handles selectorless services, namespaces and jobs',
      () async {
    const base = 'https://cluster.example.internal:6443';
    Map<String, dynamic> pod(String name, String ns, String app, String rs) => {
          'metadata': {
            'name': name,
            'namespace': ns,
            'labels': {'app': app},
            'ownerReferences': [
              {'kind': 'ReplicaSet', 'name': rs},
            ],
          },
          'spec': {'nodeName': 'n1'},
          'status': {'phase': 'Running'},
        };
    Map<String, dynamic> deployment(String ns) => {
          'metadata': {'name': 'web', 'namespace': ns},
          'spec': {'replicas': 1},
          'status': {'readyReplicas': 1},
        };
    Map<String, dynamic> job(String name, Map<String, dynamic> status) => {
          'metadata': {'name': name, 'namespace': 'batch'},
          'spec': {'completions': 1},
          'status': status,
        };
    final loader = KubernetesSnapshotLoader(
      transport: _FakeKubernetesTransport({
        '$base/api/v1/nodes': _listResponse([]),
        '$base/api/v1/pods': _listResponse([
          pod('web-a-1', 'a', 'web', 'web-a'),
          pod('web-b-1', 'b', 'web', 'web-b'),
        ]),
        '$base/api/v1/services': _listResponse([
          {
            'metadata': {'name': 'kubernetes', 'namespace': 'default'},
            'spec': {
              'type': 'ClusterIP',
              'ports': [
                {'port': 443, 'targetPort': 6443},
              ],
            },
          },
          {
            'metadata': {'name': 'web', 'namespace': 'a'},
            'spec': {
              'selector': {'app': 'web'},
            },
          },
        ]),
        '$base/apis/apps/v1/deployments':
            _listResponse([deployment('a'), deployment('b')]),
        '$base/apis/apps/v1/daemonsets': _listResponse([]),
        '$base/apis/apps/v1/statefulsets': _listResponse([]),
        '$base/apis/batch/v1/jobs': _listResponse([
          job('running', {'active': 1}),
          job('failed', {
            'failed': 1,
            'conditions': [
              {'type': 'Failed', 'status': 'True'},
            ],
          }),
        ]),
        '$base/apis/apps/v1/replicasets': _listResponse([
          for (final ns in ['a', 'b'])
            {
              'metadata': {
                'name': 'web-$ns',
                'namespace': ns,
                'ownerReferences': [
                  {'kind': 'Deployment', 'name': 'web'},
                ],
              },
            },
        ]),
      }),
    );

    final snapshot = await loader.loadSnapshot(
      const KubeconfigResolvedCluster(
        profile: ClusterProfile(
          id: 'c',
          name: 'c',
          apiServerHost: 'cluster.example.internal',
          environmentLabel: 'Dev',
          connectionMode: ConnectionMode.direct,
        ),
        server: base,
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

    // Selectorless default/kubernetes must not crash or raise an alert.
    final kubernetes =
        snapshot.services.firstWhere((s) => s.name == 'kubernetes');
    expect(kubernetes.targetWorkloadIds, isEmpty);
    expect(kubernetes.health, ClusterHealthLevel.healthy);

    // A selector in namespace a must not match the same-labelled workload in b.
    final web = snapshot.services.firstWhere((s) => s.name == 'web');
    expect(web.targetWorkloadIds, ['deployment:a/web']);
    expect(web.health, ClusterHealthLevel.healthy);
    expect(snapshot.alerts.where((a) => a.scope == 'Service routing'), isEmpty);

    // A running Job is not an alert; a failed one is.
    final running = snapshot.workloads.firstWhere((w) => w.name == 'running');
    expect(running.health, ClusterHealthLevel.healthy);
    final failed = snapshot.workloads.firstWhere((w) => w.name == 'failed');
    expect(failed.health, ClusterHealthLevel.warning);
    final workloadAlerts =
        snapshot.alerts.where((a) => a.scope == 'Workload health').toList();
    expect(workloadAlerts.map((a) => a.id), ['workload-${failed.id}']);
  });

  // The same table as the gateway's TestJobHealthAndAlerts: Direct and
  // Gateway mode must agree on every Job's health and alerts.
  group('Job health and alerts', () {
    Map<String, dynamic> jobPod(String name, String phase) => {
          'metadata': {
            'name': name,
            'namespace': 'default',
            'ownerReferences': [
              {'kind': 'Job', 'name': 'j', 'controller': true},
            ],
          },
          'spec': {'nodeName': 'n1'},
          'status': {'phase': phase},
        };
    const failedCondition = [
      {'type': 'Failed', 'status': 'True'},
    ];
    const healthy = ClusterHealthLevel.healthy;
    const warning = ClusterHealthLevel.warning;

    final cases = <(
      String,
      Map<String, dynamic>,
      Map<String, dynamic>,
      List<Map<String, dynamic>>,
      ClusterHealthLevel,
      String?,
    )>[
      // A Pending pod is a live attempt, so it still warns; a Job never
      // alerts on it.
      (
        'running with a Pending pod',
        {'completions': 1},
        {'active': 1},
        [jobPod('j-a', 'Pending')],
        warning,
        null,
      ),
      (
        'running after a retry',
        {'completions': 1},
        {'active': 1, 'failed': 1},
        [jobPod('j-a', 'Failed'), jobPod('j-b', 'Running')],
        healthy,
        null,
      ),
      (
        'complete after a retry',
        {'completions': 1},
        {
          'succeeded': 1,
          'failed': 1,
          'conditions': [
            {'type': 'Complete', 'status': 'True'},
          ],
        },
        [jobPod('j-a', 'Failed'), jobPod('j-b', 'Succeeded')],
        healthy,
        null,
      ),
      (
        'backoff window before a retry',
        {'completions': 1},
        {'active': 0, 'failed': 1},
        [jobPod('j-a', 'Failed')],
        healthy,
        null,
      ),
      (
        'failed condition',
        {'completions': 1},
        {'failed': 2, 'conditions': failedCondition},
        [jobPod('j-a', 'Failed'), jobPod('j-b', 'Failed')],
        warning,
        'j has failed.',
      ),
      (
        'parallelism-only Job with the failed condition',
        {'parallelism': 2},
        {'failed': 2, 'conditions': failedCondition},
        [jobPod('j-a', 'Failed'), jobPod('j-b', 'Failed')],
        warning,
        'j has failed.',
      ),
    ];

    for (final (name, spec, status, pods, health, alert) in cases) {
      test(name, () async {
        final snapshot = await _loadJob(spec: spec, status: status, pods: pods);

        expect(snapshot.workloads.single.health, health);
        if (alert == null) {
          expect(snapshot.alerts, isEmpty);
          return;
        }
        final only = snapshot.alerts.single;
        expect(only.id, 'workload-job:default/j');
        expect(only.title, 'Job failed');
        expect(only.summary, alert);
        expect(only.level, warning);
        expect(only.scope, 'Workload health');
      });
    }

    test('only a True Failed or FailureTarget condition fails a Job', () async {
      for (final (status, failed) in [
        (
          {
            'conditions': [
              {'type': 'FailureTarget', 'status': 'True'},
            ],
          },
          true,
        ),
        (
          {
            'conditions': [
              {'type': 'Failed', 'status': 'False'},
            ],
          },
          false,
        ),
        ({'failed': 3, 'active': 0}, false),
      ]) {
        final snapshot = await _loadJob(
            spec: const {'completions': 1}, status: status, pods: const []);
        expect(snapshot.alerts, hasLength(failed ? 1 : 0), reason: '$status');
      }
    });
  });

  test('snapshot loader keeps a path-prefixed API server (Rancher proxy)',
      () async {
    const base = 'https://rancher.example.com/k8s/clusters/c-abc12';
    final loader = KubernetesSnapshotLoader(
      transport: _FakeKubernetesTransport({
        for (final path in [
          'api/v1/nodes',
          'api/v1/pods',
          'api/v1/services',
          'apis/apps/v1/deployments',
          'apis/apps/v1/daemonsets',
          'apis/apps/v1/statefulsets',
          'apis/batch/v1/jobs',
          'apis/apps/v1/replicasets',
        ])
          '$base/$path': _listResponse([]),
      }),
    );

    final snapshot = await loader.loadSnapshot(
      const KubeconfigResolvedCluster(
        profile: ClusterProfile(
          id: 'c',
          name: 'c',
          apiServerHost: 'rancher.example.com',
          environmentLabel: 'Dev',
          connectionMode: ConnectionMode.direct,
        ),
        server: '$base/',
        namespace: null,
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

    expect(snapshot.nodes, isEmpty);
  });
}

/// A snapshot of one Job, default/j, with [spec], [status] and [pods].
Future<ClusterSnapshot> _loadJob({
  required Map<String, dynamic> spec,
  required Map<String, dynamic> status,
  required List<Map<String, dynamic>> pods,
}) {
  const base = 'https://cluster.example.internal:6443';
  final loader = KubernetesSnapshotLoader(
    transport: _FakeKubernetesTransport({
      for (final path in [
        'api/v1/nodes',
        'api/v1/services',
        'apis/apps/v1/deployments',
        'apis/apps/v1/daemonsets',
        'apis/apps/v1/statefulsets',
        'apis/apps/v1/replicasets',
      ])
        '$base/$path': _listResponse([]),
      '$base/api/v1/pods': _listResponse(pods),
      '$base/apis/batch/v1/jobs': _listResponse([
        {
          'metadata': {'namespace': 'default', 'name': 'j'},
          'spec': spec,
          'status': status,
        },
      ]),
    }),
  );
  return loader.loadSnapshot(
    const KubeconfigResolvedCluster(
      profile: ClusterProfile(
        id: 'c',
        name: 'c',
        apiServerHost: 'cluster.example.internal',
        environmentLabel: 'Dev',
        connectionMode: ConnectionMode.direct,
      ),
      server: base,
      namespace: null,
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
