import 'package:clusterorbit_mobile/core/cluster_domain/saved_connection.dart';
import 'package:clusterorbit_mobile/core/connectivity/cluster_connection_factory.dart';
import 'package:clusterorbit_mobile/core/theme/clusterorbit_theme.dart';
import 'package:clusterorbit_mobile/features/onboarding/onboarding_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// In-memory stub for [GatewayHttpClient]. Tests set [getResponse] or
/// [getError] to control what `listClusters()` sees.
class _FakeHttpClient implements GatewayHttpClient {
  _FakeHttpClient({this.getResponse, this.getError});

  dynamic getResponse;
  Object? getError;

  @override
  Future<dynamic> getJson(Uri url, {Map<String, String> headers = const {}}) {
    if (getError != null) return Future.error(getError!);
    return Future.value(getResponse);
  }

  @override
  Future<dynamic> postJson(
    Uri url, {
    Map<String, String> headers = const {},
    required Map<String, dynamic> body,
  }) async =>
      null;
}

Widget _wrap(AddGatewayScreen screen) {
  return MaterialApp(
    theme: ClusterOrbitTheme.dark(),
    home: screen,
  );
}

void main() {
  testWidgets('valid form calls callback with correct SavedConnection',
      (tester) async {
    SavedConnection? received;
    await tester.pumpWidget(_wrap(
      AddGatewayScreen(
        onAddConnection: (c) async => received = c,
      ),
    ));

    await tester.enterText(
        find.widgetWithText(TextFormField, 'Prod Gateway'), 'My Gateway');
    await tester.enterText(
        find.widgetWithText(TextFormField, 'https://gateway.example.com'),
        'https://gateway.example.com');
    await tester.enterText(
        find.widgetWithText(TextFormField, 'X-ClusterOrbit-Token value'),
        'secret-token');

    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(received, isNotNull);
    expect(received!.kind, SavedConnectionKind.gateway);
    expect(received!.displayName, 'My Gateway');
    expect(received!.gatewayUrl, 'https://gateway.example.com');
    expect(received!.gatewayToken, 'secret-token');
    expect(received!.id, startsWith('gateway-'));
  });

  testWidgets('invalid URL prevents callback and shows error', (tester) async {
    var callbackInvoked = false;
    await tester.pumpWidget(_wrap(
      AddGatewayScreen(
        onAddConnection: (c) async => callbackInvoked = true,
      ),
    ));

    await tester.enterText(
        find.widgetWithText(TextFormField, 'Prod Gateway'), 'My Gateway');
    await tester.enterText(
        find.widgetWithText(TextFormField, 'https://gateway.example.com'),
        'ftp://foo');

    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(callbackInvoked, isFalse);
    expect(find.text('Must start with http:// or https://'), findsOneWidget);
  });

  testWidgets('Test connection: success path shows cluster count',
      (tester) async {
    final fake = _FakeHttpClient(getResponse: <dynamic>[
      {
        'id': 'c1',
        'name': 'c1',
        'apiServerHost': 'api.c1',
        'environmentLabel': 'prod',
        'connectionMode': 'gateway',
      },
      {
        'id': 'c2',
        'name': 'c2',
        'apiServerHost': 'api.c2',
        'environmentLabel': 'prod',
        'connectionMode': 'gateway',
      },
    ]);
    await tester.pumpWidget(_wrap(
      AddGatewayScreen(
        onAddConnection: (_) async {},
        gatewayConnectionFactory: (u, t) => GatewayClusterConnection(
          gatewayBaseUrl: u,
          token: t,
          httpClient: fake,
        ),
      ),
    ));

    await tester.enterText(
      find.widgetWithText(TextFormField, 'https://gateway.example.com'),
      'https://gateway.example.com',
    );
    await tester.tap(find.byKey(const ValueKey('test-connection')));
    await tester.pumpAndSettle();

    expect(find.textContaining('Connected'), findsOneWidget);
    expect(find.textContaining('2 cluster'), findsOneWidget);
  });

  testWidgets('Test connection: failure shows error banner', (tester) async {
    final fake = _FakeHttpClient(getError: Exception('auth denied'));
    await tester.pumpWidget(_wrap(
      AddGatewayScreen(
        onAddConnection: (_) async {},
        gatewayConnectionFactory: (u, t) => GatewayClusterConnection(
          gatewayBaseUrl: u,
          token: t,
          httpClient: fake,
        ),
      ),
    ));

    await tester.enterText(
      find.widgetWithText(TextFormField, 'https://gateway.example.com'),
      'https://gateway.example.com',
    );
    await tester.tap(find.byKey(const ValueKey('test-connection')));
    await tester.pumpAndSettle();

    expect(find.textContaining('Failed'), findsOneWidget);
    expect(find.textContaining('auth denied'), findsOneWidget);
  });

  testWidgets('Test connection with empty URL shows inline error',
      (tester) async {
    await tester.pumpWidget(_wrap(
      AddGatewayScreen(onAddConnection: (_) async {}),
    ));

    await tester.tap(find.byKey(const ValueKey('test-connection')));
    await tester.pumpAndSettle();

    expect(find.textContaining('Enter a valid Gateway URL'), findsOneWidget);
  });

  testWidgets('empty token results in gatewayToken null', (tester) async {
    SavedConnection? received;
    await tester.pumpWidget(_wrap(
      AddGatewayScreen(
        onAddConnection: (c) async => received = c,
      ),
    ));

    await tester.enterText(
        find.widgetWithText(TextFormField, 'Prod Gateway'), 'Staging');
    await tester.enterText(
        find.widgetWithText(TextFormField, 'https://gateway.example.com'),
        'http://staging.internal');
    // leave token blank

    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(received, isNotNull);
    expect(received!.gatewayToken, isNull);
  });
}
