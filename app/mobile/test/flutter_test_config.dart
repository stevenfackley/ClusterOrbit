import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

/// Runs before every test file in this directory.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  // A tap that would land on some other widget than its target fails the
  // test instead of printing a warning and passing on the wrong entity.
  WidgetController.hitTestWarningShouldBeFatal = true;
  await testMain();
}
