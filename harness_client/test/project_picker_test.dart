import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/app.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';
import 'support/real_fonts.dart';

// How the two sheets that make work pick their project: a task of a board
// narrowed to one project goes to it without asking, and every other project
// is a dropdown, not a wrap of pills that a harness with many projects fills
// the sheet with.
//
//   HARNESS_SHOTS=/some/directory flutter test test/project_picker_test.dart
//
// also writes pictures of the sheets there, drawn with the fonts of a phone.

const _main = '/Users/noah/Code/emacs-agent-harness/';
const _other = '/Users/noah/Code/other-project/';

class _Rig {
  _Rig(this.settings, this.harness, this.app);
  final SettingsController settings;
  final FakeHarness harness;
  final AppController app;
}

Future<_Rig> _rig({
  bool worktrees = false,
  bool scratch = false,
  bool projectMains = true,
  bool tidyProjects = true,
  void Function(FakeHarness harness)? arrange,
}) async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsController();
  await settings.load();
  final harness = FakeHarness(
    projectMains: projectMains,
    tidyProjects: tidyProjects,
  )..seedOtherProjectTasks();
  arrange?.call(harness);
  if (worktrees) harness.seedWorktreeSessions();
  if (scratch) harness.seedScratchSessions();
  final app = AppController(settings: settings, connector: harness.connector);
  await app.connect('ws://memory/acp', token: '');
  return _Rig(settings, harness, app);
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

Future<void> _goToTasks(WidgetTester tester) async {
  await tester.tap(find.text('Tasks'));
  await _settle(tester, 6);
}

/// Open the new task sheet, from the task board.
Future<void> _openTaskSheet(WidgetTester tester, {bool apple = false}) async {
  await tester.tap(find.byIcon(apple ? CupertinoIcons.add : Icons.add_rounded));
  await _settle(tester, 4);
  expect(find.byKey(const Key('task-priority')), findsOneWidget);
}

/// Open the new session sheet, from the sessions screen.
Future<void> _openSessionSheet(
  WidgetTester tester, {
  bool apple = false,
}) async {
  await tester.tap(find.text('Sessions').first);
  await _settle(tester, 6);
  await tester.tap(find.byIcon(apple ? CupertinoIcons.add : Icons.add_rounded));
  await _settle(tester, 4);
  expect(find.text('Start session'), findsOneWidget);
}

/// The description field of the new task sheet, in the style of the phone.
Finder get _promptField => find.ancestor(
  of: find.text('Describe the change, the bug, or the question…'),
  matching: find.byWidgetPredicate(
    (widget) => widget is TextField || widget is CupertinoTextField,
  ),
);

/// Describe and send a task, through the sheet.
Future<void> _sendTask(WidgetTester tester, String prompt) async {
  await tester.enterText(_promptField, prompt);
  await tester.pump();
  await tester.ensureVisible(find.text('Submit task'));
  await tester.tap(find.text('Submit task'));
  await _settle(tester, 10);
  expect(find.byKey(const Key('task-priority')), findsNothing);
}

/// The project to choose, on the new task sheet, and its dropdown menu.
Finder get _taskProject => find.byKey(const Key('task-project'));

/// The project the new task sheet fixes when the board is narrowed to one.
Finder get _fixedTaskProject => find.byKey(const Key('task-project-fixed'));

