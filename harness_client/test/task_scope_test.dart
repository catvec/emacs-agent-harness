import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/acp/acp_message.dart';
import 'package:harness_client/src/models/task.dart';
import 'package:harness_client/src/services/harness_api.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:harness_client/src/state/task_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';

const _main = '/Users/noah/Code/emacs-agent-harness/';
const _other = '/Users/noah/Code/other-project/';

/// What the fake harness has on its boards: six tasks of [_main], and two of
/// [_other] once it was given them (`seedOtherProjectTasks`).
const _everyTask = {
  'task-1',
  'task-2',
  'task-3',
  'task-4',
  'task-5',
  'task-6',
  'task-7',
  'task-8',
};
const _otherTasks = {'task-7', 'task-8'};

Future<(AppController, FakeHarness)> _connected() async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsController();
  await settings.load();
  final harness = FakeHarness()..seedOtherProjectTasks();
  final app = AppController(
    settings: settings,
    connector: harness.connector,
    reconnectDelays: const [Duration(milliseconds: 5)],
  );
  addTearDown(app.dispose);
  await app.connect('ws://memory/acp');
  // The board loads on its own once the app is connected.
  await _until(() => app.tasks!.tasks.isNotEmpty, what: 'the board');
  return (app, harness);
}

/// Wait, in short steps, until [done]: what the app starts by itself.
Future<void> _until(bool Function() done, {String? what}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for ${what ?? 'the app'}.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 4));
  }
}

Set<String> _ids(TaskController board) => {
  for (final task in board.tasks) task.id,
};

/// The params of every `task/list` the harness was asked for, in order.
List<JsonMap> _listings(FakeHarness harness) => [
  for (final request in harness.requests)
    if (request.$1 == '_harness/task/list') request.$2,
];

/// A task as the harness announces it when it changes.
JsonMap _wire(FakeHarness harness, String id) => {...harness.tasks[id]!};

/// An api whose `task/list` answers when the test lets it, to have answers
/// arrive in another order than the questions.
class _GatedApi extends HarnessApi {
  _GatedApi(super.client, super.capabilities);

  final gates = <Completer<void>>[];

