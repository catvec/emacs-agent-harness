import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/app.dart';
import 'package:harness_client/src/models/task.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:harness_client/src/ui/adaptive/layout_widgets.dart';
import 'package:harness_client/src/ui/screens/session_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/board_navigation.dart';
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
Future<(SettingsController, FakeHarness, AppController)> _rig({
  void Function(FakeHarness harness)? arrange,
}) async {
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
  arrange?.call(harness);
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

Future<(FakeHarness, AppController)> _openTasks(
  WidgetTester tester,
  Size size, {
  void Function(FakeHarness harness)? arrange,
}) async {
  final (settings, harness, app) = await _rig(arrange: arrange);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(HarnessApp(settings: settings, appController: app));
  await tester.pump();
  await _settle(tester, 8);
  await tester.tap(find.text('Tasks'));
  await _settle(tester, 8);
  return (harness, app);
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

    test('reads down a phone in the order a person attends to the work, and '
        'leaves the workflow order of the columns alone', () {
      // The phone: the work blocked on the person, then the work ready for
      // them, the work at work, the work waiting for a slot and the work that
      // is over.
      expect(taskPhoneSections, const [
        'needs-input',
        'review',
        'active',
        'pending',
        'backlog',
        'merging',
        'done',
        'cancelled',
      ]);
      // Every stage has a section and no section is a stage twice; the lane
      // is no stage.
      expect(
        taskPhoneSections.where((section) => section != 'needs-input').toSet(),
        taskColumns.toSet(),
      );
      expect(taskPhoneSections.toSet(), hasLength(taskPhoneSections.length));
      // Pending and the backlog are after Active and before what is over;
      // cancelled is last.
      int at(String section) => taskPhoneSections.indexOf(section);
      expect(at('pending'), greaterThan(at('active')));
      expect(at('backlog'), greaterThan(at('active')));
      expect(at('pending'), lessThan(at('done')));
      expect(at('backlog'), lessThan(at('done')));
      expect(at('done'), lessThan(at('cancelled')));
      expect(taskPhoneSections.last, 'cancelled');
      // The wide board's order is the workflow's, whatever the phone's is:
      // a phone-only change must not reorder it.
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
          reason: 'the asking task too: a stage heading counts every lane',
        );
        // The needs-input lane has the higher priority first; the others keep
        // the harness's own order.
        expect(
          [for (final task in app.tasks!.forLane('needs-input')) task.id],
          ['task-needs-input'],
        );
        expect(
          [for (final task in app.tasks!.forAttention()) task.id],
          ['task-needs-input'],
        );
      },
    );

    test('puts what waits on the person in the lane above the stages, and '
        'the priorities in them', () async {
      final (_, harness, app) = await _rig();
      addTearDown(app.dispose);
      // A low-priority task that waits on the person, beside a high-priority
      // one that does not: a phone's board separates them by lane, and the
      // stage holds only the one that does not wait.
      harness.tasks['task-needs-low'] = {
        ..._task('needs-input', state: 'active', priority: 'low'),
        'id': 'task-needs-low',
        'name': 'A low one asking',
      };
      await app.tasks!.reload();
      expect(
        [for (final task in app.tasks!.forAttention()) task.id],
        ['task-needs-input', 'task-needs-low'],
        reason: 'what waits on the person is the lane above the stages, '
            'the higher priority first',
      );
      expect(
        [for (final task in app.tasks!.forStage('active')) task.id],
        ['task-active'],
        reason: 'the asking tasks are in the lane, not in the stage',
      );
      expect([for (final task in app.tasks!.forStage('review')) task.id], [
        'task-review',
      ]);
      expect([for (final task in app.tasks!.forStage('pending')) task.id], [
        'task-pending',
      ]);
      expect([for (final task in app.tasks!.forStage('backlog')) task.id], [
        'task-backlog',
      ]);
    });

    testWidgets('reads down one list in the order the person attends to the '
        'work: needs input, review, active, pending, backlog, merging, done, '
        'cancelled', (tester) async {
      // A phone's width, tall enough to draw every section at once, so the
      // order the board renders is the order it reads down.
      final (harness, app) = await _openTasks(tester, const Size(1170, 6000));
      // A second task at Review and at Done, of other priorities: a section
      // holds every priority, the higher one first.
      harness.tasks['task-review-high'] = {
        ..._task('review', state: 'review', priority: 'high'),
        'id': 'task-review-high',
        'name': 'Sort the queue',
      };
      harness.tasks['task-done-low'] = {
        ..._task('done', state: 'done', priority: 'low'),
        'id': 'task-done-low',
        'name': 'Old work',
      };
      await app.tasks!.reload();
      await _settle(tester, 6);

      // The lane first, then the stages in the order a person attends to
      // them -- not the order a task travels them.
      final order = [
        'needs-input',
        'review',
        'active',
        'pending',
        'backlog',
        'merging',
        'done',
        'cancelled',
      ];
      final tops = <String, double>{
        for (final section in order)
          section: tester
              .getTopLeft(
                section == 'needs-input'
                    ? find.byKey(const ValueKey('task-lane-needs-input'))
                    : find.byKey(ValueKey('task-section-$section')),
              )
              .dy,
      };
      for (var i = 1; i < order.length; i++) {
        expect(
          tops[order[i]]!,
          greaterThan(tops[order[i - 1]]!),
          reason: '${order[i]} is below ${order[i - 1]} on a phone',
        );
      }
      // Each section says its name and how many cards it holds; every
      // priority is in it.
      expect(_heading(tester, 'needs-input'), ('Needs input', '1'));
      expect(_heading(tester, 'review'), ('Review', '2'));
      expect(_heading(tester, 'active'), ('Active', '1'));
      expect(_heading(tester, 'pending'), ('Pending', '1'));
      expect(_heading(tester, 'backlog'), ('Backlog', '1'));
      expect(_heading(tester, 'merging'), ('Merging', '1'));
      expect(_heading(tester, 'done'), ('Done', '2'));
      expect(_heading(tester, 'cancelled'), ('Cancelled', '1'));
      // Within a section the higher priority comes first, whatever the
      // harness's own order, and the card still says its priority.
      expect(
        tester.getTopLeft(find.text('Sort the queue')).dy,
        lessThan(tester.getTopLeft(find.text('Work in review')).dy),
      );
      expect(_cardMeta(tester, 'task-review-high'), 'High priority · emacs-agent-harness');
      expect(
        tester.getTopLeft(find.text('Work in done')).dy,
        lessThan(tester.getTopLeft(find.text('Old work')).dy),
      );
      expect(_cardMeta(tester, 'task-done-low'), 'Low priority · emacs-agent-harness');
      expect(_cardMeta(tester, 'task-merging'), 'Low priority · emacs-agent-harness');
      expect(_cardMeta(tester, 'task-active'), 'High priority · emacs-agent-harness');
      expect(_cardMeta(tester, 'task-pending'), 'Low priority · emacs-agent-harness');
      expect(_cardMeta(tester, 'task-backlog'), 'Medium priority · emacs-agent-harness');
      // The lane's card says the stage it stopped in and its priority; the
      // lane itself says it waits on the person.
      expect(
        _cardMeta(tester, 'task-needs-input'),
        'Active · High priority · emacs-agent-harness',
      );
      // A task that waits on the person is in the lane only: not again under
      // the stage it stopped in.
      expect(find.text('Fix the import'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('task-section-active')),
          matching: find.byKey(const ValueKey('task-card-task-needs-input')),
        ),
        findsNothing,
      );
      // The sections carry no tab strip: every priority is on the board at
      // once.
      expect(find.byType(HarnessTabStrip<String>), findsNothing);
    });

    testWidgets('draws no section that holds nothing, and no lane when '
        'nothing waits on the person', (tester) async {
      final (harness, app) = await _openTasks(tester, const Size(1170, 6000));
      harness.tasks
        ..remove('task-merging')
        ..remove('task-cancelled')
        ..remove('task-needs-input');
      await app.tasks!.reload();
      await _settle(tester, 6);
      // The lane is drawn when it holds a task, and a stage section when it
      // holds a card that does not wait on the person.
      expect(find.byKey(const ValueKey('task-lane-needs-input')), findsNothing);
      expect(find.byKey(const ValueKey('task-section-merging')), findsNothing);
      expect(find.byKey(const ValueKey('task-section-cancelled')), findsNothing);
      expect(find.text('Merging'), findsNothing);
      expect(find.text('Cancelled'), findsNothing);
      // The rest of the order stands, with the gaps closed.
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('task-section-review'))).dy,
        lessThan(
          tester.getTopLeft(find.byKey(const ValueKey('task-section-active'))).dy,
        ),
      );
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('task-section-backlog'))).dy,
        lessThan(tester.getTopLeft(find.byKey(const ValueKey('task-section-done'))).dy),
      );
      // A board with nothing on it says so.
      harness.tasks.clear();
      await app.tasks!.reload();
      await _settle(tester, 6);
      expect(find.text('No tasks'), findsOneWidget);
      expect(find.text('Needs input'), findsNothing);
    });

    testWidgets('leaves the stage of a task that waits on the person to the '
        'lane, when it holds nothing else', (tester) async {
      final (harness, app) = await _openTasks(
        tester,
        const Size(1170, 2532),
      );
      // The one other task at Active goes: the task that waits on the person
      // is all the stage has, and the lane above says where it is.
      harness.tasks.remove('task-active');
      await app.tasks!.reload();
      await _settle(tester, 6);
      expect(find.text('Fix the import'), findsOneWidget);
      expect(
        find.text('Active'),
        findsNothing,
        reason: 'a stage section holds what does not wait on the person',
      );
      // The card in the lane still says the stage it stopped in.
      expect(
        _cardMeta(tester, 'task-needs-input'),
        'Active · High priority · emacs-agent-harness',
      );
    });

    testWidgets('presents Pending and Backlog as sections of their own, after '
        'Active and before what is over', (tester) async {
      final (harness, app) = await _openTasks(tester, const Size(1170, 6000));
      // Each keeps the state the harness gave it: the queue's task and the
      // backlog's are not merged into one list.
      expect(app.tasks!.forStage('pending').map((task) => task.id), [
        'task-pending',
      ]);
      expect(app.tasks!.forStage('backlog').map((task) => task.id), [
        'task-backlog',
      ]);
      expect(app.tasks!.countForStage('pending'), 1);
      expect(app.tasks!.countForStage('backlog'), 1);
      expect(_heading(tester, 'pending'), ('Pending', '1'));
      expect(_heading(tester, 'backlog'), ('Backlog', '1'));
      final active = tester
          .getTopLeft(find.byKey(const ValueKey('task-section-active')))
          .dy;
      final pending = tester
          .getTopLeft(find.byKey(const ValueKey('task-section-pending')))
          .dy;
      final backlog = tester
          .getTopLeft(find.byKey(const ValueKey('task-section-backlog')))
          .dy;
      final merging = tester
          .getTopLeft(find.byKey(const ValueKey('task-section-merging')))
          .dy;
      final done =
          tester.getTopLeft(find.byKey(const ValueKey('task-section-done'))).dy;
      expect(active, lessThan(pending));
      expect(pending, lessThan(backlog));
      expect(backlog, lessThan(merging));
      expect(merging, lessThan(done));
      // The board's own line above it is unchanged by the sections' order.
      expect(
        find.text('All projects · project queue and backlog settings'),
        findsOneWidget,
      );
      // Put away tasks leave the sections unless they are asked for, and
      // come back in the same places when they are.
      harness.tasks['task-backlog']!['archived'] = true;
      await app.tasks!.reload();
      await _settle(tester, 6);
      expect(find.text('Work in backlog'), findsNothing);
      expect(
        find.byKey(const ValueKey('task-section-backlog')),
        findsNothing,
        reason: 'no section for a stage whose only task was put away',
      );
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('task-section-pending'))).dy,
        lessThan(tester.getTopLeft(find.byKey(const ValueKey('task-section-merging'))).dy),
      );
      app.tasks!.setShowArchived(true);
      await _settle(tester, 4);
      expect(find.text('Work in backlog'), findsOneWidget);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('task-section-backlog'))).dy,
        lessThan(tester.getTopLeft(find.byKey(const ValueKey('task-section-merging'))).dy),
      );
    });

    testWidgets('opens the conversation of a card in any section, in the '
        'order it is drawn', (tester) async {
      late final FakeHarness harness;
      (harness, _) = await _openTasks(
        tester,
        const Size(1170, 6000),
        arrange: (harness) => harness.seedTaskSession('task-review'),
      );
      // A card is a way in, wherever its section is.
      await showTask(tester, 'Work in review');
      await tester.tap(find.text('Work in review'));
      await _settle(tester, 12);
      expect(find.byType(SessionScreen), findsOneWidget);
      expect(harness.calls('session/load').isNotEmpty, isTrue);
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
      // The row says the priority; a card does not repeat it, except for one
      // that waits on the person, whose row is Needs input and not its
      // priority's.
      expect(find.text('Needs input'), findsOneWidget);
      expect(find.text('High priority'), findsOneWidget);
      expect(find.text('Low priority'), findsOneWidget);
      expect(find.text('Medium priority'), findsOneWidget);
      expect(
        _cardMeta(tester, 'task-needs-input'),
        'High priority · emacs-agent-harness',
      );
    });
  });
}

