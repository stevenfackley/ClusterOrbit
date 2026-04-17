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

    test('round-trips gateway connection mode', () {
      const profile = ClusterProfile(
        id: 'p2',
        name: 'Gateway Cluster',
        apiServerHost: 'gw.host.local',
        environmentLabel: 'Prod',
        connectionMode: ConnectionMode.gateway,
      );
      final restored = ClusterProfile.fromJson(profile.toJson());
      expect(restored.connectionMode, ConnectionMode.gateway);
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

    test('round-trips controlPlane role', () {
      const node = ClusterNode(
        id: 'cp1',
        name: 'cp-1',
        role: ClusterNodeRole.controlPlane,
        version: 'v1.32.0',
        zone: 'use1-a',
        podCount: 17,
        schedulable: true,
        health: ClusterHealthLevel.healthy,
        cpuCapacity: '4',
        memoryCapacity: '16Gi',
        osImage: 'Ubuntu 22.04',
      );
      final restored = ClusterNode.fromJson(node.toJson());
      expect(restored.role, ClusterNodeRole.controlPlane);
      expect(restored.health, ClusterHealthLevel.healthy);
    });

    test('round-trips critical health level', () {
      const node = ClusterNode(
        id: 'n2',
        name: 'node-2',
        role: ClusterNodeRole.worker,
        version: 'v1.32.0',
        zone: 'use1-b',
        podCount: 0,
        schedulable: false,
        health: ClusterHealthLevel.critical,
        cpuCapacity: '8',
        memoryCapacity: '32Gi',
        osImage: 'Ubuntu 22.04',
      );
      final restored = ClusterNode.fromJson(node.toJson());
      expect(restored.health, ClusterHealthLevel.critical);
    });
  });

  group('ClusterWorkload', () {
    test('round-trips deployment kind', () {
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

    test('round-trips all WorkloadKind values', () {
      for (final kind in WorkloadKind.values) {
        const base = ClusterWorkload(
          id: 'w',
          namespace: 'ns',
          name: 'wl',
          kind: WorkloadKind.deployment,
          desiredReplicas: 1,
          readyReplicas: 1,
          nodeIds: [],
          health: ClusterHealthLevel.healthy,
          images: [],
        );
        final workload = ClusterWorkload(
          id: base.id,
          namespace: base.namespace,
          name: base.name,
          kind: kind,
          desiredReplicas: base.desiredReplicas,
          readyReplicas: base.readyReplicas,
          nodeIds: base.nodeIds,
          health: base.health,
          images: base.images,
        );
        final restored = ClusterWorkload.fromJson(workload.toJson());
        expect(restored.kind, kind,
            reason: 'WorkloadKind.$kind failed round-trip');
      }
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
      const port = ServicePort(
          port: 443, targetPort: 8443, protocol: 'TCP', name: 'https');
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

    test('round-trips all ServiceExposure values', () {
      for (final exposure in ServiceExposure.values) {
        final service = ClusterService(
          id: 's',
          namespace: 'ns',
          name: 'svc',
          exposure: exposure,
          targetWorkloadIds: const [],
          ports: const [],
          health: ClusterHealthLevel.healthy,
          clusterIp: exposure == ServiceExposure.ingress ? null : '10.0.0.1',
        );
        final restored = ClusterService.fromJson(service.toJson());
        expect(
          restored.exposure,
          exposure,
          reason: 'ServiceExposure.$exposure failed round-trip',
        );
      }
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

    test('round-trips all TopologyEntityKind values', () {
      for (final kind in TopologyEntityKind.values) {
        final link = TopologyLink(
          sourceId: 'src',
          targetId: 'tgt',
          kind: kind,
        );
        final restored = TopologyLink.fromJson(link.toJson());
        expect(
          restored.kind,
          kind,
          reason: 'TopologyEntityKind.$kind failed round-trip',
        );
      }
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

    test('round-trips snapshot with workloads, services, alerts, and links',
        () {
      const profile = ClusterProfile(
        id: 'p1',
        name: 'Full',
        apiServerHost: 'host.local',
        environmentLabel: 'Prod',
        connectionMode: ConnectionMode.direct,
      );
      const node = ClusterNode(
        id: 'n1',
        name: 'node-1',
        role: ClusterNodeRole.controlPlane,
        version: 'v1.32.0',
        zone: 'use1-a',
        podCount: 10,
        schedulable: true,
        health: ClusterHealthLevel.healthy,
        cpuCapacity: '8',
        memoryCapacity: '32Gi',
        osImage: 'Ubuntu 22.04',
      );
      const workload = ClusterWorkload(
        id: 'w1',
        namespace: 'apps',
        name: 'api',
        kind: WorkloadKind.statefulSet,
        desiredReplicas: 3,
        readyReplicas: 3,
        nodeIds: ['n1'],
        health: ClusterHealthLevel.healthy,
        images: ['ghcr.io/app:v1.0'],
      );
      const service = ClusterService(
        id: 's1',
        namespace: 'apps',
        name: 'api-svc',
        exposure: ServiceExposure.loadBalancer,
        targetWorkloadIds: ['w1'],
        ports: [ServicePort(port: 80, targetPort: 8080, protocol: 'TCP')],
        health: ClusterHealthLevel.healthy,
        clusterIp: '10.96.0.1',
      );
      const alert = ClusterAlert(
        id: 'al1',
        title: 'Test alert',
        summary: 'Summary text',
        level: ClusterHealthLevel.warning,
        scope: 'Node health',
      );
      const link = TopologyLink(
        sourceId: 'n1',
        targetId: 'w1',
        kind: TopologyEntityKind.workload,
      );

      final snapshot = ClusterSnapshot(
        profile: profile,
        generatedAt: DateTime.utc(2026, 4, 16),
        nodes: const [node],
        workloads: const [workload],
        services: const [service],
        alerts: const [alert],
        links: const [link],
      );

      final restored = ClusterSnapshot.fromJson(snapshot.toJson());
      expect(restored.nodes.length, 1);
      expect(restored.nodes.first.role, ClusterNodeRole.controlPlane);
      expect(restored.workloads.length, 1);
      expect(restored.workloads.first.kind, WorkloadKind.statefulSet);
      expect(restored.services.length, 1);
      expect(restored.services.first.exposure, ServiceExposure.loadBalancer);
      expect(restored.alerts.length, 1);
      expect(restored.alerts.first.level, ClusterHealthLevel.warning);
      expect(restored.links.length, 1);
      expect(restored.links.first.kind, TopologyEntityKind.workload);
    });
  });

  group('ClusterEvent', () {
    test('round-trips a Normal event with all fields', () {
      final event = ClusterEvent(
        type: ClusterEventType.normal,
        reason: 'Pulled',
        message: 'Successfully pulled image "nginx:1.27"',
        lastTimestamp: DateTime.utc(2026, 4, 16, 20, 15),
        count: 3,
        sourceComponent: 'kubelet',
      );
      final restored = ClusterEvent.fromJson(event.toJson());
      expect(restored.type, ClusterEventType.normal);
      expect(restored.reason, 'Pulled');
      expect(restored.message, 'Successfully pulled image "nginx:1.27"');
      expect(restored.lastTimestamp, DateTime.utc(2026, 4, 16, 20, 15));
      expect(restored.lastTimestamp.isUtc, isTrue);
      expect(restored.count, 3);
      expect(restored.sourceComponent, 'kubelet');
    });

    test('round-trips a Warning event with null sourceComponent', () {
      final event = ClusterEvent(
        type: ClusterEventType.warning,
        reason: 'BackOff',
        message: 'Back-off restarting failed container',
        lastTimestamp: DateTime.utc(2026, 4, 16, 20, 16),
        count: 7,
      );
      final restored = ClusterEvent.fromJson(event.toJson());
      expect(restored.type, ClusterEventType.warning);
      expect(restored.sourceComponent, isNull);
      expect(restored.count, 7);
    });

    test('ClusterEventTypeLabel.fromK8sType maps Warning and Normal', () {
      expect(
        ClusterEventTypeLabel.fromK8sType('Warning'),
        ClusterEventType.warning,
      );
      expect(
        ClusterEventTypeLabel.fromK8sType('Normal'),
        ClusterEventType.normal,
      );
      expect(
        ClusterEventTypeLabel.fromK8sType(null),
        ClusterEventType.normal,
      );
      expect(
        ClusterEventTypeLabel.fromK8sType('Unknown'),
        ClusterEventType.normal,
      );
    });
  });
}
