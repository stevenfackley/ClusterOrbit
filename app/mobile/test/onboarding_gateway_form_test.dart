import 'package:clusterorbit_mobile/core/cluster_domain/saved_connection.dart';
import 'package:clusterorbit_mobile/core/theme/clusterorbit_theme.dart';
import 'package:clusterorbit_mobile/features/onboarding/onboarding_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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

    await tester.tap(find.text('Save connection'));
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

    await tester.tap(find.text('Save connection'));
    await tester.pumpAndSettle();

    expect(callbackInvoked, isFalse);
    expect(find.text('Must start with http:// or https://'), findsOneWidget);
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

    await tester.tap(find.text('Save connection'));
    await tester.pumpAndSettle();

    expect(received, isNotNull);
    expect(received!.gatewayToken, isNull);
  });
}
