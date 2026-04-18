import 'package:clusterorbit_mobile/core/cluster_domain/cluster_models.dart';
import 'package:clusterorbit_mobile/core/connectivity/sample_cluster_data.dart';
import 'package:clusterorbit_mobile/core/theme/clusterorbit_theme.dart';
import 'package:clusterorbit_mobile/features/alerts/alert_detail_sheet.dart';
import 'package:clusterorbit_mobile/features/alerts/alerts_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _buildApp(ClusterSnapshot? snapshot) => MaterialApp(
      theme: ClusterOrbitTheme.dark(),
      home: Scaffold(body: AlertsScreen(snapshot: snapshot)),
    );

void main() {
  final profile = SampleClusterData.profilesFor(ConnectionMode.direct).first;
  final snapshot = SampleClusterData.snapshotFor(profile);

  testWidgets('tapping an alert opens sheet with title and summary',
      (tester) async {
    await tester.pumpWidget(_buildApp(snapshot));

    // Grab first alert that is visible in the list.
    final firstAlert = ([...snapshot.alerts]..sort((a, b) => switch (b.level) {
              ClusterHealthLevel.critical => 2,
              ClusterHealthLevel.warning => 1,
              ClusterHealthLevel.healthy => 0,
            }
                .compareTo(switch (a.level) {
              ClusterHealthLevel.critical => 2,
              ClusterHealthLevel.warning => 1,
              ClusterHealthLevel.healthy => 0,
            })))
        .first;

    await tester.tap(find.text(firstAlert.title).first);
    await tester.pumpAndSettle();

    expect(find.byType(AlertDetailSheet), findsOneWidget);
    expect(find.text(firstAlert.title), findsWidgets);
    expect(find.text(firstAlert.summary), findsWidgets);
  });

  testWidgets('sheet shows Acknowledge and Silence for 1h buttons',
      (tester) async {
    await tester.pumpWidget(_buildApp(snapshot));

    final firstAlert = snapshot.alerts.first;
    await tester.tap(find.text(firstAlert.title).first);
    await tester.pumpAndSettle();

    expect(find.text('Acknowledge'), findsOneWidget);
    expect(find.text('Silence for 1h'), findsOneWidget);
  });

  testWidgets('tapping Acknowledge pops sheet and shows SnackBar',
      (tester) async {
    await tester.pumpWidget(_buildApp(snapshot));

    final firstAlert = snapshot.alerts.first;
    await tester.tap(find.text(firstAlert.title).first);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Acknowledge'));
    await tester.pumpAndSettle();

    // Sheet gone.
    expect(find.byType(AlertDetailSheet), findsNothing);
    // SnackBar visible with stub message.
    expect(
      find.text('Acknowledge is not yet wired — see roadmap'),
      findsOneWidget,
    );
  });

  testWidgets('empty-alerts state does not show sheet on any tap',
      (tester) async {
    final emptySnapshot = ClusterSnapshot(
      profile: profile,
      generatedAt: DateTime.now(),
      nodes: const [],
      workloads: const [],
      services: const [],
      alerts: const [],
      links: const [],
    );

    await tester.pumpWidget(_buildApp(emptySnapshot));

    // No ListTile to tap — verify sheet never appears.
    expect(find.byType(AlertDetailSheet), findsNothing);
    expect(find.byType(ListTile), findsNothing);
  });
}
