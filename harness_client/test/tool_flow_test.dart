// The calls of a task's session, read through the whole client: the harness's
// replay over ACP and its nodes with the keys the harness writes (`call-id`,
// `is-error`, a result's `meta`), into the page the person reads.  Calls of
// the tools on the harness's allow list (`_harness/tools/list`) fold into runs
// under one summary line, as they do in its Emacs chat; every other call is a
// card of its own.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/app.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';
import 'support/tool_showcase.dart';
import 'support/transcript_log.dart';

Future<void> _settle(WidgetTester tester, [int rounds = 12]) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

/// Open the session [name] of [harness], which has the showcase's calls
/// unless another one is given.
Future<FakeHarness> _openSession(
  WidgetTester tester, {
  FakeHarness? harness,
  String name = toolShowcaseName,
}) async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsController();
  await settings.load();
  harness ??= FakeHarness()..seedToolShowcase();
  final app = AppController(settings: settings, connector: harness.connector);
  await app.connect('ws://memory/acp');
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(HarnessApp(settings: settings, appController: app));
  await tester.pump();
  await _settle(tester);
  await tester.tap(find.text(name));
  await _settle(tester, 30);
  return harness;
}

/// How many times the app asked the harness for its tools.
int _toolListings(FakeHarness harness) =>
    harness.requests.where((r) => r.$1 == '_harness/tools/list').length;

final _list = find.byKey(const ValueKey('transcript-list'));

/// A session of the harness that [log] is the transcript of.
void _seed(FakeHarness harness, TranscriptLog log, String name) {
  harness.sessions['s-live'] = {
    ...toolShowcaseSession(),
    'id': 's-live',
    'name': name,
    'status': 'running',
  };
  harness.nodes['s-live'] = [...log.nodes];
}

