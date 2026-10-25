import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart' show CupertinoIcons, CupertinoTextField;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/app.dart';
import 'package:harness_client/src/acp/acp_message.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:harness_client/src/ui/adaptive/adaptive_widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';
import 'support/real_fonts.dart';

// The new task sheet starts from how it was last left: the priority, and the
// three switches (write it up first, plan first, work in the main tree).  What
// is described in it is the draft's, and sending clears that; these four are
// the device's, and sending does not.
//
//   HARNESS_SHOTS=/some/directory flutter test test/new_task_choices_test.dart
//
// also writes pictures of the sheet there, drawn with the fonts of a phone:
// the first time it opens, with the choices made, and opened again once the
// task is sent.  Without HARNESS_SHOTS the same test runs and writes nothing.

class _Rig {
  _Rig(this.settings, this.harness, this.app);
  final SettingsController settings;
  final FakeHarness harness;
  final AppController app;
}

/// The app, signed in to a fake harness, on a device whose preferences hold
/// [stored]: nothing on a first run, what the last run left on a later one.
Future<_Rig> _rig([Map<String, Object> stored = const {}]) async {
  SharedPreferences.setMockInitialValues(stored);
  final settings = SettingsController();
  await settings.load();
  final harness = FakeHarness();
  final app = AppController(settings: settings, connector: harness.connector);
  await app.connect('ws://memory/acp', token: '');
  return _Rig(settings, harness, app);
}

/// What the preferences of the device hold now, as the next run of the app
/// would find them.
Future<Map<String, Object>> _onDisk() async {
  final prefs = await SharedPreferences.getInstance();
  return {for (final key in prefs.getKeys()) key: prefs.get(key)!};
}

Future<void> _pump(WidgetTester tester, _Rig rig) async {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    HarnessApp(settings: rig.settings, appController: rig.app),
  );
  await tester.pump();
  await _settle(tester, 8);
}

Future<void> _settle(WidgetTester tester, [int rounds = 10]) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

/// Go to the task board.
Future<void> _goToTasks(WidgetTester tester) async {
  await tester.tap(find.text('Tasks'));
  await _settle(tester, 5);
}

/// Open the new task sheet, from the task board, whose button is another icon
/// in the style of an iPhone.
Future<void> _openSheet(WidgetTester tester, {bool apple = false}) async {
  await tester.tap(find.byIcon(apple ? CupertinoIcons.add : Icons.add_rounded));
  await _settle(tester, 4);
  expect(find.byKey(const Key('task-priority')), findsOneWidget);
}

/// Close the sheet without sending anything, as a swipe down does.
Future<void> _closeSheet(WidgetTester tester) async {
  Navigator.of(tester.element(find.byKey(const Key('task-priority')))).pop();
  await _settle(tester, 6);
  expect(find.byKey(const Key('task-priority')), findsNothing);
}

/// The field of the description, which is another widget in the style of an
/// iPhone.
Finder get _promptField => find.ancestor(
  of: find.text('Describe the change, the bug, or the question…'),
  matching: find.byWidgetPredicate(
    (widget) => widget is TextField || widget is CupertinoTextField,
  ),
);

Finder _switchOf(String row) => find.descendant(
  of: find.byKey(Key(row)),
  matching: find.byType(HarnessSwitch),
);

/// How the sheet shows its four choices.
typedef _Shown = ({String priority, bool refine, bool plan, bool mainTree});

_Shown _shown(WidgetTester tester) => (
  priority: tester
      .widget<HarnessSegmented<String>>(find.byKey(const Key('task-priority')))
      .value,
  refine: tester.widget<HarnessSwitch>(_switchOf('task-refine')).value,
  plan: tester.widget<HarnessSwitch>(_switchOf('task-plan')).value,
  mainTree: tester.widget<HarnessSwitch>(_switchOf('task-main-tree')).value,
);

const _defaults = (
  priority: 'medium',
  refine: false,
  plan: false,
  mainTree: false,
);

/// Pick a priority on the sheet, as a person taps it.
Future<void> _pick(WidgetTester tester, String label) async {
  final segment = find.descendant(
    of: find.byKey(const Key('task-priority')),
    matching: find.text(label),
  );
  await tester.ensureVisible(segment);
  await tester.tap(segment);
  await _settle(tester, 3);
}

/// Turn one of the three switches, by the key of its row.
Future<void> _flip(WidgetTester tester, String row) async {
  await tester.ensureVisible(_switchOf(row));
  await tester.tap(_switchOf(row));
  await _settle(tester, 3);
}

/// Describe a task and send it, whatever its button says.
Future<void> _send(WidgetTester tester, String prompt) async {
  await tester.enterText(_promptField, prompt);
  await tester.pump();
  final button = find.text(
    _shown(tester).refine ? 'Add to backlog' : 'Submit task',
  );
  await tester.ensureVisible(button);
  await tester.tap(button);
  await _settle(tester, 10);
  expect(find.byKey(const Key('task-priority')), findsNothing);
}

