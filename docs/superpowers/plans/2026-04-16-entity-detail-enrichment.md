# Entity Detail Enrichment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enrich `ClusterNode`, `ClusterWorkload`, and `ClusterService` domain models with additional fields captured during snapshot load, and surface them in `_EntityDetailPanel`.

**Architecture:** Extend the three domain model classes with new fields (`cpuCapacity`, `memoryCapacity`, `osImage` on nodes; `images` on workloads; `clusterIp` on services). The `KubernetesSnapshotLoader` extracts these from existing API responses — no new network calls. `SampleClusterData` gets realistic placeholder values. The detail panel grows new rows.

**Tech Stack:** Flutter/Dart, `flutter_test`, existing `KubernetesTransport` stub pattern for loader tests.

---

## File Map

| Action | File |
|--------|------|
| Modify | `app/mobile/lib/core/cluster_domain/cluster_models.dart` |
| Modify | `app/mobile/lib/core/connectivity/kubernetes_snapshot_loader.dart` |
| Modify | `app/mobile/lib/core/connectivity/sample_cluster_data.dart` |
| Modify | `app/mobile/lib/features/topology/topology_screen.dart` |
| Modify | `app/mobile/test/kubernetes_snapshot_loader_test.dart` |

---

## Task 1: Extend domain models and fix all call sites

**Files:**
- Modify: `app/mobile/lib/core/cluster_domain/cluster_models.dart`
- Modify: `app/mobile/lib/core/connectivity/sample_cluster_data.dart`

- [ ] **Step 1: Add new fields to ClusterNode, ClusterWorkload, ClusterService**

Replace the three class definitions in `cluster_models.dart`:

```dart
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
```

- [ ] **Step 2: Fix ClusterNode call sites in sample_cluster_data.dart**

Control plane nodes (in `List.generate(3, ...)` block):

```dart
ClusterNode(
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
```

Worker nodes (in `List.generate(39, ...)` block):

```dart
ClusterNode(
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
),
```

- [ ] **Step 3: Fix ClusterWorkload call sites in sample_cluster_data.dart**

In `List.generate(18, ...)`, add `images` to the `ClusterWorkload(...)` constructor:

```dart
ClusterWorkload(
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
  images: ['ghcr.io/clusterorbit/service-${index + 1}:v0.${index + 1}.0'],
),
```

- [ ] **Step 4: Fix ClusterService call sites in sample_cluster_data.dart**

In `List.generate(12, ...)`, add `clusterIp` to the `ClusterService(...)` constructor:

```dart
ClusterService(
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
  clusterIp: '10.96.0.${index + 1}',
),
```

- [ ] **Step 5: Run tests — should still pass**

```bash
cd app/mobile && flutter test
```

Expected: all 23 tests pass. The new fields are present in sample data; nothing tests their values yet.

- [ ] **Step 6: Commit**

```bash
git add app/mobile/lib/core/cluster_domain/cluster_models.dart \
        app/mobile/lib/core/connectivity/sample_cluster_data.dart
git commit -m "feat: add cpuCapacity/memoryCapacity/osImage to ClusterNode, images to ClusterWorkload, clusterIp to ClusterService"
```

---

## Task 2: Write failing tests for new field extraction in the loader

**Files:**
- Modify: `app/mobile/test/kubernetes_snapshot_loader_test.dart`

- [ ] **Step 1: Add containers to pod fixtures**

In the `api-7d9cc6c6df-a` pod entry, add `spec.containers`:

```dart
{
  'metadata': {
    'name': 'api-7d9cc6c6df-a',
    'namespace': 'apps',
    'labels': {'app': 'api'},
    'ownerReferences': [
      {'kind': 'ReplicaSet', 'name': 'api-7d9cc6c6df'},
    ],
  },
  'spec': {
    'nodeName': 'worker-1',
    'containers': [
      {'name': 'api', 'image': 'nginx:1.25'},
    ],
  },
  'status': {
    'phase': 'Running',
    'containerStatuses': [
      {'restartCount': 0},
    ],
  },
},
```

In the `api-7d9cc6c6df-b` pod entry, add `spec.containers` (same image — loader deduplicates):

