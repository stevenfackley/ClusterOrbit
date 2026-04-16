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

    test('loadProfiles skips corrupted payload row', () async {
      // Write a valid profile first via the public API.
      await store.saveProfiles([profile]);
      // Corrupt the payload directly in the DB.
      final db = await store.dbForTest;
      final count = await db.rawUpdate(
        "UPDATE cluster_profiles SET payload = 'not-valid-json' WHERE id = 'p1'",
      );
      expect(count, 1, reason: 'update should have modified exactly one row');
      // loadProfiles should skip the corrupted row and return empty.
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
  });
}
