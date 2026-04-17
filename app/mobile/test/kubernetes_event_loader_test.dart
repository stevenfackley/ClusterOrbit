import 'package:clusterorbit_mobile/core/cluster_domain/cluster_models.dart';
import 'package:clusterorbit_mobile/core/connectivity/kubeconfig_repository.dart';
import 'package:clusterorbit_mobile/core/connectivity/kubernetes_event_loader.dart';
import 'package:clusterorbit_mobile/core/connectivity/kubernetes_snapshot_loader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('hits namespaced events endpoint for workloads', () async {
    final transport = _FakeKubernetesTransport({
      'https://cluster.example.internal:6443/api/v1/namespaces/apps/events'
              '?fieldSelector=involvedObject.name%3Dapi':
          _listResponse([
        {
          'metadata': {'creationTimestamp': '2026-04-16T20:15:00Z'},
          'type': 'Normal',
          'reason': 'Pulled',
          'message': 'Successfully pulled image "nginx:1.27"',
          'lastTimestamp': '2026-04-16T20:15:00Z',
          'count': 3,
          'source': {'component': 'kubelet'},
        },
      ]),
    });

    final events = await KubernetesEventLoader(transport: transport).loadEvents(
      cluster: _cluster(),
      namespace: 'apps',
      objectName: 'api',
    );

    expect(events, hasLength(1));
    final event = events.single;
    expect(event.type, ClusterEventType.normal);
    expect(event.reason, 'Pulled');
    expect(event.count, 3);
    expect(event.sourceComponent, 'kubelet');
    expect(event.lastTimestamp.isUtc, isTrue);
  });

  test('hits cluster-scoped events endpoint for nodes', () async {
    final transport = _FakeKubernetesTransport({
      'https://cluster.example.internal:6443/api/v1/events'
              '?fieldSelector=involvedObject.name%3Dworker-1':
          _listResponse([
        {
          'type': 'Warning',
          'reason': 'NodeSysctlChange',
          'message': 'Sysctl changes applied',
          'lastTimestamp': '2026-04-16T20:10:00Z',
          'count': 1,
        },
      ]),
    });

    final events = await KubernetesEventLoader(transport: transport).loadEvents(
      cluster: _cluster(),
      namespace: null,
      objectName: 'worker-1',
    );

    expect(events, hasLength(1));
    expect(events.single.type, ClusterEventType.warning);
    expect(events.single.sourceComponent, isNull);
  });

  test('sorts newest first and truncates to limit', () async {
    final transport = _FakeKubernetesTransport({
      'https://cluster.example.internal:6443/api/v1/namespaces/apps/events'
              '?fieldSelector=involvedObject.name%3Dapi':
          _listResponse([
        {
          'type': 'Normal',
          'reason': 'Old',
          'message': 'old',
          'lastTimestamp': '2026-04-16T19:00:00Z',
        },
        {
          'type': 'Normal',
          'reason': 'Newest',
          'message': 'newest',
          'lastTimestamp': '2026-04-16T21:00:00Z',
        },
        {
          'type': 'Normal',
          'reason': 'Middle',
          'message': 'middle',
          'lastTimestamp': '2026-04-16T20:00:00Z',
        },
      ]),
    });

    final events = await KubernetesEventLoader(transport: transport).loadEvents(
      cluster: _cluster(),
      namespace: 'apps',
      objectName: 'api',
      limit: 2,
    );

    expect(events.map((e) => e.reason).toList(), ['Newest', 'Middle']);
  });

  test('skips malformed events without reason or message', () async {
    final transport = _FakeKubernetesTransport({
      'https://cluster.example.internal:6443/api/v1/namespaces/apps/events'
              '?fieldSelector=involvedObject.name%3Dapi':
          _listResponse([
        {
          'type': 'Normal',
          'message': 'no reason',
          'lastTimestamp': '2026-04-16T20:00:00Z',
        },
        {
          'type': 'Normal',
          'reason': 'Keep',
          'message': 'good',
          'lastTimestamp': '2026-04-16T20:00:00Z',
        },
      ]),
    });

    final events = await KubernetesEventLoader(transport: transport).loadEvents(
      cluster: _cluster(),
      namespace: 'apps',
      objectName: 'api',
    );

    expect(events.map((e) => e.reason).toList(), ['Keep']);
  });

  test('returns empty list when response has no items', () async {
    final transport = _FakeKubernetesTransport({
      'https://cluster.example.internal:6443/api/v1/namespaces/apps/events'
              '?fieldSelector=involvedObject.name%3Dapi':
          {'kind': 'List'},
    });

    final events = await KubernetesEventLoader(transport: transport).loadEvents(
      cluster: _cluster(),
      namespace: 'apps',
      objectName: 'api',
    );

    expect(events, isEmpty);
  });
}

KubeconfigResolvedCluster _cluster() => const KubeconfigResolvedCluster(
      profile: ClusterProfile(
        id: 'test',
        name: 'test',
        apiServerHost: 'cluster.example.internal:6443',
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
