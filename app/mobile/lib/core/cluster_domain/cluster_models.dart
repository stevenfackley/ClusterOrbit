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
