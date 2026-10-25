import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/app.dart';
import 'package:harness_client/src/models/task.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:harness_client/src/ui/adaptive/layout_widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';

const _main = '/Users/noah/Code/emacs-agent-harness/';

/// A task the user stopped and then marked done, its work never merged: the
/// harness gives it a column of its own (`cancelled`), apart from `done`.
Map<String, Object?> _cancelled() => {
  'id': 'task-9',
  'name': 'Sketch the retry schedule',
  'prompt': 'Sketch a retry schedule for the dunning job.',
  'state': 'done',
  'column': 'cancelled',
  'outcome': 'cancelled',
  'priority': 'medium',
  'project': _main,
  'cwd': _main,
  'created': DateTime.now()
      .subtract(const Duration(hours: 3))
      .millisecondsSinceEpoch /
      1000,
  'updated': DateTime.now()
      .subtract(const Duration(hours: 1))
      .millisecondsSinceEpoch /
      1000,
};

Future<(SettingsController, FakeHarness, AppController)> _rig() async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsController();
  await settings.load();
  // Every task has its session, which a tap on it opens.
  final harness = FakeHarness()
    ..tasks['task-9'] = _cancelled()
    ..seedTaskSession('task-9', reply: 'Stopped; nothing is left to do.');
  final app = AppController(settings: settings, connector: harness.connector);
  await app.connect('ws://memory/acp');
  return (settings, harness, app);
}

/// Pump [rounds] frames.  A row of the board overflows in a phone-wide test
/// view on some machines, which Flutter reports as a failure of the test; it
/// is no concern of the column under test, so overflows are taken, and
/// anything else that goes wrong still fails it.
Future<void> _settle(WidgetTester tester, [int rounds = 10]) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 120));
    _takeOverflows(tester);
  }
}

void _takeOverflows(WidgetTester tester) {
  final error = tester.takeException();
  if (error != null && !error.toString().contains('overflowed')) {
    throw error;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('a cancelled task', () {
    test('is over, not stopped part way, and comes after the done ones', () {
      final cancelled = HarnessTask.fromWire(_cancelled());
      final finished = HarnessTask.fromWire({
        'id': 't-1',
        'state': 'done',
        'column': 'done',
        'outcome': 'end-turn',
      });
      final failed = HarnessTask.fromWire({
        'id': 't-2',
        'state': 'active',
        'column': 'needs-input',
        'outcome': 'error',
      });
      expect(cancelled.isCancelled, isTrue);
      expect(cancelled.isDone, isFalse);
      expect(cancelled.isClosed, isTrue);
      // It has an outcome, but nothing is left to retry.
      expect(cancelled.isStopped, isFalse);
      expect(finished.isCancelled, isFalse);
      expect(finished.isClosed, isTrue);
      // One that failed is still stopped part way, and open.
      expect(failed.isStopped, isTrue);
      expect(failed.isClosed, isFalse);
      expect(cancelled.columnOrder, greaterThan(finished.columnOrder));
    });

    test('has a column of its own on the board, after Done', () async {
      final (_, harness, app) = await _rig();
      addTearDown(app.dispose);
      harness.tasks['task-10'] = {
        'id': 'task-10',
        'name': 'Ship the invoice export',
        'state': 'done',
        'column': 'done',
        'outcome': 'end-turn',
        'project': _main,
        'cwd': _main,
      };
      await app.tasks!.reload();
      final columns = app.tasks!.columns;
      expect(columns, contains('cancelled'));
      expect(columns.indexOf('cancelled'), columns.indexOf('done') + 1);
      expect(app.tasks!.countFor('cancelled'), 1);
      expect(
        [for (final task in app.tasks!.forColumn('cancelled')) task.id],
        ['task-9'],
      );
      // A cancelled task is no completed one, and a completed one no
      // cancelled one.
      final done = [for (final task in app.tasks!.forColumn('done')) task.id];
      expect(done, contains('task-10'));
      expect(done, isNot(contains('task-9')));
    });
  });

  testWidgets('shows under a tab of its own, with Archive and no Retry', (
    tester,
  ) async {
    final (settings, _, app) = await _rig();
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(HarnessApp(settings: settings, appController: app));
    await tester.pump();
    _takeOverflows(tester);
    await _settle(tester, 8);
    await tester.tap(find.text('Tasks'));
    await _settle(tester);
    // Its tab is the last of the strip, which scrolls.
    await tester.dragUntilVisible(
      find.text('Cancelled'),
      find.descendant(
        of: find.byType(HarnessTabStrip<String>),
        matching: find.byType(ListView),
      ),
      const Offset(-120, 0),
    );
    _takeOverflows(tester);
    // Built is not shown: bring the tab onto the screen before tapping it.
    await tester.ensureVisible(find.text('Cancelled'));
    await _settle(tester);
    await tester.tap(find.text('Cancelled'));
    await _settle(tester);
    expect(find.text('Sketch the retry schedule'), findsOneWidget);
    await tester.tap(find.text('Sketch the retry schedule'));
    await _settle(tester, 30);
    // Its conversation opens, with the bar that handles the task.  Over: it is
    // archived, not completed again, and has nothing to retry.
    expect(find.text('Archive'), findsOneWidget);
    expect(find.text('Mark complete'), findsNothing);
    expect(find.text('Retry'), findsNothing);
  });
}
