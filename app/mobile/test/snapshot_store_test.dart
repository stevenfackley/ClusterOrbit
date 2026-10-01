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

  tearDown(() async {
    final db = await store.dbForTest;
    await db.close();
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

    test('saveProfiles with empty list is a no-op (does not clear existing)',
        () async {
      await store.saveProfiles([profile]);
      await store.saveProfiles([]);
      final loaded = await store.loadProfiles();
      // saveProfiles([]) is an upsert no-op — it does NOT delete existing rows.
      expect(loaded.length, 1);
    });

    test('loadProfiles returns the newest save first, in saved order',
        () async {
      const p2 = ClusterProfile(
        id: 'p2',
        name: 'Second',
        apiServerHost: 'host2.local',
        environmentLabel: 'Prod',
        connectionMode: ConnectionMode.direct,
      );
      const p3 = ClusterProfile(
        id: 'p3',
        name: 'Third',
        apiServerHost: 'host3.local',
        environmentLabel: 'Prod',
        connectionMode: ConnectionMode.direct,
      );
      await store.saveProfiles([profile]);
      final db = await store.dbForTest;
      await db.rawUpdate('UPDATE cluster_profiles SET cached_at = 1');
      await store.saveProfiles([p3, p2]);

      final loaded = await store.loadProfiles();
      expect(loaded.map((p) => p.id), ['p3', 'p2', 'p1']);
    });

    test('deleteProfiles drops only the given ids', () async {
      const p2 = ClusterProfile(
        id: 'p2',
        name: 'Second',
        apiServerHost: 'host2.local',
        environmentLabel: 'Prod',
        connectionMode: ConnectionMode.direct,
      );
      await store.saveProfiles([profile, p2]);
      await store.deleteProfiles(['p1', 'unknown']);
      final loaded = await store.loadProfiles();
      expect(loaded.map((p) => p.id), ['p2']);
    });

    test('loadProfiles skips corrupted payload row', () async {
      await store.saveProfiles([profile]);
      final db = await store.dbForTest;
      final count = await db.rawUpdate(
        "UPDATE cluster_profiles SET payload = 'not-valid-json' WHERE id = 'p1'",
      );
      expect(count, 1, reason: 'update should have modified exactly one row');
      final loaded = await store.loadProfiles();
      expect(loaded, isEmpty);
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
      await store
          .saveSnapshot(makeSnapshot(generatedAt: DateTime.utc(2026, 4, 16)));
      await store
          .saveSnapshot(makeSnapshot(generatedAt: DateTime.utc(2026, 4, 17)));
      final loaded = await store.loadSnapshot('p1');
      expect(loaded!.generatedAt, DateTime.utc(2026, 4, 17));
    });

    test('loadSnapshot returns null for corrupted payload', () async {
      await store.saveSnapshot(makeSnapshot());
      final db = await store.dbForTest;
      final count = await db.rawUpdate(
        "UPDATE cluster_snapshots SET payload = 'not-valid-json' WHERE profile_id = 'p1'",
      );
      expect(count, 1, reason: 'update should have modified exactly one row');
      expect(await store.loadSnapshot('p1'), isNull);
    });
  });

  group('ScopedSnapshotStore', () {
    // Prefix-adjacent ids: purging gateway-1 must not touch gateway-12.
    late ScopedSnapshotStore storeA;
    late ScopedSnapshotStore storeB;

    setUp(() {
      storeA = ScopedSnapshotStore(store, 'gateway-1');
      storeB = ScopedSnapshotStore(store, 'gateway-12');
    });

    ClusterProfile cluster(String id, String name) => ClusterProfile(
          id: id,
          name: name,
          apiServerHost: 'host.local',
          environmentLabel: 'Dev',
          connectionMode: ConnectionMode.gateway,
        );

    ClusterSnapshot snapshotOf(ClusterProfile cluster) => ClusterSnapshot(
          profile: cluster,
          generatedAt: DateTime.utc(2026, 4, 16),
          nodes: const [],
          workloads: const [],
          services: const [],
          alerts: const [],
          links: const [],
        );

    final event = ClusterEvent(
      type: ClusterEventType.warning,
      reason: 'BackOff',
      message: 'Back-off restarting failed container',
      lastTimestamp: DateTime.utc(2026, 4, 16),
      count: 3,
    );

    Future<void> cacheEverything(ScopedSnapshotStore scope, String name) async {
      final dev = cluster('dev', name);
      await scope.saveProfiles([dev]);
      await scope.saveSnapshot(snapshotOf(dev));
      await scope.saveEvents(
        profileId: 'dev',
        kind: TopologyEntityKind.node,
        objectName: 'node-1',
        events: [event],
      );
    }

    Future<List<ClusterEvent>?> loadEvents(ScopedSnapshotStore scope) =>
        scope.loadEvents(
          profileId: 'dev',
          kind: TopologyEntityKind.node,
          objectName: 'node-1',
        );

    test("connections sharing a cluster id never see each other's cache",
        () async {
      await cacheEverything(storeA, 'Dev on A');

      expect(await storeB.loadProfiles(), isEmpty);
      expect(await storeB.loadSnapshot('dev'), isNull);
      expect(await loadEvents(storeB), isNull);

      await cacheEverything(storeB, 'Dev on B');

      final profilesA = await storeA.loadProfiles();
      expect(profilesA.single.id, 'dev');
      expect(profilesA.single.name, 'Dev on A');
      expect((await storeB.loadProfiles()).single.name, 'Dev on B');

      final snapshotA = await storeA.loadSnapshot('dev');
      expect(snapshotA!.profile.id, 'dev');
      expect(snapshotA.profile.name, 'Dev on A');
      expect((await loadEvents(storeA))!.single.reason, 'BackOff');
    });

    test("saveProfiles replaces the connection's cluster list", () async {
      await storeB.saveProfiles([cluster('dev', 'Dev on B')]);
      await storeA.saveProfiles([
        cluster('dev', 'Dev on A'),
        cluster('staging', 'Staging on A'),
      ]);

      await storeA.saveProfiles([cluster('staging', 'Staging on A')]);

      expect((await storeA.loadProfiles()).map((p) => p.id), ['staging']);
      expect((await storeB.loadProfiles()).single.name, 'Dev on B');
    });

    test("deleteConnection purges only that connection's cache", () async {
      await cacheEverything(storeA, 'Dev on A');
      await cacheEverything(storeB, 'Dev on B');

      await store.deleteConnection('gateway-1');

      expect(await storeA.loadProfiles(), isEmpty);
      expect(await storeA.loadSnapshot('dev'), isNull);
      expect(await loadEvents(storeA), isNull);
      expect((await storeB.loadProfiles()).single.name, 'Dev on B');
      expect(await storeB.loadSnapshot('dev'), isNotNull);
      expect(await loadEvents(storeB), isNotNull);
    });
  });

  group('cache TTL', () {
    test('loadSnapshot returns snapshot when within maxAge', () async {
      await store.saveSnapshot(makeSnapshot());
      final loaded = await store.loadSnapshot(
        'p1',
        maxAge: const Duration(minutes: 10),
      );
      expect(loaded, isNotNull);
    });

    test('loadSnapshot returns null when cached_at older than maxAge',
        () async {
      await store.saveSnapshot(makeSnapshot());
      final db = await store.dbForTest;
      // Backdate cached_at to one hour ago.
      final oneHourAgo = DateTime.now()
          .subtract(const Duration(hours: 1))
          .millisecondsSinceEpoch;
      await db.rawUpdate(
        'UPDATE cluster_snapshots SET cached_at = ? WHERE profile_id = ?',
        [oneHourAgo, 'p1'],
      );
      final loaded = await store.loadSnapshot(
        'p1',
        maxAge: const Duration(minutes: 10),
      );
      expect(loaded, isNull);
    });

    test('loadProfiles filters rows older than maxAge', () async {
      await store.saveProfiles([profile]);
      final db = await store.dbForTest;
      final oneHourAgo = DateTime.now()
          .subtract(const Duration(hours: 1))
          .millisecondsSinceEpoch;
      await db.rawUpdate(
        'UPDATE cluster_profiles SET cached_at = ? WHERE id = ?',
        [oneHourAgo, 'p1'],
      );
      final loaded =
          await store.loadProfiles(maxAge: const Duration(minutes: 10));
      expect(loaded, isEmpty);
    });

    test('loadProfiles returns all rows when maxAge is null', () async {
      await store.saveProfiles([profile]);
      final db = await store.dbForTest;
      final oneHourAgo = DateTime.now()
          .subtract(const Duration(hours: 1))
          .millisecondsSinceEpoch;
      await db.rawUpdate(
        'UPDATE cluster_profiles SET cached_at = ? WHERE id = ?',
        [oneHourAgo, 'p1'],
      );
      final loaded = await store.loadProfiles();
      expect(loaded.length, 1);
    });
  });
}
