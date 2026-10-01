import 'dart:async';

import 'package:clusterorbit_mobile/core/cluster_domain/saved_connection.dart';
import 'package:clusterorbit_mobile/core/connectivity/cluster_connection_factory.dart';
import 'package:clusterorbit_mobile/core/connectivity/gateway_cluster_connection.dart';
import 'package:clusterorbit_mobile/core/theme/clusterorbit_theme.dart';
import 'package:clusterorbit_mobile/features/connections/add_gateway_screen.dart';
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
  Future<GatewayResponse> postJson(
    Uri url, {
    Map<String, String> headers = const {},
    required Map<String, dynamic> body,
  }) async =>
      (statusCode: 200, body: null);
}

/// Answers `getJson` only when [gate] completes.
class _GatedHttpClient extends _FakeHttpClient {
  _GatedHttpClient(this.gate);

  final Completer<dynamic> gate;

  @override
  Future<dynamic> getJson(Uri url, {Map<String, String> headers = const {}}) =>
      gate.future;
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

  testWidgets('Test connection: a 401 shows the friendly text, no URL or body',
      (tester) async {
    final fake = _FakeHttpClient(
      getError: GatewayException.fromResponse(
        401,
        Uri.parse('https://gw.example.com/v1/clusters'),
        '{"error":"bad token","detail":"raw"}',
      ),
    );
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

    expect(find.textContaining('Gateway rejected the access token: bad token'),
        findsOneWidget);
    expect(find.textContaining('/v1/clusters'), findsNothing);
    expect(find.textContaining('{'), findsNothing);
  });

  testWidgets('Test connection: a result for an edited URL is dropped',
      (tester) async {
    final gate = Completer<dynamic>();
    final fake = _GatedHttpClient(gate);
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

    final urlField =
        find.widgetWithText(TextFormField, 'https://gateway.example.com');
    await tester.enterText(urlField, 'https://good.example.com');
    await tester.tap(find.byKey(const ValueKey('test-connection')));
    await tester.pump();

    await tester.enterText(urlField, 'https://typo.example.com');
    gate.complete(<dynamic>[]);
    await tester.pumpAndSettle();

    expect(find.textContaining('Connected'), findsNothing);
    expect(find.textContaining('Failed'), findsNothing);
  });

  group('validateGatewayUrl', () {
    test('accepts http and https URLs with a host', () {
      expect(validateGatewayUrl('https://gw.example.com'), isNull);
      expect(validateGatewayUrl(' http://10.0.0.5:8080/base '), isNull);
    });

    test('rejects what Uri.tryParse rejects or leaves hostless', () {
      expect(validateGatewayUrl('https://gw.example.com:80a'), isNotNull);
      expect(validateGatewayUrl('http://[::1'), isNotNull);
      expect(validateGatewayUrl('http://'), isNotNull);
      expect(validateGatewayUrl('ftp://foo'),
          'Must start with http:// or https://');
      expect(validateGatewayUrl(''), 'Required');
      expect(validateGatewayUrl(null), 'Required');
    });
  });

  testWidgets('unparseable URL is rejected by the form', (tester) async {
    var callbackInvoked = false;
    await tester.pumpWidget(_wrap(
      AddGatewayScreen(onAddConnection: (c) async => callbackInvoked = true),
    ));

    await tester.enterText(
        find.widgetWithText(TextFormField, 'Prod Gateway'), 'GW');
    await tester.enterText(
        find.widgetWithText(TextFormField, 'https://gateway.example.com'),
        'https://gw.example.com:80a');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(callbackInvoked, isFalse);
    expect(find.text('Not a valid URL'), findsOneWidget);
  });

  testWidgets('keyboard submit while saving does not save twice',
      (tester) async {
    final gate = Completer<void>();
    var calls = 0;
    await tester.pumpWidget(_wrap(
      AddGatewayScreen(
        onAddConnection: (c) async {
          calls++;
          await gate.future;
        },
      ),
    ));

    await tester.enterText(
        find.widgetWithText(TextFormField, 'Prod Gateway'), 'GW');
    await tester.enterText(
        find.widgetWithText(TextFormField, 'https://gateway.example.com'),
        'https://gw.example.com');
    final token =
        find.widgetWithText(TextFormField, 'X-ClusterOrbit-Token value');
    await tester.enterText(token, 'tok');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(calls, 1);
    gate.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('editing the URL clears a previous test outcome', (tester) async {
    await tester.pumpWidget(_wrap(
      AddGatewayScreen(
        onAddConnection: (_) async {},
        gatewayConnectionFactory: (u, t) => GatewayClusterConnection(
          gatewayBaseUrl: u,
          token: t,
          httpClient: _FakeHttpClient(getError: Exception('auth denied')),
        ),
      ),
    ));

    final url =
        find.widgetWithText(TextFormField, 'https://gateway.example.com');
    await tester.enterText(url, 'https://gateway.example.com');
    await tester.tap(find.byKey(const ValueKey('test-connection')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Failed'), findsOneWidget);

    await tester.enterText(url, 'https://other.example.com');
    await tester.pump();
    expect(find.textContaining('Failed'), findsNothing);
  });
}