/// The meta line of the card of [taskId], as it is rendered: what its parts
/// say, joined as the card joins them.
String _cardMeta(WidgetTester tester, String taskId) {
  final meta = find.descendant(
    of: find.byKey(ValueKey('task-card-$taskId')),
    matching: find.byType(HarnessMetaLine),
  );
  final text = find.descendant(of: meta, matching: find.byType(RichText));
  return tester.widget<RichText>(text).text.toPlainText();
}

/// The name and the count a section of a phone's board draws: its label and
/// the number beside it, as the section says them.
(String, String) _heading(WidgetTester tester, String section) {
  final of = section == 'needs-input'
      ? find.byKey(const ValueKey('task-lane-needs-input'))
      : find.byKey(ValueKey('task-section-$section'));
  expect(of, findsOneWidget, reason: 'the $section section is drawn');
  final label = _stageLabel(section);
  final heading = find.descendant(of: of, matching: find.text(label));
  expect(heading, findsOneWidget, reason: 'the $section heading says "$label"');
  // The count follows the name in the heading's row: the same row, beside
  // it, and not a number from a card under it.
  final name = tester.getRect(heading);
  final count = find
      .descendant(of: of, matching: find.textContaining(RegExp(r'^\d+$')))
      .evaluate()
      .map((element) => tester.getRect(find.byWidget(element.widget)))
      .where((rect) => (rect.center.dy - name.center.dy).abs() < 2)
      .toList();
  expect(count, hasLength(1), reason: 'one count beside the $section name');
  final text = find
      .descendant(of: of, matching: find.textContaining(RegExp(r'^\d+$')))
      .evaluate()
      .map((element) => (element.widget as Text).data)
      .whereType<String>()
      .toList();
  return (label, text.single);
}

String _stageLabel(String stage) => switch (stage) {
  'needs-input' => 'Needs input',
  'backlog' => 'Backlog',
  'pending' => 'Pending',
  'active' => 'Active',
  'review' => 'Review',
  'merging' => 'Merging',
  'done' => 'Done',
  'cancelled' => 'Cancelled',
  _ => stage,
};
