# SQLite Snapshot Cache Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cache `ClusterProfile` list and `ClusterSnapshot` per profile in SQLite so the app renders immediately on cold start and stays usable when the cluster is unreachable.

**Architecture:** Add `sqflite` as the database driver with `path_provider` for the DB file location. Serialization lives on the domain model classes (`toJson`/`fromJson`). `SqfliteSnapshotStore` wraps the DB with a four-method interface. `OrbitShell._bootstrap()` reads the cache first, renders immediately, then fetches live data and silently replaces. Test isolation via an injected no-op stub.

**Tech Stack:** Flutter / Dart, `sqflite ^2.3.3`, `path_provider ^2.1.4`, `path ^1.9.0`, `sqflite_common_ffi ^2.3.4` (tests), `sqlite3_flutter_libs ^0.5.0` (tests on Windows)

---

## File Map

| Action | Path | What changes |
|--------|------|--------------|
| Modify | `app/mobile/pubspec.yaml` | Add sqflite, path_provider, path, dev deps |
| Modify | `app/mobile/lib/core/cluster_domain/cluster_models.dart` | Add `toJson`/`fromJson` to all model classes |
| Create | `app/mobile/lib/core/sync_cache/snapshot_store.dart` | `SnapshotStore` interface + `SqfliteSnapshotStore` impl |
| Modify | `app/mobile/lib/app/clusterorbit_app.dart` | Thread `store` param through to `OrbitShell` |
| Modify | `app/mobile/lib/shared/widgets/orbit_shell.dart` | Add `store` param, rewrite `_bootstrap`, update `_cycleCluster` |
| Modify | `app/mobile/test/test_helpers.dart` | Add `_NoOpSnapshotStore`, inject in `pumpClusterOrbitApp` |
| Create | `app/mobile/test/cluster_models_serialization_test.dart` | Round-trip tests for all `toJson`/`fromJson` methods |
| Create | `app/mobile/test/snapshot_store_test.dart` | Store CRUD tests using in-memory sqflite_common_ffi |

---

## Task 1: Add dependencies

**Files:**
- Modify: `app/mobile/pubspec.yaml`

- [ ] **Step 1: Add runtime and dev dependencies to pubspec.yaml**

Replace the `dependencies` and `dev_dependencies` sections with:

```yaml
dependencies:
  flutter:
    sdk: flutter
  flutter_dotenv: ^5.1.0
  sqflite: ^2.3.3
  path_provider: ^2.1.4
  path: ^1.9.0

dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^4.0.0
  sqflite_common_ffi: ^2.3.4
  sqlite3_flutter_libs: ^0.5.0
```

- [ ] **Step 2: Fetch packages**

Run from `app/mobile/`:
```bash
flutter pub get
```

Expected output ends with: `Got dependencies!`

- [ ] **Step 3: Commit**

```bash
git add app/mobile/pubspec.yaml app/mobile/pubspec.lock
git commit -m "chore: add sqflite, path_provider, and test deps for snapshot cache"
```

---

## Task 2: Serialize domain models

**Files:**
- Modify: `app/mobile/lib/core/cluster_domain/cluster_models.dart`
- Create: `app/mobile/test/cluster_models_serialization_test.dart`

- [ ] **Step 1: Write the failing serialization tests**

Create `app/mobile/test/cluster_models_serialization_test.dart`:

```dart
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
```

- [ ] **Step 2: Run tests — verify they fail**

```bash
flutter test test/cluster_models_serialization_test.dart
```

Expected: FAIL — `The method 'toJson' isn't defined` (or similar).

- [ ] **Step 3: Add toJson/fromJson to cluster_models.dart**

Add the following methods to each class in `app/mobile/lib/core/cluster_domain/cluster_models.dart`. Insert after each class's existing fields. No new imports are needed — `toJson` returns `Map<String, dynamic>` and `fromJson` receives one; no `dart:convert` required in this file.

**ClusterProfile** — add inside the class body after the field declarations:

```dart
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
```

**ClusterNode** — add inside the class body after the field declarations:

```dart
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
```

**ClusterWorkload** — add inside the class body after the field declarations:

```dart
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
```

**ServicePort** — add inside the class body after the field declarations:

```dart
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
```

**ClusterService** — add inside the class body after the field declarations:

```dart
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
```

**ClusterAlert** — add inside the class body after the field declarations:

```dart
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
```

**TopologyLink** — add inside the class body after the field declarations:

