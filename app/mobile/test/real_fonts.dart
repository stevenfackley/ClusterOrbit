import 'dart:io';

import 'package:flutter/services.dart';

/// Loads the SDK's Roboto as the app's text font, so a layout test measures
/// text as a device would. The default test font draws every glyph 1em
/// wide and overstates widths. Call it from setUpAll: the font stays loaded
/// for the rest of the test file.
Future<void> loadRoboto() async {
  final loader = FontLoader('Roboto');
  for (final file in const [
    'roboto-regular.ttf',
    'roboto-medium.ttf',
    'roboto-bold.ttf',
  ]) {
    final bytes = File('${_materialFonts()}/$file').readAsBytesSync();
    loader.addFont(Future.value(ByteData.sublistView(bytes)));
  }
  await loader.load();
}

/// The SDK's cached material_fonts: from FLUTTER_ROOT, which `flutter test`
/// sets, or else from the flutter_tester binary under
/// `bin/cache/artifacts/engine/<platform>/`.
String _materialFonts() {
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root != null && root.isNotEmpty) {
    return '$root/bin/cache/artifacts/material_fonts';
  }
  final artifacts = File(Platform.resolvedExecutable).parent.parent.parent;
  return '${artifacts.path}/material_fonts';
}