  @override
  Future<List<HarnessTask>> tasks({String? cwd}) async {
    final gate = Completer<void>();
    gates.add(gate);
    await gate.future;
    return super.tasks(cwd: cwd);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the task board', () {
    test('opens on every project, not on the one of the latest work', () async {
      final (app, harness) = await _connected();
      // The app opens on the project of the latest work: the Usage view and
      // a new task start from it...
      expect(app.selectedProject, _main);
      // ...but the board shows the work of every project, the other
      // project's included, which nothing sets apart to look for.
      expect(app.tasks!.project, isNull);
      expect(_ids(app.tasks!), _everyTask);
      expect(_listings(harness), everyElement(isNot(contains('cwd'))));
    });

    test('is narrowed to a project by asking the harness for it', () async {
      final (app, harness) = await _connected();
      await app.tasks!.load(project: _other);
      expect(app.tasks!.project, _other);
      expect(_ids(app.tasks!), _otherTasks);
      expect(_listings(harness).last['cwd'], _other);

      await app.tasks!.load(project: _main);
      expect(_ids(app.tasks!), _everyTask.difference(_otherTasks));

      // And widened again.
      await app.tasks!.load();
      expect(app.tasks!.project, isNull);
      expect(_ids(app.tasks!), _everyTask);
      expect(_listings(harness).last, isNot(contains('cwd')));
    });

    test('is read again as it is narrowed', () async {
      final (app, harness) = await _connected();
      await app.tasks!.load(project: _other);
      await app.tasks!.reload();
      expect(_listings(harness).last['cwd'], _other);
      expect(_ids(app.tasks!), _otherTasks);
      // An action of the person's reads it again too.
      await app.tasks!.pause('task-7');
      expect(_listings(harness).last['cwd'], _other);
    });

    test('is not narrowed by the project chosen for Usage', () async {
      final (app, harness) = await _connected();
      final listed = _listings(harness).length;
      app.selectProject(_other);
      expect(app.selectedProject, _other);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(app.tasks!.project, isNull);
      expect(_ids(app.tasks!), _everyTask);
      expect(_listings(harness), hasLength(listed));
      // Nor does the board's project decide what Usage shows.
      await app.tasks!.load(project: _main);
      expect(app.selectedProject, _other);
    });

    test('is read again where it was when the connection is back', () async {
      final (app, harness) = await _connected();
      await app.tasks!.load(project: _other);
      final listed = _listings(harness).length;
      await harness.dropConnection();
      await _until(
        () => app.isConnected && harness.connects == 2,
        what: 'the connection',
      );
      await _until(
        () => _listings(harness).length > listed,
        what: 'the board to be read again',
      );
      expect(_listings(harness).last['cwd'], _other);
      expect(app.tasks!.project, _other);
      expect(_ids(app.tasks!), _otherTasks);
    });

    test('is not given the tasks of another project by an event', () async {
      final (app, harness) = await _connected();
      await app.tasks!.load(project: _main);
      // The harness tells of every project's tasks, to every client.
      harness.tasks['task-9'] = {
        'id': 'task-9',
        'name': 'Rotate the cluster certificates',
        'state': 'pending',
        'column': 'pending',
        'project': _other,
        'cwd': _other,
      };
      harness.announce('task/changed', [_wire(harness, 'task-9')]);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(_ids(app.tasks!), _everyTask.difference(_otherTasks));

      // One of its project is.
      harness.tasks['task-10'] = {
        'id': 'task-10',
        'name': 'Cache the project list',
        'state': 'pending',
        'column': 'pending',
        'project': _main,
        'cwd': _main,
      };
      harness.announce('task/changed', [_wire(harness, 'task-10')]);
      await _until(
        () => _ids(app.tasks!).contains('task-10'),
        what: 'the task of the project',
      );

      // With the board on every project, all of them are.
      await app.tasks!.load();
      harness.tasks['task-11'] = {
        'id': 'task-11',
        'name': 'Silence the pager',
        'state': 'pending',
        'column': 'pending',
        'project': _other,
        'cwd': _other,
      };
      harness.announce('task/changed', [_wire(harness, 'task-11')]);
      await _until(
        () => _ids(app.tasks!).contains('task-11'),
        what: 'the task of the other project',
      );
    });

    test(
      'does not show the answer of a question it has moved on from',
      () async {
        final (app, _) = await _connected();
        final api = _GatedApi(app.client!, app.capabilities!);
        addTearDown(api.dispose);
        final board = TaskController(api);
        final narrowed = board.load(project: _other);
        final everything = board.load();
        expect(api.gates, hasLength(2));
        // The board was asked for every project last.  Its answer comes
        // first, and the one for the project it no longer shows after it.
        api.gates[1].complete();
        await everything;
        expect(_ids(board), _everyTask);
        expect(board.loading, isFalse);
        api.gates[0].complete();
        await narrowed;
        expect(board.project, isNull);
        expect(_ids(board), _everyTask);
        expect(board.loading, isFalse);
        expect(board.error, isNull);
      },
    );
  });

  group('the project the app opens on', () {
    test('is the project of the latest work, until one is chosen', () async {
      final (app, _) = await _connected();
      expect(app.selectedProject, _main);
      app.selectProject(_other);
      await app.refreshSessions();
      await app.refreshProjects();
      expect(app.selectedProject, _other);
    });

    test('is not taken back after every projects is chosen', () async {
      final (app, harness) = await _connected();
      app.selectProject(null);
      expect(app.selectedProject, isNull);
      // The harness's events bring a refresh every few seconds.
      await app.refreshSessions();
      await app.refreshProjects();
      expect(app.selectedProject, isNull);
      harness.announce('session/status', ['s1', 'running']);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(app.selectedProject, isNull);
    });

    test(
      'is the project of the latest work again after a new connection',
      () async {
        final (app, harness) = await _connected();
        app.selectProject(null);
        await app.disconnect();
        expect(app.selectedProject, isNull);
        await app.connect('ws://memory/acp');
        expect(harness.connects, 2);
        expect(app.selectedProject, _main);
      },
    );
  });
}
