import 'package:clusterorbit_mobile/core/cluster_domain/cluster_models.dart';
import 'package:clusterorbit_mobile/core/connectivity/cluster_connection.dart';
import 'package:clusterorbit_mobile/core/connectivity/sample_cluster_data.dart';
import 'package:clusterorbit_mobile/core/theme/clusterorbit_theme.dart';
import 'package:clusterorbit_mobile/features/topology/topology_orbs.dart';
import 'package:clusterorbit_mobile/features/topology/topology_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

/// The selection is held by entity kind and id, so it survives refreshes,
/// and a cluster switch drops it.
void main() {
  final profiles = SampleClusterData.profilesFor(ConnectionMode.direct);
  final dev = SampleClusterData.snapshotFor(profiles[0]);
  final staging = SampleClusterData.snapshotFor(profiles[1]);

  Future<void> pumpScreen(
    WidgetTester tester,
    ClusterSnapshot snapshot,
    ClusterConnection connection,
  ) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1400, 900);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: ClusterOrbitTheme.dark(),
        home: Scaffold(
          body: TopologyScreen(
            snapshot: snapshot,
            isLoading: false,
            error: null,
            connection: connection,
            clusterId: snapshot.profile.id,
            store: const NoOpSnapshotStore(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  bool highlighted(WidgetTester tester, String nodeId) => tester
      .widget<NodeOrb>(find.byWidgetPredicate(
          (widget) => widget is NodeOrb && widget.node.id == nodeId))
      .selected;

  testWidgets('a refresh with new objects keeps the highlight and the events',
      (tester) async {
    final connection = RecordingClusterConnection();
    await pumpScreen(tester, dev, connection);

    await tester.tap(find.text('cp-1.dev-orbit'));
    await tester.pumpAndSettle();
    expect(highlighted(tester, 'cp-1'), isTrue);
    expect(find.text('Cordon'), findsOneWidget);
    expect(connection.callsTo('loadEvents'), hasLength(1));

    // Same cluster, new objects, and cp-1 cordoned in the meantime.
    await pumpScreen(
        tester, refreshedSnapshot(dev, cordon: 'cp-1'), connection);

    expect(highlighted(tester, 'cp-1'), isTrue);
    // The panel shows the refreshed node...
    expect(find.text('Uncordon'), findsOneWidget);
    expect(find.text('Cordon'), findsNothing);
    // ...without reloading its events.
    expect(connection.callsTo('loadEvents'), hasLength(1));
  });

  testWidgets('a cluster switch clears the selection and its pending mutation',
      (tester) async {
    final connection = RecordingClusterConnection();
    await pumpScreen(tester, dev, connection);

    await tester.tap(find.text('cp-1.dev-orbit'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cordon'));
    await tester.pumpAndSettle();
    expect(find.text('Cordon cp-1.dev-orbit?'), findsOneWidget);

    // Staging has a cp-1 too.
    await pumpScreen(tester, staging, connection);

    expect(find.text('K8s Version'), findsNothing);
    expect(highlighted(tester, 'cp-1'), isFalse);

    // Confirming the dialog left over from dev reaches no cluster.
    await tester.tap(find.widgetWithText(FilledButton, 'Cordon'));
    await tester.pumpAndSettle();
    expect(connection.callsTo('setNodeSchedulable'), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the selection clears when its entity leaves the snapshot',
      (tester) async {
    final connection = RecordingClusterConnection();
    await pumpScreen(tester, dev, connection);

    await tester.tap(find.text('cp-1.dev-orbit'));
    await tester.pumpAndSettle();
    expect(find.text('K8s Version'), findsOneWidget);

    await pumpScreen(tester, refreshedSnapshot(dev, drop: 'cp-1'), connection);
    expect(find.text('K8s Version'), findsNothing);

    // It stays cleared when the entity comes back.
    await pumpScreen(tester, refreshedSnapshot(dev), connection);
    expect(find.text('K8s Version'), findsNothing);
    expect(highlighted(tester, 'cp-1'), isFalse);
  });
}
