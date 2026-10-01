import 'dart:async';

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

  testWidgets('Make active button promotes the connection and fires callback',
      (tester) async {
    final store = _FakeSavedStore()
      ..saved.addAll([
        const SavedConnection(
          id: 'gw-1',
          displayName: 'Prod Gateway',
          kind: SavedConnectionKind.gateway,
          gatewayUrl: 'https://gw.example.com',
        ),
        const SavedConnection(
          id: 'sample-1',
          displayName: 'Demo',
          kind: SavedConnectionKind.sample,
        ),
      ]);
    var changedCount = 0;
    await tester.pumpWidget(_wrap(
      SettingsScreen(
        savedConnectionStore: store,
        activeConnectionId: 'gw-1',
        onConnectionsChanged: () => changedCount++,
      ),
    ));
    await tester.pumpAndSettle();

    // Only the non-active tile (sample) has the Make active button.
    expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);

    await tester.tap(find.byIcon(Icons.check_circle_outline));
    await tester.pumpAndSettle();

    expect(store.saved.first.id, 'sample-1');
    expect(changedCount, 1);
  });

  testWidgets('delete flow requires confirmation then removes the row',
      (tester) async {
    final store = _FakeSavedStore()
      ..saved.addAll([
        const SavedConnection(
          id: 'gw-1',
          displayName: 'Prod Gateway',
          kind: SavedConnectionKind.gateway,
          gatewayUrl: 'https://gw.example.com',
        ),
        const SavedConnection(
          id: 'sample-1',
          displayName: 'Demo',
          kind: SavedConnectionKind.sample,
        ),
      ]);
    await tester.pumpWidget(_wrap(
      SettingsScreen(savedConnectionStore: store),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.delete_outline).first);
    await tester.pumpAndSettle();
    expect(find.text('Remove connection?'), findsOneWidget);

    // Cancel first — should keep the row.
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(store.saved.length, 2);

    // Now confirm.
    await tester.tap(find.byIcon(Icons.delete_outline).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();

    expect(store.saved.length, 1);
    expect(store.saved.first.id, 'sample-1');
  });

  testWidgets('delete is disabled when only one connection remains',
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

    // Find the single delete IconButton and confirm it is disabled.
    final deleteButton = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.delete_outline),
    );
    expect(deleteButton.onPressed, isNull);
    expect(deleteButton.tooltip, contains('Cannot remove'));

    // Tapping it should be a no-op — confirmation dialog must not appear.
    await tester.tap(find.byIcon(Icons.delete_outline), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.text('Remove connection?'), findsNothing);
    expect(store.saved.length, 1);
  });

  testWidgets('listConnections failure shows an error with Retry',
      (tester) async {
    final store = _FakeSavedStore()..failListings = 1;
    await tester.pumpWidget(_wrap(SettingsScreen(savedConnectionStore: store)));
    await tester.pumpAndSettle();

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.textContaining('Could not load saved connections'),
        findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(find.text('Add Sample'), findsOneWidget);
  });

  testWidgets('failed save shows a SnackBar and skips the callback',
      (tester) async {
    final store = _FakeSavedStore()..failSaves = true;
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

    expect(find.textContaining('Could not update connections'), findsOneWidget);
    expect(changedCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Add Sample is disabled while a save is in flight',
      (tester) async {
    final store = _FakeSavedStore()..saveGate = Completer<void>();
    await tester.pumpWidget(_wrap(SettingsScreen(savedConnectionStore: store)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add Sample'));
    await tester.pump();
    final button = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Add Sample'),
    );
    expect(button.onPressed, isNull);

    store.saveGate!.complete();
    await tester.pumpAndSettle();
    expect(store.saved.length, 1);
  });
}

final class _FakeSavedStore implements SavedConnectionStore {
  final List<SavedConnection> saved = [];
  int failListings = 0;
  bool failSaves = false;
  Completer<void>? saveGate;

  @override
  Future<List<SavedConnection>> listConnections() async {
    if (failListings > 0) {
      failListings--;
      throw StateError('db locked');
    }
    return List.of(saved);
  }

  @override
  Future<void> saveConnection(SavedConnection connection) async {
    if (failSaves) throw StateError('disk full');
    await saveGate?.future;
    saved.removeWhere((c) => c.id == connection.id);
    saved.add(connection);
  }

  @override
  Future<void> deleteConnection(String id) async {
    saved.removeWhere((c) => c.id == id);
  }

  @override
  Future<void> setActiveConnection(String id) async {
    final idx = saved.indexWhere((c) => c.id == id);
    if (idx <= 0) return;
    final promoted = saved.removeAt(idx);
    saved.insert(0, promoted);
  }
}
