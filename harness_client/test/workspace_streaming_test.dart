import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/models/workspace.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:harness_client/src/state/workspace_controller.dart';
import 'package:harness_client/src/ui/adaptive/platform_style.dart';
import 'package:harness_client/src/ui/screens/workspace_screen.dart';
import 'package:harness_client/src/ui/theme/harness_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';

WorkspaceSummary _workspace() => const WorkspaceSummary(
  id: 'w1',
  name: 'Home',
  lastThread: 't1',
  threads: [
    WorkspaceThread(
      id: 't1',
      title: 'Kitchen renovation',
      state: 'live',
      live: 's1',
      tags: ['Kitchen'],
    ),
    WorkspaceThread(
      id: 't2',
      title: 'Taxes',
      state: 'live',
      live: 's2',
      tags: ['Taxes'],
    ),
  ],
);

WorkspaceController _preview(List<WorkspaceEntry> entries) =>
    WorkspaceController.preview(
      workspace: _workspace(),
      entries: entries,
      memory: const WorkspaceMemoryStatus(notes: 1, fullText: true),
    );

Map<String, Object?> _chunk(String text, {String node = 'a1'}) => {
  'sessionUpdate': 'agent_message_chunk',
  'content': {'type': 'text', 'text': text},
  '_harness': {'nodeId': node},
};

Map<String, Object?> _thought(String text, {String node = 'x1'}) => {
  'sessionUpdate': 'agent_thought_chunk',
  'content': {'type': 'text', 'text': text},
  '_harness': {'nodeId': node},
};

Map<String, Object?> _node(String kind, String content, {String id = 'a1'}) => {
  'sessionUpdate': '_harness/node',
  'node': {'id': id, 'kind': kind, 'content': content},
};

