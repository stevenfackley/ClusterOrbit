import 'dart:ui';

import 'package:clusterorbit_mobile/app/clusterorbit_app.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> pumpClusterOrbitApp(
  WidgetTester tester, {
  Size? size,
}) async {
  if (size != null) {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = size;
  }

  await tester.pumpWidget(const ClusterOrbitApp());
  await tester.pumpAndSettle();
}

Future<void> resetTestSurface(WidgetTester tester) async {
  tester.view.resetPhysicalSize();
  tester.view.resetDevicePixelRatio();
  await tester.pump();
}
