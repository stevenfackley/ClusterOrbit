import 'dart:convert';
import 'dart:io';

import '../cluster_domain/cluster_models.dart';
import 'kubeconfig_repository.dart';

final class KubernetesSnapshotLoader {
  KubernetesSnapshotLoader({
    KubernetesTransport? transport,
  }) : _transport = transport ?? HttpKubernetesTransport();

  final KubernetesTransport _transport;

  Future<ClusterSnapshot> loadSnapshot(
      KubeconfigResolvedCluster cluster) async {
    final baseUri = Uri.parse(cluster.server);
    final responses = await Future.wait([
      _transport.getJson(
        KubernetesRequest(
          uri: baseUri.resolve('/api/v1/nodes'),
          auth: cluster.auth,
          tls: cluster.tls,
        ),
      ),
      _transport.getJson(
        KubernetesRequest(
          uri: baseUri.resolve('/api/v1/pods'),
          auth: cluster.auth,
          tls: cluster.tls,
        ),
      ),
      _transport.getJson(
        KubernetesRequest(
          uri: baseUri.resolve('/api/v1/services'),
          auth: cluster.auth,
          tls: cluster.tls,
        ),
      ),
      _transport.getJson(
        KubernetesRequest(
          uri: baseUri.resolve('/apis/apps/v1/deployments'),
          auth: cluster.auth,
          tls: cluster.tls,
        ),
      ),
      _transport.getJson(
        KubernetesRequest(
          uri: baseUri.resolve('/apis/apps/v1/daemonsets'),
          auth: cluster.auth,
          tls: cluster.tls,
        ),
      ),
      _transport.getJson(
        KubernetesRequest(
          uri: baseUri.resolve('/apis/apps/v1/statefulsets'),
          auth: cluster.auth,
          tls: cluster.tls,
        ),
      ),
      _transport.getJson(
        KubernetesRequest(
          uri: baseUri.resolve('/apis/batch/v1/jobs'),
          auth: cluster.auth,
          tls: cluster.tls,
        ),
      ),
      _transport.getJson(
        KubernetesRequest(
          uri: baseUri.resolve('/apis/apps/v1/replicasets'),
          auth: cluster.auth,
          tls: cluster.tls,
        ),
      ),
    ]);

    final nodeItems = _items(responses[0]);
    final podItems = _items(responses[1]);
    final serviceItems = _items(responses[2]);
    final deploymentItems = _items(responses[3]);
    final daemonSetItems = _items(responses[4]);
    final statefulSetItems = _items(responses[5]);
    final jobItems = _items(responses[6]);
    final replicaSetItems = _items(responses[7]);

    final nodePodCounts = <String, int>{};
    final replicaSetOwners = _replicaSetOwners(replicaSetItems);
    final podWorkloadIds = <String, String>{};
    final workloadNodeIds = <String, Set<String>>{};
    final workloadHealthSignals = <String, ClusterHealthLevel>{};

    for (final pod in podItems) {
      final nodeName = _stringAt(pod, ['spec', 'nodeName']);
      if (nodeName != null) {
        nodePodCounts[nodeName] = (nodePodCounts[nodeName] ?? 0) + 1;
      }

      final workloadId = _workloadIdForPod(pod, replicaSetOwners);
      if (workloadId == null) {
        continue;
      }

      final podKey = _resourceKey(
        _stringAt(pod, ['metadata', 'namespace']) ?? 'default',
        _stringAt(pod, ['metadata', 'name']) ?? workloadId,
      );
      podWorkloadIds[podKey] = workloadId;

      if (nodeName != null) {
        workloadNodeIds.putIfAbsent(workloadId, () => <String>{}).add(nodeName);
      }

      final podPhase = _stringAt(pod, ['status', 'phase'])?.toLowerCase();
      final containerStatuses = _listAt(pod, ['status', 'containerStatuses']);
      final hasRestartingContainer = containerStatuses.any(
        (status) =>
            _intAt(status, ['restartCount']) > 0 ||
            _stringAt(status, ['state', 'waiting', 'reason']) ==
                'CrashLoopBackOff',
      );

      final signal = switch (podPhase) {
        'running' || 'succeeded' => hasRestartingContainer
            ? ClusterHealthLevel.warning
            : ClusterHealthLevel.healthy,
        'pending' => ClusterHealthLevel.warning,
        _ => ClusterHealthLevel.critical,
      };

      final existing = workloadHealthSignals[workloadId];
      workloadHealthSignals[workloadId] = _maxHealth(existing, signal);
    }

    final nodes = [
      for (final item in nodeItems) _nodeFromItem(item, nodePodCounts),
    ];

    final workloads = [
      ...deploymentItems.map(
        (item) => _workloadFromController(
          item,
          kind: WorkloadKind.deployment,
          nodeIds: workloadNodeIds,
          healthSignals: workloadHealthSignals,
        ),
      ),
      ...daemonSetItems.map(
        (item) => _workloadFromController(
          item,
          kind: WorkloadKind.daemonSet,
          nodeIds: workloadNodeIds,
          healthSignals: workloadHealthSignals,
        ),
      ),
      ...statefulSetItems.map(
        (item) => _workloadFromController(
          item,
          kind: WorkloadKind.statefulSet,
          nodeIds: workloadNodeIds,
          healthSignals: workloadHealthSignals,
        ),
      ),
      ...jobItems.map(
        (item) => _workloadFromController(
          item,
          kind: WorkloadKind.job,
          nodeIds: workloadNodeIds,
          healthSignals: workloadHealthSignals,
        ),
      ),
    ];

    final workloadsById = {
      for (final workload in workloads) workload.id: workload,
    };
    final podLabelsByWorkload = _podLabelsByWorkload(podItems, podWorkloadIds);

    final services = [
      for (final item in serviceItems)
        _serviceFromItem(item, workloadsById, podLabelsByWorkload),
    ];

    final alerts = [
      ..._nodeAlerts(nodes),
      ..._workloadAlerts(workloads),
      ..._serviceAlerts(services),
    ];

    final links = [
      for (final workload in workloads)
        for (final nodeId in workload.nodeIds)
          TopologyLink(
            sourceId: nodeId,
            targetId: workload.id,
            kind: TopologyEntityKind.workload,
          ),
      for (final service in services)
        for (final workloadId in service.targetWorkloadIds)
          TopologyLink(
            sourceId: service.id,
            targetId: workloadId,
            kind: TopologyEntityKind.service,
            label: service.exposure.label,
          ),
    ];

    return ClusterSnapshot(
      profile: cluster.profile,
      generatedAt: DateTime.now().toUtc(),
      nodes: nodes,
      workloads: workloads,
      services: services,
      alerts: alerts,
      links: links,
    );
  }

