import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/app.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';

const _main = '/Users/noah/Code/emacs-agent-harness/';
const _other = '/Users/noah/Code/other-project/';

class _Rig {
  _Rig(this.settings, this.harness, this.app);
  final SettingsController settings;
  final FakeHarness harness;
  final AppController app;
}

/// An app connected to a fake harness that has the work of a second project
/// on its boards, and whatever [arrange] adds before the app connects.
Future<_Rig> _rig({void Function(FakeHarness harness)? arrange}) async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsController();
  await settings.load();
  final harness = FakeHarness()..seedOtherProjectTasks();
  arrange?.call(harness);
  final app = AppController(settings: settings, connector: harness.connector);
  await app.connect('ws://memory/acp');
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

/// A project that the harness has sessions in, named so that it sorts last.
String _project(int number) => '/Users/noah/Code/zz-project-$number/';

/// A harness with thirty projects more, as the real one has many.
void _manyProjects(FakeHarness harness) {
  harness.projectList = [
    _main,
    _other,
    for (var number = 0; number < 30; number++) _project(number),
  ];
  // The last of them has a session at work, which is what is looked for.
  harness.sessions['far'] = {
    'id': 'far',
    'name': 'Rotate the certificates',
    'kind': 'main',
    'project': _project(29),
    'cwd': _project(29),
    'model': 'claude:claude-fable-5-1',
    'permissionMode': 'auto',
    'status': 'running',
    'created': DateTime.now().millisecondsSinceEpoch / 1000,
    'updated': DateTime.now().millisecondsSinceEpoch / 1000,
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'the task board opens on every project, and a project narrows it',
    (tester) async {
      final rig = await _rig();
      await _pump(tester, rig);
      await tester.tap(find.text('Tasks'));
      await _settle(tester, 6);
      // The tasks of every project, not only those of the project the app
      // opened on: the scope says so, and a queue, which is a project's, has no
      // controls to show yet.
      expect(find.text('All projects'), findsOneWidget);
      expect(find.textContaining('working'), findsNothing);
      await tester.ensureVisible(find.text('Review'));
      await tester.tap(find.text('Review'));
      await _settle(tester, 4);
      expect(find.text('Review the emulator screenshots'), findsOneWidget);
      expect(find.text('Trim the cluster alerts'), findsOneWidget);
      // A card says whose it is.
      expect(
        find.textContaining('other-project · task/alerts'),
        findsOneWidget,
      );

      // Narrow it to one project.
      await tester.tap(find.text('All projects'));
      await _settle(tester, 4);
      final sheet = find.byType(BottomSheet);
      expect(sheet, findsOneWidget);
      expect(
        find.descendant(of: sheet, matching: find.text('All projects')),
        findsOneWidget,
      );
      await tester.tap(
        find.descendant(of: sheet, matching: find.text('other-project')),
      );
      await _settle(tester, 6);
      expect(find.text('Trim the cluster alerts'), findsOneWidget);
      expect(find.text('Review the emulator screenshots'), findsNothing);
      expect(find.textContaining('working'), findsOneWidget);
      expect(rig.app.tasks!.project, _other);
      // Usage and the next new session keep the project of the latest work.
      expect(rig.app.selectedProject, _main);

      // And every project again.
      await tester.tap(find.text('other-project'));
      await _settle(tester, 4);
      await tester.tap(
        find.descendant(
          of: find.byType(BottomSheet),
          matching: find.text('All projects'),
        ),
      );
      await _settle(tester, 6);
      expect(find.text('Review the emulator screenshots'), findsOneWidget);
      expect(find.text('Trim the cluster alerts'), findsOneWidget);
      expect(find.textContaining('working'), findsNothing);
      expect(rig.app.tasks!.project, isNull);
    },
  );

  testWidgets('a new task starts in the project the board is narrowed to', (
    tester,
  ) async {
    final rig = await _rig();
    await _pump(tester, rig);
    await tester.tap(find.text('Tasks'));
    await _settle(tester, 6);
    // With every project on the board, in the one of the latest work.
    await tester.tap(find.byIcon(Icons.add_rounded));
    await _settle(tester, 4);
    expect(find.text('Submit task'), findsOneWidget);
    expect(find.text(_main), findsOneWidget);
    expect(find.text(_other), findsNothing);
    Navigator.of(tester.element(find.text('Submit task'))).pop();
    await _settle(tester, 4);
    expect(find.text('Submit task'), findsNothing);

    // With the board on one project, in that one.
    await rig.app.tasks!.load(project: _other);
    await _settle(tester, 4);
    await tester.tap(find.byIcon(Icons.add_rounded));
    await _settle(tester, 4);
    expect(find.text('Submit task'), findsOneWidget);
    expect(find.text(_other), findsOneWidget);
    expect(find.text(_main), findsNothing);
  });

  testWidgets(
    'a task made for another project than the board shows is on the board',
    (tester) async {
      final rig = await _rig();
      await _pump(tester, rig);
      await tester.tap(find.text('Tasks'));
      await _settle(tester, 6);
      await rig.app.tasks!.load(project: _other);
      await _settle(tester, 4);

      Future<void> makeTask(String prompt, {String? inProject}) async {
        await tester.tap(find.byIcon(Icons.add_rounded));
        await _settle(tester, 4);
        if (inProject != null) {
          await tester.tap(
            find.descendant(
              of: find.byType(BottomSheet),
              matching: find.text(inProject),
            ),
          );
          await _settle(tester, 2);
        }
        await tester.enterText(
          find.byWidgetPredicate(
            (widget) => widget is TextField && (widget.minLines ?? 1) > 1,
          ),
          prompt,
        );
        await tester.ensureVisible(find.text('Submit task'));
        await tester.tap(find.text('Submit task'));
        await _settle(tester, 8);
      }

      // A task for the project the board is narrowed to joins it.
      await makeTask('Renew the certificates');
      expect(rig.app.tasks!.project, _other);
      expect(
        rig.app.tasks!.tasks.map((task) => task.title),
        contains('Renew the certificates'),
      );

      // One for another project is not on it, so the board shows them all.
      await makeTask(
        'Cache the project list',
        inProject: 'emacs-agent-harness',
      );
      expect(rig.app.tasks!.project, isNull);
      expect(
        rig.app.tasks!.tasks.map((task) => task.title),
        containsAll(['Renew the certificates', 'Cache the project list']),
      );
    },
  );

  testWidgets(
    'the project menu of the task board scrolls to the last project',
    (tester) async {
      final rig = await _rig(arrange: _manyProjects);
      await _pump(tester, rig);
      await tester.tap(find.text('Tasks'));
      await _settle(tester, 6);
      await tester.tap(find.text('All projects'));
      await _settle(tester, 4);
      final sheet = find.byType(BottomSheet);
      expect(sheet, findsOneWidget);
      // A sheet holds a part of the screen; the projects that do not fit are
      // there to scroll to, not cut off.
      expect(
        find.descendant(of: sheet, matching: find.text('zz-project-29')),
        findsNothing,
      );
      await tester.scrollUntilVisible(
        find.descendant(of: sheet, matching: find.text('zz-project-29')),
        200,
        scrollable: find
            .descendant(of: sheet, matching: find.byType(Scrollable))
            .first,
      );
      await tester.tap(
        find.descendant(of: sheet, matching: find.text('zz-project-29')),
      );
      await _settle(tester, 6);
      expect(rig.app.tasks!.project, _project(29));
      expect(find.text('zz-project-29'), findsOneWidget);
    },
  );

  testWidgets('the project filter of the sessions reaches the last project', (
    tester,
  ) async {
    final rig = await _rig(arrange: _manyProjects);
    await _pump(tester, rig);
    expect(find.text('Rotate the certificates'), findsOneWidget);
    await tester.tap(find.text('All projects'));
    await _settle(tester, 4);
    final sheet = find.byType(BottomSheet);
    await tester.scrollUntilVisible(
      find.descendant(of: sheet, matching: find.text('zz-project-29')),
      200,
      scrollable: find
          .descendant(of: sheet, matching: find.byType(Scrollable))
          .first,
    );
    await tester.tap(
      find.descendant(of: sheet, matching: find.text('zz-project-29')),
    );
    await _settle(tester, 6);
    // Only what was done in that project is left.
    expect(find.text('Rotate the certificates'), findsOneWidget);
    expect(find.text('Design the merge queue'), findsNothing);
  });
}