```dart
{
  'metadata': {
    'name': 'api-7d9cc6c6df-b',
    'namespace': 'apps',
    'labels': {'app': 'api'},
    'ownerReferences': [
      {'kind': 'ReplicaSet', 'name': 'api-7d9cc6c6df'},
    ],
  },
  'spec': {
    'nodeName': 'cp-1',
    'containers': [
      {'name': 'api', 'image': 'nginx:1.25'},
    ],
  },
  'status': {
    'phase': 'Pending',
    'containerStatuses': [
      {'restartCount': 0},
    ],
  },
},
```

In the `agent-worker-1` pod entry, add `spec.containers`:

```dart
{
  'metadata': {
    'name': 'agent-worker-1',
    'namespace': 'platform',
    'labels': {'app': 'agent'},
    'ownerReferences': [
      {'kind': 'DaemonSet', 'name': 'agent'},
    ],
  },
  'spec': {
    'nodeName': 'worker-1',
    'containers': [
      {'name': 'agent', 'image': 'ghcr.io/clusterorbit/agent:v1.2.0'},
    ],
  },
  'status': {
    'phase': 'Running',
    'containerStatuses': [
      {'restartCount': 1},
    ],
  },
},
```

- [ ] **Step 2: Add capacity and osImage to node fixtures**

Replace the `cp-1` node entry:

```dart
{
  'metadata': {
    'name': 'cp-1',
    'labels': {
      'node-role.kubernetes.io/control-plane': '',
      'topology.kubernetes.io/zone': 'use1-a',
    },
  },
  'spec': {'unschedulable': false},
  'status': {
    'nodeInfo': {
      'kubeletVersion': 'v1.32.3',
      'osImage': 'Ubuntu 22.04.3 LTS',
    },
    'capacity': {
      'cpu': '4',
      'memory': '16Gi',
    },
    'conditions': [
      {'type': 'Ready', 'status': 'True'},
    ],
  },
},
```

Replace the `worker-1` node entry:

```dart
{
  'metadata': {
    'name': 'worker-1',
    'labels': {
      'topology.kubernetes.io/zone': 'use1-b',
    },
  },
  'spec': {'unschedulable': true},
  'status': {
    'nodeInfo': {
      'kubeletVersion': 'v1.32.3',
      'osImage': 'Ubuntu 22.04.3 LTS',
    },
    'capacity': {
      'cpu': '8',
      'memory': '32Gi',
    },
    'conditions': [
      {'type': 'Ready', 'status': 'True'},
      {'type': 'MemoryPressure', 'status': 'True'},
    ],
  },
},
```

- [ ] **Step 3: Add clusterIP to service fixtures**

Replace the `api` service entry:

```dart
{
  'metadata': {
    'name': 'api',
    'namespace': 'apps',
  },
  'spec': {
    'type': 'LoadBalancer',
    'clusterIP': '10.96.0.100',
    'selector': {'app': 'api'},
    'ports': [
      {
        'name': 'http',
        'port': 80,
        'targetPort': 8080,
        'protocol': 'TCP'
      },
    ],
  },
},
```

Leave the `orphan` service without a `clusterIP` field (verifies null path).

- [ ] **Step 4: Add assertions for new fields**

Append after the existing assertions in the test (before the closing `}`):

```dart
// Node enrichment
final cp1 = snapshot.nodes.firstWhere((n) => n.id == 'cp-1');
expect(cp1.cpuCapacity, '4');
expect(cp1.memoryCapacity, '16Gi');
expect(cp1.osImage, 'Ubuntu 22.04.3 LTS');

final worker1 = snapshot.nodes.firstWhere((n) => n.id == 'worker-1');
expect(worker1.cpuCapacity, '8');
expect(worker1.memoryCapacity, '32Gi');

// Workload images
expect(apiWorkload.images, ['nginx:1.25']);
expect(agentWorkload.images, ['ghcr.io/clusterorbit/agent:v1.2.0']);

// Service clusterIp
expect(apiService.clusterIp, '10.96.0.100');
expect(orphanService.clusterIp, isNull);
```

- [ ] **Step 5: Run test — expect it to fail**

```bash
cd app/mobile && flutter test test/kubernetes_snapshot_loader_test.dart
```

Expected: FAIL. Errors like `Expected: '4' Actual: 'unknown'` for node capacity and `Expected: ['nginx:1.25'] Actual: []` for workload images. This confirms the tests are exercising real paths.

