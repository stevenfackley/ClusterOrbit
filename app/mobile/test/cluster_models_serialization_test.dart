import 'package:clusterorbit_mobile/core/cluster_domain/cluster_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ClusterProfile', () {
    test('round-trips through JSON', () {
      const profile = ClusterProfile(
        id: 'p1',
        name: 'Test Cluster',
        apiServerHost: 'host.local',
        environmentLabel: 'Dev',
        connectionMode: ConnectionMode.direct,
      );
      final restored = ClusterProfile.fromJson(profile.toJson());
      expect(restored.id, 'p1');
      expect(restored.name, 'Test Cluster');
      expect(restored.apiServerHost, 'host.local');
      expect(restored.environmentLabel, 'Dev');
      expect(restored.connectionMode, ConnectionMode.direct);
    });
  });

  group('ClusterNode', () {
    test('round-trips through JSON', () {
      const node = ClusterNode(
        id: 'n1',
        name: 'node-1',
        role: ClusterNodeRole.worker,
        version: 'v1.32.0',
        zone: 'use1-a',
        podCount: 5,
        schedulable: false,
        health: ClusterHealthLevel.warning,
        cpuCapacity: '8',
        memoryCapacity: '32Gi',
        osImage: 'Ubuntu 22.04',
      );
      final restored = ClusterNode.fromJson(node.toJson());
      expect(restored.id, 'n1');
      expect(restored.role, ClusterNodeRole.worker);
      expect(restored.schedulable, false);
      expect(restored.health, ClusterHealthLevel.warning);
      expect(restored.cpuCapacity, '8');
      expect(restored.memoryCapacity, '32Gi');
      expect(restored.osImage, 'Ubuntu 22.04');
    });
  });

  group('ClusterWorkload', () {
    test('round-trips through JSON', () {
      const workload = ClusterWorkload(
        id: 'w1',
        namespace: 'apps',
        name: 'api',
        kind: WorkloadKind.deployment,
        desiredReplicas: 3,
        readyReplicas: 2,
        nodeIds: ['n1', 'n2'],
        health: ClusterHealthLevel.warning,
        images: ['nginx:1.25', 'sidecar:latest'],
      );
      final restored = ClusterWorkload.fromJson(workload.toJson());
      expect(restored.id, 'w1');
      expect(restored.kind, WorkloadKind.deployment);
      expect(restored.readyReplicas, 2);
      expect(restored.nodeIds, ['n1', 'n2']);
      expect(restored.images, ['nginx:1.25', 'sidecar:latest']);
    });
  });

  group('ServicePort', () {
    test('round-trips with null name', () {
      const port = ServicePort(port: 80, targetPort: 8080, protocol: 'TCP');
      final restored = ServicePort.fromJson(port.toJson());
      expect(restored.port, 80);
      expect(restored.targetPort, 8080);
      expect(restored.protocol, 'TCP');
      expect(restored.name, isNull);
    });

    test('round-trips with name set', () {
      const port =
          ServicePort(port: 443, targetPort: 8443, protocol: 'TCP', name: 'https');
      final restored = ServicePort.fromJson(port.toJson());
      expect(restored.name, 'https');
    });
  });

  group('ClusterService', () {
    test('round-trips with null clusterIp', () {
      const service = ClusterService(
        id: 's1',
        namespace: 'apps',
        name: 'gateway',
        exposure: ServiceExposure.ingress,
        targetWorkloadIds: ['w1'],
        ports: [ServicePort(port: 443, targetPort: 8080, protocol: 'TCP')],
        health: ClusterHealthLevel.healthy,
      );
      final restored = ClusterService.fromJson(service.toJson());
      expect(restored.clusterIp, isNull);
      expect(restored.exposure, ServiceExposure.ingress);
      expect(restored.ports.length, 1);
      expect(restored.ports.first.port, 443);
    });

    test('round-trips with clusterIp set', () {
      const service = ClusterService(
        id: 's2',
        namespace: 'platform',
        name: 'api-svc',
        exposure: ServiceExposure.clusterIp,
        targetWorkloadIds: [],
        ports: [],
        health: ClusterHealthLevel.healthy,
        clusterIp: '10.96.0.1',
      );
      final restored = ClusterService.fromJson(service.toJson());
      expect(restored.clusterIp, '10.96.0.1');
    });
  });

  group('ClusterAlert', () {
    test('round-trips through JSON', () {
      const alert = ClusterAlert(
        id: 'a1',
        title: 'Latency spike',
        summary: 'P95 above threshold',
        level: ClusterHealthLevel.critical,
        scope: 'Cluster ingress',
      );
      final restored = ClusterAlert.fromJson(alert.toJson());
      expect(restored.id, 'a1');
      expect(restored.level, ClusterHealthLevel.critical);
      expect(restored.scope, 'Cluster ingress');
    });
  });

  group('TopologyLink', () {
    test('round-trips with null label', () {
      const link = TopologyLink(
        sourceId: 'n1',
        targetId: 'w1',
        kind: TopologyEntityKind.workload,
      );
      final restored = TopologyLink.fromJson(link.toJson());
      expect(restored.sourceId, 'n1');
      expect(restored.kind, TopologyEntityKind.workload);
      expect(restored.label, isNull);
    });

    test('round-trips with label', () {
      const link = TopologyLink(
        sourceId: 's1',
        targetId: 'w1',
        kind: TopologyEntityKind.service,
        label: 'Ingress',
      );
      final restored = TopologyLink.fromJson(link.toJson());
      expect(restored.label, 'Ingress');
    });
  });

  group('ClusterSnapshot', () {
    test('round-trips a full snapshot including generatedAt UTC', () {
      const profile = ClusterProfile(
        id: 'p1',
        name: 'Test',
        apiServerHost: 'host.local',
        environmentLabel: 'Dev',
        connectionMode: ConnectionMode.direct,
      );
      final snapshot = ClusterSnapshot(
        profile: profile,
        generatedAt: DateTime.utc(2026, 4, 16, 12, 0),
        nodes: const [
          ClusterNode(
            id: 'n1',
            name: 'node-1',
            role: ClusterNodeRole.worker,
            version: 'v1.32.0',
            zone: 'use1-a',
            podCount: 3,
            schedulable: true,
            health: ClusterHealthLevel.healthy,
            cpuCapacity: '4',
            memoryCapacity: '16Gi',
            osImage: 'Ubuntu 22.04',
          ),
        ],
        workloads: const [],
        services: const [],
        alerts: const [],
        links: const [],
      );

      final restored = ClusterSnapshot.fromJson(snapshot.toJson());
      expect(restored.profile.id, 'p1');
      expect(restored.generatedAt, DateTime.utc(2026, 4, 16, 12, 0));
      expect(restored.nodes.length, 1);
      expect(restored.nodes.first.id, 'n1');
      expect(restored.workloads, isEmpty);
    });
  });
}
