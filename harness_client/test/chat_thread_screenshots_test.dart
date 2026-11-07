// Pictures of a reply in a thread on a phone: the cards the harness records,
// the words under a quote, and the composer that answers one message.
//
//   HARNESS_SHOTS=/some/directory flutter test test/chat_thread_screenshots_test.dart
//
// writes `chat-thread-360.png`, `chat-thread-320-text2.png`,
// `chat-reply-keyboard.png` and `chat-thread-wide.png`.  Without HARNESS_SHOTS
// the cases still draw and check that nothing overflows, and write nothing.
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
import 'package:harness_client/src/ui/widgets/message_composer.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';
import 'support/real_fonts.dart';

const _session = 's1';

Map<String, Object?> _threadData() => {
  'id': 't-review-1',
  'refs': [
    {
      'kind': 'chat',
      'node': 'n2',
      'who': 'agent',
      'session': _session,
      'text':
          'The merge queue has three moving parts: queued branches wait, '
          'merging runs one at a time, and conflicts go back to the task.',
    },
  ],
  'response': 'Which part should the phone show?',
};

String _markup() =>
    '<thread id="t-review-1">\n'
    '<quote>The merge queue has three moving parts: queued branches wait, '
    'merging runs one at a time, and conflicts go back to the task.</quote>\n'
    'Which part should the phone show?\n'
    '</thread>';

