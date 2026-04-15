// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter_test/flutter_test.dart';

import 'package:clusterorbit_mobile/app/clusterorbit_app.dart';

void main() {
  testWidgets('ClusterOrbit renders primary navigation', (tester) async {
    await tester.pumpWidget(const ClusterOrbitApp());

    expect(find.text('Cluster Map'), findsWidgets);
    expect(find.text('Map'), findsOneWidget);
    expect(find.text('Resources'), findsOneWidget);
  });
}