  List<Map<String, dynamic>> _items(Map<String, dynamic> response) {
    final rawItems = response['items'];
    if (rawItems is! List) {
      return const [];
    }

    return rawItems.whereType<Map>().map((item) {
      return item.map((key, value) => MapEntry('$key', value));
    }).toList();
  }

  Map<String, String> _replicaSetOwners(
      List<Map<String, dynamic>> replicaSets) {
    final owners = <String, String>{};
    for (final replicaSet in replicaSets) {
      final namespace = _stringAt(replicaSet, ['metadata', 'namespace']);
      final name = _stringAt(replicaSet, ['metadata', 'name']);
      if (namespace == null || name == null) {
        continue;
      }

      final ownerRefs = _listAt(replicaSet, ['metadata', 'ownerReferences']);
      final deploymentOwner =
          ownerRefs.cast<Map?>().whereType<Map>().firstWhere(
                (owner) => '${owner['kind']}' == 'Deployment',
                orElse: () => const {},
              );
      final deploymentName = deploymentOwner['name'];
      if (deploymentName is String && deploymentName.isNotEmpty) {
        owners[_resourceKey(namespace, name)] =
            _workloadId(WorkloadKind.deployment, namespace, deploymentName);
      }
    }
    return owners;
  }

  Map<String, List<Map<String, String>>> _podLabelsByWorkload(
    List<Map<String, dynamic>> pods,
    Map<String, String> podWorkloadIds,
  ) {
    final result = <String, List<Map<String, String>>>{};
    for (final pod in pods) {
      final namespace = _stringAt(pod, ['metadata', 'namespace']);
      final name = _stringAt(pod, ['metadata', 'name']);
      if (namespace == null || name == null) {
        continue;
      }

      final workloadId = podWorkloadIds[_resourceKey(namespace, name)];
      if (workloadId == null) {
        continue;
      }

      final labels = _mapAt(pod, ['metadata', 'labels']);
      result.putIfAbsent(workloadId, () => <Map<String, String>>[]).add(labels);
    }
    return result;
  }