void _seed(FakeHarness harness) {
  final now = DateTime.now().millisecondsSinceEpoch / 1000;
  harness.nodes[_session]!.addAll([
    {
      'id': 'tu1',
      'kind': 'user',
      'ts': now + 1,
      'content': _markup(),
      'blocks': [
        {'type': 'text', 'text': _markup(), 'thread': _threadData()},
      ],
    },
    {
      'id': 'ta1',
      'kind': 'assistant',
      'ts': now + 2,
      'content':
          'The queue itself: its states, the file it is reading and the '
          'conflict that comes back.\n\n'
          '<thread id="t-review-1" status="closed">\n'
          '<quote>Which part should the phone show?</quote>\n'
          'The queue, in one list: what waits, what merges, and what needs '
          'a person.\n\n'
          'The diff comes after it, one file at a time, when the queue '
          'says which task failed.\n'
          '</thread>',
      'meta': {'model': 'claude:claude-fable-5-1'},
    },
  ]);
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
  _seed(harness);
  final app = AppController(settings: settings, connector: harness.connector);
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
  double width = 360,
  double height = 800,
  double textScale = 1,
  bool keyboard = false,
  bool reply = false,
  Brightness brightness = Brightness.light,
}) async {
  tester.view.physicalSize = Size(width * 2, height * 2);
  tester.view.devicePixelRatio = 2;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  if (keyboard) addTearDown(tester.view.resetViewInsets);
  final frame = GlobalKey();
  await tester.pumpWidget(
    RepaintBoundary(
      key: frame,
      child: HarnessStyle(
        style: HarnessPlatformStyle.material,
        child: HarnessScope(
          app: rig.app,
          settings: rig.settings,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: HarnessTheme.material(brightness),
            home: SessionScreen(sessionId: _session),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await _settle(tester);
  if (reply) {
    final target = find.byKey(const ValueKey('reply-node-ta1-head'));
    await tester.dragUntilVisible(
      target,
      find.byKey(const ValueKey('transcript-list')),
      const Offset(0, 300),
    );
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
    await tester.tap(target);
    await tester.pumpAndSettle();
  }
  if (keyboard) {
    // The tap opens the keyboard on a real phone; give the box the room the
    // keyboard leaves only after the message to answer is chosen.
    tester.view.viewInsets = const FakeViewPadding(bottom: 520);
    await tester.pumpAndSettle();
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

  testWidgets('draws a reply in a thread on a phone', (tester) async {
    final rig = await _connected();
    final frame = await _pump(tester, rig);
    expect(find.text('Thread'), findsWidgets);
    expect(tester.takeException(), isNull);
    await _shot(tester, frame, shots, 'chat-thread-360.png');
  });

  testWidgets('draws it at 320 points and twice the text', (tester) async {
    final rig = await _connected();
    final frame = await _pump(tester, rig, width: 320, textScale: 2);
    final card = find.byKey(const ValueKey('node-ta1-t-review-1'));
    await tester.dragUntilVisible(
      card,
      find.byKey(const ValueKey('transcript-list')),
      const Offset(0, 300),
    );
    await tester.ensureVisible(card);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Message'), findsOneWidget);
    expect(find.byKey(const Key('session-plan')), findsOneWidget);
    expect(find.byKey(const Key('session-footer')), findsOneWidget);
    await _shot(tester, frame, shots, 'chat-thread-320-text2.png');
  });

  testWidgets('draws the reply box above the keyboard', (tester) async {
    final rig = await _connected();
    final frame = await _pump(
      tester,
      rig,
      keyboard: true,
      reply: true,
      width: 360,
      height: 740,
    );
    expect(find.byTooltip('Cancel reply'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _shot(tester, frame, shots, 'chat-reply-keyboard.png');
  });

  testWidgets('draws the reply box at 320 points, twice the text, with the '
      'keyboard up', (tester) async {
    final rig = await _connected();
    final frame = await _pump(
      tester,
      rig,
      width: 320,
      height: 640,
      textScale: 2,
      keyboard: true,
      reply: true,
    );
    expect(find.byTooltip('Cancel reply'), findsOneWidget);
    expect(find.text('· Message'), findsOneWidget);
    expect(find.byKey(const Key('session-plan')), findsNothing);
    expect(find.byKey(const Key('session-footer')), findsNothing);
    // The field stops at two lines and scrolls: typing cannot push the
    // controls under the keyboard, and the words are all still there.
    await tester.enterText(
      find.byKey(const Key('composer-field')),
      'A line of the reply.\nA second line of it.\nA third line of it.',
    );
    await tester.pump();
    final written = tester.widget<EditableText>(
      find.descendant(
        of: find.byKey(const Key('composer-field')),
        matching: find.byType(EditableText),
      ),
    );
    expect(written.controller.text, contains('A third line of it.'));
    expect(tester.getSize(find.byType(MessageComposer)).height, lessThan(281));
    expect(tester.takeException(), isNull);
    await _shot(tester, frame, shots, 'chat-reply-keyboard-320-text2.png');
  });

  testWidgets('draws an ordinary message being written at 360 points, twice '
      'the text, with the keyboard up', (tester) async {
    final rig = await _connected();
    final frame = await _pump(
      tester,
      rig,
      width: 360,
      height: 740,
      textScale: 2,
      keyboard: true,
    );
    await tester.enterText(
      find.byKey(const Key('composer-field')),
      'The composer keeps words whole at twice the text.',
    );
    await tester.pump();
    expect(find.byTooltip('Cancel reply'), findsNothing);
    expect(find.byKey(const Key('session-footer')), findsNothing);
    expect(tester.takeException(), isNull);
    await _shot(tester, frame, shots, 'chat-composer-keyboard-360-text2.png');
  });

  testWidgets('draws the reply box at 360 points, twice the text, with the '
      'keyboard up', (tester) async {
    final rig = await _connected();
    final frame = await _pump(
      tester,
      rig,
      width: 360,
      height: 740,
      textScale: 2,
      keyboard: true,
      reply: true,
    );
    expect(find.byTooltip('Cancel reply'), findsOneWidget);
    expect(find.textContaining('The queue itself'), findsWidgets);
    await tester.enterText(
      find.byKey(const Key('composer-field')),
      'A line of the reply.\nA second line.\nA third line.',
    );
    await tester.pump();
    expect(find.byKey(const Key('session-footer')), findsNothing);
    expect(tester.takeException(), isNull);
    await _shot(tester, frame, shots, 'chat-reply-keyboard-360-text2.png');
  });

  testWidgets('draws the reply box at 360 points, twice the text, with the '
      'keyboard down', (tester) async {
    final rig = await _connected();
    final frame = await _pump(
      tester,
      rig,
      width: 360,
      height: 740,
      textScale: 2,
      reply: true,
    );
    expect(find.byTooltip('Cancel reply'), findsOneWidget);
    expect(find.byKey(const Key('session-plan')), findsOneWidget);
    expect(find.byKey(const Key('session-footer')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _shot(tester, frame, shots, 'chat-reply-360-text2.png');
  });

  testWidgets('draws it on a wide window', (tester) async {
    final rig = await _connected();
    final frame = await _pump(tester, rig, width: 900, height: 760);
    expect(tester.takeException(), isNull);
    await _shot(tester, frame, shots, 'chat-thread-wide.png');
  });
}
