// The quick search without a screen: what the harness answers, read; the
// commands the app offers it; and the controller that asks, waits, drops the
// answers nobody wants any more and does what a person says yes to.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/acp/acp_message.dart';
import 'package:harness_client/src/models/quick_search.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/quick_search_catalogue.dart';
import 'package:harness_client/src/state/quick_search_controller.dart';
import 'package:harness_client/src/state/quick_search_history.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';
import 'support/quick_search_harness.dart';

const _main = '/Users/noah/Code/emacs-agent-harness/';
const _other = '/Users/noah/Code/other-project/';

class _Rig {
  _Rig(this.settings, this.search, this.app);
  final SettingsController settings;
  final SearchingHarness search;
  final AppController app;

  FakeHarness get harness => search.harness;

  QuickSearchController controller([
    QuickSearchPlace place = const QuickSearchPlace(SearchOrigin.sessions),
    String? project,
  ]) => QuickSearchController(app: app, place: place, project: project);
}

Future<_Rig> _rig({
  bool offersSearch = true,
  bool enhanced = true,
  void Function(FakeHarness harness)? arrange,
}) async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsController();
  await settings.load();
  final search = SearchingHarness(
    harness: FakeHarness(enhanced: enhanced),
    offersSearch: offersSearch,
  );
  arrange?.call(search.harness);
  final app = AppController(settings: settings, connector: search.connector);
  await app.connect('ws://memory/acp');
  await _settle();
  return _Rig(settings, search, app);
}

/// Let what is in flight arrive.
Future<void> _settle([int rounds = 6]) async {
  for (var i = 0; i < rounds; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 15));
  }
}

/// A host that notes where the search sent the app.
class _Host implements QuickSearchHost {
  final List<String> went = [];
  bool needsYou = true;

  @override
  void openTab(String tab) => went.add('tab:$tab');

  @override
  void openSession(String sessionId) => went.add('session:$sessionId');