  String? _workloadIdForPod(
    Map<String, dynamic> pod,
    Map<String, String> replicaSetOwners,
  ) {
    final namespace = _stringAt(pod, ['metadata', 'namespace']);
    if (namespace == null) {
      return null;
    }

    final ownerRefs = _listAt(pod, ['metadata', 'ownerReferences']);
    for (final owner in ownerRefs.cast<Map?>().whereType<Map>()) {
      final kind = '${owner['kind']}';
      final name = owner['name'];
      if (name is! String || name.isEmpty) {
        continue;
      }

      switch (kind) {
        case 'ReplicaSet':
          return replicaSetOwners[_resourceKey(namespace, name)];
        case 'DaemonSet':
          return _workloadId(WorkloadKind.daemonSet, namespace, name);
        case 'StatefulSet':
          return _workloadId(WorkloadKind.statefulSet, namespace, name);
        case 'Job':
          return _workloadId(WorkloadKind.job, namespace, name);
      }
    }

    return null;
  }

  ClusterNode _nodeFromItem(
    Map<String, dynamic> item,
    Map<String, int> nodePodCounts,
  ) {
    final name = _stringAt(item, ['metadata', 'name']) ?? 'unknown-node';
    final labels = _mapAt(item, ['metadata', 'labels']);
    final conditions = _listAt(item, ['status', 'conditions']);
    final readyCondition = conditions.cast<Map?>().whereType<Map>().firstWhere(
          (condition) => '${condition['type']}' == 'Ready',
          orElse: () => const {},
        );
    final isReady = '${readyCondition['status']}' == 'True';
    final hasPressure = conditions.cast<Map?>().whereType<Map>().any(
          (condition) =>
              ('${condition['type']}'.contains('Pressure')) &&
              '${condition['status']}' == 'True',
        );
    final schedulable = !(_boolAt(item, ['spec', 'unschedulable']) ?? false);

    final health = !isReady
        ? ClusterHealthLevel.critical
        : (hasPressure || !schedulable)
            ? ClusterHealthLevel.warning
            : ClusterHealthLevel.healthy;

    return ClusterNode(
      id: name,
      name: name,
      role: _isControlPlane(labels)
          ? ClusterNodeRole.controlPlane
          : ClusterNodeRole.worker,
      version: _stringAt(item, ['status', 'nodeInfo', 'kubeletVersion']) ??
          'unknown',
      zone: labels['topology.kubernetes.io/zone'] ??
          labels['failure-domain.beta.kubernetes.io/zone'] ??
          'unassigned',
      podCount: nodePodCounts[name] ?? 0,
      schedulable: schedulable,
      health: health,
      cpuCapacity: _stringAt(item, ['status', 'capacity', 'cpu']) ?? 'unknown',
      memoryCapacity:
          _stringAt(item, ['status', 'capacity', 'memory']) ?? 'unknown',
      osImage: _stringAt(item, ['status', 'nodeInfo', 'osImage']) ?? 'unknown',
    );
  }

