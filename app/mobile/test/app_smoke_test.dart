import 'package:clusterorbit_mobile/app/clusterorbit_app.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('renders ClusterOrbit shell', (tester) async {
    await tester.pumpWidget(const ClusterOrbitApp());

    expect(find.text('Cluster Map'), findsWidgets);
    expect(find.text('Map'), findsOneWidget);
    expect(find.text('Switch Cluster'), findsOneWidget);
  });
}
