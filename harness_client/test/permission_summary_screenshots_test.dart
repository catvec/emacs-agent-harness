// Pictures of the permission card with a model's summary of the call, on
// phones, drawn with the fonts of a phone.
//
//   HARNESS_SHOTS=/some/directory flutter test test/permission_summary_screenshots_test.dart
//
// writes a PNG for each case there.  Without HARNESS_SHOTS the cases still
// run (they draw, and check that the card is whole on the picture's screen),
// and write nothing.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/app.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:harness_client/src/ui/widgets/interaction_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';
import 'support/real_fonts.dart';

const _command = 'rm -rf build dist && python3 -m build && ls dist';

const _summary =
    'Deletes the build and dist directories, then builds the package again '
    'and lists what it made. Nothing leaves the project.';

class _Case {
  const _Case(
    this.file,
    this.width,
    this.height, {
    this.waiting = false,
    this.apple = false,
  });
  final String file;
  final double width;
  final double height;

  /// The summary is still being written: the card has its placeholder.
  final bool waiting;

  /// Drawn in the style of an iPhone, not of an Android phone.
  final bool apple;
}

const _cases = [
  _Case('permission-summarizing', 360, 800, waiting: true),
  _Case('permission-summary', 360, 800),
  _Case('permission-summary-small-phone', 360, 640),
  _Case('permission-summary-ios', 390, 844, apple: true),
];

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  final shots = Platform.environment['HARNESS_SHOTS'];
  final real = await loadRealFonts();

  for (final shot in _cases) {
    testWidgets('draws ${shot.file}', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsController();
      await settings.load();
      if (shot.apple) {
        await settings.setPreviewPlatform(PreviewPlatform.cupertino);
      }
      final harness = FakeHarness();
      final app = AppController(
        settings: settings,
        connector: harness.connector,
      );
      await app.connect('ws://memory/acp');

      const ratio = 2.0;
      tester.view.physicalSize = Size(shot.width * ratio, shot.height * ratio);
      tester.view.devicePixelRatio = ratio;
      tester.view.viewPadding = const FakeViewPadding(
        top: 24 * ratio,
        bottom: 24 * ratio,
      );
      tester.view.padding = tester.view.viewPadding;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);
      addTearDown(tester.view.resetViewInsets);

      final boundary = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: HarnessApp(settings: settings, appController: app),
        ),
      );
      await tester.pump();
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 120));
      }
      await tester.tap(find.text('Design the merge queue'));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 120));
        // See question_screenshots_test.dart: not what is drawn.
        if (shot.apple) tester.takeException();
      }
      final answer = harness.askPermission(
        's1',
        callId: 'c1',
        title: 'Bash: $_command',
        extra: shot.waiting
            ? {'summarizing': true}
            : {'summary': _summary, 'summaryModel': 'claude:claude-haiku-4-5'},
      );
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 120));
      }
      expect(
        find.text(shot.waiting ? 'Summarizing…' : _summary),
        findsOneWidget,
      );
      expect(find.text('Model summary'), findsOneWidget);

      // The whole card is on the screen.
      final card = tester.getRect(find.byType(InteractionCard));
      expect(card.top, greaterThanOrEqualTo(0));
      expect(card.bottom, lessThanOrEqualTo(shot.height + 0.01));

      if (shots != null) {
        await tester.runAsync(() async {
          final render =
              boundary.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await render.toImage(pixelRatio: 1.5);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File('$shots/${shot.file}${real ? '' : '-ahem'}.png');
          file.parent.createSync(recursive: true);
          file.writeAsBytesSync(data!.buffer.asUint8List());
        });
      }

      // On a small phone the answers may be below the card's fold: it
      // scrolls to them.
      await tester.ensureVisible(find.text('Deny'));
      await tester.pump();
      await tester.tap(find.text('Deny'));
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 120));
      }
      await answer.timeout(const Duration(seconds: 5));
    });
  }
}
