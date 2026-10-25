// Pictures of the board of tasks and of a task's conversation, on a phone,
// drawn with the fonts of a phone.
//
//   HARNESS_SHOTS=/some/directory flutter test test/task_bar_screenshots_test.dart
//
// writes a PNG for each case there.  Without HARNESS_SHOTS the cases still
// run (they draw, and check what is on the screen), and write nothing.  The
// keyboard is drawn as a grey block: the test has no keyboard, only the room
// one takes.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/app.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:harness_client/src/ui/adaptive/layout_widgets.dart';
import 'package:harness_client/src/ui/screens/session_screen.dart';
import 'package:harness_client/src/ui/screens/tasks_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';
import 'support/phone_fonts.dart';
import 'support/real_fonts.dart';

enum _Scene {
  board,
  boardReview,
  review,
  feedback,
  backlog,
  stopped,
  menu,
  stopAsks,
  paused,
  queuePaused,
}

/// The project of the tasks that work, in the harness the tests have.
const _main = '/Users/noah/Code/emacs-agent-harness/';

// Named as the screenshots of the README and of the end-to-end run are.
const _cases = {
  // The board is a list to choose from: nothing on a card to push.
  'android-tasks': _Scene.board,
  'android-tasks-review': _Scene.boardReview,
  // A task in review: the report it handed in, then the bar.
  'android-task-review': _Scene.review,
  // Send back: the cursor is in the box, the bar makes room for the keyboard.
  'android-task-feedback': _Scene.feedback,
  // A task that waits in the backlog, and one that stopped on an error.
  'android-task-backlog': _Scene.backlog,
  'android-task-stopped': _Scene.stopped,
  // A task at work: the menu behind the bar's "...", and what is asked before
  // it is stopped.
  'android-task-bar-menu': _Scene.menu,
  'android-task-stop-asks': _Scene.stopAsks,
  // A task that was paused waits in Pending, to be resumed.
  'android-task-paused': _Scene.paused,
  // The queue of a project is on the board, not on a card.
  'android-task-queue-paused': _Scene.queuePaused,
};

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  final shots = Platform.environment['HARNESS_SHOTS'];
  final real = await loadRealFonts();

  const width = 412.0;
  const height = 915.0;
  const ratio = 2.625;
  const keyboard = 300.0;

  for (final MapEntry(key: file, value: scene) in _cases.entries) {
    testWidgets('draws $file', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsController();
      await settings.load();
      final harness = FakeHarness()
        ..seedOtherProjectTasks()
        ..seedTaskSessions();
      if (scene == _Scene.menu || scene == _Scene.stopAsks) {
        // The conversation of the task at work is named as the task is.
        harness.sessions['s3']!['name'] = harness.tasks['task-1']!['name'];
      }
      if (scene == _Scene.stopped) {
        harness.sessions['s2']!['pending'] = <Map<String, Object?>>[];
        harness.tasks['task-4']!['outcome'] = 'error';
        harness.tasks['task-4']!['error'] =
            'The model answered: overloaded (529). Try again in a minute.';
      }
      final app = AppController(
        settings: settings,
        connector: harness.connector,
      );
      await app.connect('ws://memory/acp');

      tester.view.physicalSize = const Size(width * ratio, height * ratio);
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
      final keyboardUp = ValueNotifier<bool>(false);
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: Stack(
            textDirection: TextDirection.ltr,
            children: [
              Positioned.fill(
                child: HarnessApp(
                  settings: settings,
                  appController: app,
                  themeBuilder: phoneFonts,
                ),
              ),
              ValueListenableBuilder<bool>(
                valueListenable: keyboardUp,
                builder: (context, up, _) => up
                    ? const Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        height: keyboard,
                        child: ColoredBox(
                          color: Color(0xFFD3D6DB),
                          child: Center(
                            child: Text(
                              'soft keyboard',
                              textDirection: TextDirection.ltr,
                              style: TextStyle(
                                color: Color(0xFF5F6368),
                                fontFamily: 'Roboto',
                                fontSize: 14,
                                decoration: TextDecoration.none,
                              ),
                            ),
                          ),
                        ),
                      )
                    : const Positioned(
                        left: 0,
                        top: 0,
                        width: 0,
                        height: 0,
                        child: SizedBox.shrink(),
                      ),
              ),
            ],
          ),
        ),
      );
      await tester.pump();
      Future<void> settle([int rounds = 8]) async {
        for (var i = 0; i < rounds; i++) {
          await tester.pump(const Duration(milliseconds: 120));
        }
      }

      await settle(10);
      await tester.tap(find.text('Tasks'));
      await settle(6);

      Future<void> showColumn(String column) async {
        final tabs = find.byType(HarnessTabStrip<String>);
        final tab = find.descendant(of: tabs, matching: find.text(column));
        final strip = find
            .descendant(of: tabs, matching: find.byType(Scrollable))
            .first;
        await tester.drag(strip, const Offset(2000, 0));
        await tester.pump();
        await tester.scrollUntilVisible(tab, 80, scrollable: strip);
        await tester.ensureVisible(tab);
        await tester.pump();
        await tester.tap(tab);
        await settle(4);
      }

      // The queue of the project has its controls on the board; a card has
      // none: it is a way in.
      Finder onCards(Finder what) =>
          find.descendant(of: find.byType(TaskCard), matching: what);

      Future<void> open(String column, String task) async {
        await showColumn(column);
        await tester.tap(find.text(task));
        await settle(10);
      }

      switch (scene) {
        case _Scene.board:
          expect(find.text('Answer the permission'), findsOneWidget);
          expect(find.byType(FilledButton), findsNothing);
          expect(onCards(find.byType(TextButton)), findsNothing);
          expect(find.byTooltip('Task actions'), findsNothing);
        case _Scene.boardReview:
          await showColumn('Review');
          expect(find.text('Review the emulator screenshots'), findsOneWidget);
          expect(find.byType(FilledButton), findsNothing);
          expect(onCards(find.byType(TextButton)), findsNothing);
          expect(find.byTooltip('Task actions'), findsNothing);
        case _Scene.review:
          await open('Review', 'Review the emulator screenshots');
          expect(find.byType(SessionScreen), findsOneWidget);
          expect(find.text('Verify and merge'), findsOneWidget);
        case _Scene.menu:
          await open('Active', 'Build the Flutter ACP client');
          await tester.tap(find.byTooltip('Task actions'));
          await settle(6);
          expect(find.text('Return to queue'), findsOneWidget);
          expect(find.text('Stop'), findsOneWidget);
        case _Scene.stopAsks:
          await open('Active', 'Build the Flutter ACP client');
          await tester.tap(find.byTooltip('Task actions'));
          await settle(6);
          await tester.tap(find.text('Stop'));
          await settle(6);
          expect(find.text('Stop this task?'), findsOneWidget);
        case _Scene.paused:
          await open('Pending', 'Cache the model catalogue');
          await tester.tap(find.text('Pause'));
          await settle(8);
          expect(find.text('Resume'), findsOneWidget);
        case _Scene.queuePaused:
          await app.tasks!.load(project: _main);
          await settle(4);
          await tester.tap(find.textContaining('working'));
          await settle(6);
          await tester.tap(find.byType(Switch).first);
          await settle(4);
          await tester.tap(find.text('Pause all'));
          await settle(6);
          expect(find.text('Paused 3 tasks.'), findsOneWidget);
        case _Scene.feedback:
          await open('Review', 'Review the emulator screenshots');
          await tester.tap(find.text('Send back'));
          await settle(3);
          keyboardUp.value = true;
          tester.view.viewInsets = const FakeViewPadding(
            bottom: keyboard * ratio,
          );
          tester.view.padding = const FakeViewPadding(top: 24 * ratio);
          await tester.pump();
          await settle(4);
          await tester.enterText(
            find.byKey(const Key('composer-field')),
            'Use the large radius on the sheet, and check the dark palette.',
          );
          await tester.pump();
          await settle(4);
          expect(find.text('Verify and merge'), findsNothing);
        case _Scene.backlog:
          await open('Backlog', 'Write the migration notes');
          expect(find.text('Queue it'), findsOneWidget);
        case _Scene.stopped:
          await open('Needs input', 'Answer the permission');
          expect(find.text('Retry'), findsOneWidget);
      }

      if (shots != null) {
        await tester.runAsync(() async {
          final render =
              boundary.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await render.toImage(pixelRatio: 2);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          final out = File('$shots/$file${real ? '' : '-ahem'}.png');
          out.parent.createSync(recursive: true);
          out.writeAsBytesSync(data!.buffer.asUint8List());
        });
      }
    });
  }
}
