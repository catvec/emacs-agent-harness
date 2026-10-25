import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/app.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:harness_client/src/ui/adaptive/layout_widgets.dart';
import 'package:harness_client/src/ui/screens/tasks_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';
import 'support/real_fonts.dart';

const _main = '/Users/noah/Code/emacs-agent-harness/';

class _Rig {
  _Rig(this.settings, this.harness, this.app);
  final SettingsController settings;
  final FakeHarness harness;
  final AppController app;
}

Future<_Rig> _rig({
  bool taskControls = true,
  void Function(FakeHarness harness)? arrange,
}) async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsController();
  await settings.load();
  // Every task has its conversation, where it is handled.
  final harness = FakeHarness(taskControls: taskControls)
    ..seedOtherProjectTasks()
    ..seedTaskSessions();
  arrange?.call(harness);
  final app = AppController(settings: settings, connector: harness.connector);
  await app.connect('ws://memory/acp');
  return _Rig(settings, harness, app);
}

Future<void> _settle(WidgetTester tester, [int rounds = 10]) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

/// The task board of [rig], on a phone, with its tasks read.
Future<void> _openBoard(WidgetTester tester, _Rig rig) async {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    HarnessApp(settings: rig.settings, appController: rig.app),
  );
  await tester.pump();
  await _settle(tester, 8);
  await tester.tap(find.text('Tasks'));
  await _settle(tester, 6);
}

/// Choose the column called [label].  The tabs are a row that scrolls, and
/// only the ones near the screen are there: it is moved until [label] is.
Future<void> _column(WidgetTester tester, String label) async {
  final strip = find.byType(HarnessTabStrip<String>);
  for (final shift in [0.0, 400.0, -400.0, -400.0, -400.0]) {
    if (find.text(label).evaluate().isNotEmpty) break;
    await tester.drag(strip, Offset(shift, 0));
    await tester.pump();
  }
  await tester.ensureVisible(find.text(label).first);
  await tester.tap(find.text(label).first);
  await _settle(tester, 4);
}

/// The card of the task called [title].
Finder _card(String title) =>
    find.ancestor(of: find.text(title), matching: find.byType(TaskCard));

Finder _inCard(String title, Finder what) =>
    find.descendant(of: _card(title), matching: what);

Future<void> _tap(WidgetTester tester, Finder finder, [int rounds = 6]) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await _settle(tester, rounds);
}

/// The bar of the conversation of a task, and what is in it.
const _bar = Key('task-bar');

Finder _inBar(Finder what) =>
    find.descendant(of: find.byKey(_bar), matching: what);

/// Open the menu of the bar, and choose [label] in it.  A menu is a sheet that
/// holds a part of the screen, and a long one scrolls.
Future<void> _menu(WidgetTester tester, String label) async {
  await _tap(tester, find.byTooltip('Task actions'), 4);
  await tester.scrollUntilVisible(
    find.text(label),
    80,
    scrollable: find.descendant(
      of: find.byType(BottomSheet),
      matching: find.byType(Scrollable),
    ),
  );
  await _tap(tester, find.text(label));
}

