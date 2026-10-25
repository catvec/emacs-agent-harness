// The quick search against a real harness: the Emacs one, with its demo
// provider standing in for the cheap model, over ACP as the app talks to it.
//
//   HARNESS_REAL_ADDRESS=127.0.0.1:PORT flutter test \
//       test/quick_search_real_harness_test.dart
//
// It is skipped without HARNESS_REAL_ADDRESS (the harness's ACP server, TCP or
// a ws:// address; HARNESS_REAL_TOKEN is the secret of one that wants it, and
// HARNESS_REAL_CWD the project to search in).  The other suites use the fake
// harness, which says what the harness is believed to answer; this is the
// harness answering: the plan as the real `search/ask` encodes it, from the
// catalogue the app really builds, to the controller and what it lists.
//
// What the demo provider is does not matter to the rest: it answers a search
// from the words of the query, deterministically, which is why this can say
// what comes back.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/acp/acp_message.dart';
import 'package:harness_client/src/models/quick_search.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/quick_search_catalogue.dart';
import 'package:harness_client/src/state/quick_search_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final address = Platform.environment['HARNESS_REAL_ADDRESS'];
  final token = Platform.environment['HARNESS_REAL_TOKEN'] ?? '';
  final skip = address == null || address.isEmpty
      ? 'HARNESS_REAL_ADDRESS names no running harness'
      : false;

  late AppController app;
  late String project;
  late String taskId;

  Future<void> eventually(bool Function() done, [int seconds = 20]) async {
    final deadline = DateTime.now().add(Duration(seconds: seconds));
    while (!done()) {
      if (DateTime.now().isAfter(deadline)) fail('timed out');
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  setUpAll(() async {
    if (skip != false) return;
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsController();
    await settings.load();
    app = AppController(settings: settings);
    await app.connect(address!, token: token);
    expect(
      app.isConnected,
      isTrue,
      reason: '${app.phase.name}: ${app.error ?? app.resumeError}',
    );
    project =
        Platform.environment['HARNESS_REAL_CWD'] ?? Directory.current.path;
    // A task works in a worktree, so the project is a repository.
    Future<void> git(List<String> arguments) async {
      final result = await Process.run('git', [
        '-C',
        project,
        '-c',
        'user.name=probe',
        '-c',
        'user.email=probe@example.invalid',
        ...arguments,
      ]);
      if (result.exitCode != 0) fail('git $arguments: ${result.stderr}');
    }

    await git(['init', '-q', '-b', 'main']);
    await git(['commit', '-q', '--allow-empty', '-m', 'Start the project']);
    // A session the search can find, with something said in it.
    final created = asMap(
      await app.api!.client.request('session/new', {
        'cwd': project,
        'mcpServers': const <Object?>[],
        '_harness': {'name': 'Write the API guide'},
      }),
    );
    final id = asString(created['sessionId'])!;
    await app.api!.client.request('session/prompt', {
      'sessionId': id,
      'prompt': [
        {
          'type': 'text',
          'text': 'Document the retry policy of the billing endpoint in the API guide',
        },
      ],
    }, Duration.zero);
    // A task, which the demo provider works on and hands in.
    final task = await app.api!.submitTask(
      cwd: project,
      prompt: 'Write the parser docs',
    );
    taskId = task.id;
    await app.refreshSessions();
    await app.refreshProjects();
    await eventually(() => app.sessions.any((s) => s.id == id));
  });

  tearDownAll(() async {
    if (skip != false) return;
    await app.disconnect();
  });

  test('the harness offers the search the app uses', () {
    final api = app.api!;
    expect(api.can('search/ask'), isTrue);
    expect(api.can('search/warm'), isTrue);
    expect(api.can('task/search-apply'), isTrue);
  }, skip: skip);

  test('warms the model of the search and says which it is', () async {
    final controller = QuickSearchController(
      app: app,
      place: const QuickSearchPlace(SearchOrigin.settings),
      project: project,
    );
    await controller.warm();
    expect(controller.model, isNotNull);
    stdout.writeln('model: ${controller.model}');
    controller.dispose();
  }, skip: skip);

  test('answers how to do something with the app\'s own actions', () async {
    final controller = QuickSearchController(
      app: app,
      place: const QuickSearchPlace(SearchOrigin.settings),
      project: project,
    );
    await controller.search('how do I attach an image to a task?');
    expect(controller.status, QuickSearchStatus.done, reason: controller.error);
    final plan = controller.plan!;
    stdout.writeln('answer: ${plan.answer}');
    stdout.writeln(
      'commands: ${[for (final c in plan.commands) '${c.command} (${c.keys})']}',
    );
    // The model was told the engineer is on the phone, and the commands are
    // the app's: what it names is what the app sent, with its taps.
    expect(plan.commands, isNotEmpty);
    for (final found in plan.commands) {
      final command = controller.commandFor(found);
      expect(command, isNotNull, reason: '${found.command} is not the app\'s');
      expect(found.label, command!.label);
      expect(found.keys, command.keys);
    }
    // A question that starts with "how" is answered in words, naming the
    // first command with the taps that reach it.
    expect(plan.answer, isNotNull);
    expect(plan.answer, contains('Tasks tab'));
    expect(plan.answer, isNot(contains('C-c')), reason: 'no Emacs keys');
    expect(plan.bias, SearchBias.commands);
    controller.dispose();
  }, skip: skip);

  test('finds a session by what was said in it, with where', () async {
    final controller = QuickSearchController(
      app: app,
      place: const QuickSearchPlace(SearchOrigin.sessions),
      project: project,
    );
    await controller.search('where did I document the retry policy?');
    expect(controller.status, QuickSearchStatus.done, reason: controller.error);
    final plan = controller.plan!;
    stdout.writeln(
      'sessions: ${[for (final s in plan.sessions) '${s.title} | ${s.snippet} | ${s.ranges}']}',
    );
    expect(plan.bias, SearchBias.sessions);
    expect(plan.sessionQuery, isNotNull);
    final found = plan.sessions.where((s) => s.title == 'Write the API guide');
    expect(found, isNotEmpty);
    final session = found.first;
    expect(session.id, isNotEmpty);
    expect(app.sessions.any((s) => s.id == session.id), isTrue);
    if (session.snippet != null) {
      // The words found are inside the passage they were found in.
      for (final (start, end) in session.ranges) {
        expect(start, inInclusiveRange(0, session.snippet!.length));
        expect(end, inInclusiveRange(start, session.snippet!.length));
      }
    }
    controller.dispose();
  }, skip: skip);

  test('says nothing found for words nothing has', () async {
    final controller = QuickSearchController(
      app: app,
      place: const QuickSearchPlace(SearchOrigin.usage),
      project: project,
    );
    await controller.search('zxqv wvut qqqq');
    expect(controller.status, QuickSearchStatus.done, reason: controller.error);
    final plan = controller.plan!;
    stdout.writeln('nothing: widened=${plan.widened} note=${plan.note}');
    expect(plan.tasks, isEmpty);
    expect(plan.actions, isEmpty);
    expect(plan.isEmpty || plan.note != null, isTrue);
    controller.dispose();
  }, skip: skip);

  test('finds a task by its words, and does what it proposes when told to', () async {
    final controller = QuickSearchController(
      app: app,
      place: const QuickSearchPlace(SearchOrigin.tasks),
      project: project,
    );
    await controller.search('did I have a task about the parser docs?');
    expect(controller.status, QuickSearchStatus.done, reason: controller.error);
    final found = controller.plan!;
    stdout.writeln(
      'tasks: ${[for (final t in found.tasks) '${t.id} | ${t.title} | ${t.status} | ${t.sessionId}']}',
    );
    expect(found.bias, SearchBias.tasks);
    expect([for (final t in found.tasks) t.id], contains(taskId));
    final task = found.tasks.firstWhere((t) => t.id == taskId);
    expect(task.title, contains('parser docs'));
    expect(task.status, isNotNull);
    expect(found.actions, isEmpty);

    // An order: the task is proposed to be archived, and nothing is done
    // until it is said.
    await controller.search('get rid of the parser docs task');
    expect(controller.status, QuickSearchStatus.done, reason: controller.error);
    final order = controller.plan!;
    stdout.writeln(
      'actions: ${[for (final a in order.actions) '${a.action} ${a.task} (${a.title}) confirm=${a.confirm}']}',
    );
    expect(controller.proposed, hasLength(1));
    expect(controller.proposed.single.task, taskId);
    expect(controller.proposed.single.action, 'archive');
    expect(controller.proposed.single.title, contains('parser docs'));
    expect((await app.api!.task(taskId)).archived, isFalse);

    await controller.doIt();
    stdout.writeln(
      'results: ${[for (final r in controller.results) r.sentence]}',
    );
    expect(controller.results, hasLength(1));
    expect(
      controller.results.single.ok,
      isTrue,
      reason: controller.results.single.error,
    );
    expect(controller.results.single.sentence, startsWith('Archived '));
    expect((await app.api!.task(taskId)).archived, isTrue);
    controller.dispose();
  }, skip: skip);

  test(
    'an empty line is the harness\'s to refuse, and the app does not ask',
    () async {
      final controller = QuickSearchController(
        app: app,
        place: const QuickSearchPlace(SearchOrigin.usage),
        project: project,
      );
      await controller.search('   ');
      expect(controller.status, QuickSearchStatus.idle);
      controller.dispose();
    },
    skip: skip,
  );
}
