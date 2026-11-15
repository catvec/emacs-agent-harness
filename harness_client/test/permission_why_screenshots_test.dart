// Pictures of the permission card's reason line: the one that is a safety
// judgment on the call, and one that is no judgment at all.  Drawn with the
// fonts of a phone.
//
//   HARNESS_SHOTS=/some/directory flutter test test/permission_why_screenshots_test.dart
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

const _command = 'rm -rf build dist && python3 -m build';

const _unsafe = {
  'code': 'judge-deny',
  'label': 'Safety check · denied by the permission judge',
  'unsafe': true,
  'detail': 'it force pushes to the shared remote',
};

const _timeout = {
  'code': 'judge-timeout',
  'label': 'No safety verdict · judge timeout',
  'unsafe': false,
  'detail': 'it took longer than 30s',
};

class _Case {
  const _Case(
    this.file,
    this.why, {
    this.width = 360,
    this.height = 800,
    this.apple = false,
  });
  final String file;
  final Map<String, Object?> why;
  final double width;
  final double height;

  /// Drawn in the style of an iPhone, not of an Android phone.
  final bool apple;
}

final _cases = [
  _Case('permission-why-unsafe', _unsafe),
  _Case('permission-why-no-verdict', _timeout),
  _Case('permission-why-unsafe-ios', _unsafe,
      width: 390, height: 844, apple: true),
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
        extra: {'why': shot.why},
      );
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 120));
      }
      expect(find.byKey(const ValueKey('permission-why')), findsOneWidget);
      expect(find.text(shot.why['label']! as String), findsOneWidget);
      expect(find.text(shot.why['detail']! as String), findsOneWidget);
      expect(
        find.byIcon(
          shot.why['unsafe'] == true
              ? Icons.warning_amber_rounded
              : Icons.info_outline_rounded,
        ),
        findsOneWidget,
      );

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
