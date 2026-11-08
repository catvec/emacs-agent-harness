// The names under the icons of the bottom bar: one line each, inside their
// destination, on the narrowest phones and at every text size — in the
// Material bar and in the Cupertino one.  A name broken in the middle reads
// as two names, and is what a phone with six destinations used to get.
//
//   HARNESS_SHOTS=/some/directory flutter test test/bottom_bar_test.dart
//
// also writes a picture of each case.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/app.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';
import 'support/phone_fonts.dart';
import 'support/real_fonts.dart';

class _Rig {
  _Rig(this.settings, this.harness, this.app);
  final SettingsController settings;
  final FakeHarness harness;
  final AppController app;
}

Future<_Rig> _rig({bool workspace = true}) async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsController();
  await settings.load();
  final harness = FakeHarness(workspace: workspace);
  final app = AppController(settings: settings, connector: harness.connector);
  await app.connect('ws://memory/acp');
  return _Rig(settings, harness, app);
}

Future<void> _settle(WidgetTester tester, [int rounds = 10]) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

/// A phone [width] × [height] points, the app on it, its text at [scale].
Future<void> _pump(
  WidgetTester tester, {
  required double width,
  double height = 700,
  double scale = 1,
  bool workspace = true,
  bool cupertino = false,
  GlobalKey? boundary,
}) async {
  final rig = await _rig(workspace: workspace);
  if (cupertino) {
    await rig.settings.setPreviewPlatform(PreviewPlatform.cupertino);
  }
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  tester.view.physicalSize = Size(width * 3, height * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    RepaintBoundary(
      key: boundary,
      child: HarnessApp(
        settings: rig.settings,
        appController: rig.app,
        themeBuilder: phoneFonts,
      ),
    ),
  );
  await tester.pump();
  await _settle(tester);
}

/// The text of one destination's name, in the bar.
Finder _labelIn(Type bar, String label) => find.descendant(
  of: find.byType(bar),
  matching: find.text(label),
);

/// The name is drawn on one line: no taller than the one line it would be at
/// the size the bar gives it, and as wide as its own destination.
void _expectOneLine(
  WidgetTester tester,
  Type bar,
  String label, {
  required int destinations,
}) {
  final finder = _labelIn(bar, label);
  expect(finder, findsOneWidget, reason: '$label is named in the bar');
  final element = tester.element(finder);
  final text = tester.widget<Text>(finder);
  // What the Text resolves: its own style over the one it inherits.
  final style = DefaultTextStyle.of(element).style.merge(text.style);
  final painter = TextPainter(
    text: TextSpan(text: label, style: style),
    textDirection: TextDirection.ltr,
    textScaler: MediaQuery.textScalerOf(element),
    maxLines: 1,
  )..layout();
  final oneLine = painter.height;
  painter.dispose();

  final rect = tester.getRect(finder);
  final barRect = tester.getRect(find.byType(bar));
  expect(
    rect.height,
    lessThanOrEqualTo(oneLine * 1.25),
    reason: '$label is one line, not two',
  );
  expect(
    rect.width,
    lessThanOrEqualTo(barRect.width / destinations + 0.01),
    reason: '$label fits its destination',
  );
  expect(rect.left, greaterThanOrEqualTo(barRect.left - 0.01), reason: label);
  expect(rect.right, lessThanOrEqualTo(barRect.right + 0.01), reason: label);
  expect(rect.top, greaterThanOrEqualTo(barRect.top - 0.01), reason: label);
  expect(
    rect.bottom,
    lessThanOrEqualTo(barRect.bottom + 0.01),
    reason: '$label is inside the bar',
  );
}

void main() {
  final shots = Platform.environment['HARNESS_SHOTS'];
  var real = false;
  setUpAll(() async => real = await loadRealFonts());

  Future<void> shoot(
    WidgetTester tester,
    GlobalKey boundary,
    String name,
  ) async {
    if (shots == null) return;
    await tester.runAsync(() async {
      final render =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await render.toImage(pixelRatio: 2);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final out = File('$shots/$name${real ? '' : '-ahem'}.png');
      out.parent.createSync(recursive: true);
      out.writeAsBytesSync(data!.buffer.asUint8List());
    });
  }

  const six = ['Sessions', 'Workspace', 'Tasks', 'Usage', 'Server', 'Settings'];

  for (final (width, scale) in [
    (320.0, 1.0),
    (360.0, 1.0),
    (320.0, 1.3),
    (390.0, 1.5),
  ]) {
    testWidgets(
      'six destinations are named on one line at $width points, '
      'text at $scale×',
      (tester) async {
        final boundary = GlobalKey();
        await _pump(
          tester,
          width: width,
          scale: scale,
          boundary: boundary,
        );
        await shoot(tester, boundary, 'bottom-bar-$width-$scale');
        expect(find.byType(NavigationBar), findsOneWidget);
        for (final label in six) {
          _expectOneLine(
            tester,
            NavigationBar,
            label,
            destinations: six.length,
          );
        }
        // One size for every name: none is shrunk on its own.
        final heights = {
          for (final label in six)
            tester.getSize(_labelIn(NavigationBar, label)).height,
        };
        expect(heights, hasLength(1), reason: 'all names are one size');
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('the names of the iPhone bar are one line too, at 320 and '
      'one and a third times the text', (tester) async {
    final boundary = GlobalKey();
    await _pump(
      tester,
      width: 320,
      scale: 1.3,
      cupertino: true,
      boundary: boundary,
    );
    await shoot(tester, boundary, 'bottom-bar-cupertino-320-1.3');
    expect(find.byType(CupertinoTabBar), findsOneWidget);
    for (final label in six) {
      _expectOneLine(tester, CupertinoTabBar, label, destinations: six.length);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('a bar with room still grows its names with the text', (
    tester,
  ) async {
    // Five destinations on a tablet: nothing is made smaller, and the bar's
    // own cap (1.3, as Material makes it) stands.
    await _pump(tester, width: 900, scale: 1.5, workspace: false);
    final element = tester.element(_labelIn(NavigationBar, 'Sessions'));
    final scaler = MediaQuery.textScalerOf(element);
    expect(scaler.scale(11), closeTo(11 * 1.3, 0.01));
    for (final label in ['Sessions', 'Tasks', 'Usage', 'Server', 'Settings']) {
      _expectOneLine(tester, NavigationBar, label, destinations: 5);
    }
    expect(tester.takeException(), isNull);
  });
}
