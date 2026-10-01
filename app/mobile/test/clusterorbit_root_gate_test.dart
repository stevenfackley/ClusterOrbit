import 'package:clusterorbit_mobile/app/clusterorbit_root_gate.dart';
import 'package:clusterorbit_mobile/core/cluster_domain/cluster_models.dart';
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

  testWidgets("the shell caches under the active connection's scope",
      (tester) async {
    final savedStore = _FakeSavedStore();
    await savedStore.saveConnection(
      const SavedConnection(
        id: 'sample-1',
        displayName: 'Sample',
        kind: SavedConnectionKind.sample,
      ),
    );
    final snapshotStore = _RecordingSnapshotStore();
    await tester.pumpWidget(
      MaterialApp(
        theme: ClusterOrbitTheme.dark(),
        home: ClusterOrbitRootGate(
          savedConnectionStore: savedStore,
          snapshotStore: snapshotStore,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(snapshotStore.savedProfileIds, isNotEmpty);
    expect(
        snapshotStore.savedProfileIds, everyElement(startsWith('sample-1|')));
  });
}

/// Records the profile ids the shell writes to the shared cache.
final class _RecordingSnapshotStore implements SnapshotStore {
  final List<String> savedProfileIds = [];

  @override
  Future<List<ClusterProfile>> loadProfiles({Duration? maxAge}) async =>
      const [];

  @override
  Future<void> saveProfiles(List<ClusterProfile> profiles) async =>
      savedProfileIds.addAll(profiles.map((p) => p.id));

  @override
  Future<void> deleteProfiles(Iterable<String> ids) async {}

  @override
  Future<ClusterSnapshot?> loadSnapshot(
    String profileId, {
    Duration? maxAge,
  }) async =>
      null;

  @override
  Future<void> saveSnapshot(ClusterSnapshot snapshot) async {}

  @override
  Future<List<ClusterEvent>?> loadEvents({
    required String profileId,
    required TopologyEntityKind kind,
    required String objectName,
    String? namespace,
    Duration? maxAge,
  }) async =>
      null;

  @override
  Future<void> saveEvents({
    required String profileId,
    required TopologyEntityKind kind,
    required String objectName,
    String? namespace,
    required List<ClusterEvent> events,
  }) async {}
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
