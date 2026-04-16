import '../cluster_domain/cluster_models.dart';

final class SampleClusterData {
  const SampleClusterData._();

  static List<ClusterProfile> profilesFor(ConnectionMode mode) => [
        ClusterProfile(
          id: 'dev-orbit',
          name: 'clusterorbit.local',
          apiServerHost: 'dev-us-east.control.clusterorbit.local',
          environmentLabel: 'Development',
          connectionMode: mode,
        ),
        ClusterProfile(
          id: 'staging-orbit',
          name: 'staging-orbit',
          apiServerHost: 'staging-us-east.control.clusterorbit.local',
          environmentLabel: 'Staging',
          connectionMode: mode,
        ),
        ClusterProfile(
          id: 'prod-orbit',
          name: 'prod-orbit',
          apiServerHost: 'prod-us-east.control.clusterorbit.local',
          environmentLabel: 'Production',
          connectionMode: mode,
        ),
      ];

  static ClusterSnapshot snapshotFor(ClusterProfile profile) {
    final nodes = [
      ...List.generate(
        3,
        (index) => ClusterNode(
          id: 'cp-${index + 1}',
          name: 'cp-${index + 1}.${profile.id}',
          role: ClusterNodeRole.controlPlane,
          version: 'v1.32.3+k3s1',
          zone: 'use1-${String.fromCharCode(97 + index)}',
          podCount: 17 + index,
          schedulable: true,
          health: ClusterHealthLevel.healthy,
          cpuCapacity: '4',
          memoryCapacity: '16Gi',
          osImage: 'Ubuntu 22.04.3 LTS',
        ),
      ),
      ...List.generate(
        39,
        (index) {
          final isUnschedulable = index == 6;
          final isWarning = index == 6 || index == 14 || index == 27;
          return ClusterNode(
            id: 'worker-${index + 1}',
            name: 'worker-${index + 1}.${profile.id}',
            role: ClusterNodeRole.worker,
            version: 'v1.32.3+k3s1',
            zone: 'use1-${String.fromCharCode(97 + (index % 3))}',
            podCount: 22 + (index % 9),
            schedulable: !isUnschedulable,
            health: isWarning
                ? ClusterHealthLevel.warning
                : ClusterHealthLevel.healthy,
            cpuCapacity: index % 2 == 0 ? '8' : '16',
            memoryCapacity: index % 2 == 0 ? '32Gi' : '64Gi',
            osImage: 'Ubuntu 22.04.3 LTS',
          );
        },
      ),
    ];

    final workloads = List.generate(
      18,
      (index) {
        final kind = switch (index % 4) {
          0 => WorkloadKind.deployment,
          1 => WorkloadKind.daemonSet,
          2 => WorkloadKind.statefulSet,
          _ => WorkloadKind.job,
        };
        final desiredReplicas = kind == WorkloadKind.daemonSet ? 39 : 3;
        final readyReplicas =
            index == 5 ? desiredReplicas - 1 : desiredReplicas;
        final nodeOffset = index * 2;
        return ClusterWorkload(
          id: 'workload-${index + 1}',
          namespace: index < 6 ? 'platform' : 'apps',
          name: 'service-${index + 1}',
          kind: kind,
          desiredReplicas: desiredReplicas,
          readyReplicas: readyReplicas,
          nodeIds: [
            nodes[nodeOffset % nodes.length].id,
            nodes[(nodeOffset + 1) % nodes.length].id,
            if (kind != WorkloadKind.daemonSet)
              nodes[(nodeOffset + 2) % nodes.length].id,
          ],
          health: readyReplicas == desiredReplicas
              ? ClusterHealthLevel.healthy
              : ClusterHealthLevel.warning,
          images: [
            'ghcr.io/clusterorbit/service-${index + 1}:v0.${index + 1}.0'
          ],
        );
      },
    );

    final services = List.generate(
      12,
      (index) {
        final exposure = switch (index % 4) {
          0 => ServiceExposure.clusterIp,
          1 => ServiceExposure.nodePort,
          2 => ServiceExposure.loadBalancer,
          _ => ServiceExposure.ingress,
        };
        return ClusterService(
          id: 'service-${index + 1}',
          namespace: index < 4 ? 'platform' : 'apps',
          name: 'service-${index + 1}',
          exposure: exposure,
          targetWorkloadIds: [workloads[index].id],
          ports: [
            ServicePort(
              name: 'http',
              port: exposure == ServiceExposure.ingress ? 443 : 80,
              targetPort: 8080,
              protocol: 'TCP',
            ),
          ],
          health: index == 10
              ? ClusterHealthLevel.warning
              : ClusterHealthLevel.healthy,
          clusterIp: exposure == ServiceExposure.ingress
              ? null
              : '10.96.0.${index + 1}',
        );
      },
    );

    const alerts = [
      ClusterAlert(
        id: 'alert-1',
        title: 'Node drain in progress',
        summary: 'worker-7 is cordoned and draining remaining workloads.',
        level: ClusterHealthLevel.warning,
        scope: 'Node lifecycle',
      ),
      ClusterAlert(
        id: 'alert-2',
        title: 'Replica skew detected',
        summary: 'service-6 is below desired replica count in apps.',
        level: ClusterHealthLevel.warning,
        scope: 'Workload health',
      ),
      ClusterAlert(
        id: 'alert-3',
        title: 'Control plane certificate renewal due',
        summary: 'Production certificate rotation window opens in 36 hours.',
        level: ClusterHealthLevel.warning,
        scope: 'Platform maintenance',
      ),
      ClusterAlert(
        id: 'alert-4',
        title: 'API latency elevated',
        summary: 'P95 request latency crossed 420ms on the gateway path.',
        level: ClusterHealthLevel.critical,
        scope: 'Cluster ingress',
      ),
      ClusterAlert(
        id: 'alert-5',
        title: 'Node pressure event',
        summary: 'worker-15 reported transient memory pressure in use1-c.',
        level: ClusterHealthLevel.warning,
        scope: 'Node health',
      ),
    ];

    final links = <TopologyLink>[
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
      profile: profile,
      generatedAt: DateTime.utc(2026, 4, 15, 23, 45),
      nodes: nodes,
      workloads: workloads,
      services: services,
      alerts: alerts,
      links: links,
    );
  }
}
