import 'package:clusterorbit_mobile/core/cluster_domain/saved_connection.dart';
import 'package:clusterorbit_mobile/core/sync_cache/snapshot_store.dart';
import 'package:clusterorbit_mobile/core/theme/clusterorbit_theme.dart';
import 'package:clusterorbit_mobile/features/settings/settings_screen.dart';
import 'package:clusterorbit_mobile/shared/widgets/feature_placeholder.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child) => MaterialApp(
      theme: ClusterOrbitTheme.dark(),
      home: Scaffold(body: child),
    );

void main() {
  testWidgets('renders FeaturePlaceholder when store is null', (tester) async {
    await tester.pumpWidget(_wrap(const SettingsScreen()));
    await tester.pumpAndSettle();

    expect(find.byType(FeaturePlaceholder), findsOneWidget);
  });

  testWidgets('empty store shows "No connections saved yet" copy',
      (tester) async {
    final store = _FakeSavedStore();
    await tester.pumpWidget(_wrap(SettingsScreen(savedConnectionStore: store)));
    await tester.pumpAndSettle();

    expect(find.text('No connections saved yet.'), findsOneWidget);
    expect(find.text('Add Gateway'), findsOneWidget);
    expect(find.text('Add Sample'), findsOneWidget);
  });

  testWidgets('connection tiles render with Active chip on the active one',
      (tester) async {
    final store = _FakeSavedStore()
      ..saved.addAll([
        const SavedConnection(
          id: 'sample-1',
          displayName: 'Demo',
          kind: SavedConnectionKind.sample,
        ),
        const SavedConnection(
          id: 'gw-1',
          displayName: 'Prod Gateway',
          kind: SavedConnectionKind.gateway,
          gatewayUrl: 'https://gw.example.com',
        ),
      ]);

    await tester.pumpWidget(_wrap(
      SettingsScreen(
        savedConnectionStore: store,
        activeConnectionId: 'sample-1',
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Demo'), findsOneWidget);
    expect(find.text('Prod Gateway'), findsOneWidget);
    expect(find.text('Active'), findsOneWidget);
  });

  testWidgets('tapping Add Sample writes a sample and refreshes the list',
      (tester) async {
    final store = _FakeSavedStore();
    var changedCount = 0;
    await tester.pumpWidget(_wrap(
      SettingsScreen(
        savedConnectionStore: store,
        onConnectionsChanged: () => changedCount++,
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add Sample'));
    await tester.pumpAndSettle();

    expect(store.saved.length, 1);
    expect(store.saved.first.kind, SavedConnectionKind.sample);
    expect(changedCount, 1);
    expect(find.text('Sample data'), findsOneWidget);
  });

  testWidgets('delete flow requires confirmation then removes the row',
      (tester) async {
    final store = _FakeSavedStore()
      ..saved.add(const SavedConnection(
        id: 'gw-1',
        displayName: 'Prod Gateway',
        kind: SavedConnectionKind.gateway,
        gatewayUrl: 'https://gw.example.com',
      ));
    await tester.pumpWidget(_wrap(
      SettingsScreen(savedConnectionStore: store),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    expect(find.text('Remove connection?'), findsOneWidget);

    // Cancel first — should keep the row.
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(store.saved.length, 1);

    // Now confirm.
    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();

    expect(store.saved, isEmpty);
    expect(find.text('No connections saved yet.'), findsOneWidget);
  });
}

final class _FakeSavedStore implements SavedConnectionStore {
  final List<SavedConnection> saved = [];

  @override
  Future<List<SavedConnection>> listConnections() async => List.of(saved);

  @override
  Future<void> saveConnection(SavedConnection connection) async {
    saved.removeWhere((c) => c.id == connection.id);
    saved.add(connection);
  }

  @override
  Future<void> deleteConnection(String id) async {
    saved.removeWhere((c) => c.id == id);
  }
}