/// The options of the `task/submit` requests the harness got.
List<JsonMap> _submitted(_Rig rig) => [
  for (final (method, params) in rig.harness.requests)
    if (method == '_harness/task/submit') asMap(params['opts']),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Drawn with the fonts of a phone: the board under the sheet does not fit
  // 390 pixels in the test font, whose letters are all squares.
  var realFonts = false;
  setUpAll(() async => realFonts = await loadRealFonts());

  testWidgets('the first sheet starts from the defaults', (tester) async {
    final rig = await _rig();
    await _pump(tester, rig);
    await _goToTasks(tester);
    await _openSheet(tester);
    expect(_shown(tester), _defaults);
    expect(find.text('Submit task'), findsOneWidget);
  });

  testWidgets('a task is begun as the last one was set', (tester) async {
    final rig = await _rig();
    await _pump(tester, rig);
    await _goToTasks(tester);
    await _openSheet(tester);

    await _pick(tester, 'High');
    await _flip(tester, 'task-refine');
    await _flip(tester, 'task-plan');
    await _flip(tester, 'task-main-tree');
    expect(_shown(tester), (
      priority: 'high',
      refine: true,
      plan: true,
      mainTree: true,
    ));
    await _send(tester, 'Tidy the settings page');

    // The task went with them ...
    final sent = _submitted(rig).single;
    expect(sent['priority'], 'high');
    expect(sent['refine'], isTrue);
    expect(sent['plan'], isTrue);
    expect(sent['main-tree'], isTrue);

    // ... and the next sheet has them set, but not the words.
    await _openSheet(tester);
    expect(_shown(tester), (
      priority: 'high',
      refine: true,
      plan: true,
      mainTree: true,
    ));
    expect(find.text('Add to backlog'), findsOneWidget);
    expect(find.text('Submit task'), findsNothing);
    expect(tester.widget<TextField>(_promptField).controller!.text, isEmpty);
  });

  testWidgets('changing a choice and sending it changes what is kept', (
    tester,
  ) async {
    final rig = await _rig();
    await _pump(tester, rig);
    await _goToTasks(tester);
    await _openSheet(tester);
    await _pick(tester, 'High');
    await _flip(tester, 'task-refine');
    await _flip(tester, 'task-main-tree');
    await _send(tester, 'First');

    await _openSheet(tester);
    expect(_shown(tester), (
      priority: 'high',
      refine: true,
      plan: false,
      mainTree: true,
    ));
    // The priority goes down, the main tree off, the plan on; the write-up
    // is left as it was.
    await _pick(tester, 'Low');
    await _flip(tester, 'task-main-tree');
    await _flip(tester, 'task-plan');
    await _send(tester, 'Second');

    final second = _submitted(rig).last;
    expect(second['priority'], 'low');
    expect(second['refine'], isTrue);
    expect(second['plan'], isTrue);
    expect(second.containsKey('main-tree'), isFalse);

    await _openSheet(tester);
    expect(_shown(tester), (
      priority: 'low',
      refine: true,
      plan: true,
      mainTree: false,
    ));
    expect(
      rig.settings.newTaskChoices,
      const NewTaskChoices(priority: 'low', refine: true, plan: true),
    );
  });

  testWidgets('a sheet closed without sending leaves them as they were set', (
    tester,
  ) async {
    final rig = await _rig();
    await _pump(tester, rig);
    await _goToTasks(tester);
    await _openSheet(tester);
    await _pick(tester, 'Low');
    await _flip(tester, 'task-main-tree');
    await _closeSheet(tester);
    expect(_submitted(rig), isEmpty, reason: 'nothing was sent');

    await _openSheet(tester);
    expect(_shown(tester), (
      priority: 'low',
      refine: false,
      plan: false,
      mainTree: true,
    ));

    // A description that was begun comes back with them, as it did.
    await tester.enterText(_promptField, 'Half a thought');
    await tester.pump();
    await _flip(tester, 'task-plan');
    await _closeSheet(tester);
    await _openSheet(tester);
    expect(find.text('Half a thought'), findsOneWidget);
    expect(_shown(tester), (
      priority: 'low',
      refine: false,
      plan: true,
      mainTree: true,
    ));
  });

  testWidgets('they are there when the app is opened again', (tester) async {
    var rig = await _rig();
    await _pump(tester, rig);
    await _goToTasks(tester);
    await _openSheet(tester);
    await _pick(tester, 'High');
    await _flip(tester, 'task-plan');
    await _flip(tester, 'task-main-tree');
    await _closeSheet(tester);

    // The app is closed, and opened again on the same device.
    final kept = await _onDisk();
    expect(kept['newTaskPriority'], 'high');
    expect(kept['newTaskRefine'], isFalse);
    expect(kept['newTaskPlan'], isTrue);
    expect(kept['newTaskMainTree'], isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    rig = await _rig(kept);
    await _pump(tester, rig);
    await _goToTasks(tester);
    await _openSheet(tester);
    expect(_shown(tester), (
      priority: 'high',
      refine: false,
      plan: true,
      mainTree: true,
    ));
  });

  testWidgets('they stay when the connection is lost and comes back', (
    tester,
  ) async {
    final rig = await _rig();
    await _pump(tester, rig);
    await _goToTasks(tester);
    await _openSheet(tester);
    await _pick(tester, 'High');
    await _flip(tester, 'task-main-tree');
    await _closeSheet(tester);

    await rig.app.disconnect();
    await rig.app.connect('ws://memory/acp', token: '');
    await _settle(tester, 8);
    // The board is where it was.
    await _openSheet(tester);
    expect(_shown(tester), (
      priority: 'high',
      refine: false,
      plan: false,
      mainTree: true,
    ));
  });

  test('a task sent without the sheet is sent as it was asked for', () async {
    final rig = await _rig();
    const set = NewTaskChoices(
      priority: 'high',
      refine: true,
      plan: true,
      mainTree: true,
    );
    await rig.settings.setNewTaskChoices(set);

    // What the sheet remembers is the sheet's: another way to send a task
    // neither takes it up nor changes it.
    final task = await rig.app.tasks!.submit(
      cwd: '/work/app',
      prompt: 'Run the tests',
    );
    expect(task, isNotNull);
    final opts = _submitted(rig).single;
    for (final key in ['priority', 'refine', 'plan', 'main-tree']) {
      expect(opts.containsKey(key), isFalse, reason: key);
    }
    expect(rig.settings.newTaskChoices, set);
  });

  for (final apple in [false, true]) {
    testWidgets(
      'draws the sheet as it opens, and as it opens again, '
      'on ${apple ? 'an iPhone' : 'an Android phone'}',
      (tester) => _drawSheet(tester, apple: apple, real: realFonts),
    );
  }
}

/// The sheet the first time it opens, with the choices made, and opened again
/// once the task is sent, as pictures when `HARNESS_SHOTS` says where.  A
/// Material button is drawn in the test font whatever the fonts loaded (see
/// `loadRealFonts`), so the labels of the segments and of the button are
/// squares on an Android phone's picture: the iPhone's name their fonts.
Future<void> _drawSheet(
  WidgetTester tester, {
  required bool apple,
  required bool real,
}) async {
  final shots = Platform.environment['HARNESS_SHOTS'];
  final rig = await _rig();
  if (apple) await rig.settings.setPreviewPlatform(PreviewPlatform.cupertino);
  const ratio = 2.0;
  tester.view.physicalSize = const Size(412 * ratio, 915 * ratio);
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

  final boundary = GlobalKey();
  await tester.pumpWidget(
    RepaintBoundary(
      key: boundary,
      child: HarnessApp(settings: rig.settings, appController: rig.app),
    ),
  );
  await tester.pump();
  await _settle(tester, 8);

  Future<void> shoot(String name) async {
    // The thumb of a switch slides over a moment, and the ripple of a tap
    // fades: both are let go by.
    await tester.pump(const Duration(seconds: 1));
    if (shots == null) return;
    await tester.runAsync(() async {
      final render =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await render.toImage(pixelRatio: 1.5);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File(
        '$shots/$name${apple ? '-ios' : ''}${real ? '' : '-ahem'}.png',
      );
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(data!.buffer.asUint8List());
    });
  }

  await _goToTasks(tester);
  await _openSheet(tester, apple: apple);
  expect(_shown(tester), _defaults);
  // All four controls are on the screen, above the button.
  for (final key in ['task-priority', 'task-main-tree']) {
    expect(tester.getRect(find.byKey(Key(key))).bottom, lessThan(915));
  }
  await shoot('new-task-sheet-first');

  await _pick(tester, 'High');
  await _flip(tester, 'task-refine');
  await _flip(tester, 'task-main-tree');
  await tester.enterText(_promptField, 'Add a dark theme to the settings');
  await tester.pump();
  expect(_shown(tester), (
    priority: 'high',
    refine: true,
    plan: false,
    mainTree: true,
  ));
  await shoot('new-task-sheet-chosen');

  await _send(tester, 'Add a dark theme to the settings');
  await _openSheet(tester, apple: apple);
  expect(_shown(tester), (
    priority: 'high',
    refine: true,
    plan: false,
    mainTree: true,
  ));
  expect(find.text('Add to backlog'), findsOneWidget);
  await shoot('new-task-sheet-reopened');
}