/// Open the conversation of the task called [title], in [column] of the board:
/// a tap on the task, where it is handled.
Future<void> _open(WidgetTester tester, String column, String title) async {
  await _column(tester, column);
  await tester.tap(find.text(title));
  await _settle(tester, 10);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(loadRealFonts);

  group('a card', () {
    testWidgets('says a task is held, and archived', (tester) async {
      final rig = await _rig(
        arrange: (harness) {
          harness.tasks['task-3']!['hold'] = {
            'kind': 'quota',
            'reason': 'Out of quota',
          };
          harness.tasks['task-6']!['archived'] = true;
        },
      );
      await _openBoard(tester, rig);
      await _column(tester, 'Pending');
      expect(
        _inCard(
          'Cache the model catalogue',
          find.textContaining('Waiting for quota'),
        ),
        findsOneWidget,
      );
    });
  });

  // A task is handled in its conversation: the card opens it, and the bar
  // above its message box offers what the card's menu and the task's sheet once
  // did, the same sets, asked first the same way.
  group('the bar of a task\u2019s conversation', () {
    testWidgets('stops a task at work, once the person has said yes', (
      tester,
    ) async {
      final rig = await _rig();
      await _openBoard(tester, rig);
      const title = 'Build the Flutter ACP client';
      await _open(tester, 'Active', title);

      // Stopping is in the menu, asks first, and asking again changes nothing.
      await _menu(tester, 'Stop');
      expect(find.text('Stop this task?'), findsOneWidget);
      await _tap(tester, find.text('Keep going'));
      expect(rig.harness.calls('_harness/task/cancel'), isEmpty);
      expect(rig.harness.tasks['task-1']!['outcome'], isNull);

      await _menu(tester, 'Stop');
      await _tap(tester, find.text('Stop task'));
      expect(rig.harness.calls('_harness/task/cancel'), [
        {'id': 'task-1'},
      ]);
      // The task is stopped, not gone: it waits for the person, who can retry.
      expect(rig.harness.tasks['task-1']!['outcome'], 'cancelled');
      expect(_inBar(find.text('Needs input')), findsOneWidget);
      expect(_inBar(find.text('Retry')), findsOneWidget);
    });

    testWidgets(
      'drops a task that never started, once the person has said yes',
      (tester) async {
        final rig = await _rig();
        await _openBoard(tester, rig);
        await _open(tester, 'Pending', 'Cache the model catalogue');

        await _menu(tester, 'Drop');
        expect(find.text('Drop this task?'), findsOneWidget);
        await _tap(tester, find.text('Keep it'));
        expect(rig.harness.calls('_harness/task/cancel'), isEmpty);
        expect(rig.harness.tasks.containsKey('task-3'), isTrue);

        await _menu(tester, 'Drop');
        await _tap(tester, find.text('Drop task'));
        expect(rig.harness.calls('_harness/task/cancel'), [
          {'id': 'task-3'},
        ]);
        expect(rig.harness.tasks.containsKey('task-3'), isFalse);
        // Nothing is left to handle: the bar goes with the task.
        expect(find.byKey(_bar), findsNothing);
      },
    );

    testWidgets('lists everything that applies to a task at work', (
      tester,
    ) async {
      final rig = await _rig();
      await _openBoard(tester, rig);
      await _open(tester, 'Active', 'Build the Flutter ACP client');
      // The quick one is a button; the rest is in the menu.
      expect(find.widgetWithText(OutlinedButton, 'Pause'), findsOneWidget);
      await _tap(tester, find.byTooltip('Task actions'), 4);
      final labels = [
        'Return to queue',
        'Mark complete',
        'Priority · High',
        'Stop',
        'Delete task…',
      ];
      // It is a list that scrolls: each is found by going to it.
      for (final label in labels) {
        await tester.scrollUntilVisible(
          find.text(label),
          80,
          scrollable: find.descendant(
            of: find.byType(BottomSheet),
            matching: find.byType(Scrollable),
          ),
        );
        expect(find.text(label), findsOneWidget, reason: label);
      }
      // What is the conversation's own is not offered in it: the session is
      // open, and the message is written in the box.  Nor what is not a way to
      // proceed for work in progress.
      for (final label in [
        'Open session',
        'Message',
        'Start now',
        'Verify and merge',
        'Archive',
      ]) {
        expect(find.text(label), findsNothing, reason: label);
      }
    });

    testWidgets('pauses a task, which waits in Pending to be resumed', (
      tester,
    ) async {
      final rig = await _rig();
      await _openBoard(tester, rig);
      await _open(tester, 'Active', 'Build the Flutter ACP client');
      await _tap(tester, find.widgetWithText(OutlinedButton, 'Pause'));
      expect(rig.harness.calls('_harness/task/pause'), [
        {'id': 'task-1'},
      ]);

      // The bar follows it into Pending, says it is paused, and its main
      // button is the one that undoes it.
      expect(_inBar(find.text('Pending')), findsOneWidget);
      expect(
        _inBar(find.textContaining('Paused', findRichText: true)),
        findsWidgets,
      );
      expect(find.widgetWithText(FilledButton, 'Resume'), findsOneWidget);
      await _tap(tester, find.widgetWithText(FilledButton, 'Resume'));
      expect(rig.harness.calls('_harness/task/resume'), [
        {'id': 'task-1'},
      ]);
      expect(
        _inBar(find.textContaining('Paused', findRichText: true)),
        findsNothing,
      );
      expect(find.widgetWithText(FilledButton, 'Start now'), findsOneWidget);
    });

    testWidgets('returns a task at work to the queue', (tester) async {
      final rig = await _rig();
      await _openBoard(tester, rig);
      await _open(tester, 'Active', 'Build the Flutter ACP client');
      await _menu(tester, 'Return to queue');
      expect(rig.harness.calls('_harness/task/return-to-pending'), [
        {'id': 'task-1'},
      ]);
      expect(_inBar(find.text('Pending')), findsOneWidget);
      expect(
        _inBar(find.textContaining('Paused', findRichText: true)),
        findsNothing,
      );
      expect(find.widgetWithText(FilledButton, 'Start now'), findsOneWidget);
    });

    testWidgets('verifies the work of a task in review, and it is done', (
      tester,
    ) async {
      final rig = await _rig();
      await _openBoard(tester, rig);
      await _open(tester, 'Review', 'Review the emulator screenshots');
      await _tap(tester, find.widgetWithText(FilledButton, 'Verify and merge'));
      expect(rig.harness.calls('_harness/task/verify'), [
        {'id': 'task-2'},
      ]);
      expect(rig.harness.tasks['task-2']!['state'], 'done');
      expect(_inBar(find.text('Done')), findsOneWidget);
    });

    testWidgets('sets a priority from the menu, offering the others', (
      tester,
    ) async {
      final rig = await _rig();
      await _openBoard(tester, rig);
      await _open(tester, 'Pending', 'Cache the model catalogue');
      await _menu(tester, 'Priority · Low');
      // It is low now, so the choices are the others.
      final sheet = find.byType(BottomSheet);
      Finder inSheet(String text) =>
          find.descendant(of: sheet, matching: find.text(text));
      expect(inSheet('Priority is low'), findsOneWidget);
      expect(inSheet('Low priority'), findsNothing);
      expect(inSheet('Medium priority'), findsOneWidget);
      await _tap(tester, inSheet('High priority'));
      expect(rig.harness.calls('_harness/priority/set'), [
        {'session-id': 's-pending', 'priority': 'high'},
      ]);
      expect(rig.harness.tasks['task-3']!['priority'], 'high');
      expect(
        _inBar(find.textContaining('High priority', findRichText: true)),
        findsOneWidget,
      );
    });

    testWidgets('has the message written in its box, not asked for in a dialog', (
      tester,
    ) async {
      final rig = await _rig();
      await _openBoard(tester, rig);
      // A task that is done takes a message up again, as it did from its sheet.
      await _open(tester, 'Done', 'Ship the session list');
      expect(find.text('Message'), findsNothing);
      await tester.enterText(
        find.byKey(const Key('composer-field')),
        'Use the new endpoint too',
      );
      await tester.pump();
      await _tap(tester, find.byKey(const Key('composer-send')));
      expect(rig.harness.prompts.last, 'Use the new endpoint too');
    });

    testWidgets('sends a task in review back with feedback typed in the box', (
      tester,
    ) async {
      final rig = await _rig();
      await _openBoard(tester, rig);
      await _open(tester, 'Review', 'Review the emulator screenshots');
      await _tap(tester, find.widgetWithText(OutlinedButton, 'Send back'));
      // No dialog: the box takes the feedback, and the harness takes a
      // message to a task in review for it.
      expect(find.text('Send it back'), findsNothing);
      await tester.enterText(
        find.byKey(const Key('composer-field')),
        'The footer is cut off',
      );
      await tester.pump();
      await _tap(tester, find.byKey(const Key('composer-send')));
      expect(rig.harness.prompts.last, 'The footer is cut off');
      expect(rig.harness.tasks['task-2']!['state'], 'active');
    });

    testWidgets('asks before marking a task complete', (tester) async {
      final rig = await _rig();
      await _openBoard(tester, rig);
      await _open(tester, 'Review', 'Review the emulator screenshots');
      await _menu(tester, 'Mark complete');
      expect(find.text('Mark this task complete?'), findsOneWidget);
      await _tap(tester, find.text('Cancel'));
      expect(rig.harness.calls('_harness/task/complete'), isEmpty);

      await _menu(tester, 'Mark complete');
      await _tap(tester, find.text('Complete'));
      expect(rig.harness.calls('_harness/task/complete'), [
        {'id': 'task-2'},
      ]);
    });

    testWidgets('deletes a task, and its session when asked', (tester) async {
      final rig = await _rig();
      await _openBoard(tester, rig);
      await _open(tester, 'Active', 'Build the Flutter ACP client');
      await _menu(tester, 'Delete task…');
      expect(find.text('Delete this task?'), findsOneWidget);
      // Asked first: nothing is gone until the person says so.
      await _tap(tester, find.text('Cancel'));
      expect(rig.harness.calls('_harness/task/delete'), isEmpty);

      await _menu(tester, 'Delete task…');
      expect(find.text('Also delete its session'), findsOneWidget);
      await _tap(tester, find.byType(Switch));
      await _tap(tester, find.text('Delete'));
      expect(rig.harness.calls('_harness/task/delete'), [
        {'id': 'task-1', 'delete-session': true},
      ]);
      expect(rig.harness.tasks.containsKey('task-1'), isFalse);
      // Nothing is left to handle: the bar goes with the task.
      expect(find.byKey(_bar), findsNothing);
    });

    testWidgets('does not ask about the session of a task that never started', (
      tester,
    ) async {
      final rig = await _rig();
      await _openBoard(tester, rig);
      await _open(tester, 'Pending', 'Cache the model catalogue');
      await _menu(tester, 'Delete task…');
      expect(find.text('Delete this task?'), findsOneWidget);
      // The harness takes the session of a task that never started with it.
      expect(find.text('Also delete its session'), findsNothing);
    });

    testWidgets('says what the harness said when it refuses', (tester) async {
      final rig = await _rig();
      await _openBoard(tester, rig);
      await _open(tester, 'Review', 'Review the emulator screenshots');
      // Someone verified it in Emacs while the conversation was open.
      rig.harness.tasks['task-2']!
        ..['state'] = 'done'
        ..['column'] = 'done';
      await _tap(tester, find.widgetWithText(FilledButton, 'Verify and merge'));
      expect(
        _inBar(find.text('Task task-2 is not waiting for review')),
        findsOneWidget,
        reason: 'in the bar, where the person is',
      );
      // And the board is read again: the bar says what is so now.
      expect(_inBar(find.text('Done')), findsOneWidget);
    });

    testWidgets('brings an archived task back', (tester) async {
      final rig = await _rig();
      await _openBoard(tester, rig);
      await _open(tester, 'Done', 'Ship the session list');
      await _tap(tester, find.widgetWithText(FilledButton, 'Archive'));
      expect(rig.harness.calls('_harness/task/archive'), [
        {'id': 'task-6'},
      ]);
      // Out of sight on the board, as in Emacs; the conversation still has it.
      expect(find.widgetWithText(FilledButton, 'Unarchive'), findsOneWidget);
      await _tap(tester, find.widgetWithText(FilledButton, 'Unarchive'));
      expect(rig.harness.calls('_harness/task/archive').last, {
        'id': 'task-6',
        'restore': true,
      });
      expect(rig.harness.tasks['task-6']!['archived'], false);
    });
  });

  group('archived tasks', () {
    testWidgets('are kept out of sight until they are asked for', (
      tester,
    ) async {
      final rig = await _rig(
        arrange: (harness) => harness.tasks['task-6']!['archived'] = true,
      );
      await _openBoard(tester, rig);
      // Nothing else is done: the board does not even have the column.
      expect(find.text('Done'), findsNothing);
      expect(find.byTooltip('Show archived tasks'), findsOneWidget);

      await _tap(tester, find.byTooltip('Show archived tasks'));
      expect(find.byTooltip('Hide archived tasks'), findsOneWidget);
      await _column(tester, 'Done');
      expect(_card('Ship the session list'), findsOneWidget);
      expect(
        _inCard('Ship the session list', find.textContaining('Archived')),
        findsOneWidget,
      );
      await tester.tap(find.text('Ship the session list'));
      await _settle(tester, 10);
      await _tap(tester, find.widgetWithText(FilledButton, 'Unarchive'));
      expect(rig.harness.calls('_harness/task/archive').last, {
        'id': 'task-6',
        'restore': true,
      });
    });

    testWidgets('have no button on a board that has none', (tester) async {
      final rig = await _rig();
      await _openBoard(tester, rig);
      expect(find.byTooltip('Show archived tasks'), findsNothing);
    });
  });

  group('the queue', () {
    testWidgets('is paused and resumed by its switch, one project at a time', (
      tester,
    ) async {
      final rig = await _rig();
      await _openBoard(tester, rig);
      await rig.app.tasks!.load(project: _main);
      await _settle(tester, 4);
      await _tap(tester, find.textContaining('working'));
      expect(find.text('Pause the queue'), findsOneWidget);

      await _tap(tester, find.byType(Switch).first);
      expect(rig.harness.calls('_harness/task/suspend-queue'), [
        {'cwd': _main},
      ]);
      expect(rig.harness.suspendedQueues, {_main});
      expect(rig.app.tasks!.slots!.suspended, isTrue);

      await _tap(tester, find.byType(Switch).first);
      expect(rig.harness.calls('_harness/task/resume-queue'), [
        {'cwd': _main},
      ]);
      expect(rig.harness.suspendedQueues, isEmpty);
      expect(rig.harness.calls('_harness/task/toggle-queue'), isEmpty);
    });

    testWidgets('has its backlog queued by itself, or by the person', (
      tester,
    ) async {
      final rig = await _rig();
      await _openBoard(tester, rig);
      await rig.app.tasks!.load(project: _main);
      await _settle(tester, 4);
      await _tap(tester, find.textContaining('working'));
      await _tap(tester, find.byType(Switch).last);
      expect(rig.harness.calls('_harness/task/set-backlog-mode'), [
        {'mode': 'auto', 'cwd': _main},
      ]);
      await _tap(tester, find.byType(Switch).last);
      expect(rig.harness.calls('_harness/task/set-backlog-mode').last, {
        'mode': 'manual',
        'cwd': _main,
      });
    });

    testWidgets('pauses every task of the project, and says how many', (
      tester,
    ) async {
      final rig = await _rig();
      await _openBoard(tester, rig);
      await rig.app.tasks!.load(project: _main);
      await _settle(tester, 4);
      await _tap(tester, find.textContaining('working'));
      await _tap(tester, find.text('Pause all'));
      expect(rig.harness.calls('_harness/task/pause-all'), [
        {'cwd': _main},
      ]);
      expect(find.text('Paused 3 tasks.'), findsOneWidget);
      await _tap(tester, find.text('Resume all'));
      expect(find.text('Resumed 3 tasks.'), findsOneWidget);
    });

    testWidgets('follows Emacs when it pauses the queue', (tester) async {
      final rig = await _rig();
      await _openBoard(tester, rig);
      await rig.app.tasks!.load(project: _main);
      await _settle(tester, 4);
      final paused = find.textContaining('Queue paused', findRichText: true);
      expect(paused, findsNothing);
      rig.harness.suspendedQueues.add(_main);
      rig.harness.announce('task/queue', [_main, true]);
      await _settle(tester, 6);
      expect(paused, findsOneWidget);
    });

    testWidgets('of every project is paused from the board that shows them', (
      tester,
    ) async {
      final rig = await _rig();
      await _openBoard(tester, rig);
      expect(find.textContaining('working'), findsNothing);
      await _tap(tester, find.text('All queues'));
      expect(find.text('Every project'), findsOneWidget);
      await _tap(tester, find.text('Pause every queue'));
      expect(
        rig.harness.calls('_harness/task/suspend-all-queues'),
        hasLength(1),
      );
      expect(rig.harness.suspendedQueues, hasLength(2));
      expect(find.text('Paused 2 queues.'), findsOneWidget);
      await _tap(tester, find.text('Resume every queue'));
      expect(rig.harness.suspendedQueues, isEmpty);
      expect(find.text('Resumed 2 queues.'), findsOneWidget);
      await _tap(tester, find.text('Pause all'));
      expect(rig.harness.calls('_harness/task/pause-all'), [
        <String, Object?>{},
      ]);
    });
  });

  group('a harness from before the controls', () {
    testWidgets('is not offered what it cannot do', (tester) async {
      final rig = await _rig(taskControls: false);
      await _openBoard(tester, rig);
      await _open(tester, 'Active', 'Build the Flutter ACP client');
      expect(find.widgetWithText(OutlinedButton, 'Pause'), findsNothing);
      await _tap(tester, find.byTooltip('Task actions'), 4);
      expect(find.text('Mark complete'), findsOneWidget);
      for (final label in ['Pause', 'Return to queue', 'Delete task…']) {
        expect(find.text(label), findsNothing, reason: label);
      }
    });

    testWidgets('has the queue switched, and no button for every task', (
      tester,
    ) async {
      final rig = await _rig(taskControls: false);
      await _openBoard(tester, rig);
      expect(find.text('All queues'), findsNothing);
      await rig.app.tasks!.load(project: _main);
      await _settle(tester, 4);
      await _tap(tester, find.textContaining('working'));
      expect(find.text('Pause all'), findsNothing);
      await _tap(tester, find.byType(Switch).first);
      expect(rig.harness.calls('_harness/task/toggle-queue'), hasLength(1));
      expect(rig.harness.suspendedQueues, {_main});
    });
  });
}
