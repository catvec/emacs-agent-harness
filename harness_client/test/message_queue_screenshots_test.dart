// Pictures of a conversation whose agent works while messages wait for the
// next turn: the queue above the box, with what can be done about each.
//
//   HARNESS_SHOTS=/some/directory flutter test test/message_queue_screenshots_test.dart
//
// writes `android-message-queue.png` and `message-queue-320-text2.png`.
// Without HARNESS_SHOTS the cases still draw and check that nothing
// overflows, and write nothing.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:harness_client/src/ui/adaptive/platform_style.dart';
import 'package:harness_client/src/ui/app_scope.dart';
import 'package:harness_client/src/ui/screens/session_screen.dart';
import 'package:harness_client/src/ui/theme/harness_theme.dart';
import 'package:harness_client/src/ui/widgets/queued_messages.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';
import 'support/phone_fonts.dart';
import 'support/real_fonts.dart';

const _session = 's1';

void _seedQueue(FakeHarness harness) {
  harness.sessions[_session]!['queue'] = [
    {
      'id': 'q-1',
      'text': 'Also update the docs for the queue.',
      'attachments': <Object?>[],
      'ts': 1.0,
    },
    {
      'id': 'q-2',
      'text': 'And run the full test suite again before you hand it in.',
      'attachments': <Object?>[],
      'ts': 2.0,
    },
  ];
}

class _Rig {
  _Rig(this.settings, this.harness, this.app);
  final SettingsController settings;
  final FakeHarness harness;
  final AppController app;
}

Future<_Rig> _connected() async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsController();
  await settings.load();
  final harness = FakeHarness();
  _seedQueue(harness);
  final app = AppController(settings: settings, connector: harness.connector);
  addTearDown(app.dispose);
  await app.connect('ws://memory/acp');
  return _Rig(settings, harness, app);
}

Future<void> _settle(WidgetTester tester, [int rounds = 20]) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

Future<ui.Image> _picture(WidgetTester tester, GlobalKey frame) async {
  final image = await tester.runAsync(() async {
    final boundary =
        frame.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    return boundary.toImage(pixelRatio: 2);
  });
  return image!;
}

Future<void> _write(WidgetTester tester, ui.Image image, String path) async {
  await tester.runAsync(() async {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File(path);
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(data!.buffer.asUint8List());
  });
}

Future<GlobalKey> _pump(
  WidgetTester tester,
  _Rig rig, {
  required double width,
  required double height,
  required double ratio,
  double textScale = 1,
  HarnessPlatformStyle style = HarnessPlatformStyle.material,
  bool startTurn = true,
}) async {
  tester.view.physicalSize = Size(width * ratio, height * ratio);
  tester.view.devicePixelRatio = ratio;
  tester.view.viewPadding = FakeViewPadding(
    top: 24 * ratio,
    bottom: 24 * ratio,
  );
  tester.view.padding = tester.view.viewPadding;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPadding);
  addTearDown(tester.view.resetViewPadding);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final frame = GlobalKey();
  await tester.pumpWidget(
    RepaintBoundary(
      key: frame,
      child: HarnessStyle(
        style: style,
        child: HarnessScope(
          app: rig.app,
          settings: rig.settings,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: phoneFonts(HarnessTheme.material(Brightness.light)),
            home: const SessionScreen(sessionId: _session),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await _settle(tester);
  if (startTurn) {
    // A turn that runs long enough for the queue to show under it.
    await tester.enterText(
      find.byKey(const Key('composer-field')),
      'Take it slowly and work through the plan.',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('composer-send')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
  }
  return frame;
}

Future<void> _shot(
  WidgetTester tester,
  GlobalKey frame,
  String? directory,
  String name,
) async {
  if (directory == null) return;
  final image = await _picture(tester, frame);
  await _write(tester, image, '$directory/$name');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final shots = Platform.environment['HARNESS_SHOTS'];

  setUpAll(() async {
    await loadRealFonts();
  });

  testWidgets('draws a message queued while the agent works', (tester) async {
    final rig = await _connected();
    final frame = await _pump(
      tester,
      rig,
      width: 412,
      height: 915,
      ratio: 2.625,
    );
    expect(find.byType(QueuedMessages), findsOneWidget);
    expect(find.text('Queue'), findsOneWidget);
    expect(find.text('Also update the docs for the queue.'), findsOneWidget);
    expect(
      find.text('And run the full test suite again before you hand it in.'),
      findsOneWidget,
    );
    expect(find.text('Message for the next turn'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _shot(tester, frame, shots, 'android-message-queue.png');
    // Let the slow turn run out, and the reads it scheduled, so that no
    // timer outlives the test.
    await _settle(tester, 50);
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets('draws the queue at 320 points and twice the text', (
    tester,
  ) async {
    final rig = await _connected();
    // One message: at twice the text a row takes the strip's room, and the
    // next one is a scroll away.
    rig.harness.sessions[_session]!['queue'] = [
      (rig.harness.sessions[_session]!['queue']! as List).first,
    ];
    final frame = await _pump(
      tester,
      rig,
      width: 320,
      height: 740,
      ratio: 2,
      textScale: 2,
    );
    expect(find.byType(QueuedMessages), findsOneWidget);
    expect(find.byKey(const Key('composer-queue')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _shot(tester, frame, shots, 'message-queue-320-text2.png');
    // Let the slow turn run out, and the reads it scheduled.
    await _settle(tester, 50);
    await tester.pump(const Duration(milliseconds: 500));
  });
}
