import 'dart:io';

import 'package:flutter/services.dart';

/// Loads Roboto as the app's text font, so a layout test measures text as a
/// device would. The default test font draws every glyph 1em wide and
/// overstates widths. Call it from setUpAll: the font stays loaded for the
/// rest of the test file.
///
/// The fonts are vendored in test/fonts (Apache-2.0, see LICENSE-Roboto.txt)
/// because `flutter test` never downloads the SDK's material fonts, so a
/// fresh CI runner has no copy to load.
Future<void> loadRoboto() async {
  final loader = FontLoader('Roboto');
  for (final file in const [
    'roboto-regular.ttf',
    'roboto-medium.ttf',
    'roboto-bold.ttf',
  ]) {
    final bytes = File('test/fonts/$file').readAsBytesSync();
    loader.addFont(Future.value(ByteData.sublistView(bytes)));
  }
  await loader.load();
}
