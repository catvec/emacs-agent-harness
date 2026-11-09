// Carrying a task card to another column of the board, and what that does:
// the action of the harness that puts the task in the column's state, the
// words a column says while a card is over it, and the drops it refuses.  A
// card is carried along its lane: the columns it can be dropped on are the
// cells of that lane, and on a phone the sections under the lane's tab.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/app.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/board_navigation.dart';
import 'support/fake_harness.dart';
import 'support/real_fonts.dart';

class _Rig {
  _Rig(this.settings, this.harness, this.app);
  final SettingsController settings;
  final FakeHarness harness;
  final AppController app;
}

Future<_Rig> _rig({bool taskControls = true}) async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsController();
  await settings.load();
  final harness = FakeHarness(taskControls: taskControls)
    ..seedOtherProjectTasks()
    ..seedTaskSessions();
  final app = AppController(settings: settings, connector: harness.connector);
  await app.connect('ws://memory/acp');
  return _Rig(settings, harness, app);
}

Future<void> _settle(WidgetTester tester, [int rounds = 10]) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

/// The board on a screen wide enough for every column side by side, with its
/// tasks read.
Future<void> _openWide(WidgetTester tester, _Rig rig) async {
  tester.view.physicalSize = const Size(2600, 1000);
  tester.view.devicePixelRatio = 1.0;
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

/// The board on a phone: one lane at a time, the lanes as tabs and the
/// columns as the sections under the one shown.
Future<void> _openPhone(WidgetTester tester, _Rig rig) async {
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

Finder _card(String taskId) => find.byKey(ValueKey('task-card-$taskId'));

/// The lane [taskId] is drawn in: what waits on the person, else its
/// priority.
String _laneOf(_Rig rig, String taskId) =>
    rig.app.tasks!.tasks.firstWhere((task) => task.id == taskId).laneName;

/// The cell of the board at [column], in the lane of [taskId]: a card is
/// carried along its lane, and dropped on another column of it.
Finder _cell(_Rig rig, String taskId, String column) =>
    find.byKey(ValueKey('task-cell-${_laneOf(rig, taskId)}-$column'));

/// Lift the card of [taskId] with a long press, carry it to [target] (a cell
/// of its lane, or a section), and leave it there; [beforeDrop] runs while it
/// is still over the target.
Future<void> _carry(
  WidgetTester tester,
  String taskId,
  Finder target, {
  Future<void> Function()? beforeDrop,
}) async {
  await tester.ensureVisible(_card(taskId));
  final gesture = await tester.startGesture(
    tester.getCenter(_card(taskId)),
    kind: PointerDeviceKind.touch,
  );
  // The long press that lifts the card (`kLongPressTimeout`).
  await tester.pump(kLongPressTimeout + const Duration(milliseconds: 80));
  // The target the drop is aimed at, which a phone draws while a card is
  // carried, is brought into sight before the card goes to it.
  await tester.ensureVisible(target);
  await tester.pump();
  await gesture.moveTo(tester.getCenter(target));
  await tester.pump(const Duration(milliseconds: 200));
  if (beforeDrop != null) await beforeDrop();
  await gesture.up();
  await tester.pump();
  await _settle(tester, 8);
}

/// The card of [taskId] is in [column] of the board, in whatever lane the
/// board draws it in by then.
void _expectIn(String taskId, String column) {
  final cells = find.byWidgetPredicate((widget) {
    final key = widget.key;
    return key is ValueKey<String> &&
        key.value.startsWith('task-cell-') &&
        key.value.endsWith('-$column');
  });
  expect(
    find.descendant(of: cells, matching: _card(taskId)),
    findsOneWidget,
    reason: 'task $taskId is in $column',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(loadRealFonts);

  group('a card carried to a column', () {
    testWidgets('that starts a waiting task says so, and starts it', (
      tester,
    ) async {
      final rig = await _rig();
      await _openWide(tester, rig);
      expect(find.text('Start now'), findsNothing);
      await _carry(
        tester,
        'task-3',
        _cell(rig, 'task-3', 'active'),
        beforeDrop: () async {
          // The column it is over says what leaving it there does.
          expect(find.text('Start now'), findsOneWidget);
        },
      );
      expect(rig.harness.calls('_harness/task/start').last['id'], 'task-3');
      expect(rig.harness.tasks['task-3']!['column'], 'active');
      _expectIn('task-3', 'active');
      // The count is back once the card is carried off.
      expect(find.text('Start now'), findsNothing);
    });

    testWidgets('that parks a waiting task in the backlog', (tester) async {
      final rig = await _rig();
      await _openWide(tester, rig);
      await _carry(
        tester,
        'task-3',
        _cell(rig, 'task-3', 'backlog'),
        beforeDrop: () async {
          expect(find.text('Move to backlog'), findsOneWidget);
        },
      );
      expect(rig.harness.calls('_harness/task/park').last['id'], 'task-3');
      expect(rig.harness.tasks['task-3']!['column'], 'backlog');
      _expectIn('task-3', 'backlog');
    });

    testWidgets('that returns a working task to the queue', (tester) async {
      final rig = await _rig();
      await _openWide(tester, rig);
      await _carry(
        tester,
        'task-1',
        _cell(rig, 'task-1', 'pending'),
        beforeDrop: () async {
          expect(find.text('Return to queue'), findsOneWidget);
        },
      );
      expect(
        rig.harness.calls('_harness/task/return-to-pending').last['id'],
        'task-1',
      );
      _expectIn('task-1', 'pending');
    });

    testWidgets('that puts a working task in review says so', (tester) async {
      final rig = await _rig();
      await _openWide(tester, rig);
      await _carry(
        tester,
        'task-1',
        _cell(rig, 'task-1', 'review'),
        beforeDrop: () async {
          expect(find.text('Put in review'), findsOneWidget);
        },
      );
      expect(
        rig.harness.calls('_harness/task/force-review').last['id'],
        'task-1',
      );
      expect(rig.harness.tasks['task-1']!['column'], 'review');
      _expectIn('task-1', 'review');
    });

    testWidgets('that verifies a task in review merges it', (tester) async {
      final rig = await _rig();
      await _openWide(tester, rig);
      await _carry(
        tester,
        'task-2',
        _cell(rig, 'task-2', 'merging'),
        beforeDrop: () async {
          expect(find.text('Verify and merge'), findsOneWidget);
        },
      );
      expect(rig.harness.calls('_harness/task/verify').last['id'], 'task-2');
      expect(rig.harness.tasks['task-2']!['column'], 'done');
      _expectIn('task-2', 'done');
    });

    testWidgets('that sends a task in review back asks for the feedback', (
      tester,
    ) async {
      final rig = await _rig();
      await _openWide(tester, rig);
      await _carry(
        tester,
        'task-2',
        _cell(rig, 'task-2', 'active'),
        beforeDrop: () async {
          expect(find.text('Send back'), findsOneWidget);
        },
      );
      // The drop opens the words the work is sent back with; nothing is sent
      // until they are written.  The sheet's title and its button say the same
      // noun, so the button is the one that sends.
      expect(find.text('Return'), findsWidgets);
      expect(rig.harness.calls('_harness/task/reject'), isEmpty);
      await tester.enterText(
        find.byType(TextField).last,
        'Name the files that changed.',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Return'));
      await _settle(tester, 8);
      expect(
        rig.harness.calls('_harness/task/reject').last['feedback'],
        'Name the files that changed.',
      );
      expect(rig.harness.tasks['task-2']!['column'], 'active');
    });

    testWidgets('that cannot take the task refuses it, and leaves it where '
        'it was', (tester) async {
      final rig = await _rig();
      await _openWide(tester, rig);
      await _carry(
        tester,
        'task-3',
        _cell(rig, 'task-3', 'review'),
        beforeDrop: () async {
          // A waiting task was never started: there is no work to review.
          expect(find.text('Put in review'), findsNothing);
        },
      );
      expect(rig.harness.calls('_harness/task/force-review'), isEmpty);
      expect(rig.harness.tasks['task-3']!['column'], 'pending');
      _expectIn('task-3', 'pending');
    });

    testWidgets('that the harness has no action for is refused', (
      tester,
    ) async {
      final rig = await _rig(taskControls: false);
      await _openWide(tester, rig);
      await _carry(tester, 'task-1', _cell(rig, 'task-1', 'review'));
      expect(rig.harness.calls('_harness/task/force-review'), isEmpty);
      expect(rig.harness.tasks['task-1']!['column'], 'active');
      _expectIn('task-1', 'active');
    });
  });

  group('a phone', () {
    testWidgets('shows every column as a target while a card is carried', (
      tester,
    ) async {
      final rig = await _rig();
      await _openPhone(tester, rig);
      // The lane the task at work is drawn in: a phone shows one lane, its
      // columns as the sections under it.
      await showLane(tester, 'High priority');
      expect(find.text('Merging'), findsNothing);
      await _carry(
        tester,
        'task-1',
        find.text('Review'),
        beforeDrop: () async {
          // A column that holds nothing is there to be dropped on.
          expect(find.text('Merging'), findsOneWidget);
        },
      );
      expect(
        rig.harness.calls('_harness/task/force-review').last['id'],
        'task-1',
      );
      expect(rig.harness.tasks['task-1']!['column'], 'review');
    });
  });
}
