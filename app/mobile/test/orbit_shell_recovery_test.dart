import 'package:clusterorbit_mobile/core/cluster_domain/cluster_models.dart';
import 'package:clusterorbit_mobile/core/connectivity/gateway_cluster_connection.dart';
import 'package:clusterorbit_mobile/core/connectivity/sample_cluster_data.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

/// A shell whose first load failed, or found no clusters, says which, and
/// recovers through Retry without an app restart.
void main() {
  final profiles = SampleClusterData.profilesFor(ConnectionMode.direct);
  final unreachable = GatewayException.fromResponse(
    503,
    Uri.parse('https://gw.example.test/v1/clusters'),
    '{"error": "upstream down"}',
  );
  const phone = Size(390, 844);

  testWidgets('a failed bootstrap shows the error with Retry, which recovers',
      (tester) async {
    var fail = true;
    final connection = RecordingClusterConnection()
      ..onListClusters =
          () async => fail ? throw unreachable : profiles.toList();
    await pumpClusterOrbitApp(tester, size: phone, connection: connection);

    expect(
      find.text('Connection failed: Gateway error (503): upstream down'),
      findsOneWidget,
    );
    expect(find.textContaining('gw.example.test'), findsNothing);
    expect(find.text('Connection failed'), findsOneWidget);

    fail = false;
    await tester.tap(find.widgetWithText(FilledButton, 'Retry'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Connection failed'), findsNothing);
    expect(find.textContaining(profiles.first.apiServerHost), findsOneWidget);
    expect(find.byKey(const ValueKey('phone-view-toggle')), findsOneWidget);
    expect(tester.takeException(), isNull);

    await resetTestSurface(tester);
  });

  testWidgets('the other tabs show the readable error too', (tester) async {
    final connection = RecordingClusterConnection()
      ..onListClusters = () async => throw unreachable;
    await pumpClusterOrbitApp(tester, size: phone, connection: connection);

    await tester.tap(find.text('Resources'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Could not load cluster: Gateway error (503): '
          'upstream down.'),
      findsOneWidget,
    );
    expect(find.textContaining('gw.example.test'), findsNothing);

    await resetTestSurface(tester);
  });

  testWidgets('no clusters is told apart from a failure, and Retry re-lists',
      (tester) async {
    var visible = <ClusterProfile>[];
    final connection = RecordingClusterConnection()
      ..onListClusters = () async => visible;
    await pumpClusterOrbitApp(tester, size: phone, connection: connection);

    expect(find.textContaining('No clusters visible.'), findsOneWidget);
    expect(find.text('No clusters visible'), findsOneWidget);
    expect(find.textContaining('Connection failed'), findsNothing);

    visible = profiles.toList();
    await tester.tap(find.widgetWithText(FilledButton, 'Retry'));
    await tester.pumpAndSettle();

    expect(find.textContaining('No clusters visible'), findsNothing);
    expect(find.textContaining(profiles.first.apiServerHost), findsOneWidget);

    await resetTestSurface(tester);
  });
}
