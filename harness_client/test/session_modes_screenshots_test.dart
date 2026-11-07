// Pictures of the permission-mode picker on a conversation, on a desktop and
// on a phone, drawn with the fonts of the platform.
//
//   HARNESS_SHOTS=/some/directory flutter test test/session_modes_screenshots_test.dart
//
// writes a PNG for each case there.  Without HARNESS_SHOTS the cases still
// run (they draw, and check the picker and its sheet are whole on the
// screen), and write nothing.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/app.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:harness_client/src/ui/adaptive/layout_widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';
import 'support/real_fonts.dart';

class _Case {
  const _Case(
    this.file,
    this.width,
    this.height, {
    this.mode,
    this.sheet = false,
  });
  final String file;
  final double width;
  final double height;

  /// A mode chosen before the picture, so that the footer shows it.
  final String? mode;

  /// Open the mode sheet for the picture, instead of the footer alone.
  final bool sheet;
}

const _cases = [
  _Case('session-mode-picker-desktop', 1280, 900, mode: 'accept-edits'),
  _Case('session-mode-sheet-desktop', 1280, 900, sheet: true),
  _Case('session-mode-picker-phone', 390, 844, mode: 'yolo'),
  _Case('session-mode-sheet-phone', 390, 844, sheet: true),
];

Future<void> _write(WidgetTester tester, ui.Image image, String path) async {
  await tester.runAsync(() async {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File(path);
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(data!.buffer.asUint8List());
  });
}

Future<void> _settle(WidgetTester tester, [int rounds = 10]) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

Future<void> _picture(WidgetTester tester, GlobalKey frame, String path) async {
  final image = await tester.runAsync(() async {
    final boundary =
        frame.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    return boundary.toImage(pixelRatio: 1.5);
  });
  await _write(tester, image!, path);
}

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  final shots = Platform.environment['HARNESS_SHOTS'];
  final real = await loadRealFonts();

  for (final shot in _cases) {
    testWidgets('draws ${shot.file}', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsController();
      await settings.load();
      final harness = FakeHarness();
      final app = AppController(
        settings: settings,
        connector: harness.connector,
      );
      await app.connect('ws://memory/acp');

      const ratio = 2.0;
      tester.view.physicalSize = Size(shot.width * ratio, shot.height * ratio);
      tester.view.devicePixelRatio = ratio;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final boundary = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: HarnessApp(settings: settings, appController: app),
        ),
      );
      await tester.pump();
      await _settle(tester);
      await tester.tap(find.text('Design the merge queue'));
      await _settle(tester);

      if (shot.mode case final mode?) {
        await tester.tap(find.byIcon(Icons.shield_outlined));
        await _settle(tester);
        await tester.tap(
          find.widgetWithText(
            ListTile,
            mode == 'accept-edits' ? 'Accept edits' : 'YOLO',
          ),
        );
        await _settle(tester);
        expect(
          find.descendant(
            of: find.byType(HarnessPicker),
            matching: find.text(
              mode == 'accept-edits' ? 'Accept edits' : 'YOLO',
            ),
          ),
          findsOneWidget,
        );
      }

      if (shot.sheet) {
        await tester.tap(find.byIcon(Icons.shield_outlined));
        await _settle(tester);
        expect(find.text('Permission mode'), findsOneWidget);
        expect(find.widgetWithText(ListTile, 'Ask'), findsOneWidget);
        expect(find.widgetWithText(ListTile, 'Accept edits'), findsOneWidget);
        expect(find.widgetWithText(ListTile, 'Auto'), findsOneWidget);
        expect(find.widgetWithText(ListTile, 'YOLO'), findsOneWidget);
        expect(find.textContaining('reads allowed'), findsNothing);
      }

      expect(tester.getRect(find.byType(MaterialApp)).width, greaterThan(0));
      if (shots != null) {
        await _picture(
          tester,
          boundary,
          '$shots/${shot.file}${real ? '' : '-ahem'}.png',
        );
      }
    });
  }
}
