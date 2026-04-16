enum ConnectionMode {
  direct,
  gateway,
}

extension ConnectionModeLabel on ConnectionMode {
  String get label => switch (this) {
        ConnectionMode.direct => 'Direct',
        ConnectionMode.gateway => 'Gateway',
      };

  static ConnectionMode fromEnvironment(String? value) {
    switch (value?.trim().toLowerCase()) {
      case 'gateway':
        return ConnectionMode.gateway;
      case 'direct':
      default:
        return ConnectionMode.direct;
    }
  }
}

enum ClusterHealthLevel {
  healthy,
  warning,
  critical,
}

enum ClusterNodeRole {
  controlPlane,
  worker,
}

extension ClusterNodeRoleLabel on ClusterNodeRole {
  String get label => switch (this) {
        ClusterNodeRole.controlPlane => 'Control plane',
        ClusterNodeRole.worker => 'Worker',
      };
}

enum WorkloadKind {
  deployment,
  daemonSet,
  statefulSet,
  job,
}

extension WorkloadKindLabel on WorkloadKind {
  String get label => switch (this) {
        WorkloadKind.deployment => 'Deployment',
        WorkloadKind.daemonSet => 'DaemonSet',
        WorkloadKind.statefulSet => 'StatefulSet',
        WorkloadKind.job => 'Job',
      };
}

enum ServiceExposure {
  clusterIp,
  nodePort,
  loadBalancer,
  ingress,
}

extension ServiceExposureLabel on ServiceExposure {
  String get label => switch (this) {
        ServiceExposure.clusterIp => 'ClusterIP',
        ServiceExposure.nodePort => 'NodePort',
        ServiceExposure.loadBalancer => 'LoadBalancer',
        ServiceExposure.ingress => 'Ingress',
      };
}

enum TopologyEntityKind {
  node,
  workload,
  service,
}

class ClusterProfile {
  const ClusterProfile({
    required this.id,
    required this.name,
    required this.apiServerHost,
    required this.environmentLabel,
    required this.connectionMode,
  });

  final String id;
  final String name;
  final String apiServerHost;
  final String environmentLabel;
  final ConnectionMode connectionMode;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'apiServerHost': apiServerHost,
        'environmentLabel': environmentLabel,
        'connectionMode': connectionMode.name,
      };

  factory ClusterProfile.fromJson(Map<String, dynamic> json) => ClusterProfile(
        id: json['id'] as String,
        name: json['name'] as String,
        apiServerHost: json['apiServerHost'] as String,
        environmentLabel: json['environmentLabel'] as String,
        connectionMode:
            ConnectionMode.values.byName(json['connectionMode'] as String),
      );
}

class ClusterNode {
  const ClusterNode({
    required this.id,
    required this.name,
    required this.role,
    required this.version,
    required this.zone,
    required this.podCount,
    required this.schedulable,
    required this.health,
    required this.cpuCapacity,
    required this.memoryCapacity,
    required this.osImage,
  });

  final String id;
  final String name;
  final ClusterNodeRole role;
  final String version;
  final String zone;
  final int podCount;
  final bool schedulable;
  final ClusterHealthLevel health;
  final String cpuCapacity;
  final String memoryCapacity;
  final String osImage;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'role': role.name,
        'version': version,
        'zone': zone,
        'podCount': podCount,
        'schedulable': schedulable,
        'health': health.name,
        'cpuCapacity': cpuCapacity,
        'memoryCapacity': memoryCapacity,
        'osImage': osImage,
      };

  factory ClusterNode.fromJson(Map<String, dynamic> json) => ClusterNode(
        id: json['id'] as String,
        name: json['name'] as String,
        role: ClusterNodeRole.values.byName(json['role'] as String),
        version: json['version'] as String,
        zone: json['zone'] as String,
        podCount: json['podCount'] as int,
        schedulable: json['schedulable'] as bool,
        health: ClusterHealthLevel.values.byName(json['health'] as String),
        cpuCapacity: json['cpuCapacity'] as String,
        memoryCapacity: json['memoryCapacity'] as String,
        osImage: json['osImage'] as String,
      );
}

class ClusterWorkload {
  const ClusterWorkload({
    required this.id,
    required this.namespace,
    required this.name,
    required this.kind,
    required this.desiredReplicas,
    required this.readyReplicas,
    required this.nodeIds,
    required this.health,
    required this.images,
  });

  final String id;
  final String namespace;
  final String name;
  final WorkloadKind kind;
  final int desiredReplicas;
  final int readyReplicas;
  final List<String> nodeIds;
  final ClusterHealthLevel health;
  final List<String> images;

  Map<String, dynamic> toJson() => {
        'id': id,
        'namespace': namespace,
        'name': name,
        'kind': kind.name,
        'desiredReplicas': desiredReplicas,
        'readyReplicas': readyReplicas,
        'nodeIds': nodeIds,
        'health': health.name,
        'images': images,
      };

  factory ClusterWorkload.fromJson(Map<String, dynamic> json) => ClusterWorkload(
        id: json['id'] as String,
        namespace: json['namespace'] as String,
        name: json['name'] as String,
        kind: WorkloadKind.values.byName(json['kind'] as String),
        desiredReplicas: json['desiredReplicas'] as int,
        readyReplicas: json['readyReplicas'] as int,
        nodeIds: List<String>.from(json['nodeIds'] as List),
        health: ClusterHealthLevel.values.byName(json['health'] as String),
        images: List<String>.from(json['images'] as List),
      );
}

class ServicePort {
  const ServicePort({
    required this.port,
    required this.targetPort,
    required this.protocol,
    this.name,
  });

  final int port;
  final int targetPort;
  final String protocol;
  final String? name;

