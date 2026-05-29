import 'dart:convert';

import 'cluster_connection.dart';
import 'kubeconfig_repository.dart';
import 'kubernetes_snapshot_loader.dart';

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

    final parsed = _parseWorkloadId(workloadId);
    final resource = _scaleResourceFor(parsed.kind);
    if (resource == null) {
      throw UnsupportedWorkloadKindException(parsed.kind);
    }

    final baseUri = Uri.parse(cluster.server);
    final path =
        '/apis/apps/v1/namespaces/${parsed.namespace}/$resource/${parsed.name}/scale';
    final body = utf8.encode(
      jsonEncode({
        'spec': {'replicas': replicas}
      }),
    );

    await _transport.patchJson(
      KubernetesRequest(
        uri: baseUri.resolve(path),
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
    final parsed = _parseWorkloadId(workloadId);
    final resource = _restartResourceFor(parsed.kind);
    if (resource == null) {
      throw UnsupportedWorkloadKindException(parsed.kind);
    }

    final baseUri = Uri.parse(cluster.server);
    final path =
        '/apis/apps/v1/namespaces/${parsed.namespace}/$resource/${parsed.name}';
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
        uri: baseUri.resolve(path),
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
    final baseUri = Uri.parse(cluster.server);
    final path = '/api/v1/nodes/$nodeId';
    final body = utf8.encode(
      jsonEncode({
        'spec': {'unschedulable': !schedulable}
      }),
    );

    await _transport.patchJson(
      KubernetesRequest(
        uri: baseUri.resolve(path),
        auth: cluster.auth,
        tls: cluster.tls,
      ),
      contentType: 'application/merge-patch+json',
      body: body,
    );
  }
}

/// Topology workload ID shape: `{kind}:{namespace}/{name}`. The `/` inside
/// the namespace/name tail is preserved by splitting the colon first.
_ParsedWorkloadId _parseWorkloadId(String id) {
  final colon = id.indexOf(':');
  if (colon <= 0 || colon == id.length - 1) {
    throw ArgumentError.value(id, 'workloadId', 'malformed');
  }
  final kind = id.substring(0, colon);
  final tail = id.substring(colon + 1);
  final slash = tail.indexOf('/');
  if (slash <= 0 || slash == tail.length - 1) {
    throw ArgumentError.value(id, 'workloadId', 'malformed');
  }
  return _ParsedWorkloadId(
    kind: kind,
    namespace: tail.substring(0, slash),
    name: tail.substring(slash + 1),
  );
}

String? _scaleResourceFor(String kind) {
  switch (kind) {
    case 'deployment':
      return 'deployments';
    case 'statefulSet':
      return 'statefulsets';
    default:
      return null;
  }
}

String? _restartResourceFor(String kind) {
  switch (kind) {
    case 'deployment':
      return 'deployments';
    case 'statefulSet':
      return 'statefulsets';
    case 'daemonSet':
      return 'daemonsets';
    default:
      return null;
  }
}

class _ParsedWorkloadId {
  const _ParsedWorkloadId({
    required this.kind,
    required this.namespace,
    required this.name,
  });
  final String kind;
  final String namespace;
  final String name;
}
