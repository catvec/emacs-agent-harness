// The fonts of a phone, for the tests that draw the app as a person sees it.
//
// `flutter test` draws every letter as a square as wide as it is high (the
// Ahem font), which is a harsh judge of whether things fit but looks like
// nothing.  A test that makes a picture of the app, or that needs the text to
// be as wide as it is on a phone, loads Roboto and the Material icons from
// the Flutter SDK that runs it, and, if the machine has one, a monospace
// font for the diagrams of a question.
//
// What the test engine cannot be told is its default font: a style that
// names no family (the Material theme's buttons have such a style) is drawn
// in Ahem all the same, as squares.  The Cupertino theme names its families,
// so a picture of the app in the style of an iPhone has none of them.
import 'dart:io';

import 'package:flutter/services.dart';

/// Where the Flutter SDK that runs the tests keeps its Material fonts, or
/// null when it cannot be found.
Directory? _materialFonts() {
  final candidates = <String>[
    if (Platform.environment['FLUTTER_ROOT'] case final root?)
      '$root/bin/cache/artifacts/material_fonts',
  ];
  // `flutter_tester` is in the SDK's engine artifacts: .../bin/cache/
  // artifacts/engine/PLATFORM/flutter_tester.
  var directory = File(Platform.resolvedExecutable).parent;
  for (var depth = 0; depth < 6; depth++) {
    candidates.add('${directory.path}/material_fonts');
    directory = directory.parent;
  }
  for (final path in candidates) {
    final found = Directory(path);
    if (found.existsSync()) return found;
  }
  return null;
}

Future<void> _load(String family, Iterable<File> files) async {
  final loader = FontLoader(family);
  for (final file in files) {
    final bytes = file.readAsBytesSync();
    loader.addFont(Future.value(ByteData.sublistView(Uint8List.fromList(bytes))));
  }
  await loader.load();
}

/// Load Roboto (every weight the app draws), the Material icons and a
/// monospace font, so that text is as wide as on a phone and the icons are
/// icons.  Whether the SDK's fonts were found: when they were not, the tests
/// go on with the test font.
Future<bool> loadRealFonts() async {
  final fonts = _materialFonts();
  if (fonts == null) return false;
  final roboto = <File>[
    for (final name in const [
      'Roboto-Light.ttf',
      'Roboto-Regular.ttf',
      'Roboto-Medium.ttf',
      'Roboto-Bold.ttf',
      'Roboto-Italic.ttf',
    ])
      File('${fonts.path}/$name'),
  ].where((file) => file.existsSync()).toList();
  final icons = File('${fonts.path}/MaterialIcons-Regular.otf');
  if (roboto.isEmpty || !icons.existsSync()) return false;
  await _load('Roboto', roboto);
  await _load('MaterialIcons', [icons]);
  // A style that names the test font itself (`Ahem`) is drawn in Roboto too.
  await _load('Ahem', roboto);
  // The font of an iPhone, which the app's Cupertino theme names: Roboto
  // stands for it, as it stands for the phone's own in the Material theme.
  for (final name in const ['.SF Pro Text', '.SF Pro Display']) {
    await _load(name, roboto);
  }
  // What a phone calls `monospace`: any fixed-width font the machine has.
  for (final path in const [
    '/usr/share/fonts/noto/NotoSansMono-Regular.ttf',
    '/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf',
    '/usr/share/fonts/TTF/DejaVuSansMono.ttf',
  ]) {
    final file = File(path);
    if (file.existsSync()) {
      await _load('monospace', [file]);
      break;
    }
  }
  return true;
}