```dart
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
```

**ClusterSnapshot** — add inside the class body after the field declarations (before the computed getters):

```dart
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
```

- [ ] **Step 4: Run serialization tests — verify they pass**

```bash
flutter test test/cluster_models_serialization_test.dart
```

Expected: `All tests passed!` (9 tests)

- [ ] **Step 5: Run full test suite — verify nothing regressed**

```bash
flutter test
```

Expected: All tests passed.

- [ ] **Step 6: Commit**

```bash
git add app/mobile/lib/core/cluster_domain/cluster_models.dart \
        app/mobile/test/cluster_models_serialization_test.dart
git commit -m "feat: add toJson/fromJson serialization to all domain model classes"
```

---

## Task 3: Implement SqfliteSnapshotStore

**Files:**
- Create: `app/mobile/lib/core/sync_cache/snapshot_store.dart`
- Create: `app/mobile/test/snapshot_store_test.dart`

- [ ] **Step 1: Write the failing store tests**

Create `app/mobile/test/snapshot_store_test.dart`:

```dart
import 'package:clusterorbit_mobile/core/cluster_domain/cluster_models.dart';
import 'package:clusterorbit_mobile/core/sync_cache/snapshot_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late SqfliteSnapshotStore store;

  setUp(() {
    store = SqfliteSnapshotStore(dbPath: inMemoryDatabasePath);
  });

  const profile = ClusterProfile(
    id: 'p1',
    name: 'Test Cluster',
    apiServerHost: 'host.local',
    environmentLabel: 'Dev',
    connectionMode: ConnectionMode.direct,
  );

  ClusterSnapshot makeSnapshot({DateTime? generatedAt}) => ClusterSnapshot(
        profile: profile,
        generatedAt: generatedAt ?? DateTime.utc(2026, 4, 16),
        nodes: const [],
        workloads: const [],
        services: const [],
        alerts: const [],
        links: const [],
      );

  group('profiles', () {
    test('loadProfiles returns empty list when nothing cached', () async {
      expect(await store.loadProfiles(), isEmpty);
    });

    test('saveProfiles then loadProfiles returns saved profiles', () async {
      await store.saveProfiles([profile]);
      final loaded = await store.loadProfiles();
      expect(loaded.length, 1);
      expect(loaded.first.id, 'p1');
      expect(loaded.first.apiServerHost, 'host.local');
      expect(loaded.first.connectionMode, ConnectionMode.direct);
    });

    test('saveProfiles replaces existing profile on duplicate id', () async {
      await store.saveProfiles([profile]);
      const updated = ClusterProfile(
        id: 'p1',
        name: 'Renamed',
        apiServerHost: 'host2.local',
        environmentLabel: 'Prod',
        connectionMode: ConnectionMode.gateway,
      );
      await store.saveProfiles([updated]);
      final loaded = await store.loadProfiles();
      expect(loaded.length, 1);
      expect(loaded.first.name, 'Renamed');
    });

    test('saveProfiles saves multiple profiles', () async {
      const p2 = ClusterProfile(
        id: 'p2',
        name: 'Second',
        apiServerHost: 'host2.local',
        environmentLabel: 'Prod',
        connectionMode: ConnectionMode.direct,
      );
      await store.saveProfiles([profile, p2]);
      final loaded = await store.loadProfiles();
      expect(loaded.length, 2);
    });
  });

  group('snapshots', () {
    test('loadSnapshot returns null for unknown profile', () async {
      expect(await store.loadSnapshot('nonexistent'), isNull);
    });

    test('saveSnapshot then loadSnapshot returns saved snapshot', () async {
      final snap = makeSnapshot();
      await store.saveSnapshot(snap);
      final loaded = await store.loadSnapshot('p1');
      expect(loaded, isNotNull);
      expect(loaded!.profile.id, 'p1');
      expect(loaded.generatedAt, DateTime.utc(2026, 4, 16));
    });

    test('saveSnapshot replaces existing on duplicate profile_id', () async {
      await store.saveSnapshot(makeSnapshot(generatedAt: DateTime.utc(2026, 4, 16)));
      await store.saveSnapshot(makeSnapshot(generatedAt: DateTime.utc(2026, 4, 17)));
      final loaded = await store.loadSnapshot('p1');
      expect(loaded!.generatedAt, DateTime.utc(2026, 4, 17));
    });
  });
}
```

- [ ] **Step 2: Run tests — verify they fail**