  ClusterWorkload _workloadFromController(
    Map<String, dynamic> item, {
    required WorkloadKind kind,
    required Map<String, Set<String>> nodeIds,
    required Map<String, ClusterHealthLevel> healthSignals,
  }) {
    final namespace = _stringAt(item, ['metadata', 'namespace']) ?? 'default';
    final name = _stringAt(item, ['metadata', 'name']) ?? 'unknown';
    final workloadId = _workloadId(kind, namespace, name);

    final desiredReplicas = switch (kind) {
      WorkloadKind.deployment ||
      WorkloadKind.statefulSet =>
        _intAt(item, ['spec', 'replicas']),
      WorkloadKind.daemonSet =>
        _intAt(item, ['status', 'desiredNumberScheduled']),
      WorkloadKind.job => _intAt(item, ['spec', 'completions']),
    };
    final readyReplicas = switch (kind) {
      WorkloadKind.deployment ||
      WorkloadKind.statefulSet =>
        _intAt(item, ['status', 'readyReplicas']),
      WorkloadKind.daemonSet => _intAt(item, ['status', 'numberReady']),
      WorkloadKind.job => _intAt(item, ['status', 'succeeded']),
    };

    final target = desiredReplicas == 0 && kind == WorkloadKind.job
        ? (_intAt(item, ['status', 'active']) > 0 ? 1 : readyReplicas)
        : desiredReplicas;

    final healthSignal = healthSignals[workloadId];
    final health = readyReplicas < target
        ? ClusterHealthLevel.warning
        : (healthSignal ?? ClusterHealthLevel.healthy);

    final containers = _listAt(item, ['spec', 'template', 'spec', 'containers'])
        .cast<Map?>()
        .whereType<Map>()
        .map((c) => '${c['image']}')
        .where((s) => s.isNotEmpty && s != 'null')
        .toList();

    return ClusterWorkload(
      id: workloadId,
      namespace: namespace,
      name: name,
      kind: kind,
      desiredReplicas: target,
      readyReplicas: readyReplicas,
      nodeIds: (nodeIds[workloadId] ?? const <String>{}).toList()..sort(),
      health: health,
      images: containers,
    );
  }

  ClusterService _serviceFromItem(
    Map<String, dynamic> item,
    Map<String, ClusterWorkload> workloadsById,
    Map<String, List<Map<String, String>>> podLabelsByWorkload,
  ) {
    final namespace = _stringAt(item, ['metadata', 'namespace']) ?? 'default';
    final name = _stringAt(item, ['metadata', 'name']) ?? 'unknown-service';
    final selector = _mapAt(item, ['spec', 'selector']);
    final targetWorkloadIds = selector.isEmpty
        ? const <String>[]
        : [
            for (final entry in workloadsById.entries)
              if (_matchesSelector(
                  selector, podLabelsByWorkload[entry.key] ?? const []))
                entry.key,
          ]
      ..sort();

    return ClusterService(
      id: _resourceId('service', namespace, name),
      namespace: namespace,
      name: name,
      exposure: _serviceExposure(item),
      targetWorkloadIds: targetWorkloadIds,
      ports: [
        for (final port in _listAt(item, ['spec', 'ports']))
          ServicePort(
            name: _stringAt(port, ['name']),
            port: _intAt(port, ['port']),
            targetPort: _targetPort(port['targetPort']),
            protocol: _stringAt(port, ['protocol']) ?? 'TCP',
          ),
      ],
      health: targetWorkloadIds.isEmpty
          ? ClusterHealthLevel.warning
          : ClusterHealthLevel.healthy,
      clusterIp: _toNullableClusterIp(_stringAt(item, ['spec', 'clusterIP'])),
    );
  }