---

## Task 3: Implement new field extraction in the loader

**Files:**
- Modify: `app/mobile/lib/core/connectivity/kubernetes_snapshot_loader.dart`

- [ ] **Step 1: Add workloadImages collection to the pod iteration loop**

In `loadSnapshot`, after the declaration of `workloadHealthSignals`, add:

```dart
final workloadImages = <String, Set<String>>{};
```

Inside the `for (final pod in podItems)` loop, after the existing `workloadId` resolve and health-signal logic, add image collection. Place it immediately after the `if (workloadId == null) { continue; }` guard (or after the null check):

```dart
for (final container in _listAt(pod, ['spec', 'containers'])) {
  if (container is Map) {
    final image = container['image'];
    if (image is String && image.isNotEmpty) {
      workloadImages.putIfAbsent(workloadId!, () => <String>{}).add(image);
    }
  }
}
```

- [ ] **Step 2: Thread workloadImages into _workloadFromController calls**

Update every call to `_workloadFromController` in `loadSnapshot` to pass `images: workloadImages`:

```dart
final workloads = [
  ...deploymentItems.map(
    (item) => _workloadFromController(
      item,
      kind: WorkloadKind.deployment,
      nodeIds: workloadNodeIds,
      healthSignals: workloadHealthSignals,
      images: workloadImages,
    ),
  ),
  ...daemonSetItems.map(
    (item) => _workloadFromController(
      item,
      kind: WorkloadKind.daemonSet,
      nodeIds: workloadNodeIds,
      healthSignals: workloadHealthSignals,
      images: workloadImages,
    ),
  ),
  ...statefulSetItems.map(
    (item) => _workloadFromController(
      item,
      kind: WorkloadKind.statefulSet,
      nodeIds: workloadNodeIds,
      healthSignals: workloadHealthSignals,
      images: workloadImages,
    ),
  ),
  ...jobItems.map(
    (item) => _workloadFromController(
      item,
      kind: WorkloadKind.job,
      nodeIds: workloadNodeIds,
      healthSignals: workloadHealthSignals,
      images: workloadImages,
    ),
  ),
];
```

- [ ] **Step 3: Update _workloadFromController signature and return**

Add `required Map<String, Set<String>> images` parameter and populate `images` in the returned object:

```dart
ClusterWorkload _workloadFromController(
  Map<String, dynamic> item, {
  required WorkloadKind kind,
  required Map<String, Set<String>> nodeIds,
  required Map<String, ClusterHealthLevel> healthSignals,
  required Map<String, Set<String>> images,
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

  return ClusterWorkload(
    id: workloadId,
    namespace: namespace,
    name: name,
    kind: kind,
    desiredReplicas: target,
    readyReplicas: readyReplicas,
    nodeIds: (nodeIds[workloadId] ?? const <String>{}).toList()..sort(),
    health: health,
    images: (images[workloadId] ?? const <String>{}).toList()..sort(),
  );
}
```

- [ ] **Step 4: Update _nodeFromItem to extract capacity and osImage**

```dart
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
```

- [ ] **Step 5: Update _serviceFromItem to extract clusterIp**

```dart
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

  final rawClusterIp = _stringAt(item, ['spec', 'clusterIP']);
  final clusterIp = (rawClusterIp == null ||
          rawClusterIp.isEmpty ||
          rawClusterIp == 'None')
      ? null
      : rawClusterIp;

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
    clusterIp: clusterIp,
  );
}
```

- [ ] **Step 6: Run tests — all should pass**

```bash
cd app/mobile && flutter test
```

Expected: all 23 tests pass. The new assertions from Task 2 now also pass.

- [ ] **Step 7: Commit**

```bash
git add app/mobile/lib/core/connectivity/kubernetes_snapshot_loader.dart \
        app/mobile/test/kubernetes_snapshot_loader_test.dart
git commit -m "feat: extract cpuCapacity/memoryCapacity/osImage/images/clusterIp in snapshot loader"
```

---

## Task 4: Show new fields in EntityDetailPanel

**Files:**
- Modify: `app/mobile/lib/features/topology/topology_screen.dart`

- [ ] **Step 1: Update _nodeFields to show OS, CPU, Memory**

Replace the `_nodeFields` method body:

