import '../cluster_domain/cluster_models.dart';
import 'kube_transport.dart';
import 'kubeconfig_repository.dart';

/// Fetches Kubernetes events for a single involved object.
///
/// Node events are cluster-scoped (`/api/v1/events`); workload and service
/// events are namespaced (`/api/v1/namespaces/{ns}/events`). Both use a
/// `fieldSelector=involvedObject.name={name}` filter, plus
/// `involvedObject.kind={kind}` when [loadEvents] gets an `involvedObjectKind`.
/// The reducer mirrors the gateway's `eventFromItem` (backend.go).
final class KubernetesEventLoader {
  KubernetesEventLoader({
    KubernetesTransport? transport,
  }) : _transport = transport ?? HttpKubernetesTransport();

  final KubernetesTransport _transport;

  Future<List<ClusterEvent>> loadEvents({
    required KubeconfigResolvedCluster cluster,
    required String objectName,
    String? namespace,
    String? involvedObjectKind,
    int limit = 5,
  }) async {
    final uri = kubeApiUri(
      cluster.server,
      namespace == null || namespace.isEmpty
          ? ['api', 'v1', 'events']
          : ['api', 'v1', 'namespaces', namespace, 'events'],
      queryParameters: {
        'fieldSelector': [
          'involvedObject.name=$objectName',
          if (involvedObjectKind != null)
            'involvedObject.kind=$involvedObjectKind',
        ].join(','),
      },
    );

    final response = await _transport.getJson(
      KubernetesRequest(
        uri: uri,
        auth: cluster.auth,
        tls: cluster.tls,
      ),
    );

    final rawItems = response['items'];
    if (rawItems is! List) {
      return const [];
    }

    final events = rawItems
        .whereType<Map>()
        .map((item) => item.map((k, v) => MapEntry('$k', v)))
        .map(_eventFromItem)
        .whereType<ClusterEvent>()
        .toList()
      ..sort((a, b) => b.lastTimestamp.compareTo(a.lastTimestamp));

    return events.take(limit).toList();
  }

  ClusterEvent? _eventFromItem(Map<String, dynamic> item) {
    final message = item['message'];
    final reason = item['reason'];
    if (message is! String || reason is! String) {
      return null;
    }

    final rawTimestamp = (item['lastTimestamp'] ??
        item['eventTime'] ??
        item['firstTimestamp'] ??
        _metadataCreationTimestamp(item)) as Object?;
    final timestamp = _parseTimestamp(rawTimestamp);
    if (timestamp == null) {
      return null;
    }

    final source = item['source'];
    final reporting = item['reportingComponent'];
    final component = source is Map &&
            source['component'] is String &&
            source['component'] != ''
        ? source['component'] as String
        : reporting is String && reporting.isNotEmpty
            ? reporting
            : null;

    final count = item['count'];
    return ClusterEvent(
      type: ClusterEventTypeLabel.fromK8sType(item['type'] as String?),
      reason: reason,
      message: message,
      lastTimestamp: timestamp,
      count: count is int && count != 0 ? count : 1,
      sourceComponent: component,
    );
  }

  Object? _metadataCreationTimestamp(Map<String, dynamic> item) {
    final metadata = item['metadata'];
    if (metadata is Map) {
      return metadata['creationTimestamp'];
    }
    return null;
  }

  DateTime? _parseTimestamp(Object? raw) {
    if (raw is String && raw.isNotEmpty) {
      return DateTime.tryParse(raw)?.toUtc();
    }
    return null;
  }
}
