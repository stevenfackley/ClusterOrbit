import 'dart:convert';

import '../cluster_domain/cluster_models.dart';
import 'cluster_connection.dart';
import 'kube_transport.dart';
import 'kubeconfig_repository.dart';

/// Scales a single workload on a live cluster by PATCH-ing the `scale`
/// subresource of the relevant apps/v1 collection. Only Deployment and
/// StatefulSet are supported — DaemonSet/Job ignore replica counts.
final class KubernetesWorkloadScaler {
  KubernetesWorkloadScaler({
    KubernetesTransport? transport,
  }) : _transport = transport ?? HttpKubernetesTransport();

  final KubernetesTransport _transport;

  Future<void> scaleWorkload({
    required KubeconfigResolvedCluster cluster,
    required String workloadId,
    required int replicas,
  }) async {
    if (replicas < 0) {
      throw ArgumentError.value(
          replicas, 'replicas', 'must be a non-negative integer');
    }

    final parsed = parseWorkloadId(workloadId);
    final resource = _kindThat(parsed.kind, (k) => k.isScalable).resource;

    final uri = kubeApiUri(cluster.server, [
      'apis',
      'apps',
      'v1',
      'namespaces',
      parsed.namespace,
      resource,
      parsed.name,
      'scale',
    ]);
    final body = utf8.encode(
      jsonEncode({
        'spec': {'replicas': replicas}
      }),
    );

    await _transport.patchJson(
      KubernetesRequest(
        uri: uri,
        auth: cluster.auth,
        tls: cluster.tls,
      ),
      contentType: 'application/merge-patch+json',
      body: body,
    );
  }

  /// Triggers a rolling restart by strategic-merge-patching the pod template's
  /// `restartedAt` annotation (kubectl rollout restart semantics). Deployment,
  /// StatefulSet, and DaemonSet are supported; Job is not.
  Future<void> restartWorkload({
    required KubeconfigResolvedCluster cluster,
    required String workloadId,
    DateTime? now,
  }) async {
    final parsed = parseWorkloadId(workloadId);
    final resource = _kindThat(parsed.kind, (k) => k.isRestartable).resource;

    final uri = kubeApiUri(cluster.server, [
      'apis',
      'apps',
      'v1',
      'namespaces',
      parsed.namespace,
      resource,
      parsed.name,
    ]);
    final timestamp = (now ?? DateTime.now()).toUtc().toIso8601String();
    final body = utf8.encode(
      jsonEncode({
        'spec': {
          'template': {
            'metadata': {
              'annotations': {
                'kubectl.kubernetes.io/restartedAt': timestamp,
              },
            },
          },
        },
      }),
    );

    await _transport.patchJson(
      KubernetesRequest(
        uri: uri,
        auth: cluster.auth,
        tls: cluster.tls,
      ),
      contentType: 'application/strategic-merge-patch+json',
      body: body,
    );
  }
}

/// Cordons / uncordons a node on a live cluster by merge-patching the node's
/// `spec.unschedulable` field. Cordoning only blocks new scheduling; it does
/// not evict running pods.
final class KubernetesNodeCordoner {
  KubernetesNodeCordoner({
    KubernetesTransport? transport,
  }) : _transport = transport ?? HttpKubernetesTransport();

  final KubernetesTransport _transport;

  Future<void> setSchedulable({
    required KubeconfigResolvedCluster cluster,
    required String nodeId,
    required bool schedulable,
  }) async {
    if (nodeId.isEmpty) {
      throw ArgumentError.value(nodeId, 'nodeId', 'must not be empty');
    }
    final uri = kubeApiUri(cluster.server, ['api', 'v1', 'nodes', nodeId]);
    final body = utf8.encode(
      jsonEncode({
        'spec': {'unschedulable': !schedulable}
      }),
    );

    await _transport.patchJson(
      KubernetesRequest(
        uri: uri,
        auth: cluster.auth,
        tls: cluster.tls,
      ),
      contentType: 'application/merge-patch+json',
      body: body,
    );
  }
}

/// The [WorkloadKind] named [kind], when it passes [supports]; otherwise an
/// [UnsupportedWorkloadKindException] naming [kind] as written.
WorkloadKind _kindThat(String kind, bool Function(WorkloadKind) supports) {
  final known = WorkloadKind.values.asNameMap()[kind];
  if (known == null || !supports(known)) {
    throw UnsupportedWorkloadKindException(kind);
  }
  return known;
}