  Map<String, dynamic> toJson() => {
        'port': port,
        'targetPort': targetPort,
        'protocol': protocol,
        'name': name,
      };

  factory ServicePort.fromJson(Map<String, dynamic> json) => ServicePort(
        port: json['port'] as int,
        targetPort: json['targetPort'] as int,
        protocol: json['protocol'] as String,
        name: json['name'] as String?,
      );
}

class ClusterService {
  const ClusterService({
    required this.id,
    required this.namespace,
    required this.name,
    required this.exposure,
    required this.targetWorkloadIds,
    required this.ports,
    required this.health,
    this.clusterIp,
  });

  final String id;
  final String namespace;
  final String name;
  final ServiceExposure exposure;
  final List<String> targetWorkloadIds;
  final List<ServicePort> ports;
  final ClusterHealthLevel health;
  final String? clusterIp;

  Map<String, dynamic> toJson() => {
        'id': id,
        'namespace': namespace,
        'name': name,
        'exposure': exposure.name,
        'targetWorkloadIds': targetWorkloadIds,
        'ports': ports.map((p) => p.toJson()).toList(),
        'health': health.name,
        'clusterIp': clusterIp,
      };

  factory ClusterService.fromJson(Map<String, dynamic> json) => ClusterService(
        id: json['id'] as String,
        namespace: json['namespace'] as String,
        name: json['name'] as String,
        exposure: ServiceExposure.values.byName(json['exposure'] as String),
        targetWorkloadIds:
            List<String>.from(json['targetWorkloadIds'] as List),
        ports: (json['ports'] as List)
            .map((p) => ServicePort.fromJson(p as Map<String, dynamic>))
            .toList(),
        health: ClusterHealthLevel.values.byName(json['health'] as String),
        clusterIp: json['clusterIp'] as String?,
      );
}

class ClusterAlert {
  const ClusterAlert({
    required this.id,
    required this.title,
    required this.summary,
    required this.level,
    required this.scope,
  });

  final String id;
  final String title;
  final String summary;
  final ClusterHealthLevel level;
  final String scope;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'summary': summary,
        'level': level.name,
        'scope': scope,
      };

  factory ClusterAlert.fromJson(Map<String, dynamic> json) => ClusterAlert(
        id: json['id'] as String,
        title: json['title'] as String,
        summary: json['summary'] as String,
        level: ClusterHealthLevel.values.byName(json['level'] as String),
        scope: json['scope'] as String,
      );
}

class TopologyLink {
  const TopologyLink({
    required this.sourceId,
    required this.targetId,
    required this.kind,
    this.label,
  });

  final String sourceId;
  final String targetId;
  final TopologyEntityKind kind;
  final String? label;

  Map<String, dynamic> toJson() => {
        'sourceId': sourceId,
        'targetId': targetId,
        'kind': kind.name,
        'label': label,
      };

  factory TopologyLink.fromJson(Map<String, dynamic> json) => TopologyLink(
        sourceId: json['sourceId'] as String,
        targetId: json['targetId'] as String,
        kind: TopologyEntityKind.values.byName(json['kind'] as String),
        label: json['label'] as String?,
      );
}

class ClusterSnapshot {
  const ClusterSnapshot({
    required this.profile,
    required this.generatedAt,
    required this.nodes,
    required this.workloads,
    required this.services,
    required this.alerts,
    required this.links,
  });

  final ClusterProfile profile;
  final DateTime generatedAt;
  final List<ClusterNode> nodes;
  final List<ClusterWorkload> workloads;
  final List<ClusterService> services;
  final List<ClusterAlert> alerts;
  final List<TopologyLink> links;

  Map<String, dynamic> toJson() => {
        'profile': profile.toJson(),
        'generatedAt': generatedAt.millisecondsSinceEpoch,
        'nodes': nodes.map((n) => n.toJson()).toList(),
        'workloads': workloads.map((w) => w.toJson()).toList(),
        'services': services.map((s) => s.toJson()).toList(),
        'alerts': alerts.map((a) => a.toJson()).toList(),
        'links': links.map((l) => l.toJson()).toList(),
      };

  factory ClusterSnapshot.fromJson(Map<String, dynamic> json) => ClusterSnapshot(
        profile:
            ClusterProfile.fromJson(json['profile'] as Map<String, dynamic>),
        generatedAt: DateTime.fromMillisecondsSinceEpoch(
          json['generatedAt'] as int,
          isUtc: true,
        ),
        nodes: (json['nodes'] as List)
            .map((n) => ClusterNode.fromJson(n as Map<String, dynamic>))
            .toList(),
        workloads: (json['workloads'] as List)
            .map((w) => ClusterWorkload.fromJson(w as Map<String, dynamic>))
            .toList(),
        services: (json['services'] as List)
            .map((s) => ClusterService.fromJson(s as Map<String, dynamic>))
            .toList(),
        alerts: (json['alerts'] as List)
            .map((a) => ClusterAlert.fromJson(a as Map<String, dynamic>))
            .toList(),
        links: (json['links'] as List)
            .map((l) => TopologyLink.fromJson(l as Map<String, dynamic>))
            .toList(),
      );

  int get controlPlaneCount =>
      nodes.where((node) => node.role == ClusterNodeRole.controlPlane).length;

  int get workerCount =>
      nodes.where((node) => node.role == ClusterNodeRole.worker).length;

  int get unschedulableNodeCount =>
      nodes.where((node) => !node.schedulable).length;

  int get warningCount =>
      alerts.where((alert) => alert.level == ClusterHealthLevel.warning).length;

  int get criticalCount => alerts
      .where((alert) => alert.level == ClusterHealthLevel.critical)
      .length;
}