void main() {
  testWidgets('a task\'s session opens on the call that handed its work in', (
    tester,
  ) async {
    await _openSession(tester);
    // The latest of what the agent did is what is on the screen.
    expect(find.textContaining('Hand in the finished work'), findsOneWidget);
    expect(find.text('Hand-in'), findsOneWidget);
  });

  testWidgets('the call that handed the work in opens to its report', (
    tester,
  ) async {
    await _openSession(tester);
    await tester.tap(find.textContaining('Hand in the finished work'));
    await _settle(tester, 6);
    expect(find.text('PROBLEM'), findsOneWidget);
    expect(find.text('SUMMARY'), findsOneWidget);
    expect(find.text('What was wrong'), findsOneWidget);
    expect(
      find.textContaining('Tool call results are hard to read'),
      findsWidgets,
    );
    // Not the call as it was sent.
    expect(find.textContaining('"evidence"'), findsNothing);
    expect(find.textContaining(r'\n'), findsNothing);
  });

  testWidgets('a refused call and a failed one are not the same', (
    tester,
  ) async {
    await _openSession(tester);
    // The refused call is one that writes, which is not on the allow list:
    // a card of its own, in the screen's reach.
    await tester.dragUntilVisible(
      find.text('Denied'),
      _list,
      const Offset(0, 120),
      maxIteration: 40,
    );
    expect(find.text('Denied'), findsOneWidget);
    expect(find.textContaining('lies outside the directories'), findsOneWidget);
    // The failed one is a command, which is on it: it is in a run, and the
    // run's line says one of its calls failed, without being opened.
    await tester.dragUntilVisible(
      find.text('1 failed'),
      _list,
      const Offset(0, 120),
      maxIteration: 40,
    );
    expect(find.text('1 failed'), findsOneWidget);
    expect(find.text('Failed'), findsNothing);
    // Opened, the call says it failed, and why.
    await tester.tap(find.text('Bash ×2'));
    await _settle(tester, 6);
    expect(find.text('Failed'), findsOneWidget);
    expect(
      find.textContaining("error • Undefined name 'theme'"),
      findsOneWidget,
    );
  });

  testWidgets('calls fold as the harness\'s allow list says, as in Emacs', (
    tester,
  ) async {
    final harness = await _openSession(tester);
    // The harness was asked what its tools are, once.
    expect(_toolListings(harness), 1);
    // A read and a search, with the thought between them, are one run; so
    // are the two commands.
    await tester.dragUntilVisible(
      find.text('Read file, Search files · thinking'),
      _list,
      const Offset(0, 120),
      maxIteration: 40,
    );
    expect(find.text('Read file, Search files · thinking'), findsOneWidget);
    expect(
      find.text('Read file: lib/src/ui/widgets/tool_card.dart'),
      findsNothing,
    );
    expect(find.text('Thought'), findsNothing);
    expect(find.text('Bash ×2'), findsOneWidget);
    expect(find.text('2 tool calls'), findsNWidgets(2));
    // The edit, and the write that was refused, are not on the list: they
    // are cards, each between the runs it cut, with what they are about.
    expect(
      find.textContaining('Edit file: lib/src/ui/widgets/tool_card.dart'),
      findsOneWidget,
    );
    expect(find.textContaining('Write file: /etc/hosts'), findsOneWidget);
    // And the hand-in, which the person must see, is one too.
    expect(find.textContaining('Hand in the finished work'), findsOneWidget);
    // Opened, a run shows its calls as the cards they are, and the thought
    // that was folded in with them, between them.
    await tester.tap(find.text('Read file, Search files · thinking'));
    await _settle(tester, 6);
    expect(
      find.textContaining('Read file: lib/src/ui/widgets/tool_card.dart'),
      findsOneWidget,
    );
    expect(find.textContaining('Search files: _open'), findsOneWidget);
    expect(find.text('Thought'), findsOneWidget);
  });

  testWidgets('a harness without the list of its tools folds nothing', (
    tester,
  ) async {
    // An older harness: no `tools/list`, so the app knows no allow list.
    final harness = await _openSession(
      tester,
      harness: FakeHarness(toolCatalogue: false)..seedToolShowcase(),
    );
    expect(_toolListings(harness), 0);
    expect(find.textContaining('tool call'), findsNothing);
    await tester.dragUntilVisible(
      find.text('Denied'),
      _list,
      const Offset(0, 120),
      maxIteration: 40,
    );
    // Every call is a card, as it was before calls folded: the failed
    // command says so at once.
    expect(find.text('Failed'), findsOneWidget);
    expect(find.text('Denied'), findsOneWidget);
  });

  testWidgets('a harness that cannot list its tools still opens the session', (
    tester,
  ) async {
    final harness = FakeHarness()
      ..seedToolShowcase()
      ..failToolList = true;
    await _openSession(tester, harness: harness);
    expect(_toolListings(harness), greaterThan(0));
    // The conversation is there, on its latest call, and nothing is folded.
    expect(find.textContaining('Hand in the finished work'), findsOneWidget);
    expect(find.textContaining('tool call'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reads the tools again when the harness is reloaded', (
    tester,
  ) async {
    final harness = await _openSession(tester);
    await tester.dragUntilVisible(
      find.text('Read file, Search files · thinking'),
      _list,
      const Offset(0, 120),
      maxIteration: 40,
    );
    expect(find.text('2 tool calls'), findsNWidgets(2));
    expect(find.textContaining('Edit file: lib/src'), findsOneWidget);
    // The harness was reloaded with its edit tool on the list: the edit
    // is no longer a card between two runs, and all five calls are one.
    for (final spec in harness.toolSpecs) {
      if (spec['name'] == 'edit_file') spec['coalescable'] = true;
    }
    harness.announce('harness/reloaded');
    await _settle(tester, 12);
    expect(_toolListings(harness), 2);
    await tester.dragUntilVisible(
      find.text('5 tool calls'),
      _list,
      const Offset(0, 120),
      maxIteration: 40,
    );
    expect(find.text('5 tool calls'), findsOneWidget);
    expect(find.text('2 tool calls'), findsNothing);
  });

  testWidgets('a run grows with the calls, and never folds away one that '
      'waits for you', (tester) async {
    final log = TranscriptLog()
      ..user('Find where the cards are drawn')
      ..call('c1', 'read_file', title: 'Read file: lib/a.dart')
      ..call('c2', 'grep', title: 'Search files: ToolCard');
    final harness = FakeHarness();
    _seed(harness, log, 'Look around');
    await _openSession(tester, harness: harness, name: 'Look around');
    expect(find.text('2 tool calls'), findsOneWidget);
    expect(find.text('Read file, Search files'), findsOneWidget);
    // The person opens the run.
    await tester.tap(find.text('Read file, Search files'));
    await _settle(tester, 6);
    expect(find.textContaining('Read file: lib/a.dart'), findsOneWidget);

    // The agent reads another file: it joins the run, which stays open.
    log.call('c3', 'read_file', title: 'Read file: lib/b.dart');
    harness.stream('s-live', log.nodes[log.nodes.length - 2]);
    harness.stream('s-live', log.nodes.last);
    await _settle(tester, 8);
    expect(find.text('3 tool calls'), findsOneWidget);
    expect(find.text('Read file ×2, Search files'), findsOneWidget);
    expect(find.textContaining('Read file: lib/b.dart'), findsOneWidget);
    expect(find.textContaining('Read file: lib/a.dart'), findsOneWidget);

    // Then a command it has no leave for: the session waits on the person,
    // and the call stays in view, outside the run, until it is answered.
    log.call('c4', 'bash', title: 'Bash: make test', result: false);
    harness.stream('s-live', log.nodes.last);
    final answer = harness.askPermission(
      's-live',
      callId: 'c4',
      title: 'Bash: make test',
    );
    await _settle(tester, 8);
    expect(find.text('PERMISSION'), findsOneWidget);
    expect(find.text('3 tool calls'), findsOneWidget);
    expect(find.text('Read file ×2, Search files'), findsOneWidget);
    expect(find.textContaining('Bash: make test'), findsWidgets);

    // Allowed, it runs and ends, and the run takes it in.
    await tester.tap(find.text('Allow'));
    await _settle(tester, 8);
    expect((await answer)['outcome'], containsPair('optionId', 'allow-once'));
    log.result('c4', output: 'All passed');
    harness.stream('s-live', log.nodes.last);
    await _settle(tester, 8);
    expect(find.text('PERMISSION'), findsNothing);
    expect(find.text('4 tool calls'), findsOneWidget);
    expect(find.text('Bash, Read file ×2, Search files'), findsNothing);
    expect(find.text('Read file ×2, Search files, Bash'), findsOneWidget);
  });
}