  List<ClusterAlert> _nodeAlerts(List<ClusterNode> nodes) {
    return [
      for (final node in nodes)
        if (node.health == ClusterHealthLevel.critical)
          ClusterAlert(
            id: 'node-critical-${node.id}',
            title: 'Node not ready',
            summary: '${node.name} is reporting an unhealthy ready condition.',
            level: ClusterHealthLevel.critical,
            scope: 'Node health',
          )
        else if (!node.schedulable)
          ClusterAlert(
            id: 'node-drain-${node.id}',
            title: 'Node unschedulable',
            summary: '${node.name} is cordoned or draining.',
            level: ClusterHealthLevel.warning,
            scope: 'Node lifecycle',
          )
        else if (node.health == ClusterHealthLevel.warning)
          ClusterAlert(
            id: 'node-warning-${node.id}',
            title: 'Node pressure detected',
            summary:
                '${node.name} is healthy but reporting pressure conditions.',
            level: ClusterHealthLevel.warning,
            scope: 'Node health',
          ),
    ];
  }

  List<ClusterAlert> _workloadAlerts(List<ClusterWorkload> workloads) {
    return [
      for (final workload in workloads)
        if (workload.readyReplicas < workload.desiredReplicas)
          ClusterAlert(
            id: 'workload-${workload.id}',
            title: 'Replica skew detected',
            summary:
                '${workload.name} is at ${workload.readyReplicas}/${workload.desiredReplicas} ready replicas.',
            level: ClusterHealthLevel.warning,
            scope: 'Workload health',
          ),
    ];
  }

  List<ClusterAlert> _serviceAlerts(List<ClusterService> services) {
    return [
      for (final service in services)
        if (service.targetWorkloadIds.isEmpty)
          ClusterAlert(
            id: 'service-${service.id}',
            title: 'Service has no backing workloads',
            summary:
                '${service.name} does not currently match any discovered workload pods.',
            level: ClusterHealthLevel.warning,
            scope: 'Service routing',
          ),
    ];
  }

  String? _toNullableClusterIp(String? raw) {
    if (raw == null || raw.isEmpty || raw == 'None') return null;
    return raw;
  }

  bool _matchesSelector(
    Map<String, String> selector,
    List<Map<String, String>> podLabels,
  ) {
    for (final labels in podLabels) {
      final matches =
          selector.entries.every((entry) => labels[entry.key] == entry.value);
      if (matches) {
        return true;
      }
    }
    return false;
  }

  bool _isControlPlane(Map<String, String> labels) {
    return labels.containsKey('node-role.kubernetes.io/control-plane') ||
        labels.containsKey('node-role.kubernetes.io/master');
  }

  ServiceExposure _serviceExposure(Map<String, dynamic> item) {
    final type = _stringAt(item, ['spec', 'type']) ?? 'ClusterIP';
    switch (type) {
      case 'NodePort':
        return ServiceExposure.nodePort;
      case 'LoadBalancer':
        return ServiceExposure.loadBalancer;
      case 'ExternalName':
        return ServiceExposure.ingress;
      default:
        return ServiceExposure.clusterIp;
    }
  }

  ClusterHealthLevel _maxHealth(
    ClusterHealthLevel? current,
    ClusterHealthLevel next,
  ) {
    if (current == null) {
      return next;
    }
    if (current == ClusterHealthLevel.critical ||
        next == ClusterHealthLevel.critical) {
      return ClusterHealthLevel.critical;
    }
    if (current == ClusterHealthLevel.warning ||
        next == ClusterHealthLevel.warning) {
      return ClusterHealthLevel.warning;
    }
    return ClusterHealthLevel.healthy;
  }

  String _workloadId(WorkloadKind kind, String namespace, String name) =>
      _resourceId(kind.name, namespace, name);

  String _resourceId(String prefix, String namespace, String name) =>
      '$prefix:$namespace/$name';

  String _resourceKey(String namespace, String name) => '$namespace/$name';