```bash
flutter test test/snapshot_store_test.dart
```

Expected: FAIL — `Target of URI doesn't exist: 'package:clusterorbit_mobile/core/sync_cache/snapshot_store.dart'`

- [ ] **Step 3: Create the snapshot_store.dart implementation**

Create `app/mobile/lib/core/sync_cache/snapshot_store.dart`:

```dart
import 'dart:convert';

import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../cluster_domain/cluster_models.dart';

abstract interface class SnapshotStore {
  Future<List<ClusterProfile>> loadProfiles();
  Future<void> saveProfiles(List<ClusterProfile> profiles);
  Future<ClusterSnapshot?> loadSnapshot(String profileId);
  Future<void> saveSnapshot(ClusterSnapshot snapshot);
}

final class SqfliteSnapshotStore implements SnapshotStore {
  SqfliteSnapshotStore({this.dbPath});

  final String? dbPath;
  Future<Database>? _dbFuture;

  Future<Database> get _db => _dbFuture ??= _openDb();

  Future<Database> _openDb() async {
    final path = dbPath ??
        join((await getApplicationDocumentsDirectory()).path, 'clusterorbit.db');
    return openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE cluster_profiles (
            id        TEXT PRIMARY KEY,
            payload   TEXT NOT NULL,
            cached_at INTEGER NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE cluster_snapshots (
            profile_id   TEXT PRIMARY KEY,
            payload      TEXT NOT NULL,
            generated_at INTEGER NOT NULL,
            cached_at    INTEGER NOT NULL
          )
        ''');
      },
    );
  }

  @override
  Future<List<ClusterProfile>> loadProfiles() async {
    final db = await _db;
    final rows = await db.query('cluster_profiles');
    return rows.map((row) {
      final map = jsonDecode(row['payload'] as String) as Map<String, dynamic>;
      return ClusterProfile.fromJson(map);
    }).toList();
  }

  @override
  Future<void> saveProfiles(List<ClusterProfile> profiles) async {
    final db = await _db;
    final now = DateTime.now().millisecondsSinceEpoch;
    final batch = db.batch();
    for (final profile in profiles) {
      batch.insert(
        'cluster_profiles',
        {
          'id': profile.id,
          'payload': jsonEncode(profile.toJson()),
          'cached_at': now,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  @override
  Future<ClusterSnapshot?> loadSnapshot(String profileId) async {
    final db = await _db;
    final rows = await db.query(
      'cluster_snapshots',
      where: 'profile_id = ?',
      whereArgs: [profileId],
    );
    if (rows.isEmpty) return null;
    try {
      final map =
          jsonDecode(rows.first['payload'] as String) as Map<String, dynamic>;
      return ClusterSnapshot.fromJson(map);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> saveSnapshot(ClusterSnapshot snapshot) async {
    final db = await _db;
    await db.insert(
      'cluster_snapshots',
      {
        'profile_id': snapshot.profile.id,
        'payload': jsonEncode(snapshot.toJson()),
        'generated_at': snapshot.generatedAt.millisecondsSinceEpoch,
        'cached_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }
}
```

- [ ] **Step 4: Run store tests — verify they pass**

```bash
flutter test test/snapshot_store_test.dart
```

Expected: `All tests passed!` (7 tests)

- [ ] **Step 5: Run full test suite — verify nothing regressed**

```bash
flutter test
```

Expected: All tests passed.

- [ ] **Step 6: Commit**

```bash
git add app/mobile/lib/core/sync_cache/snapshot_store.dart \
        app/mobile/test/snapshot_store_test.dart
git commit -m "feat: implement SqfliteSnapshotStore with two-table schema"
```

---

## Task 4: Wire SnapshotStore into OrbitShell

**Files:**
- Modify: `app/mobile/test/test_helpers.dart`
- Modify: `app/mobile/lib/app/clusterorbit_app.dart`
- Modify: `app/mobile/lib/shared/widgets/orbit_shell.dart`

- [ ] **Step 1: Verify existing tests pass before touching OrbitShell**

```bash
flutter test
```

Expected: All tests passed. This is your baseline.

- [ ] **Step 2: Update test_helpers.dart to inject a no-op store**

Replace the entire content of `app/mobile/test/test_helpers.dart` with:

```dart
import 'dart:ui';

import 'package:clusterorbit_mobile/app/clusterorbit_app.dart';
import 'package:clusterorbit_mobile/core/cluster_domain/cluster_models.dart';
import 'package:clusterorbit_mobile/core/connectivity/cluster_connection.dart';
import 'package:clusterorbit_mobile/core/connectivity/sample_cluster_data.dart';
import 'package:clusterorbit_mobile/core/sync_cache/snapshot_store.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> pumpClusterOrbitApp(
  WidgetTester tester, {
  Size? size,
  ClusterConnection? connection,
}) async {
  if (size != null) {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = size;
  }

  await tester.pumpWidget(
    ClusterOrbitApp(
      connection: connection ?? TestClusterConnection(),
      store: _NoOpSnapshotStore(),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> resetTestSurface(WidgetTester tester) async {
  tester.view.resetPhysicalSize();
  tester.view.resetDevicePixelRatio();
  await tester.pump();
}

final class TestClusterConnection implements ClusterConnection {
  final List<ClusterProfile> _profiles =
      SampleClusterData.profilesFor(ConnectionMode.direct);

  @override
  ConnectionMode get mode => ConnectionMode.direct;

  @override
  Future<List<ClusterProfile>> listClusters() async => _profiles;

  @override
  Future<ClusterSnapshot> loadSnapshot(String clusterId) async {
    final profile = _profiles.firstWhere(
      (item) => item.id == clusterId,
      orElse: () => _profiles.first,
    );
    return SampleClusterData.snapshotFor(profile);
  }

  @override
  Stream<ClusterSnapshot> watchSnapshot(String clusterId) async* {
    yield await loadSnapshot(clusterId);
  }
}

final class _NoOpSnapshotStore implements SnapshotStore {
  @override
  Future<List<ClusterProfile>> loadProfiles() async => [];

  @override
  Future<void> saveProfiles(List<ClusterProfile> profiles) async {}

  @override
  Future<ClusterSnapshot?> loadSnapshot(String profileId) async => null;

  @override
  Future<void> saveSnapshot(ClusterSnapshot snapshot) async {}
}
```

- [ ] **Step 3: Add store parameter to ClusterOrbitApp**

Replace the entire content of `app/mobile/lib/app/clusterorbit_app.dart` with:

```dart
import 'package:flutter/material.dart';

import '../core/connectivity/cluster_connection.dart';
import '../core/sync_cache/snapshot_store.dart';
import '../core/theme/clusterorbit_theme.dart';
import '../shared/widgets/orbit_shell.dart';

class ClusterOrbitApp extends StatelessWidget {
  const ClusterOrbitApp({
    super.key,
    this.connection,
    this.store,
  });

  final ClusterConnection? connection;
  final SnapshotStore? store;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ClusterOrbit',
      debugShowCheckedModeBanner: false,
      theme: ClusterOrbitTheme.light(),
      darkTheme: ClusterOrbitTheme.dark(),
      themeMode: ThemeMode.dark,
      home: OrbitShell(connection: connection, store: store),
    );
  }
}
```

- [ ] **Step 4: Rewrite OrbitShell with store wiring**

Replace the entire content of `app/mobile/lib/shared/widgets/orbit_shell.dart` with:

```dart
import 'package:flutter/material.dart';

import '../../core/cluster_domain/cluster_models.dart';
import '../../core/connectivity/cluster_connection.dart';
import '../../core/connectivity/cluster_connection_factory.dart';
import '../../core/sync_cache/snapshot_store.dart';
import '../../core/theme/clusterorbit_theme.dart';
import '../../features/alerts/alerts_screen.dart';
import '../../features/changes/changes_screen.dart';
import '../../features/resources/resources_screen.dart';
import '../../features/settings/settings_screen.dart';
import '../../features/topology/topology_screen.dart';

class OrbitShell extends StatefulWidget {
  const OrbitShell({
    super.key,
    this.connection,
    this.store,
  });

  final ClusterConnection? connection;
  final SnapshotStore? store;

  @override
  State<OrbitShell> createState() => _OrbitShellState();
}

class _OrbitShellState extends State<OrbitShell> {
  int _index = 0;
  late final ClusterConnection _connection;
  late final SnapshotStore _store;
  List<ClusterProfile> _clusters = const [];
  ClusterProfile? _selectedCluster;
  ClusterSnapshot? _snapshot;
  Object? _loadError;
  bool _isLoading = true;

  static const _destinations = [
    NavigationDestination(icon: Icon(Icons.blur_on_outlined), label: 'Map'),
    NavigationDestination(
      icon: Icon(Icons.inventory_2_outlined),
      label: 'Resources',
    ),
    NavigationDestination(
        icon: Icon(Icons.alt_route_outlined), label: 'Changes'),
    NavigationDestination(
      icon: Icon(Icons.warning_amber_outlined),
      label: 'Alerts',
    ),
    NavigationDestination(
        icon: Icon(Icons.settings_outlined), label: 'Settings'),
  ];

  static const _titles = [
    'Cluster Map',
    'Resources',
    'Changes',
    'Alerts',
    'Settings',
  ];

  @override
  void initState() {
    super.initState();
    _connection =
        widget.connection ?? ClusterConnectionFactory.fromEnvironment();
    _store = widget.store ?? SqfliteSnapshotStore();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    // Show cached data immediately if available.
    try {
      final cachedProfiles = await _store.loadProfiles();
      if (cachedProfiles.isNotEmpty) {
        final cachedSnapshot =
            await _store.loadSnapshot(cachedProfiles.first.id);
        if (cachedSnapshot != null && mounted) {
          setState(() {
            _clusters = cachedProfiles;
            _selectedCluster = cachedProfiles.first;
            _snapshot = cachedSnapshot;
            _isLoading = false;
          });
        }
      }
    } catch (_) {
      // DB failure is non-fatal — proceed to live fetch.
    }

    // Fetch live data and silently replace.
    try {
      final clusters = await _connection.listClusters();
      final selectedCluster = clusters.first;
      final snapshot = await _connection.loadSnapshot(selectedCluster.id);

      try {
        await _store.saveProfiles(clusters);
        await _store.saveSnapshot(snapshot);
      } catch (_) {
        // Cache write failure is non-fatal.
      }

      if (!mounted) return;
      setState(() {
        _clusters = clusters;
        _selectedCluster = selectedCluster;
        _snapshot = snapshot;
        _loadError = null;
        _isLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        // Only surface the error if we have nothing to show.
        if (_snapshot == null) _loadError = error;
        _isLoading = false;
      });
    }
  }

  Future<void> _cycleCluster() async {
    if (_clusters.length < 2 || _isLoading || _selectedCluster == null) {
      return;
    }

    final currentIndex = _clusters.indexOf(_selectedCluster!);
    final nextCluster = _clusters[(currentIndex + 1) % _clusters.length];

    // Show cached snapshot for the target cluster immediately if available.
    ClusterSnapshot? cachedSnapshot;
    try {
      cachedSnapshot = await _store.loadSnapshot(nextCluster.id);
    } catch (_) {}

    setState(() {
      _selectedCluster = nextCluster;
      _isLoading = cachedSnapshot == null;
      if (cachedSnapshot != null) _snapshot = cachedSnapshot;
    });

    // Fetch live data and silently replace.
    try {
      final snapshot = await _connection.loadSnapshot(nextCluster.id);

      try {
        await _store.saveSnapshot(snapshot);
      } catch (_) {}

      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
        _loadError = null;
        _isLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        if (_snapshot == null) _loadError = error;
        _isLoading = false;
      });
    }
  }

  List<Widget> _buildScreens() {
    return [
      TopologyScreen(
        snapshot: _snapshot,
        isLoading: _isLoading,
        error: _loadError,
      ),
      const ResourcesScreen(),
      const ChangesScreen(),
      const AlertsScreen(),
      const SettingsScreen(),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final isTablet = MediaQuery.sizeOf(context).width >= 960;
    final palette = Theme.of(context).extension<ClusterOrbitPalette>()!;
    final screens = _buildScreens();
    final subtitle = _selectedCluster == null
        ? 'Preparing ${_connection.mode.label.toLowerCase()} connection'
        : '${_selectedCluster!.apiServerHost} / ${_selectedCluster!.environmentLabel}';

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_titles[_index]),
            Text(
              subtitle,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.white.withValues(alpha: 0.68),
                  ),
            ),
          ],
        ),
        actions: [
          TextButton.icon(
            onPressed: _clusters.isEmpty ? null : _cycleCluster,
            icon: const Icon(Icons.hub_outlined),
            label: const Text('Switch Cluster'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: const Alignment(0.8, -0.9),
            radius: 1.5,
            colors: [
              palette.canvasGlow.withValues(alpha: 0.18),
              Colors.transparent,
            ],
          ),
        ),
        child: SafeArea(
          top: false,
          child:
              isTablet ? _buildTabletLayout(context, screens) : screens[_index],
        ),
      ),
      bottomNavigationBar: isTablet
          ? null
          : NavigationBar(
              selectedIndex: _index,
              destinations: _destinations,
              onDestinationSelected: (value) => setState(() => _index = value),
            ),
    );
  }

  Widget _buildTabletLayout(BuildContext context, List<Widget> screens) {
    return Row(
      children: [
        SizedBox(
          width: 260,
          child: _SideRail(
            selectedIndex: _index,
            titles: _titles,
            clusterCount: _clusters.length,
            nodeCount: _snapshot?.nodes.length ?? 0,
            alertCount: _snapshot?.alerts.length ?? 0,
            onChanged: (value) => setState(() => _index = value),
          ),
        ),
        Expanded(child: screens[_index]),
        SizedBox(
          width: 360,
          child: _InspectorPanel(
            snapshot: _snapshot,
            isLoading: _isLoading,
          ),
        ),
      ],
    );
  }
}

class _SideRail extends StatelessWidget {
  const _SideRail({
    required this.selectedIndex,
    required this.titles,
    required this.clusterCount,
    required this.nodeCount,
    required this.alertCount,
    required this.onChanged,
  });

  final int selectedIndex;
  final List<String> titles;
  final int clusterCount;
  final int nodeCount;
  final int alertCount;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('ClusterOrbit', style: theme.textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(
                'Machine-first cluster visibility with guarded operations.',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 20),
              for (var i = 0; i < titles.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: FilledButton.tonal(
                    onPressed: () => onChanged(i),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(52),
                      alignment: Alignment.centerLeft,
                      backgroundColor: i == selectedIndex
                          ? theme.colorScheme.primary.withValues(alpha: 0.16)
                          : Colors.white.withValues(alpha: 0.04),
                    ),
                    child: Text(titles[i]),
                  ),
                ),
              const Spacer(),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  Chip(label: Text('$clusterCount clusters')),
                  Chip(label: Text('$nodeCount nodes')),
                  Chip(label: Text('$alertCount alerts')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InspectorPanel extends StatelessWidget {
  const _InspectorPanel({
    required this.snapshot,
    required this.isLoading,
  });

  final ClusterSnapshot? snapshot;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controlPlanes = snapshot?.controlPlaneCount ?? 0;
    final workers = snapshot?.workerCount ?? 0;
    final unschedulable = snapshot?.unschedulableNodeCount ?? 0;

    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 20, 20, 20),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Inspector', style: theme.textTheme.titleLarge),
              const SizedBox(height: 12),
              Text(
                isLoading
                    ? 'Loading snapshot details for the selected cluster.'
                    : 'This panel is reserved for node details, config diffs, logs, and guarded actions on tablet layouts.',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 20),
              _MetricTile(label: 'Control planes', value: '$controlPlanes'),
              _MetricTile(label: 'Workers', value: '$workers'),
              _MetricTile(label: 'Unschedulable', value: '$unschedulable'),
              const Spacer(),
              FilledButton.icon(
                onPressed: () {},
                icon: const Icon(Icons.playlist_add_check_circle_outlined),
                label: const Text('Open change preview'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Text(label, style: theme.textTheme.bodyLarge),
          const Spacer(),
          Text(value, style: theme.textTheme.titleLarge),
        ],
      ),
    );
  }
}
```

- [ ] **Step 5: Run full test suite — verify all tests pass**

```bash
flutter test
```

Expected: All tests passed. The no-op store is injected for all widget tests; OrbitShell compiles with the new store wiring.

- [ ] **Step 6: Run dart format and analyze**

```bash
dart format --output=none --set-exit-if-changed lib test
flutter analyze
```

Expected: no format violations, no analyzer issues.

- [ ] **Step 7: Commit**

```bash
git add app/mobile/lib/app/clusterorbit_app.dart \
        app/mobile/lib/shared/widgets/orbit_shell.dart \
        app/mobile/test/test_helpers.dart
git commit -m "feat: wire SqfliteSnapshotStore into OrbitShell; cache-first bootstrap"
```

---

## Final verification

- [ ] **Run the full test suite one last time**

```bash
flutter test
```

Expected: All tests passed (should now be 32 tests: existing 23 + 9 serialization + 7 store = 39 total — exact count may vary).

- [ ] **Run format and analyze**

```bash
dart format --output=none --set-exit-if-changed lib test
flutter analyze
```

Expected: clean.
