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

/// A task on the wire, in [column], with [state] and [priority].
Map<String, Object?> _task(
  String column, {
  required String state,
  String priority = 'medium',
  bool backlog = false,
  String? outcome,
}) {
  final now = DateTime.now().millisecondsSinceEpoch / 1000;
  return {
    'id': 'task-$column',
    'name': 'Work in $column',
    'prompt': 'A task in the $column column.',
    'state': state,
    'column': column,
    'priority': priority,
    'project': _main,
    'cwd': _main,
    'created': now,
    'updated': now,
    if (backlog) 'backlog': true,
    if (outcome != null) 'outcome': outcome,
  };
}

/// A harness with a task in every stage and every lane: a task that waits
/// on the person in Active, and the rest spread over the workflow.
Future<(SettingsController, FakeHarness, AppController)> _rig() async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsController();
  await settings.load();
  final harness = FakeHarness()..tasks.clear();
  final tasks = <String, Map<String, Object?>>{
    'task-needs-input': {
      ..._task('needs-input', state: 'active', priority: 'high'),
      'name': 'Fix the import',
    },
    'task-backlog': _task('backlog', state: 'pending', backlog: true),
    'task-pending': _task('pending', state: 'pending', priority: 'low'),
    'task-active': _task('active', state: 'active', priority: 'high'),
    'task-review': _task('review', state: 'review'),
    'task-merging': _task('merging', state: 'merging', priority: 'low'),
    'task-done': _task('done', state: 'done'),
    'task-cancelled': _task('cancelled', state: 'done', outcome: 'cancelled'),
  };
  harness.tasks.addAll(tasks);
  final app = AppController(settings: settings, connector: harness.connector);
  await app.connect('ws://memory/acp');
  return (settings, harness, app);
}

Future<void> _settle(WidgetTester tester, [int rounds = 10]) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 120));
    _takeOverflows(tester);
  }
}

/// The board's header overflows in a phone-wide test view with the test
/// font's square letters; it is no concern of the lanes and columns under
/// test, so overflows are taken, and anything else still fails.
void _takeOverflows(WidgetTester tester) {
  final error = tester.takeException();
  if (error != null && !error.toString().contains('overflowed')) {
    throw error;
  }
}