/// What a dropdown shows, as the text inside it.
Finder _in(Finder field, String text) =>
    find.descendant(of: field, matching: find.text(text));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Drawn with the fonts of a phone: the test font's letters are all
  // squares, and the board and the sheets do not fit at the width a
  // phone has.
  var realFonts = false;
  setUpAll(() async => realFonts = await loadRealFonts());

  testWidgets('a task sheet on every project picks its project from a '
      'dropdown', (tester) async {
    final rig = await _rig();
    await _pump(tester, rig);
    await _goToTasks(tester);
    await _openTaskSheet(tester);

    // One field, naming the project of the latest work, not a pill for
    // every project: a harness with many of them would fill the sheet.
    expect(_taskProject, findsOneWidget);
    expect(_in(_taskProject, 'emacs-agent-harness'), findsOneWidget);
    expect(_in(_taskProject, 'other-project'), findsNothing);
    expect(find.text(_other), findsNothing);

    await tester.tap(_taskProject);
    await _settle(tester, 4);
    final menu = find.byType(BottomSheet).last;
    expect(
      find.descendant(of: menu, matching: find.text('Projects')),
      findsOneWidget,
    );
    await tester.tap(
      find.descendant(of: menu, matching: find.text('other-project')),
    );
    await _settle(tester, 3);
    // What is chosen is named on the field, and in the path it fills.
    expect(_in(_taskProject, 'other-project'), findsOneWidget);
    expect(find.text(_other), findsOneWidget);

    await _sendTask(tester, 'Publish the docs site');
    expect(rig.harness.calls('_harness/task/submit').single['cwd'], _other);
  });

  testWidgets('a task sheet on a narrowed board asks for no project', (
    tester,
  ) async {
    final rig = await _rig();
    await _pump(tester, rig);
    await _goToTasks(tester);
    await rig.app.tasks!.load(project: _other);
    await _settle(tester, 4);
    await _openTaskSheet(tester);

    // The project is said, not asked: no dropdown, no path to another one.
    expect(_taskProject, findsNothing);
    expect(_fixedTaskProject, findsOneWidget);
    expect(_in(_fixedTaskProject, 'other-project'), findsOneWidget);
    expect(find.text('/absolute/path/to/project'), findsNothing);
    expect(find.byIcon(Icons.folder_open_rounded), findsNothing);

    await _sendTask(tester, 'Renew the certificates');
    expect(rig.harness.calls('_harness/task/submit').single['cwd'], _other);
    expect(rig.app.tasks!.project, _other);
  });

  testWidgets('a draft begun in another project does not decide a narrowed '
      "board's task", (tester) async {
    final rig = await _rig();
    await _pump(tester, rig);
    await _goToTasks(tester);

    // A draft begun on the board of every project, with another project
    // chosen.
    await _openTaskSheet(tester);
    await tester.tap(_taskProject);
    await _settle(tester, 4);
    await tester.tap(
      find.descendant(
        of: find.byType(BottomSheet).last,
        matching: find.text('other-project'),
      ),
    );
    await _settle(tester, 3);
    await tester.enterText(_promptField, 'Publish the docs site');
    await tester.pump();
    Navigator.of(tester.element(find.text('Submit task'))).pop();
    await _settle(tester, 4);

    // Opened again from a board narrowed to another project, the sheet
    // keeps the description and takes the board's project.
    await rig.app.tasks!.load(project: _main);
    await _settle(tester, 4);
    await _openTaskSheet(tester);
    expect(find.text('Publish the docs site'), findsOneWidget);
    expect(_taskProject, findsNothing);
    expect(_in(_fixedTaskProject, 'emacs-agent-harness'), findsOneWidget);
    await _sendTask(tester, 'Publish the docs site');
    expect(rig.harness.calls('_harness/task/submit').single['cwd'], _main);
  });

  testWidgets('a field with no project chosen says so', (tester) async {
    final rig = await _rig();
    await _pump(tester, rig);
    // Every project: the app opened on one, and the person chose none.
    rig.app.selectProject(null);
    await _settle(tester, 4);
    await _goToTasks(tester);
    await _openTaskSheet(tester);
    expect(_taskProject, findsOneWidget);
    expect(_in(_taskProject, 'No project chosen'), findsOneWidget);
  });

  testWidgets('the new task sheet offers projects, not the worktrees and '
      'scratch directories an older harness lists', (tester) async {
    // What the app showed: a worktree a task was made in, the scratch
    // directories sub-agents were given, and the worktrees of sessions,
    // each as a project, from a harness that says nothing of them.
    final rig = await _rig(
      worktrees: true,
      scratch: true,
      tidyProjects: false,
      projectMains: false,
    );
    expect(
      rig.harness.listedProjects(),
      containsAll([
        '/Users/noah/Code/emacs-agent-harness-worktrees/task-old-layout/',
        '/tmp/harness-1000/${FakeHarness.scratchOwner}/client-1/',
        '/tmp/harness-1000/${FakeHarness.goneOwner}/wt/core/',
      ]),
    );
    await _pump(tester, rig);
    await _goToTasks(tester);
    await _openTaskSheet(tester);
    final sheet = find.byType(BottomSheet);
    expect(
      find.descendant(of: sheet, matching: find.text('PROJECT')),
      findsOneWidget,
    );
    // A dropdown: one folder, the project it holds, and no other project
    // on the sheet until its menu is opened.
    expect(
      find.descendant(of: sheet, matching: find.byIcon(Icons.folder_outlined)),
      findsOneWidget,
    );
    expect(_in(_taskProject, 'emacs-agent-harness'), findsOneWidget);
    expect(_in(sheet, 'other-project'), findsNothing);

    await tester.tap(_taskProject);
    await _settle(tester, 4);
    final menu = find.byType(BottomSheet).last;
    for (final name in ['emacs-agent-harness', 'other-project']) {
      expect(
        find.descendant(of: menu, matching: find.text(name)),
        findsOneWidget,
        reason: name,
      );
    }
    for (final junk in [
      'task-old-layout',
      'client-1',
      'client-2',
      'core',
      'task-fix-titles',
    ]) {
      expect(
        find.descendant(of: menu, matching: find.text(junk)),
        findsNothing,
        reason: junk,
      );
    }
  });

  testWidgets('the new session sheet picks its project from a dropdown', (
    tester,
  ) async {
    final rig = await _rig();
    await _pump(tester, rig);
    await _openSessionSheet(tester);
    final sheet = find.byType(BottomSheet);
    final select = find.byKey(const Key('session-project'));
    expect(
      find.descendant(of: sheet, matching: find.text('PROJECT')),
      findsOneWidget,
    );
    expect(_in(select, 'emacs-agent-harness'), findsOneWidget);
    // The projects are not a wrap of pills on the sheet.
    expect(
      find.descendant(of: sheet, matching: find.byIcon(Icons.folder_outlined)),
      findsOneWidget,
    );
    expect(_in(sheet, 'other-project'), findsNothing);

    await tester.tap(select);
    await _settle(tester, 4);
    final menu = find.byType(BottomSheet).last;
    expect(
      find.descendant(of: menu, matching: find.text('Projects')),
      findsOneWidget,
    );
    await tester.tap(
      find.descendant(of: menu, matching: find.text('other-project')),
    );
    await _settle(tester, 3);
    expect(_in(select, 'other-project'), findsOneWidget);

    await tester.ensureVisible(find.text('Start session'));
    await tester.tap(find.text('Start session'));
    await _settle(tester, 10);
    expect(rig.harness.sessions['s5']!['cwd'], _other);
  });

  testWidgets('the dropdown opens in the style of an iPhone', (tester) async {
    final rig = await _rig();
    await rig.settings.setPreviewPlatform(PreviewPlatform.cupertino);
    await _pump(tester, rig);
    await _goToTasks(tester);
    await _openTaskSheet(tester, apple: true);
    expect(_taskProject, findsOneWidget);
    expect(_in(_taskProject, 'emacs-agent-harness'), findsOneWidget);
    await tester.tap(_taskProject);
    await _settle(tester, 4);
    // The choices are the platform's action sheet, named as the menu is.
    expect(find.text('Projects'), findsOneWidget);
    await tester.tap(find.text('other-project').last);
    await _settle(tester, 3);
    expect(_in(_taskProject, 'other-project'), findsOneWidget);
    await _sendTask(tester, 'Publish the docs site');
    expect(rig.harness.calls('_harness/task/submit').single['cwd'], _other);
  });

  testWidgets('draws the project pickers', (tester) async {
    final shots = Platform.environment['HARNESS_SHOTS'];
    // As many projects as the person has: the point of the dropdown.
    final rig = await _rig(
      arrange: (harness) => harness.projectList = [
        _main,
        _other,
        for (var number = 1; number <= 10; number++)
          '/Users/noah/Code/zz-project-$number/',
      ],
    );
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
      // A ripple or a sheet's slide is let go by before the picture.
      await tester.pump(const Duration(seconds: 1));
      if (shots == null) return;
      await tester.runAsync(() async {
        final render =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await render.toImage(pixelRatio: 1.5);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('$shots/$name${realFonts ? '' : '-ahem'}.png');
        file.parent.createSync(recursive: true);
        file.writeAsBytesSync(data!.buffer.asUint8List());
      });
    }

    // A task of the project the board is narrowed to: said, not asked.
    await _goToTasks(tester);
    await rig.app.tasks!.load(project: _other);
    await _settle(tester, 4);
    await _openTaskSheet(tester);
    await tester.enterText(_promptField, 'Publish the docs site');
    await tester.pump();
    await shoot('project-picker-task-narrowed');
    Navigator.of(tester.element(find.text('Submit task'))).pop();
    await _settle(tester, 4);

    // A task of every project: the project is a dropdown.
    rig.app.drafts.task.clear();
    await rig.app.tasks!.load();
    await _settle(tester, 4);
    await _openTaskSheet(tester);
    await tester.enterText(_promptField, 'Publish the docs site');
    await tester.pump();
    await shoot('project-picker-task-all');
    await tester.tap(_taskProject);
    await _settle(tester, 4);
    await shoot('project-picker-task-menu');
    Navigator.of(tester.element(find.text('Projects'))).pop();
    await _settle(tester, 3);
    Navigator.of(tester.element(find.text('Submit task'))).pop();
    await _settle(tester, 4);

    // A session's project: a dropdown too.
    await _openSessionSheet(tester);
    await shoot('project-picker-session');
    await tester.tap(find.byKey(const Key('session-project')));
    await _settle(tester, 4);
    await shoot('project-picker-session-menu');
  });
}
