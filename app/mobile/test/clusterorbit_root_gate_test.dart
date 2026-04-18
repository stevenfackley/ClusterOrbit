import 'package:clusterorbit_mobile/app/clusterorbit_root_gate.dart';
import 'package:clusterorbit_mobile/core/cluster_domain/saved_connection.dart';
import 'package:clusterorbit_mobile/core/sync_cache/snapshot_store.dart';
import 'package:clusterorbit_mobile/core/theme/clusterorbit_theme.dart';
import 'package:clusterorbit_mobile/features/onboarding/onboarding_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

void main() {
  testWidgets('empty saved-connection store shows OnboardingScreen',
      (tester) async {
    final store = _FakeSavedStore();
    await tester.pumpWidget(
      MaterialApp(
        theme: ClusterOrbitTheme.dark(),
        home: ClusterOrbitRootGate(
          savedConnectionStore: store,
          snapshotStore: const NoOpSnapshotStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(OnboardingScreen), findsOneWidget);
    expect(find.text('Use sample'), findsOneWidget);
  });

  testWidgets('tapping Use sample writes a connection and leaves onboarding',
      (tester) async {
    final store = _FakeSavedStore();
    await tester.pumpWidget(
      MaterialApp(
        theme: ClusterOrbitTheme.dark(),
        home: ClusterOrbitRootGate(
          savedConnectionStore: store,
          snapshotStore: const NoOpSnapshotStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Use sample'));
    await tester.pumpAndSettle();

    expect(find.byType(OnboardingScreen), findsNothing);
    expect(store.saved.length, 1);
    expect(store.saved.first.kind, SavedConnectionKind.sample);
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

  @override
  Future<void> setActiveConnection(String id) async {
    final idx = saved.indexWhere((c) => c.id == id);
    if (idx <= 0) return;
    final promoted = saved.removeAt(idx);
    saved.insert(0, promoted);
  }
}