```dart
List<Widget> _nodeFields(ClusterNode n, ThemeData theme) {
  final tint = _healthTint(n.health, palette);
  return [
    _DetailRow(label: 'Role', value: n.role.label, theme: theme),
    _DetailRow(label: 'Zone', value: n.zone, theme: theme),
    _DetailRow(label: 'K8s Version', value: n.version, theme: theme),
    _DetailRow(label: 'OS', value: n.osImage, theme: theme),
    _DetailRow(label: 'CPU', value: n.cpuCapacity, theme: theme),
    _DetailRow(label: 'Memory', value: n.memoryCapacity, theme: theme),
    _DetailRow(label: 'Pod Count', value: '${n.podCount}', theme: theme),
    _DetailRow(
        label: 'Schedulable',
        value: n.schedulable ? 'Yes' : 'Cordoned',
        theme: theme),
    _DetailStatusRow(
        label: 'Health', value: n.health.name, tint: tint, theme: theme),
  ];
}
```

- [ ] **Step 2: Update _workloadFields to show container images**

Replace the `_workloadFields` method body:

```dart
List<Widget> _workloadFields(ClusterWorkload w, ThemeData theme) {
  final tint = _healthTint(w.health, palette);
  return [
    _DetailRow(label: 'Namespace', value: w.namespace, theme: theme),
    _DetailRow(label: 'Kind', value: w.kind.label, theme: theme),
    _DetailRow(
        label: 'Replicas',
        value: '${w.readyReplicas} / ${w.desiredReplicas} ready',
        theme: theme),
    _DetailRow(
        label: 'Nodes',
        value: '${w.nodeIds.length} placement(s)',
        theme: theme),
    for (final image in w.images)
      _DetailRow(label: 'Image', value: image, theme: theme),
    _DetailStatusRow(
        label: 'Health', value: w.health.name, tint: tint, theme: theme),
  ];
}
```

- [ ] **Step 3: Update _serviceFields to show Cluster IP**

Replace the `_serviceFields` method body:

```dart
List<Widget> _serviceFields(ClusterService s, ThemeData theme) {
  final tint = _healthTint(s.health, palette);
  return [
    _DetailRow(label: 'Namespace', value: s.namespace, theme: theme),
    _DetailRow(label: 'Exposure', value: s.exposure.label, theme: theme),
    if (s.clusterIp != null)
      _DetailRow(label: 'Cluster IP', value: s.clusterIp!, theme: theme),
    _DetailRow(
        label: 'Targets',
        value: '${s.targetWorkloadIds.length} workload(s)',
        theme: theme),
    for (final p in s.ports)
      _DetailRow(
        label: 'Port',
        value:
            '${p.port} → ${p.targetPort} / ${p.protocol}${p.name != null ? ' (${p.name})' : ''}',
        theme: theme,
      ),
    _DetailStatusRow(
        label: 'Health', value: s.health.name, tint: tint, theme: theme),
  ];
}
```

- [ ] **Step 4: Format**

```bash
cd app/mobile && dart format lib/features/topology/topology_screen.dart
```

Expected: no changes if code was already formatted correctly.

- [ ] **Step 5: Run full test suite**

```bash
cd app/mobile && flutter test
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add app/mobile/lib/features/topology/topology_screen.dart
git commit -m "feat: show OS, CPU, memory, container images, and cluster IP in entity detail panel"
```

---

## Self-Review

**Spec coverage:**
- ClusterNode enriched with cpuCapacity, memoryCapacity, osImage ✓
- ClusterWorkload enriched with images ✓
- ClusterService enriched with clusterIp ✓
- Loader extracts all new fields from existing API responses ✓
- Sample data provides realistic values ✓
- Detail panel renders new rows ✓
- Tests cover extraction of each new field ✓

**No placeholders:** All code blocks are complete and compilable.

**Type consistency:**
- `cpuCapacity: String` — consistent across models, loader (`_stringAt ?? 'unknown'`), and sample data (`'4'`, `'8'`, `'16'`)
- `memoryCapacity: String` — same pattern
- `osImage: String` — same pattern
- `images: List<String>` — consistent; loader sorts, sample data passes literal list
- `clusterIp: String?` — optional on model, loader returns null for missing/`None` values, sample data passes IP string