Future<void> _show(WidgetTester tester, WorkspaceController controller) async {
  tester.view.physicalSize = const Size(1024, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    HarnessStyle(
      style: HarnessPlatformStyle.material,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: HarnessTheme.material(Brightness.light),
        home: MediaQuery(
          data: const MediaQueryData(size: Size(1024, 900)),
          child: WorkspaceScreen(
            app: AppController(settings: SettingsController()),
            controller: controller,
            onOpenSession: (_) {},
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

WorkspaceEntry? _entry(WorkspaceController controller, String node) {
  for (final entry in controller.entries) {
    if (entry.node == node) return entry;
  }
  return null;
}

/// The words as the screen draws them: a reply is Markdown, which drops the
/// space at the end of a line that is still being written.
Finder _reply(String words) => find.text(words.trim());

Future<void> _until(bool Function() done, {String what = 'the app'}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) fail('Timed out waiting for $what.');
    await Future<void>.delayed(const Duration(milliseconds: 4));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the opening node and its first delta are one piece of text', () {
    final controller = WorkspaceController.preview(workspace: _workspace());
    controller.applyEvent('workspace/episode-changed', [
      'w1',
      't1',
      's1',
      const <String, Object?>{},
    ]);
    // The harness opens the node with the first chunk, then sends that same
    // chunk as the first stream delta.
    controller.applySessionUpdate('s1', _node('assistant', 'The '));
    controller.applySessionUpdate('s1', _chunk('The '));
    controller.applySessionUpdate('s1', _chunk('quote '));
    controller.applySessionUpdate('s1', _chunk('is open.'));
    expect(_entry(controller, 'a1')!.text, 'The quote is open.');

    // A brief node is the workspace's private context, not a message.
    controller.applySessionUpdate('s1', {
      'sessionUpdate': '_harness/node',
      'node': {
        'id': 'b1',
        'kind': 'user',
        'content': '[Workspace Home]',
        'meta': {'workspace-brief': true},
      },
    });
    expect(_entry(controller, 'b1'), isNull);

    controller.applySessionUpdate(
      's1',
      _node('assistant', 'The quote is open.'),
    );
    expect(_entry(controller, 'a1')!.text, 'The quote is open.');
    expect(
      controller.entries.where((entry) => entry.node == 'a1'),
      hasLength(1),
    );
  });

  testWidgets('a streamed reply grows, then replaces with its final text', (
    tester,
  ) async {
    final controller = _preview(const [
      WorkspaceEntry(
        kind: 'message',
        thread: 't1',
        episode: 's1',
        role: 'assistant',
        node: 'a1',
        text: 'The ',
      ),
    ]);
    await _show(tester, controller);
    expect(_reply('The '), findsOneWidget);
    // The timeline keys a reply by its node, so the element the words grow
    // in is the one it started in.
    const reply = ValueKey('message:t1:a1');
    final firstEntry = tester.element(find.byKey(reply));

    // The opening chunk is already in the timeline: it is not appended twice.
    controller.applySessionUpdate('s1', _chunk('The '));
    await tester.pump();
    expect(_reply('The '), findsOneWidget);
    expect(_reply('The The '), findsNothing);

    controller.applySessionUpdate('s1', _chunk('quote '));
    await tester.pump();
    expect(_reply('The quote '), findsOneWidget);
    // The growing entry keeps its element, so its reveal does not replay.
    expect(identical(firstEntry, tester.element(find.byKey(reply))), isTrue);
    expect(_entry(controller, 'a1')!.text, 'The quote ');

    controller.applySessionUpdate('s1', _chunk('is open.'));
    await tester.pump();
    expect(find.text('The quote is open.'), findsOneWidget);
    expect(_entry(controller, 'a1')!.streaming, isTrue);

    // The final node is the whole message: it replaces the accumulated
    // deltas instead of being added to them.
    controller.applySessionUpdate(
      's1',
      _node('assistant', 'The quote is open.'),
    );
    await tester.pump();
    expect(find.text('The quote is open.'), findsOneWidget);
    expect(_entry(controller, 'a1')!.streaming, isFalse);
    expect(find.textContaining('The The'), findsNothing);
    expect(
      controller.entries.where((entry) => entry.node == 'a1'),
      hasLength(1),
    );
  });

  testWidgets('thinking, status and other threads do not change the answer', (
    tester,
  ) async {
    final controller = _preview(const [
      WorkspaceEntry(
        kind: 'message',
        thread: 't1',
        episode: 's1',
        role: 'assistant',
        node: 'a1',
        text: 'Kitchen ',
      ),
      WorkspaceEntry(
        kind: 'message',
        thread: 't2',
        episode: 's2',
        role: 'assistant',
        node: 'a2',
        text: 'Tax ',
      ),
    ]);
    await _show(tester, controller);

    controller.applySessionUpdate('s1', _thought('Kitchen '));
    controller.applySessionUpdate('s1', _node('thinking', 'Kitchen '));
    controller.applySessionUpdate('s1', {
      'sessionUpdate': '_harness/activity',
      'activity': {'phase': 'thinking'},
    });
    controller.applySessionUpdate('s1', {
      'sessionUpdate': 'tool_call',
      'toolCallId': 'c1',
      'status': 'in_progress',
    });
    // A blocked turn is session status and a permission card, not a new
    // assistant message: the words already written stay.
    controller.applySessionUpdate('s1', {
      'sessionUpdate': '_harness/session',
      'session': {'id': 's1', 'status': 'blocked'},
    });
    controller.applySessionUpdate('s1', {
      'sessionUpdate': 'tool_call_update',
      'toolCallId': 'c1',
      'status': 'pending',
    });
    controller.applyEvent('session/pending-changed', ['s1', []]);
    await tester.pump();
    expect(_entry(controller, 'a1')!.text, 'Kitchen ');
    expect(_entry(controller, 'a1')!.streaming, isFalse);

    controller.applySessionUpdate('s2', _chunk('return.', node: 'a2'));
    await tester.pump();
    expect(_entry(controller, 'a2')!.text, 'Tax return.');
    expect(_entry(controller, 'a1')!.text, 'Kitchen ');

    // A session that is not this workspace's is not shown.
    controller.applySessionUpdate('s9', _chunk('elsewhere', node: 'a9'));
    await tester.pump();
    expect(_entry(controller, 'a9'), isNull);
    expect(
      controller.entries.where((entry) => entry.text.contains('elsewhere')),
      isEmpty,
    );
  });

  test('reconnect replays the complete reply once', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsController();
    await settings.load();
    final harness = FakeHarness(workspace: true);
    final app = AppController(
      settings: settings,
      connector: harness.connector,
      reconnectDelays: const [Duration(milliseconds: 5)],
    );
    addTearDown(app.dispose);
    await app.connect('ws://memory/acp');
    final workspace = app.workspace!;
    await _until(
      () => workspace.entries.any((entry) => entry.node == 'a1'),
      what: 'the workspace timeline',
    );

    harness.appendWorkspaceEntry({
      'kind': 'message',
      'thread': 'th-1',
      'episode': 's1',
      'role': 'assistant',
      'node': 'a2',
      'text': 'I ',
    });
    await _until(
      () => workspace.entries.any((entry) => entry.node == 'a2'),
      what: 'the new entry',
    );
    harness.streamChunk('s1', 'a2', 'I ');
    harness.streamChunk('s1', 'a2', 'can ');
    harness.streamChunk('s1', 'a2', 'help.');
    await _until(
      () => _entry(workspace, 'a2')?.text == 'I can help.',
      what: 'the streamed text',
    );
    expect(_entry(workspace, 'a2')!.text, 'I can help.');
    expect(_entry(workspace, 'a1')!.text, 'Noted. The quote is open.');

    // A read that began before the last chunk answers with the first one.
    // It must not erase words the client already showed.
    await workspace.load();
    expect(_entry(workspace, 'a2')!.text, 'I can help.');

    harness.streamNode('s1', {
      'id': 'a2',
      'kind': 'assistant',
      'content': 'I can help.',
    });
    await _until(
      () => _entry(workspace, 'a2')?.streaming == false,
      what: 'the final node',
    );
    harness.setWorkspaceEntryText('a2', 'I can help.');

    await harness.dropConnection();
    await _until(
      () => app.isConnected && harness.connects == 2,
      what: 'the reconnect',
    );
    await _until(
      () =>
          !workspace.loading &&
          _entry(workspace, 'a2')?.text == 'I can help.' &&
          _entry(workspace, 'a2')?.streaming == false,
      what: 'the replayed timeline',
    );
    final replayed = workspace.entries
        .where((entry) => entry.node == 'a2')
        .toList();
    expect(replayed, hasLength(1));
    expect(replayed.single.text, 'I can help.');
    expect(replayed.single.text.contains('I can help.I can help.'), isFalse);
    expect(
      workspace.entries.where((entry) => entry.node == 'a1'),
      hasLength(1),
    );
  });
}
