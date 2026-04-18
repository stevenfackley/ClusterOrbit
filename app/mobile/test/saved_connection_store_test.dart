import 'package:clusterorbit_mobile/core/cluster_domain/saved_connection.dart';
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

  const sampleConn = SavedConnection(
    id: 'sample-1',
    displayName: 'Demo data',
    kind: SavedConnectionKind.sample,
  );

  const gatewayConn = SavedConnection(
    id: 'gw-1',
    displayName: 'Prod Gateway',
    kind: SavedConnectionKind.gateway,
    gatewayUrl: 'https://gateway.example.com',
    gatewayToken: 'tok-abc',
  );

  const directConn = SavedConnection(
    id: 'direct-1',
    displayName: 'Local kube',
    kind: SavedConnectionKind.direct,
    kubeconfigYaml: 'apiVersion: v1\n',
    kubeconfigContext: 'minikube',
  );

  group('SavedConnectionStore', () {
    test('listConnections returns empty list on fresh store', () async {
      expect(await store.listConnections(), isEmpty);
    });

    test('saveConnection then listConnections round-trips all kinds', () async {
      await store.saveConnection(sampleConn);
      await store.saveConnection(gatewayConn);
      await store.saveConnection(directConn);
      final loaded = await store.listConnections();
      expect(loaded.length, 3);
      final ids = loaded.map((c) => c.id).toSet();
      expect(ids, {'sample-1', 'gw-1', 'direct-1'});

      final gw = loaded.firstWhere((c) => c.id == 'gw-1');
      expect(gw.kind, SavedConnectionKind.gateway);
      expect(gw.gatewayUrl, 'https://gateway.example.com');
      expect(gw.gatewayToken, 'tok-abc');

      final direct = loaded.firstWhere((c) => c.id == 'direct-1');
      expect(direct.kind, SavedConnectionKind.direct);
      expect(direct.kubeconfigContext, 'minikube');
    });

    test('listConnections orders most-recently-touched first', () async {
      await store.saveConnection(sampleConn);
      // Force a measurable timestamp gap — cheaper than sleeping.
      final db = await store.dbForTest;
      await db.rawUpdate(
        'UPDATE saved_connections SET created_at = ? WHERE id = ?',
        [1, 'sample-1'],
      );
      await store.saveConnection(gatewayConn);
      final loaded = await store.listConnections();
      expect(loaded.map((c) => c.id).toList(), ['gw-1', 'sample-1']);
    });

    test('setActiveConnection promotes target to head of list', () async {
      await store.saveConnection(sampleConn);
      await store.saveConnection(gatewayConn);
      // gateway is currently first (most recent). Promote sample.
      await store.setActiveConnection('sample-1');
      final loaded = await store.listConnections();
      expect(loaded.first.id, 'sample-1');
      expect(loaded.last.id, 'gw-1');
    });

    test('setActiveConnection is a no-op for unknown id', () async {
      await store.saveConnection(sampleConn);
      await store.saveConnection(gatewayConn);
      final before = await store.listConnections();
      await store.setActiveConnection('does-not-exist');
      final after = await store.listConnections();
      expect(after.map((c) => c.id).toList(), before.map((c) => c.id).toList());
    });

    test('saveConnection upserts on duplicate id', () async {
      await store.saveConnection(gatewayConn);
      final renamed = gatewayConn.copyWith(displayName: 'Renamed Gateway');
      await store.saveConnection(renamed);
      final loaded = await store.listConnections();
      expect(loaded.length, 1);
      expect(loaded.first.displayName, 'Renamed Gateway');
    });

    test('deleteConnection removes only the target row', () async {
      await store.saveConnection(sampleConn);
      await store.saveConnection(gatewayConn);
      await store.deleteConnection('sample-1');
      final loaded = await store.listConnections();
      expect(loaded.length, 1);
      expect(loaded.first.id, 'gw-1');
    });

    test('deleteConnection is a no-op for unknown id', () async {
      await store.saveConnection(gatewayConn);
      await store.deleteConnection('does-not-exist');
      expect((await store.listConnections()).length, 1);
    });

    test('listConnections skips corrupted payload row', () async {
      await store.saveConnection(gatewayConn);
      final db = await store.dbForTest;
      final count = await db.rawUpdate(
        "UPDATE saved_connections SET payload = 'not-valid-json' WHERE id = ?",
        ['gw-1'],
      );
      expect(count, 1);
      expect(await store.listConnections(), isEmpty);
    });
  });

  group('SavedConnection serialization', () {
    test('sample round-trips', () {
      final json = sampleConn.toJson();
      expect(json.containsKey('gatewayUrl'), isFalse);
      final restored = SavedConnection.fromJson(json);
      expect(restored.id, sampleConn.id);
      expect(restored.kind, SavedConnectionKind.sample);
    });

    test('gateway round-trips with token + url', () {
      final restored = SavedConnection.fromJson(gatewayConn.toJson());
      expect(restored.gatewayUrl, gatewayConn.gatewayUrl);
      expect(restored.gatewayToken, gatewayConn.gatewayToken);
    });

    test('direct round-trips with kubeconfig yaml + context', () {
      final restored = SavedConnection.fromJson(directConn.toJson());
      expect(restored.kubeconfigYaml, directConn.kubeconfigYaml);
      expect(restored.kubeconfigContext, directConn.kubeconfigContext);
    });

    test('unknown kind name falls back to sample', () {
      final restored = SavedConnection.fromJson({
        'id': 'x',
        'displayName': 'y',
        'kind': 'not-a-kind',
      });
      expect(restored.kind, SavedConnectionKind.sample);
    });
  });

  group('SavedConnection.subtitle', () {
    test('sample', () {
      expect(sampleConn.subtitle, 'Built-in demo data');
    });

    test('gateway with url', () {
      expect(gatewayConn.subtitle, 'https://gateway.example.com');
    });

    test('gateway without url', () {
      const g = SavedConnection(
        id: 'g',
        displayName: 'n',
        kind: SavedConnectionKind.gateway,
      );
      expect(g.subtitle, 'Gateway (no URL)');
    });

    test('direct with context', () {
      expect(directConn.subtitle, 'Kubeconfig · minikube');
    });

    test('direct without context', () {
      const d = SavedConnection(
        id: 'd',
        displayName: 'n',
        kind: SavedConnectionKind.direct,
      );
      expect(d.subtitle, 'Kubeconfig (current-context)');
    });
  });
}
