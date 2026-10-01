import 'package:clusterorbit_mobile/app/clusterorbit_root_gate.dart';
import 'package:clusterorbit_mobile/core/cluster_domain/saved_connection.dart';
import 'package:clusterorbit_mobile/core/theme/clusterorbit_theme.dart';
import 'package:clusterorbit_mobile/features/onboarding/onboarding_screen.dart';
import 'package:clusterorbit_mobile/shared/widgets/orbit_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

void main() {
  testWidgets('empty saved-connection store shows OnboardingScreen',
      (tester) async {
    final store = InMemorySavedConnectionStore();
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
    final store = InMemorySavedConnectionStore();
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

  testWidgets('listConnections failure shows an error with Retry',
      (tester) async {
    final store = InMemorySavedConnectionStore()..failListings = 1;
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

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.textContaining('Could not load saved connections'),
        findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(find.byType(OnboardingScreen), findsOneWidget);
  });

  testWidgets('Use sample failure shows a SnackBar and stays on onboarding',
      (tester) async {
    final store = InMemorySavedConnectionStore()..failSaves = true;
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

    expect(find.byType(OnboardingScreen), findsOneWidget);
    expect(find.textContaining('Could not add connection'), findsOneWidget);
  });

  testWidgets('a connection added from Settings becomes the active shell',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = InMemorySavedConnectionStore()
      ..saved.add(const SavedConnection(
        id: 'old',
        displayName: 'Old sample',
        kind: SavedConnectionKind.sample,
      ));
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
    expect(
        tester.widget<OrbitShell>(find.byType(OrbitShell)).activeConnectionId,
        'old');

    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add Sample'));
    await tester.pumpAndSettle();

    // saveConnection inserts at index 0, so the new row drives the shell.
    expect(store.saved.length, 2);
    final shell = tester.widget<OrbitShell>(find.byType(OrbitShell));
    expect(shell.activeConnectionId, store.saved.first.id);
    expect(shell.activeConnectionId, isNot('old'));

    await tester.pumpWidget(const SizedBox());
  });
}