  Map<String, String> _mapAt(Map<String, dynamic> source, List<String> path) {
    final value = _valueAt(source, path);
    if (value is! Map) {
      return const {};
    }

    return value.map((key, value) => MapEntry('$key', '$value'));
  }

  List<dynamic> _listAt(Map<String, dynamic> source, List<String> path) {
    final value = _valueAt(source, path);
    return value is List ? value : const [];
  }

  String? _stringAt(Map<String, dynamic> source, List<String> path) {
    final value = _valueAt(source, path);
    return value is String ? value : null;
  }

  bool? _boolAt(Map<String, dynamic> source, List<String> path) {
    final value = _valueAt(source, path);
    return value is bool ? value : null;
  }

  int _intAt(Map<String, dynamic> source, List<String> path) {
    final value = _valueAt(source, path);
    if (value is int) {
      return value;
    }
    if (value is String) {
      return int.tryParse(value) ?? 0;
    }
    return 0;
  }

  int _targetPort(dynamic value) {
    if (value is int) {
      return value;
    }
    if (value is String) {
      return int.tryParse(value) ?? 0;
    }
    return 0;
  }

  dynamic _valueAt(Map<String, dynamic> source, List<String> path) {
    dynamic current = source;
    for (final segment in path) {
      if (current is Map) {
        current = current[segment];
      } else {
        return null;
      }
    }
    return current;
  }
}

final class KubernetesRequest {
  const KubernetesRequest({
    required this.uri,
    required this.auth,
    required this.tls,
  });

  final Uri uri;
  final KubeconfigAuth auth;
  final KubeconfigTlsConfig tls;
}

abstract interface class KubernetesTransport {
  Future<Map<String, dynamic>> getJson(KubernetesRequest request);
}

final class HttpKubernetesTransport implements KubernetesTransport {
  @override
  Future<Map<String, dynamic>> getJson(KubernetesRequest request) async {
    final client = HttpClient(
      context: _buildSecurityContext(request.tls, request.auth),
    );
    if (request.tls.insecureSkipTlsVerify) {
      client.badCertificateCallback = (_, __, ___) => true;
    }

    try {
      final httpRequest = await client.getUrl(request.uri);
      httpRequest.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (request.auth.bearerToken != null &&
          request.auth.bearerToken!.isNotEmpty) {
        httpRequest.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer ${request.auth.bearerToken}',
        );
      } else if (request.auth.basicUsername != null &&
          request.auth.basicPassword != null) {
        final token = base64Encode(
          utf8.encode(
              '${request.auth.basicUsername}:${request.auth.basicPassword}'),
        );
        httpRequest.headers.set(
          HttpHeaders.authorizationHeader,
          'Basic $token',
        );
      }

      final response = await httpRequest.close();
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode >= 400) {
        throw HttpException(
          'Kubernetes API request failed with status ${response.statusCode}: $body',
          uri: request.uri,
        );
      }

      final decoded = jsonDecode(body);
      if (decoded is! Map) {
        throw const FormatException(
            'Kubernetes API response was not an object');
      }

      return decoded.map((key, value) => MapEntry('$key', value));
    } finally {
      client.close(force: true);
    }
  }

  SecurityContext? _buildSecurityContext(
    KubeconfigTlsConfig tls,
    KubeconfigAuth auth,
  ) {
    final hasCustomContext = tls.certificateAuthorityData != null ||
        (auth.clientCertificateData != null && auth.clientKeyData != null);
    if (!hasCustomContext) {
      return null;
    }

    final context = SecurityContext.defaultContext;
    if (tls.certificateAuthorityData != null) {
      context.setTrustedCertificatesBytes(tls.certificateAuthorityData!);
    }
    if (auth.clientCertificateData != null && auth.clientKeyData != null) {
      context.useCertificateChainBytes(auth.clientCertificateData!);
      context.usePrivateKeyBytes(auth.clientKeyData!);
    }
    return context;
  }
}
