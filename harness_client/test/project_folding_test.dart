import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/acp/acp_message.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';

const _main = '/Users/noah/Code/emacs-agent-harness/';
const _other = '/Users/noah/Code/other-project/';
const _titles = '$_main.worktrees/task-fix-titles/';
const _flutter = '$_main.worktrees/task-flutter/';
const _beside =
    '/Users/noah/Code/emacs-agent-harness-worktrees/task-old-layout/';

Future<(AppController, FakeHarness)> _connected({
  bool worktrees = true,
  bool projectMains = true,
  void Function(FakeHarness harness)? arrange,
}) async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsController();
  await settings.load();
  final harness = FakeHarness(projectMains: projectMains);
  if (worktrees) harness.seedWorktreeSessions();
  arrange?.call(harness);
  final app = AppController(settings: settings, connector: harness.connector);
  await app.connect('ws://memory/acp');
  return (app, harness);
}

/// Let the loads the app starts once it is connected finish, so that what a
/// test loads next is the last word.
Future<void> _settled() =>
    Future<void>.delayed(const Duration(milliseconds: 100));

List<(String, JsonMap)> _asked(FakeHarness harness, String method) => [
  for (final request in harness.requests)
    if (request.$1 == method) request,
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the projects of a harness whose sessions work in git worktrees', () {
    test('are its main checkouts, not the worktrees', () async {
      final (app, harness) = await _connected();
      expect(app.phase, ConnectionPhase.connected);
      // Four sessions work in a worktree of their own (see
      // seedWorktreeSessions); none of them is a project.
      expect(
        harness.sessions.values.where(
          (session) => '${session['project']}'.contains('worktrees'),
        ),
        hasLength(4),
      );
      expect(app.projects, [_main, _other]);
    });

    test('a worktree beside the repository is folded when the harness '
        'says what it is of', () async {
      final (app, harness) = await _connected();
      expect(app.projects, isNot(contains(_beside)));
      expect(
        app.projectOfSession(
          app.sessions.firstWhere((session) => session.id == 'w3'),
        ),
        _main,
      );
      expect(_asked(harness, '_harness/project/mains'), hasLength(1));
    });

    test(
      'are folded by an older harness too, as far as its paths say',
      () async {
        final (app, harness) = await _connected(projectMains: false);
        expect(app.capability!.has('project/mains'), isFalse);
        // The worktrees in a `.worktrees` are folded.  One made elsewhere can
        // only be told by the harness, which cannot here.
        expect(app.projects, [_beside, _main, _other]);
        expect(
          harness.requestsByClient,
          isNot(contains('_harness/project/mains')),
        );
      },
    );

    test('are folded for a plain ACP agent too, which names only the '
        'directory a session works in', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsController();
      await settings.load();
      final harness = FakeHarness(enhanced: false);
      final app = AppController(
        settings: settings,
        connector: harness.connector,
      );
      await app.connect('ws://memory/acp');
      expect(app.phase, ConnectionPhase.connected);
      // `s2` works in a worktree of the project, and has no `project`.
      expect(app.sessions.map((session) => session.cwd), contains(_titles));
      expect(app.sessions.every((session) => session.project == null), isTrue);
      expect(app.projects, [_main, _other]);
      expect(app.selectedProject, _main);
    });

    test('each session is in the project of its worktree', () async {
      final (app, _) = await _connected();
      String? projectOf(String id) => app.projectOfSession(
        app.sessions.firstWhere((session) => session.id == id),
      );
      expect(projectOf('s1'), _main);
      expect(projectOf('s2'), _main);
      expect(projectOf('w1'), _main);
      expect(projectOf('w2'), _main);
      expect(projectOf('w3'), _main);
      expect(projectOf('w4'), _other);
      expect(projectOf('s4'), _other);
    });

    test('and each task is in the project it is for', () async {
      final (app, _) = await _connected();
      await app.tasks!.load(showSpinner: false);
      for (final task in app.tasks!.tasks) {
        expect(app.projectOfTask(task), _main, reason: task.title);
      }
    });

    test('never open on a worktree, though it is the latest work', () async {
      final (app, _) = await _connected(
        arrange: (harness) {
          // The session touched last is a sub-agent in a worktree.
          harness.sessions['w1']!['lastMessage'] =
              DateTime.now().millisecondsSinceEpoch / 1000;
        },
      );
      expect(app.sessions.first.id, 'w1');
      expect(app.selectedProject, _main);
    });

    test('are asked of the harness once for each directory', () async {
      final (app, harness) = await _connected();
      await app.refreshProjects();
      await app.refreshProjects();
      expect(_asked(harness, '_harness/project/mains'), hasLength(1));
      final roots =
          _asked(harness, '_harness/project/mains').single.$2['roots'] as List;
      // Only the directories that are not a main checkout it listed.
      expect(roots, isNot(contains(_main)));
      expect(roots, containsAll([_titles, _beside]));
    });

    test('stay the same when a session starts in a new worktree', () async {
      final (app, harness) = await _connected();
      const fresh = '$_other.worktrees/task-layout/';
      harness.sessions['w5'] = {
        ...harness.sessions['w1']!,
        'id': 'w5',
        'name': 'Check the layout',
        'project': fresh,
        'cwd': fresh,
      };
      harness.announce('session/created', ['w5']);
      // The app refreshes a moment later, and asks about the new directory.
      for (var i = 0; i < 100; i++) {
        final asked = _asked(harness, '_harness/project/mains');
        if (asked.any(
          (request) => (request.$2['roots'] as List).contains(fresh),
        )) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      await _settled();
      expect(app.sessions.map((session) => session.id), contains('w5'));
      expect(
        app.projectOfSession(
          app.sessions.firstWhere((session) => session.id == 'w5'),
        ),
        _other,
      );
      expect(app.projects, [_main, _other]);
    });

    test('are what the harness says, over what a path looks like', () async {
      final (app, _) = await _connected(
        arrange: (harness) {
          // The directory beside the repository is no worktree of it, as
          // far as the harness reads from the disk: a project of its own.
          harness.worktreeOf.clear();
        },
      );
      expect(app.projects, [_beside, _main, _other]);
    });
  });

  group('usage of a project and its worktrees', () {
    test('has one row for a project, its worktrees added', () async {
      final (app, _) = await _connected();
      await _settled();
      await app.usage!.load(showSpinner: false);
      final rows = app.usage!.overview.byProject;
      expect(rows.map((row) => row.key), [_main, _other]);
      // 0.60 of its own, 0.61 in task-flutter, 0.12 in task-fix-titles.
      expect(rows.first.listCost, closeTo(1.33, 1e-9));
      expect(rows.first.cost, closeTo(1.09, 1e-9));
      expect(rows.first.calls, 24);
      expect(rows.last.listCost, closeTo(0.18, 1e-9));
    });

    test('is asked for with the worktrees of the project chosen', () async {
      final (app, harness) = await _connected();
      await _settled();
      await app.usage!.load(project: _main, showSpinner: false);
      for (final method in [
        '_harness/usage/totals',
        '_harness/usage/summary',
      ]) {
        final asked = _asked(
          harness,
          method,
        ).where((request) => request.$2['group-by'] != 'project');
        expect(asked, isNotEmpty);
        final last = asked.last.$2;
        expect(last.containsKey('project'), isFalse, reason: method);
        expect(
          last['projects'],
          unorderedEquals([_main, _flutter, _titles]),
          reason: method,
        );
      }
      // The rows by project are asked for first, of every project: they say
      // which directories are the project's.
      final byProject = _asked(
        harness,
        '_harness/usage/summary',
      ).where((request) => request.$2['group-by'] == 'project');
      expect(byProject.last.$2.containsKey('projects'), isFalse);
      expect(byProject.last.$2.containsKey('project'), isFalse);
      expect(app.usage!.overview.byProject.map((row) => row.key), [_main]);
    });

    test(
      'of a project nothing was spent in is asked for by its name',
      () async {
        final (app, harness) = await _connected();
        await _settled();
        const quiet = '/Users/noah/Code/quiet-project/';
        await app.usage!.load(project: quiet, showSpinner: false);
        final totals = _asked(harness, '_harness/usage/totals').last.$2;
        expect(totals['project'], quiet);
        expect(totals.containsKey('projects'), isFalse);
        expect(app.usage!.overview.byProject, isEmpty);
      },
    );
  });
}
