// A task is handled in its conversation.  Tapping it on the board opens the
// conversation, and the bar above the message box says where the task stands
// and offers what can be done about it: verify, send back (by typing what
// should change), start, queue, try again, stop, complete, archive.  Nothing
// is pushed on the board.
//
// Drawn with the fonts of a phone, as the other tests of the task board are:
// the test font, with its wide letters, squeezes the tabs of the board.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/app.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:harness_client/src/ui/adaptive/layout_widgets.dart';
import 'package:harness_client/src/ui/screens/session_screen.dart';
import 'package:harness_client/src/ui/screens/tasks_screen.dart';
import 'package:harness_client/src/ui/widgets/interaction_card.dart';
import 'package:harness_client/src/ui/widgets/message_composer.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';
import 'support/real_fonts.dart';

Future<void> _settle(WidgetTester tester, [int rounds = 10]) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

const _bar = Key('task-bar');

Finder get _composer => find.byType(MessageComposer);

/// The bar, and what is in it.
Finder _inBar(Finder what) =>
    find.descendant(of: find.byKey(_bar), matching: what);

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  await loadRealFonts();

  late FakeHarness harness;
  late AppController app;

  /// The app, connected to a harness whose tasks have their conversations,
  /// on the Tasks tab of a phone.
  Future<void> open(
    WidgetTester tester, {
    void Function(FakeHarness harness)? arrange,
    Size size = const Size(1170, 2532),
    bool sessions = true,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsController();
    await settings.load();
    harness = FakeHarness();
    if (sessions) harness.seedTaskSessions();
    arrange?.call(harness);
    app = AppController(settings: settings, connector: harness.connector);
    await app.connect('ws://memory/acp');
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(HarnessApp(settings: settings, appController: app));
    await tester.pump();
    await _settle(tester, 8);
    await tester.tap(find.text('Tasks'));
    await _settle(tester, 6);
  }

  /// The tab of [column], scrolled to: the strip builds the tabs it shows.
  Future<void> showColumn(WidgetTester tester, String column) async {
    final tabs = find.byType(HarnessTabStrip<String>);
    final tab = find.descendant(of: tabs, matching: find.text(column));
    final strip = find
        .descendant(of: tabs, matching: find.byType(Scrollable))
        .first;
    // From the first tab on, whichever the strip showed.
    await tester.drag(strip, const Offset(2000, 0));
    await tester.pump();
    await tester.scrollUntilVisible(tab, 80, scrollable: strip);
    // All of it, not an edge of it that a tap would miss.
    await tester.ensureVisible(tab);
    await tester.pump();
    await tester.tap(tab);
    await _settle(tester, 4);
  }

  /// Tap [title] in the [column] of the board: its conversation opens.
  Future<void> openTask(
    WidgetTester tester,
    String column,
    String title,
  ) async {
    await showColumn(tester, column);
    await tester.tap(find.text(title));
    await _settle(tester, 10);
  }

  /// The heading of the bar: where the task stands.
  String heading(WidgetTester tester) {
    final texts = tester.widgetList<Text>(_inBar(find.byType(Text))).toList();
    return texts.first.data ?? '';
  }

  group('a tap on a task, in any column,', () {
    const columns = [
      // column, task, the conversation it opens, what its bar says.
      ('Needs input', 'Answer the permission', 'Fix duplicate task titles'),
      ('Active', 'Build the Flutter ACP client', 'Polish the iOS sheet'),
      ('Review', 'Review the emulator screenshots', 'Tidy the tool cards'),
      ('Pending', 'Cache the model catalogue', 'Cache the model catalogue'),
      ('Backlog', 'Write the migration notes', 'Write the migration notes'),
      ('Done', 'Ship the session list', 'Ship the session list'),
    ];
    for (final (column, task, conversation) in columns) {
      testWidgets('opens the conversation of "$task"', (tester) async {
        await open(tester);
        expect(find.byType(SessionScreen), findsNothing);
        await openTask(tester, column, task);
        expect(find.byType(SessionScreen), findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(AppBar),
            matching: find.text(conversation),
          ),
          findsOneWidget,
        );
        // Where the task stands is said there, but for a task that waits
        // for an answer, whose conversation has the question in its place.
        if (column == 'Needs input') {
          expect(find.byType(InteractionCard), findsOneWidget);
          expect(find.byKey(_bar), findsNothing);
        } else {
          expect(heading(tester), column);
        }
      });
    }

    testWidgets('has nothing on the card to push', (tester) async {
      await open(tester);
      for (final column in ['Review', 'Pending', 'Backlog', 'Active']) {
        await showColumn(tester, column);
        // A card is a way in: no button of any kind on it, no menu.
        for (final kind in [
          TextButton,
          FilledButton,
          OutlinedButton,
          IconButton,
        ]) {
          expect(
            find.descendant(
              of: find.byType(TaskCard),
              matching: find.byType(kind),
            ),
            findsNothing,
            reason: '$column: $kind',
          );
        }
        expect(find.byTooltip('Task actions'), findsNothing, reason: column);
        expect(find.byTooltip('Verify task'), findsNothing, reason: column);
        expect(find.text('Start now'), findsNothing, reason: column);
        expect(find.text('Verify and merge'), findsNothing, reason: column);
      }
    });

    testWidgets('of a task just submitted opens its own conversation', (
      tester,
    ) async {
      await open(tester, sessions: false);
      await app.tasks!.submit(
        cwd: app.selectedProject!,
        prompt: 'Write the changelog',
        priority: 'medium',
      );
      await _settle(tester, 6);
      await openTask(tester, 'Pending', 'Write the changelog');
      expect(find.byType(SessionScreen), findsOneWidget);
      expect(heading(tester), 'Pending');
      expect(find.text('Start now'), findsOneWidget);
      // The task is its first message.
      expect(find.text('Write the changelog'), findsWidgets);
    });

    testWidgets('of a task sent with pictures says how many', (tester) async {
      await open(
        tester,
        arrange: (harness) {
          harness.tasks['task-3']!['attachments'] = [
            {
              'name': 'shown.png',
              'path': '/state/attachments/task-3/shown.png',
            },
            {
              'name': 'other.png',
              'path': '/state/attachments/task-3/other.png',
            },
          ];
        },
      );
      await openTask(tester, 'Pending', 'Cache the model catalogue');
      expect(
        _inBar(find.textContaining('2 attachments', findRichText: true)),
        findsOneWidget,
      );
    });

    testWidgets('of a task with no conversation says so and stays', (
      tester,
    ) async {
      await open(tester, sessions: false);
      await openTask(tester, 'Review', 'Review the emulator screenshots');
      expect(find.byType(SessionScreen), findsNothing);
      expect(
        find.text(
          '“Review the emulator screenshots” has no conversation to open.',
        ),
        findsOneWidget,
      );
      // The notice goes with a tap on the next task that has one.
      await showColumn(tester, 'Needs input');
      await tester.tap(find.text('Answer the permission'));
      await _settle(tester, 8);
      expect(find.byType(SessionScreen), findsOneWidget);
    });
  });

  group('the conversation of a task in review', () {
    Future<void> review(WidgetTester tester) async {
      await open(tester);
      await openTask(tester, 'Review', 'Review the emulator screenshots');
    }

    testWidgets('verifies it from the bar, with the report above', (
      tester,
    ) async {
      await review(tester);
      // The report it handed in is in the conversation, then the bar.
      expect(
        find.textContaining('Tool call results are hard to read'),
        findsWidgets,
      );
      expect(heading(tester), 'Review');
      expect(find.text('Verify and merge'), findsOneWidget);
      expect(find.text('Send back'), findsOneWidget);
      expect(
        find.text('Feedback · sending it sends the task back'),
        findsOneWidget,
      );

      await tester.tap(find.text('Verify and merge'));
      await _settle(tester, 8);

      expect(harness.tasks['task-2']!['state'], 'done');
      expect(harness.tasks['task-2']!['verified'], isTrue);
      // The bar follows the task, and the box says what it always did.
      expect(heading(tester), 'Done');
      expect(find.text('Verify and merge'), findsNothing);
      expect(find.text('Archive'), findsOneWidget);
      expect(
        _inBar(find.textContaining('· Verified', findRichText: true)),
        findsOneWidget,
      );
      expect(
        find.text('Feedback · sending it sends the task back'),
        findsNothing,
      );
    });

    testWidgets('is sent back by typing what should change', (tester) async {
      await review(tester);
      final field = find.byKey(const Key('composer-field'));
      final focus = tester
          .widget<EditableText>(
            find.descendant(of: field, matching: find.byType(EditableText)),
          )
          .focusNode;
      expect(focus.hasFocus, isFalse);

      await tester.tap(find.text('Send back'));
      await _settle(tester, 3);
      // The cursor is in the box: that is where the feedback is written.
      expect(focus.hasFocus, isTrue);
      expect(harness.tasks['task-2']!['state'], 'review');

      await tester.enterText(field, 'Use the large radius on the sheet');
      await tester.pump();
      await tester.tap(find.byKey(const Key('composer-send')));
      await _settle(tester, 10);

      // The harness takes a message to a task in review for the feedback.
      expect(harness.prompts.last, 'Use the large radius on the sheet');
      expect(harness.tasks['task-2']!['state'], 'active');
      final rounds = harness.tasks['task-2']!['feedback'] as List;
      expect((rounds.last as Map)['text'], 'Use the large radius on the sheet');
      expect(heading(tester), 'Active');
      expect(find.text('Verify and merge'), findsNothing);
    });

    testWidgets('says why the harness refused, and keeps its buttons', (
      tester,
    ) async {
      await review(tester);
      harness.taskActionError = 'Task task-2 is not waiting for review';
      await tester.tap(find.text('Verify and merge'));
      await _settle(tester, 6);
      expect(
        find.text('Task task-2 is not waiting for review'),
        findsOneWidget,
      );
      expect(find.text('Verify and merge'), findsOneWidget);
      // Dismissed, it goes.
      await tester.tap(find.byTooltip('Dismiss'));
      await _settle(tester, 2);
      expect(find.text('Task task-2 is not waiting for review'), findsNothing);
      // And a push that goes through takes it away on its own.
      harness.taskActionError = null;
      await tester.tap(find.text('Verify and merge'));
      await _settle(tester, 6);
      expect(harness.tasks['task-2']!['state'], 'done');
    });

    testWidgets('marks it complete from the menu, after asking', (
      tester,
    ) async {
      await review(tester);
      await tester.tap(find.byTooltip('Task actions'));
      await _settle(tester, 4);
      await tester.tap(find.text('Mark complete'));
      await _settle(tester, 4);
      expect(find.text('Mark this task complete?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await _settle(tester, 4);
      expect(harness.tasks['task-2']!['state'], 'review');

      await tester.tap(find.byTooltip('Task actions'));
      await _settle(tester, 4);
      await tester.tap(find.text('Mark complete'));
      await _settle(tester, 4);
      await tester.tap(find.text('Complete'));
      await _settle(tester, 8);
      expect(harness.tasks['task-2']!['state'], 'done');
    });
  });

  group('the conversation of a task that has not started', () {
    testWidgets('in the backlog queues it, then a message starts it', (
      tester,
    ) async {
      await open(tester);
      await openTask(tester, 'Backlog', 'Write the migration notes');
      expect(heading(tester), 'Backlog');
      expect(find.text('Start now'), findsOneWidget);
      expect(find.text('Queue it'), findsOneWidget);
      expect(find.text('Message · sending it starts the task'), findsOneWidget);

      await tester.tap(find.text('Queue it'));
      await _settle(tester, 8);
      expect(harness.tasks['task-5']!['column'], 'pending');
      expect(heading(tester), 'Pending');
      expect(find.text('Start now'), findsOneWidget);
      expect(find.text('Queue it'), findsNothing);
      expect(find.text('Message · sending it starts the task'), findsNothing);
    });

    testWidgets('in the backlog is started by a message too', (tester) async {
      await open(tester);
      await openTask(tester, 'Backlog', 'Write the migration notes');
      await tester.enterText(
        find.byKey(const Key('composer-field')),
        'Go ahead',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('composer-send')));
      await _settle(tester, 10);
      expect(harness.tasks['task-5']!['state'], 'active');
      expect(heading(tester), 'Active');
    });

    testWidgets('in the backlog is started from the bar', (tester) async {
      await open(tester);
      await openTask(tester, 'Backlog', 'Write the migration notes');
      await tester.tap(find.text('Start now'));
      await _settle(tester, 8);
      expect(harness.tasks['task-5']!['state'], 'active');
      expect(heading(tester), 'Active');
    });

    testWidgets('waiting for a slot is started at once', (tester) async {
      await open(tester);
      await openTask(tester, 'Pending', 'Cache the model catalogue');
      expect(heading(tester), 'Pending');
      await tester.tap(find.text('Start now'));
      await _settle(tester, 8);
      expect(harness.tasks['task-3']!['state'], 'active');
      expect(heading(tester), 'Active');
    });
  });

  group('the conversation of a task at work', () {
    testWidgets('has its state, a pause and a menu: nothing to stop by mistake', (
      tester,
    ) async {
      await open(tester);
      await openTask(tester, 'Active', 'Build the Flutter ACP client');
      expect(heading(tester), 'Active');
      // One button, the one that undoes itself; stopping is in the menu.
      expect(_inBar(find.byType(FilledButton)), findsNothing);
      expect(_inBar(find.byType(OutlinedButton)), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Pause'), findsOneWidget);
      expect(find.text('Stop'), findsNothing);
      expect(find.byTooltip('Task actions'), findsOneWidget);
      expect(
        _inBar(find.textContaining('High priority', findRichText: true)),
        findsOneWidget,
      );
      expect(
        _inBar(
          find.textContaining('task/flutter-acp-client', findRichText: true),
        ),
        findsOneWidget,
      );
    });
  });

  group('the conversation of a task that stopped', () {
    testWidgets('says why, and tries it again', (tester) async {
      await open(
        tester,
        arrange: (harness) {
          harness.sessions['s2']!['pending'] = <Map<String, Object?>>[];
          harness.tasks['task-4']!['outcome'] = 'error';
          harness.tasks['task-4']!['error'] = 'The model said: overloaded';
        },
      );
      await openTask(tester, 'Needs input', 'Answer the permission');
      expect(heading(tester), 'Needs input');
      expect(find.text('Its last turn ended in an error.'), findsOneWidget);
      expect(find.text('The model said: overloaded'), findsOneWidget);

      await tester.tap(find.text('Retry'));
      await _settle(tester, 8);
      expect([
        for (final request in harness.requests) request.$1,
      ], contains('_harness/task/retry'));
      expect(heading(tester), 'Active');
    });

    testWidgets('whose merge failed has it queued again', (tester) async {
      await open(
        tester,
        arrange: (harness) {
          harness.sessions['s2']!['pending'] = <Map<String, Object?>>[];
          harness.tasks['task-4']!['outcome'] = 'merge-failed';
          harness.tasks['task-4']!['conflicts'] = ['lib/a.dart', 'lib/b.dart'];
        },
      );
      await openTask(tester, 'Needs input', 'Answer the permission');
      expect(find.text('Retry merge'), findsOneWidget);
      expect(
        find.textContaining('conflicts in lib/a.dart, lib/b.dart'),
        findsOneWidget,
      );
    });
  });

  group('the conversation of a finished task', () {
    testWidgets('is put away, and brought back', (tester) async {
      await open(tester);
      await openTask(tester, 'Done', 'Ship the session list');
      expect(heading(tester), 'Done');
      await tester.tap(find.text('Archive'));
      await _settle(tester, 8);
      expect(harness.tasks['task-6']!['archived'], isTrue);
      // The conversation still has the task, which says so and offers to bring
      // it back (the board hides it, as the board of Emacs does).
      expect(heading(tester), 'Done');
      expect(
        _inBar(find.textContaining('Archived', findRichText: true)),
        findsOneWidget,
      );
      expect(find.text('Archive'), findsNothing);
      await tester.tap(find.text('Unarchive'));
      await _settle(tester, 8);
      expect(harness.tasks['task-6']!['archived'], isFalse);
      expect(find.text('Archive'), findsOneWidget);
    });
  });

  group('the bar', () {
    testWidgets('is not in the conversation of a session that is no task\'s', (
      tester,
    ) async {
      await open(tester);
      await tester.tap(find.text('Sessions'));
      await _settle(tester, 6);
      await tester.tap(find.text('Design the merge queue'));
      await _settle(tester, 8);
      expect(find.byType(SessionScreen), findsOneWidget);
      expect(find.byKey(_bar), findsNothing);
      expect(find.text('Message the harness'), findsOneWidget);
    });

    testWidgets('is there for a task the board is narrowed away from', (
      tester,
    ) async {
      await open(tester);
      await app.tasks!.load(project: '/Users/noah/Code/other-project/');
      await _settle(tester, 4);
      await tester.tap(find.text('Sessions'));
      await _settle(tester, 6);
      await tester.tap(find.text('Tidy the tool cards'));
      await _settle(tester, 10);
      expect(heading(tester), 'Review');
      expect(find.text('Verify and merge'), findsOneWidget);
    });

    testWidgets('is in the pane of a wide screen too', (tester) async {
      await open(tester, size: const Size(3000, 1800));
      await tester.tap(find.text('Review the emulator screenshots'));
      await _settle(tester, 10);
      expect(find.byType(SessionScreen), findsOneWidget);
      expect(heading(tester), 'Review');
      await tester.tap(find.text('Verify and merge'));
      await _settle(tester, 8);
      expect(harness.tasks['task-2']!['state'], 'done');
    });

    testWidgets('gives its room to the keyboard, but for the state', (
      tester,
    ) async {
      await open(tester);
      await openTask(tester, 'Review', 'Review the emulator screenshots');
      expect(find.text('Verify and merge'), findsOneWidget);
      tester.view.viewInsets = const FakeViewPadding(bottom: 900);
      addTearDown(tester.view.resetViewInsets);
      await _settle(tester, 4);
      // One line: where the task stands, and the menu.
      expect(heading(tester), 'Review');
      expect(find.text('Verify and merge'), findsNothing);
      expect(find.text('Send back'), findsNothing);
    });

    testWidgets('sits above the message box, its actions in one row', (
      tester,
    ) async {
      await open(tester);
      await openTask(tester, 'Review', 'Review the emulator screenshots');
      final bar = tester.getRect(find.byKey(_bar));
      final composer = tester.getRect(_composer);
      expect(bar.bottom, lessThanOrEqualTo(composer.top + 0.5));
      expect(bar.left, 0);
      expect(bar.width, tester.view.physicalSize.width / 3);

      final verify = tester.getRect(
        find.widgetWithText(FilledButton, 'Verify and merge'),
      );
      final back = tester.getRect(
        find.widgetWithText(OutlinedButton, 'Send back'),
      );
      // The one to take is the wider, and they share a row.
      expect(verify.top, closeTo(back.top, 2));
      expect(verify.right, lessThan(back.left));
      expect(verify.width, greaterThan(back.width));
      expect(back.right, lessThanOrEqualTo(bar.right));
    });

    testWidgets('fits a small phone', (tester) async {
      await open(tester, size: const Size(960, 2000));
      await openTask(tester, 'Review', 'Review the emulator screenshots');
      expect(tester.takeException(), isNull);
      final bar = tester.getRect(find.byKey(_bar));
      for (final label in ['Verify and merge', 'Send back']) {
        final button = tester.getRect(
          find.ancestor(
            of: find.text(label),
            matching: find.byWidgetPredicate(
              (widget) => widget is FilledButton || widget is OutlinedButton,
            ),
          ),
        );
        expect(button.right, lessThanOrEqualTo(bar.right), reason: label);
        expect(button.left, greaterThanOrEqualTo(bar.left), reason: label);
      }
    });
  });
}