  @override
  bool openNeedsYou() {
    went.add('needs-you');
    return needsYou;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('what the harness answers', () {
    test('is read into a plan: answer, note, and each kind of thing', () {
      final wire = plan(
        query: 'how do I attach an image?',
        bias: 'commands',
        answer: 'Tap **+** on the Tasks screen.',
        note: 'No task matched; these sessions mention it.',
        looked: 'searched the sessions for “attach image”',
        widened: true,
        commands: [
          foundCommand(
            'attach-images',
            keys: 'Tasks tab › +',
            label: 'Attach images',
            doc: 'The image button.',
          ),
        ],
        sessions: [
          foundSession(
            's1',
            name: 'Design the merge queue',
            snippet: 'attach the image to the task',
            node: 'n3',
            ranges: [
              [0, 6],
              [11, 16],
            ],
            task: 'task-1',
          ),
        ],
        tasks: [
          foundTask(
            'task-1',
            'Build the client',
            'active: working',
            session: 's3',
          ),
        ],
        actions: [
          proposedAction('task-2', 'archive', title: 'Review the screenshots'),
        ],
      );
      final parsed = QuickSearchPlan.fromWire(wire);
      expect(parsed.query, 'how do I attach an image?');
      expect(parsed.bias, SearchBias.commands);
      expect(parsed.answer, 'Tap **+** on the Tasks screen.');
      expect(parsed.note, 'No task matched; these sessions mention it.');
      expect(parsed.looked, 'searched the sessions for “attach image”');
      expect(parsed.widened, isTrue);
      expect(parsed.isEmpty, isFalse);
      expect(parsed.commands.single.command, 'attach-images');
      expect(parsed.commands.single.keys, 'Tasks tab › +');
      expect(parsed.commands.single.label, 'Attach images');
      final session = parsed.sessions.single;
      expect(session.id, 's1');
      expect(session.title, 'Design the merge queue');
      expect(session.snippet, 'attach the image to the task');
      expect(session.node, 'n3');
      expect(session.ranges, [(0, 6), (11, 16)]);
      expect(session.task, 'task-1');
      expect(session.updated, isNotNull);
      final task = parsed.tasks.single;
      expect(
        (task.id, task.title, task.status, task.sessionId),
        ('task-1', 'Build the client', 'active: working', 's3'),
      );
      final action = parsed.actions.single;
      expect(
        (action.task, action.action, action.title),
        ('task-2', 'archive', 'Review the screenshots'),
      );
      expect(action.text, isNull);
      expect(parsed.countOf(SearchKind.commands), 1);
      expect(parsed.countOf(SearchKind.sessions), 1);
      expect(parsed.countOf(SearchKind.tasks), 1);
    });

    test('says what it holds when the harness sent next to nothing', () {
      // What the harness encodes an empty list and a missing word as: null.
      final parsed = QuickSearchPlan.fromWire({
        'query': 'x',
        'answer': null,
        'note': '   ',
        'widened': false,
        'ids': null,
        'actions': null,
        'tasks': null,
        'sessions': null,
        'commands': null,
      });
      expect(parsed.isEmpty, isTrue);
      expect(parsed.answer, isNull);
      expect(parsed.note, isNull);
      expect(parsed.widened, isFalse);
      expect(parsed.bias, isNull);
      expect(QuickSearchPlan.fromWire(const {}).isEmpty, isTrue);
      // An answer in words is something, with nothing to list.
      expect(QuickSearchPlan.fromWire({'answer': 'Yes.'}).isEmpty, isFalse);
    });

    test('drops what has nothing to be found or done by', () {
      final parsed = QuickSearchPlan.fromWire({
        'tasks': [
          {'id': '', 'title': 'No id'},
          {'id': 't-1', 'title': 'A task'},
        ],
        'sessions': [
          {'name': 'No id either'},
          {'id': 's1'},
        ],
        'commands': [
          {'label': 'No name'},
          {'command': 'open-tasks'},
        ],
        'actions': [
          {'task': 't-1'},
          {'action': 'stop'},
          {'task': 't-1', 'action': 'stop'},
        ],
      });
      expect(parsed.tasks.map((t) => t.id), ['t-1']);
      expect(parsed.sessions.map((s) => s.id), ['s1']);
      expect(parsed.commands.map((c) => c.command), ['open-tasks']);
      expect(parsed.actions.map((a) => a.action), ['stop']);
    });

    test('names a session by its id when it has no name yet', () {
      expect(
        FoundSession.fromWire({'id': 'abcdef0123456789'}).title,
        'Session abcdef01',
      );
      expect(
        FoundSession.fromWire({'id': 'abc', 'name': ' '}).title,
        'Session abc',
      );
    });

    test('keeps the ranges that are ranges, in any form the numbers come', () {
      final session = FoundSession.fromWire({
        'id': 's',
        'ranges': [
          [1, 4],
          ['5', 8.0],
          [9],
          'x',
          null,
        ],
      });
      expect(session.ranges, [(1, 4), (5, 8)]);
    });

    test('says what an action means, and how it went', () {
      const archive = ProposedAction(
        task: 't-1',
        action: 'archive',
        title: 'Fix the docs',
      );
      expect(archive.sentence, 'archive “Fix the docs”');
      expect(
        const ProposedAction(
          task: 't-1',
          action: 'complete',
          title: 'A',
        ).sentence,
        'mark “A” done',
      );
      expect(
        const ProposedAction(
          task: 't-1',
          action: 'message',
          title: 'A',
          text: 'go on',
        ).sentence,
        'send “go on” to “A”',
      );
      expect(
        const ProposedAction(
          task: 't-1',
          action: 'reject',
          title: 'A',
          text: 'tests missing',
        ).sentence,
        'send “A” back: “tests missing”',
      );
      expect(
        const ProposedAction(
          task: 't-1',
          action: 'priority',
          title: 'A',
          text: 'high',
        ).sentence,
        'make “A” high priority',
      );
      expect(
        const ProposedAction(task: 't-9', action: 'stop').sentence,
        'stop t-9',
      );
      expect(
        ActionResult.fromWire({
          'task': 't-1',
          'action': 'archive',
          'title': 'Fix the docs',
          'ok': true,
        }).sentence,
        'Archived “Fix the docs”',
      );
      expect(
        ActionResult.fromWire({
          'task': 't-1',
          'action': 'stop',
          'title': 'Fix the docs',
          'ok': false,
          'error': 'it is not working',
        }).sentence,
        'Could not stop “Fix the docs”: it is not working',
      );
      expect(
        ActionResult.failed(archive, 'The connection was closed.').sentence,
        'Could not archive “Fix the docs”: The connection was closed.',
      );
    });

    test('goes back to the harness as it was proposed', () {
      const action = ProposedAction(
        task: 't-1',
        action: 'message',
        text: 'go on',
        title: 'A',
        confirm: true,
      );
      expect(action.toWire(), {
        'task': 't-1',
        'action': 'message',
        'text': 'go on',
        'title': 'A',
        'confirm': true,
      });
      // What the proposal did not have is not sent as null.
      expect(const ProposedAction(task: 't-1', action: 'stop').toWire(), {
        'task': 't-1',
        'action': 'stop',
        'confirm': false,
      });
    });

    test('lists the kinds in the order the place favours them', () {
      expect(SearchBias.tasks.order.first, SearchKind.tasks);
      expect(SearchBias.sessions.order.first, SearchKind.sessions);
      expect(SearchBias.commands.order.first, SearchKind.commands);
      for (final bias in SearchBias.values) {
        expect(bias.order.toSet(), SearchKind.values.toSet());
        expect(SearchBias.fromWire(bias.wire), bias);
      }
      expect(SearchBias.fromWire(' Tasks '), SearchBias.tasks);
      expect(SearchBias.fromWire('nonsense'), isNull);
    });
  });

  group('where a search was opened', () {
    test('sets what it favours, and tells the harness who asks', () {
      const tasks = QuickSearchPlace(SearchOrigin.tasks);
      expect(tasks.bias, SearchBias.tasks);
      expect(tasks.toContext(_main), {
        'view': 'board',
        'title': 'Tasks',
        'client': 'phone app',
        'project': _main,
      });
      expect(
        const QuickSearchPlace(SearchOrigin.sessions).bias,
        SearchBias.sessions,
      );
      expect(const QuickSearchPlace(SearchOrigin.sessions).view, 'sessions');
      for (final origin in [
        SearchOrigin.usage,
        SearchOrigin.server,
        SearchOrigin.settings,
      ]) {
        expect(QuickSearchPlace(origin).bias, SearchBias.commands);
      }
      expect(const QuickSearchPlace(SearchOrigin.usage).view, 'buffer');
      expect(const QuickSearchPlace(SearchOrigin.settings).view, 'settings');
      expect(const QuickSearchPlace(SearchOrigin.usage).title, 'Usage');
    });

    test('in a conversation names it, so that a search leaves it out', () {
      const place = QuickSearchPlace.chat(
        's1',
        title: 'Design the merge queue',
      );
      expect(place.bias, SearchBias.commands);
      expect(place.toContext(_main), {
        'view': 'chat',
        'title': 'Design the merge queue',
        'client': 'phone app',
        'project': _main,
        'session': 's1',
      });
      expect(const QuickSearchPlace.chat('s1').title, 'Conversation');
    });

    test('is the screen of the tab that is open', () {
      expect(SearchOrigin.ofTab('tasks'), SearchOrigin.tasks);
      expect(SearchOrigin.ofTab('usage'), SearchOrigin.usage);
      expect(SearchOrigin.ofTab('server'), SearchOrigin.server);
      expect(SearchOrigin.ofTab('settings'), SearchOrigin.settings);
      expect(SearchOrigin.ofTab('sessions'), SearchOrigin.sessions);
      expect(SearchOrigin.ofTab('nonsense'), SearchOrigin.sessions);
      expect(SearchOrigin.ofTab('chat'), SearchOrigin.sessions);
    });
  });

  group('the commands of the app', () {
    test(
      'are named once each, in words, and are told whole to the model',
      () async {
        final rig = await _rig();
        final commands = quickCommands(rig.app, project: _main);
        final names = [for (final command in commands) command.name];
        expect(names.toSet().length, names.length, reason: 'unique names');
        for (final command in commands) {
          expect(
            RegExp(r'^[a-z][a-z0-9]*(-[a-z0-9]+)*$').hasMatch(command.name),
            isTrue,
            reason: command.name,
          );
          expect(command.label.trim(), isNotEmpty, reason: command.name);
          expect(command.doc.trim(), isNotEmpty, reason: command.name);
          // The harness shows its model 120 characters of it, no more: a
          // longer one would be cut in the middle of a sentence.
          expect(
            command.doc.length,
            lessThanOrEqualTo(120),
            reason: '${command.name}: ${command.doc}',
          );
        }
        // Every screen and the way to each, a new session and a new task.
        expect(
          names,
          containsAll([
            'open-sessions',
            'open-tasks',
            'open-usage',
            'open-server',
            'open-settings',
            'new-session',
            'new-task',
            'attach-images',
            'answer-waiting',
            'task-actions',
            'queue-controls',
            'reconnect',
            'disconnect',
            'remember-connection',
            'platform-feel',
          ]),
        );
      },
    );

    test(
      'go to the harness as an Emacs command does: with their taps as keys',
      () async {
        final rig = await _rig();
        final wire = {
          for (final command in quickCommands(rig.app, project: _main))
            command.name: command.toWire(),
        };
        expect(wire['open-tasks'], {
          'command': 'open-tasks',
          'keys': 'Tasks tab',
          'where': 'menu',
          'label': 'Open the task board',
          'doc': wire['open-tasks']!['doc'],
          'here': true,
        });
        expect(wire['new-task']!['keys'], 'Tasks tab › +');
        expect(wire['new-session']!['keys'], 'Sessions tab › +');
        // A command with no taps says none, and says nothing of it.
        final bare = QuickCommand(
          name: 'x',
          label: 'X',
          doc: 'Does x.',
          run: (_) async {},
        ).toWire();
        expect(bare.containsKey('keys'), isFalse);
        expect(bare['here'], isTrue);
      },
    );

    test('leave out what this harness cannot do', () async {
      final rig = await _rig(
        arrange: (harness) => harness.methods.removeAll({
          'task/list',
          'task/submit',
          'usage/totals',
          'usage/summary',
        }),
      );
      final names = [
        for (final command in quickCommands(rig.app, project: _main))
          command.name,
      ];
      expect(names, isNot(contains('open-tasks')));
      expect(names, isNot(contains('new-task')));
      expect(names, isNot(contains('task-actions')));
      expect(names, isNot(contains('queue-controls')));
      expect(names, isNot(contains('open-usage')));
      expect(names, contains('open-sessions'));
      expect(names, contains('open-settings'));
      // Projects narrow what the app still has.
      expect(names.any((name) => name.startsWith('project-')), isTrue);
    });

    test(
      'leave out a theme that is in use already, and flip the thinking',
      () async {
        final rig = await _rig();
        List<String> names() => [
          for (final command in quickCommands(rig.app, project: _main))
            command.name,
        ];
        expect(names(), containsAll(['theme-light', 'theme-dark']));
        expect(names(), isNot(contains('theme-system')));
        expect(names(), contains('hide-thinking'));
        expect(names(), isNot(contains('show-thinking')));
        await rig.settings.setThemeMode(ThemeMode.dark);
        await rig.settings.setShowThinking(false);
        expect(names(), containsAll(['theme-light', 'theme-system']));
        expect(names(), isNot(contains('theme-dark')));
        expect(names(), contains('show-thinking'));
        expect(names(), isNot(contains('hide-thinking')));
      },
    );

    test('set the theme and the thinking at once', () async {
      final rig = await _rig();
      final host = _Host();
      QuickCommand command(String name) => quickCommands(
        rig.app,
        project: _main,
      ).firstWhere((command) => command.name == name);
      await command('theme-dark').run(host);
      expect(rig.settings.themeMode, ThemeMode.dark);
      await command('theme-light').run(host);
      expect(rig.settings.themeMode, ThemeMode.light);
      await command('theme-system').run(host);
      expect(rig.settings.themeMode, ThemeMode.system);
      await command('hide-thinking').run(host);
      expect(rig.settings.showThinking, isFalse);
      await command('show-thinking').run(host);
      expect(rig.settings.showThinking, isTrue);
      expect(host.went, isEmpty, reason: 'a setting goes nowhere');
    });

    test('go to the screen they are about', () async {
      final rig = await _rig();
      final host = _Host();
      for (final (name, tab) in [
        ('open-sessions', 'sessions'),
        ('open-tasks', 'tasks'),
        ('open-usage', 'usage'),
        ('open-server', 'server'),
        ('open-settings', 'settings'),
        ('new-task', 'tasks'),
        ('task-actions', 'tasks'),
        ('queue-controls', 'tasks'),
        ('disconnect', 'settings'),
        ('platform-feel', 'settings'),
        ('remember-connection', 'settings'),
        ('attach-images', 'tasks'),
      ]) {
        host.went.clear();
        await quickCommands(
          rig.app,
          project: _main,
        ).firstWhere((command) => command.name == name).run(host);
        expect(host.went, ['tab:$tab'], reason: name);
      }
    });

    test('a project of each, which narrows the board to it', () async {
      final rig = await _rig(
        arrange: (harness) => harness.seedOtherProjectTasks(),
      );
      await rig.app.refreshProjects();
      final commands = quickCommands(rig.app, project: _main);
      final projects = commands
          .where((command) => command.name.startsWith('project-'))
          .toList();
      expect(rig.app.projects, containsAll([_main, _other]));
      expect(projects.length, rig.app.projects.length);
      final other = projects.firstWhere(
        (command) => command.label.contains('other-project'),
      );
      expect(other.name, 'project-other-project');
      expect(other.label, 'Show the other-project project’s tasks');
      expect(other.doc.length, lessThanOrEqualTo(120));
      final host = _Host();
      await other.run(host);
      await _settle();
      expect(host.went, ['tab:tasks']);
      expect(rig.app.selectedProject, _other);
      expect(rig.app.tasks!.project, _other);
      // And every project again.
      final all = quickCommands(
        rig.app,
        project: _other,
      ).firstWhere((command) => command.name == 'all-projects');
      await all.run(host);
      await _settle();
      expect(rig.app.tasks!.project, isNull);
      expect(
        quickCommands(rig.app, project: _other).map((c) => c.name),
        isNot(contains('all-projects')),
        reason: 'nothing to widen on a board that shows every project',
      );
    });

    test('tell two projects of one name apart', () async {
      final rig = await _rig(
        arrange: (harness) => harness.projectList = [
          '/Users/a/Code/app/',
          '/Users/b/Code/app/',
          '/Users/b/Code/App Two!/',
        ],
      );
      await rig.app.refreshProjects();
      final names = [
        for (final command in quickCommands(rig.app))
          if (command.name.startsWith('project-')) command.name,
      ];
      expect(
        names,
        containsAll(['project-app', 'project-app-2', 'project-app-two']),
      );
    });

    test('start a session in the project the search is about', () async {
      final rig = await _rig();
      final host = _Host();
      final command = quickCommands(
        rig.app,
        project: _other,
      ).firstWhere((command) => command.name == 'new-session');
      expect(command.label, 'Start a new session');
      expect(command.doc, contains('other-project'));
      await command.run(host);
      await _settle();
      final created = rig.harness.calls('session/new');
      expect(created, hasLength(1));
      expect(created.single['cwd'], _other);
      // The list of sessions, where it appears, and then the session.
      expect(host.went, hasLength(2));
      expect(host.went.first, 'tab:sessions');
      expect(host.went.last, startsWith('session:'));
    });

    test(
      'offer to answer the session that needs you, and say how many wait',
      () async {
        final rig = await _rig();
        // Nobody has opened the session that waits yet.
        rig.app.openSession('s2');
        rig.app.closeSession();
        await _settle();
        expect(rig.app.attentionCount, greaterThan(0));
        final waiting = quickCommands(
          rig.app,
          project: _main,
        ).firstWhere((command) => command.name == 'answer-waiting');
        expect(waiting.label, 'Answer the session that needs you');
        expect(waiting.kind, QuickCommandKind.action);
        final host = _Host();
        await waiting.run(host);
        expect(host.went, ['needs-you']);
        // With none waiting it is a way to where they are answered.
        host
          ..went.clear()
          ..needsYou = false;
        await waiting.run(host);
        expect(host.went, ['needs-you', 'tab:sessions']);
      },
    );
  });

  group('a controller', () {
    test(
      'asks the harness with where it was typed and what the app can do',
      () async {
        final rig = await _rig();
        final controller = rig.controller(
          const QuickSearchPlace(SearchOrigin.tasks),
          _main,
        );
        rig.search.onAsk = (_) => plan(
          query: 'the task about the docs',
          bias: 'tasks',
          tasks: [foundTask('task-1', 'Build the client', 'active: working')],
        );
        await controller.search('  the task about the docs  ');
        expect(controller.status, QuickSearchStatus.done);
        expect(controller.query, 'the task about the docs');
        expect(controller.bias, SearchBias.tasks);
        expect(controller.plan!.tasks.single.id, 'task-1');
        expect(controller.model, 'claude:claude-haiku-4-5');
        expect(rig.search.asks, hasLength(1));
        final ask = rig.search.asks.single;
        expect(ask['cwd'], _main);
        expect(ask['query'], 'the task about the docs');
        expect(rig.search.lastOpts['bias'], 'tasks');
        expect(rig.search.lastContext, {
          'view': 'board',
          'title': 'Tasks',
          'client': 'phone app',
          'project': _main,
        });
        expect(
          rig.search.lastCommandNames,
          containsAll(['open-tasks', 'new-task', 'open-settings']),
        );
        // Each command goes as the app offers it.
        final first = asMapList(rig.search.lastOpts['commands']).first;
        expect(
          first.keys,
          containsAll(['command', 'where', 'label', 'doc', 'here']),
        );
        expect(first['here'], isTrue);
        controller.dispose();
      },
    );

    test(
      'says which model answers before it does, and where it is typed',
      () async {
        final rig = await _rig();
        final controller = rig.controller(
          const QuickSearchPlace(SearchOrigin.settings),
          _main,
        );
        expect(controller.model, isNull);
        await controller.warm();
        expect(controller.model, 'claude:claude-haiku-4-5');
        expect(rig.search.warms.single, {'cwd': _main});
        controller.dispose();
      },
    );

    test(
      'asks nothing of a harness without the method, and warm does not mind',
      () async {
        final rig = await _rig(offersSearch: false);
        final controller = rig.controller();
        expect(controller.availability, QuickSearchAvailability.unsupported);
        await controller.warm();
        await controller.search('how do I attach an image?');
        expect(controller.status, QuickSearchStatus.idle);
        expect(rig.search.asks, isEmpty);
        expect(rig.search.warms, isEmpty);
        expect(rig.app.quickSearchHistory.lines, isEmpty);
        controller.dispose();
      },
    );

    test('does not ask about an empty line', () async {
      final rig = await _rig();
      final controller = rig.controller();
      await controller.search('   ');
      expect(controller.status, QuickSearchStatus.idle);
      expect(rig.search.asks, isEmpty);
      controller.dispose();
    });

    test('keeps the lines asked, newest first, each once', () async {
      final rig = await _rig();
      final controller = rig.controller();
      await controller.search('one');
      await controller.search('two');
      await controller.search('one');
      expect(controller.history, ['one', 'two']);
      expect(rig.app.quickSearchHistory.lines, ['one', 'two']);
      controller.dispose();
    });

    test('drops the answer to a line that was asked over', () async {
      final rig = await _rig();
      final controller = rig.controller();
      final first = Completer<Object?>();
      final second = Completer<Object?>();
      final gates = [first, second];
      rig.search.onAsk = (_) => gates.removeAt(0).future;
      final one = controller.search('first line');
      await _settle();
      final two = controller.search('second line');
      await _settle();
      // The second answers first, and the first comes late.
      second.complete(plan(query: 'second line', answer: 'The second.'));
      await two;
      first.complete(plan(query: 'first line', answer: 'The first.'));
      await one;
      await _settle();
      expect(controller.query, 'second line');
      expect(controller.plan!.answer, 'The second.');
      expect(controller.status, QuickSearchStatus.done);
      controller.dispose();
    });

    test('stops waiting when asked to, and drops what comes late', () async {
      final rig = await _rig();
      final controller = rig.controller();
      final gate = Completer<Object?>();
      rig.search.onAsk = (_) => gate.future;
      final done = controller.search('where did I debug the merge queue?');
      await _settle();
      expect(controller.status, QuickSearchStatus.searching);
      expect(controller.searching, isTrue);
      controller.cancel();
      expect(controller.status, QuickSearchStatus.idle);
      gate.complete(plan(answer: 'Too late.'));
      await done;
      await _settle();
      expect(controller.status, QuickSearchStatus.idle);
      expect(controller.plan, isNull);
      // Cancelling when nothing waits changes nothing.
      controller.cancel();
      expect(controller.status, QuickSearchStatus.idle);
      // The line was asked: it is in the history, to be refined.
      expect(controller.history, ['where did I debug the merge queue?']);
      controller.dispose();
    });

    test('says why a search failed in the harness\'s words, and asks again on retry', () async {
      final rig = await _rig();
      final controller = rig.controller();
      rig.search.onAsk = (_) =>
          throw const SearchFailure('The model took longer than 45s');
      await controller.search('slow one');
      expect(controller.status, QuickSearchStatus.failed);
      expect(controller.error, 'The model took longer than 45s');
      expect(controller.plan, isNull);
      rig.search.onAsk = (_) => plan(answer: 'Now it answers.');
      await controller.retry();
      expect(controller.status, QuickSearchStatus.done);
      expect(controller.error, isNull);
      expect(controller.plan!.answer, 'Now it answers.');
      expect(rig.search.asks.map((ask) => ask['query']), [
        'slow one',
        'slow one',
      ]);
      controller.dispose();
    });

    test('says a lost connection as it is', () async {
      final rig = await _rig();
      final controller = rig.controller();
      final gate = Completer<Object?>();
      rig.search.onAsk = (_) => gate.future;
      final done = controller.search('anything');
      await _settle();
      await rig.harness.dropConnection('The network went away.');
      await done;
      expect(controller.status, QuickSearchStatus.failed);
      expect(controller.error, isNotEmpty);
      controller.dispose();
    });

    test('asks the same line again favouring something else', () async {
      final rig = await _rig();
      final controller = rig.controller(
        const QuickSearchPlace(SearchOrigin.tasks),
        _main,
      );
      await controller.search('the merge queue');
      expect(rig.search.lastOpts['bias'], 'tasks');
      await controller.reask(SearchBias.sessions);
      expect(controller.bias, SearchBias.sessions);
      expect(rig.search.lastOpts['bias'], 'sessions');
      expect(rig.search.lastQuery, 'the merge queue');
      await controller.reask(SearchBias.commands);
      expect(rig.search.lastOpts['bias'], 'commands');
      expect(rig.search.asks, hasLength(3));
      controller.dispose();
    });

    test('keeps the project of the screen it was opened from', () async {
      final rig = await _rig(
        arrange: (harness) => harness.seedOtherProjectTasks(),
      );
      await rig.app.refreshProjects();
      rig.app.selectProject(_main);
      expect(
        QuickSearchController.defaultProject(
          rig.app,
          const QuickSearchPlace(SearchOrigin.usage),
        ),
        _main,
      );
      // The board narrowed to a project is about that project.
      await rig.app.tasks!.load(project: _other);
      expect(
        QuickSearchController.defaultProject(
          rig.app,
          const QuickSearchPlace(SearchOrigin.tasks),
        ),
        _other,
      );
      expect(
        QuickSearchController.defaultProject(
          rig.app,
          const QuickSearchPlace(SearchOrigin.sessions),
        ),
        _main,
      );
      // A conversation is about its own session's project.
      expect(
        QuickSearchController.defaultProject(
          rig.app,
          const QuickSearchPlace.chat('s4'),
        ),
        _other,
      );
    });

    test(
      'searches another project from when it is told to, and warms it',
      () async {
        final rig = await _rig(
          arrange: (harness) => harness.seedOtherProjectTasks(),
        );
        await rig.app.refreshProjects();
        final controller = rig.controller(
          const QuickSearchPlace(SearchOrigin.tasks),
          _main,
        );
        controller.setProject(_other);
        await _settle();
        expect(controller.project, _other);
        expect(rig.search.warms.last, {'cwd': _other});
        await controller.search('anything');
        expect(rig.search.asks.last['cwd'], _other);
        expect(rig.search.lastContext['project'], _other);
        controller.dispose();
      },
    );

    test(
      'says why it cannot ask: no harness, no search, no connection',
      () async {
        final rig = await _rig();
        final controller = rig.controller();
        expect(controller.availability, QuickSearchAvailability.ready);
        await rig.app.disconnect();
        expect(controller.availability, QuickSearchAvailability.disconnected);
        await controller.search('anything');
        expect(rig.search.asks, isEmpty);
        controller.dispose();

        final plain = await _rig(enhanced: false);
        expect(
          plain.controller().availability,
          QuickSearchAvailability.unsupported,
        );
      },
    );

    test('does what a person says yes to, and says how it went', () async {
      final rig = await _rig();
      final controller = rig.controller();
      rig.search.onAsk = (_) => plan(
        actions: [
          proposedAction('task-2', 'archive', title: 'Review the screenshots'),
          proposedAction(
            'task-1',
            'stop',
            title: 'Build the client',
            confirm: true,
          ),
        ],
        tasks: [
          foundTask('task-2', 'Review the screenshots', 'review: finished'),
        ],
      );
      await controller.search(
        'get rid of the screenshots task and stop the client',
      );
      // Every order is proposed, the ones the board would run at once too.
      expect(controller.proposed, hasLength(2));
      expect(controller.results, isEmpty);
      await controller.doIt();
      expect(controller.proposed, isEmpty);
      expect(controller.running, isEmpty);
      expect(controller.results.map((r) => r.ok), [true, true]);
      expect(controller.results.map((r) => r.sentence), [
        'Archived “Review the screenshots”',
        'Stopped “Build the client”',
      ]);
      expect(rig.search.applies, hasLength(1));
      expect(asMapList(rig.search.applies.single['actions']), [
        {
          'task': 'task-2',
          'action': 'archive',
          'title': 'Review the screenshots',
          'confirm': false,
        },
        {
          'task': 'task-1',
          'action': 'stop',
          'title': 'Build the client',
          'confirm': true,
        },
      ]);
      controller.dispose();
    });

    test('says what failed when the harness will not', () async {
      final rig = await _rig();
      final controller = rig.controller();
      rig.search.onAsk = (_) => plan(
        actions: [proposedAction('task-1', 'stop', title: 'Build the client')],
      );
      rig.search.onApply = (_) => [
        {
          'task': 'task-1',
          'action': 'stop',
          'title': 'Build the client',
          'ok': false,
          'error': 'it is not working',
        },
      ];
      await controller.search('stop the client');
      await controller.doIt();
      expect(controller.results.single.ok, isFalse);
      expect(
        controller.results.single.sentence,
        'Could not stop “Build the client”: it is not working',
      );
      // And when the call itself fails, each action says so.
      rig.search.onAsk = (_) => plan(
        actions: [
          proposedAction('task-1', 'stop', title: 'Build the client'),
          proposedAction('task-2', 'archive', title: 'Review'),
        ],
      );
      rig.search.onApply = (_) => throw const SearchFailure('No such task');
      await controller.search('stop the client and archive the review');
      await controller.doIt();
      expect(controller.results.map((r) => r.ok), [false, false]);
      expect(controller.results.first.error, 'No such task');
      controller.dispose();
    });

    test('leaves undone what is skipped', () async {
      final rig = await _rig();
      final controller = rig.controller();
      rig.search.onAsk = (_) => plan(
        actions: [proposedAction('task-1', 'stop', title: 'Build the client')],
      );
      await controller.search('stop the client');
      expect(controller.proposed, hasLength(1));
      controller.skip();
      expect(controller.proposed, isEmpty);
      await controller.doIt();
      expect(rig.search.applies, isEmpty);
      expect(controller.results, isEmpty);
      controller.dispose();
    });

    test('reads the board again after it did something to a task', () async {
      final rig = await _rig();
      final controller = rig.controller();
      rig.search.onAsk = (_) =>
          plan(actions: [proposedAction('task-2', 'archive', title: 'Review')]);
      await controller.search('archive the review task');
      final before = rig.harness.calls('_harness/task/list').length;
      await controller.doIt();
      await _settle();
      expect(
        rig.harness.calls('_harness/task/list').length,
        greaterThan(before),
      );
      controller.dispose();
    });

    test('is quiet once it is gone: a late answer touches nothing', () async {
      final rig = await _rig();
      final controller = rig.controller();
      final gate = Completer<Object?>();
      rig.search.onAsk = (_) => gate.future;
      final done = controller.search('anything');
      await _settle();
      controller.dispose();
      gate.complete(plan(answer: 'Late.'));
      await done;
      await _settle();
      expect(controller.plan, isNull);
    });
  });

  group('the history', () {
    test('keeps the latest first, each once, and no more than it can hold', () {
      final history = QuickSearchHistory();
      expect(history.isEmpty, isTrue);
      history.add('  a  ');
      history.add('b');
      history.add('a');
      history.add('   ');
      expect(history.lines, ['a', 'b']);
      for (var n = 0; n < 50; n++) {
        history.add('line $n');
      }
      expect(history.lines.length, QuickSearchHistory.capacity);
      expect(history.lines.first, 'line 49');
      history.clear();
      expect(history.isEmpty, isTrue);
    });
  });
}