Future<void> _openTasks(WidgetTester tester, Size size) async {
  final (settings, _, app) = await _rig();
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(HarnessApp(settings: settings, appController: app));
  await tester.pump();
  await _settle(tester, 8);
  await tester.tap(find.text('Tasks'));
  await _settle(tester, 8);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the board of tasks', () {
    test('has the workflow as its columns, in the order a task travels', () {
      expect(taskColumns, const [
        'backlog',
        'pending',
        'active',
        'review',
        'merging',
        'done',
        'cancelled',
      ]);
    });

    test('has the needs-input lane first, then the priorities', () {
      expect(taskLanes, const ['needs-input', 'high', 'medium', 'low']);
    });

    test('puts a task in the lane of what it waits on, else its priority', () {
      HarnessTask task(
        String column, {
        required String state,
        String priority = 'medium',
        bool backlog = false,
      }) => HarnessTask.fromWire({
        ..._task(column, state: state, priority: priority, backlog: backlog),
      });
      // A task that waits on the person is in the needs-input lane, whatever
      // its priority, and over the stage it stopped in.
      final asking = task('needs-input', state: 'active', priority: 'high');
      expect(asking.laneName, 'needs-input');
      expect(asking.stageName, 'active');
      // A returned or paused task waits in Pending, a stopped write-up in
      // the backlog it was written up for.
      expect(task('needs-input', state: 'pending').stageName, 'pending');
      expect(
        task('needs-input', state: 'refining', backlog: true).stageName,
        'backlog',
      );
      // Everything else is in its priority lane, at the stage the harness
      // says.
      final high = task('review', state: 'review', priority: 'high');
      expect(high.laneName, 'high');
      expect(high.stageName, 'review');
      expect(task('active', state: 'active').laneName, 'medium');
      expect(
        task('pending', state: 'pending', priority: 'low').laneName,
        'low',
      );
    });

    test('ranks the stages in workflow order, a stage it does not know after '
        'the backlog', () {
      final ranks = [
        for (final column in taskColumns)
          HarnessTask.fromWire({'id': column, 'column': column}).columnOrder,
      ];
      for (var i = 1; i < ranks.length; i++) {
        expect(
          ranks[i],
          greaterThan(ranks[i - 1]),
          reason: '${taskColumns[i]} comes after ${taskColumns[i - 1]}',
        );
      }
      final unknown = HarnessTask.fromWire({
        'id': 'new',
        'column': 'a-new-column',
      });
      expect(
        unknown.columnOrder,
        greaterThan(ranks[taskColumns.indexOf('backlog')]),
      );
      expect(unknown.columnOrder, lessThan(ranks[taskColumns.indexOf('done')]));
      // A task that waits on the person ranks at its stage.
      final asking = HarnessTask.fromWire({
        'id': 'asking',
        'column': 'needs-input',
        'state': 'review',
      });
      expect(asking.columnOrder, ranks[taskColumns.indexOf('review')]);
    });

    test(
      'lists its stages and lanes in order, and every task in its cell',
      () async {
        final (_, _, app) = await _rig();
        addTearDown(app.dispose);
        await app.tasks!.reload();
        expect(app.tasks!.columns, taskColumns);
        expect(app.tasks!.lanes, taskLanes);
        expect(
          app.tasks!.forCell('needs-input', 'active').map((task) => task.id),
          ['task-needs-input'],
        );
        expect(app.tasks!.forCell('high', 'active').map((task) => task.id), [
          'task-active',
        ]);
        expect(app.tasks!.forCell('medium', 'review').map((task) => task.id), [
          'task-review',
        ]);
        expect(app.tasks!.countForLane('needs-input'), 1);
        expect(
          app.tasks!.countForStage('active'),
          2,
          reason: 'the asking task too',
        );
        // The needs-input lane has the higher priority first; the others keep
        // the harness's own order.
        expect(
          [for (final task in app.tasks!.forLane('needs-input')) task.id],
          ['task-needs-input'],
        );
      },
    );

    testWidgets('shows a lane as tabs on a phone, its stages in workflow '
        'order inside', (tester) async {
      await _openTasks(tester, const Size(1170, 2532));
      final strip = tester.widget<HarnessTabStrip<String>>(
        find.byType(HarnessTabStrip<String>),
      );
      // Every lane holds a task, so every lane is a tab, in this order.
      expect([for (final tab in strip.tabs) tab.value], taskLanes);
      expect(
        [for (final tab in strip.tabs) tab.label],
        const [
          'Needs input',
          'High priority',
          'Medium priority',
          'Low priority',
        ],
      );
      // It opens on what waits on the person, and the task there is drawn
      // under the stage it stopped in.
      expect(strip.value, 'needs-input');
      expect(find.text('Fix the import'), findsOneWidget);
      expect(find.text('Active'), findsOneWidget);

      // The medium lane's stages come in workflow order: Backlog, Review,
      // Done.  Its tab is off the phone's screen: bring it on first.
      final tabs = find.byType(HarnessTabStrip<String>);
      final mediumTab = find.descendant(
        of: tabs,
        matching: find.text('Medium priority'),
      );
      final stripScroll = find
          .descendant(of: tabs, matching: find.byType(Scrollable))
          .first;
      await tester.scrollUntilVisible(mediumTab, 80, scrollable: stripScroll);
      await tester.ensureVisible(mediumTab);
      await tester.pump();
      await tester.tap(mediumTab);
      await _settle(tester, 6);
      final tops = {
        for (final stage in ['Backlog', 'Review', 'Done'])
          stage: tester.getTopLeft(find.text(stage)).dy,
      };
      expect(tops.keys, hasLength(3));
      expect(tops['Backlog'], lessThan(tops['Review']!));
      expect(tops['Review'], lessThan(tops['Done']!));
      expect(find.text('Work in backlog'), findsOneWidget);
      expect(find.text('Work in review'), findsOneWidget);
      expect(find.text('Work in done'), findsOneWidget);
    });

    testWidgets('shows the workflow as the columns of a wide board, the '
        'lanes as rows', (tester) async {
      await _openTasks(tester, const Size(7800, 2700));
      final lefts = {
        for (final stage in taskColumns)
          stage: tester.getTopLeft(find.text(_stageLabel(stage))).dx,
      };
      for (var i = 1; i < taskColumns.length; i++) {
        expect(
          lefts[taskColumns[i]],
          greaterThan(lefts[taskColumns[i - 1]]!),
          reason: '${taskColumns[i]} is right of ${taskColumns[i - 1]}',
        );
      }
      final tops = {
        for (final lane in taskLanes)
          lane: tester.getTopLeft(find.byKey(ValueKey('task-lane-$lane'))).dy,
      };
      for (var i = 1; i < taskLanes.length; i++) {
        expect(
          tops[taskLanes[i]],
          greaterThan(tops[taskLanes[i - 1]]!),
          reason: '${taskLanes[i]} is below ${taskLanes[i - 1]}',
        );
      }
      // The task that waits on the person is in the Needs input row, under
      // the stage it stopped in.
      final activeLeft = lefts['active']!;
      final asking = tester.getTopLeft(find.text('Fix the import'));
      expect(asking.dx, greaterThan(activeLeft - 20));
      expect(asking.dx, lessThan(activeLeft + 300));
      expect(asking.dy, greaterThan(tops['needs-input']!));
      expect(asking.dy, lessThan(tops['high']!));
      // A high-priority task is in the High row, under its stage.
      final active = tester.getTopLeft(find.text('Work in active'));
      expect(active.dx, greaterThan(activeLeft - 20));
      expect(active.dx, lessThan(activeLeft + 300));
      expect(active.dy, greaterThan(tops['high']!));
      expect(active.dy, lessThan(tops['medium']!));
    });
  });
}

String _stageLabel(String stage) => switch (stage) {
  'backlog' => 'Backlog',
  'pending' => 'Pending',
  'active' => 'Active',
  'review' => 'Review',
  'merging' => 'Merging',
  'done' => 'Done',
  'cancelled' => 'Cancelled',
  _ => stage,
};
