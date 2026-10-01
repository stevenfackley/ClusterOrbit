import 'package:clusterorbit_mobile/core/cluster_domain/cluster_models.dart';
import 'package:clusterorbit_mobile/core/connectivity/gateway_cluster_connection.dart';
import 'package:clusterorbit_mobile/core/connectivity/sample_cluster_data.dart';
import 'package:clusterorbit_mobile/core/theme/clusterorbit_theme.dart';
import 'package:clusterorbit_mobile/features/alerts/alerts_screen.dart';
import 'package:clusterorbit_mobile/features/changes/changes_screen.dart';
import 'package:clusterorbit_mobile/features/onboarding/onboarding_screen.dart';
import 'package:clusterorbit_mobile/features/resources/resources_screen.dart';
import 'package:clusterorbit_mobile/features/settings/settings_screen.dart';
import 'package:clusterorbit_mobile/features/topology/topology_list_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

Widget _wrap(Widget child, {double textScale = 1.0}) => MaterialApp(
      theme: ClusterOrbitTheme.dark(),
      builder: (context, app) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
        ),
        child: app!,
      ),
      home: Scaffold(body: child),
    );

void _setSize(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
}

Color _warning() =>
    ClusterOrbitTheme.dark().extension<ClusterOrbitPalette>()!.warning;

void main() {
  final profiles = SampleClusterData.profilesFor(ConnectionMode.direct);
  final snapshot = SampleClusterData.snapshotFor(profiles.first);

  group('Switch Cluster', () {
    Future<void> pumpWith(
      WidgetTester tester,
      Size size,
      List<ClusterProfile> visible,
    ) async {
      final connection = RecordingClusterConnection()
        ..onListClusters = () async => visible;
      await pumpClusterOrbitApp(tester, size: size, connection: connection);
    }

    final phoneButton = find.widgetWithIcon(IconButton, Icons.hub_outlined);

    testWidgets('is enabled with several clusters', (tester) async {
      await pumpWith(tester, const Size(390, 844), profiles);
      expect(tester.widget<IconButton>(phoneButton).onPressed, isNotNull);
    });

    testWidgets('is disabled with one cluster on a phone', (tester) async {
      await pumpWith(tester, const Size(390, 844), [profiles.first]);
      expect(tester.widget<IconButton>(phoneButton).onPressed, isNull);
    });

    testWidgets('is disabled with one cluster on a wide screen',
        (tester) async {
      await pumpWith(tester, const Size(1280, 800), [profiles.first]);
      final button = find.widgetWithText(TextButton, 'Switch Cluster');
      expect(tester.widget<TextButton>(button).onPressed, isNull);
    });
  });

  testWidgets('the AppBar subtitle leads with the environment label',
      (tester) async {
    await pumpClusterOrbitApp(tester, size: const Size(390, 844));
    final p = profiles.first;
    expect(
      find.text('${p.environmentLabel} · ${p.apiServerHost}'),
      findsOneWidget,
    );
  });

  testWidgets('NoSnapshotView does not double a trailing period',
      (tester) async {
    await tester.pumpWidget(_wrap(ResourcesScreen(
      error: GatewayException('Gateway URL is not configured.'),
      onRefresh: () async {},
    )));
    await tester.pumpAndSettle();

    expect(
      find.text('Could not load cluster: Gateway URL is not configured. '
          'Pull to retry.'),
      findsOneWidget,
    );
  });

  testWidgets('Changes warning icons use the palette warning colour',
      (tester) async {
    _setSize(tester, const Size(1280, 900));
    await tester.pumpWidget(_wrap(ChangesScreen(snapshot: snapshot)));
    await tester.pumpAndSettle();

    for (final icon in [Icons.sync_problem_outlined, Icons.block_outlined]) {
      expect(tester.widget<Icon>(find.byIcon(icon).first).color, _warning());
    }
  });

  testWidgets('the list view tints Unschedulable with the palette warning',
      (tester) async {
    _setSize(tester, const Size(400, 820));
    await tester.pumpWidget(_wrap(TopologyListView(
      snapshot: snapshot,
      connection: TestClusterConnection(),
      clusterId: profiles.first.id,
    )));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Unschedulable'),
      200,
      scrollable: find.byType(Scrollable).first,
    );

    expect(tester.widget<Text>(find.text('Unschedulable')).style?.color,
        _warning());
  });

  testWidgets('onboarding cards fit at 320dp and 2x text, button below text',
      (tester) async {
    _setSize(tester, const Size(320, 640));
    await tester.pumpWidget(MaterialApp(
      theme: ClusterOrbitTheme.dark(),
      builder: (context, app) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: const TextScaler.linear(2.0)),
        child: app!,
      ),
      home: OnboardingScreen(onAddConnection: (_) async {}),
    ));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final subtitle = tester.getRect(find.textContaining('sample').first);
    final button =
        tester.getRect(find.widgetWithText(FilledButton, 'Use sample'));
    expect(button.top, greaterThanOrEqualTo(subtitle.bottom));
  });

  testWidgets('alert detail sheet scrolls at 320dp and 2x text',
      (tester) async {
    _setSize(tester, const Size(320, 640));
    await tester
        .pumpWidget(_wrap(AlertsScreen(snapshot: snapshot), textScale: 2.0));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(ListTile).first);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('the Settings placeholder scrolls on a short landscape screen',
      (tester) async {
    _setSize(tester, const Size(844, 390));
    await tester.pumpWidget(_wrap(const SettingsScreen(), textScale: 2.0));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
