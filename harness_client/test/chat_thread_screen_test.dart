// Answers in threads from the conversation on a phone: the reply cards the
// harness recorded, the composer that answers one message and not another,
// and the block the app sends -- the same `_harness.thread` data the Emacs
// chat sends, so the harness makes the same comment.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/acp/acp_message.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:harness_client/src/ui/adaptive/platform_style.dart';
import 'package:harness_client/src/ui/app_scope.dart';
import 'package:harness_client/src/ui/screens/session_screen.dart';
import 'package:harness_client/src/ui/theme/harness_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';

const _session = 's1';

Map<String, Object?> _threadData() => {
  'id': 't-review-1',
  'refs': [
    {
      'kind': 'chat',
      'node': 'n2',
      'who': 'agent',
      'session': _session,
      'text': 'The merge queue has three moving parts.',
    },
  ],
  'response': 'Which part should the phone show?',
};

String _markup() =>
    '<thread id="t-review-1">\n'
    '<quote>The merge queue has three moving parts.</quote>\n'
    'Which part should the phone show?\n'
    '</thread>';

/// A conversation with a reply of the user's, and the agent's answer in its
/// thread.
void _seedThread(FakeHarness harness) {
  final now = DateTime.now().millisecondsSinceEpoch / 1000;
  harness.nodes[_session]!.addAll([
    {
      'id': 'tu1',
      'kind': 'user',
      'ts': now + 1,
      'content': _markup(),
      'blocks': [
        {'type': 'text', 'text': _markup(), 'thread': _threadData()},
      ],
    },
    {
      'id': 'ta1',
      'kind': 'assistant',
      'ts': now + 2,
      'content':
          'The first part.\n\n'
          '<thread id="t-review-1" status="closed">\n'
          '<quote>Which part should the phone show?</quote>\n'
          'The queue, on the phone.\n'
          '</thread>',
      'meta': {'model': 'claude:claude-fable-5-1'},
    },
  ]);
}

class _Rig {
  _Rig(this.settings, this.harness, this.app);
  final SettingsController settings;
  final FakeHarness harness;
  final AppController app;
}

Future<_Rig> _connected() async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsController();
  await settings.load();
  final harness = FakeHarness();
  _seedThread(harness);
  final app = AppController(settings: settings, connector: harness.connector);
  addTearDown(app.dispose);
  await app.connect('ws://memory/acp');
  return _Rig(settings, harness, app);
}

Future<void> _settle(WidgetTester tester, [int rounds = 20]) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

Future<void> _pump(
  WidgetTester tester,
  _Rig rig, {
  double width = 390,
  double height = 844,
  Key? key,
}) async {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    HarnessStyle(
      style: HarnessPlatformStyle.material,
      child: HarnessScope(
        app: rig.app,
        settings: rig.settings,
        child: MaterialApp(
          theme: HarnessTheme.material(Brightness.dark),
          home: SessionScreen(key: key, sessionId: _session),
        ),
      ),
    ),
  );
  await tester.pump();
  await _settle(tester);
}

Future<void> _answer(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const Key('composer-field')), text);
  await tester.pump();
  await tester.tap(find.byKey(const Key('composer-send')));
  await _settle(tester);
}

Map<String, Object?> _sentThread(FakeHarness harness) {
  final blocks = harness.promptBlocks.last;
  final block = blocks.lastWhere((entry) => entry['type'] == 'text');
  return asMap(asMap(block['_harness'])['thread']);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a reply of the harness is a card, not raw markup', (
    tester,
  ) async {
    final rig = await _connected();
    await _pump(tester, rig);
    expect(find.textContaining('<thread'), findsNothing);
    expect(find.text('Which part should the phone show?'), findsWidgets);
    expect(find.text('The queue, on the phone.'), findsOneWidget);
    expect(find.text('Closed'), findsOneWidget);
    expect(find.byTooltip('Reply to thread'), findsNWidgets(2));
    expect(find.byTooltip('Reply'), findsWidgets);
  });

  testWidgets('the answer to a message sends its node and its words', (
    tester,
  ) async {
    final rig = await _connected();
    await _pump(tester, rig, height: 2000);
    await tester.tap(find.byKey(const ValueKey('reply-node-ta1-head')));
    await tester.pumpAndSettle();
    expect(find.textContaining('The first part.'), findsWidgets);
    expect(find.text('· Message'), findsOneWidget);
    await _answer(tester, 'The queue, then.');
    final thread = _sentThread(rig.harness);
    expect(thread.containsKey('id'), isFalse, reason: 'a new thread');
    final ref = asMap((thread['refs'] as List).single);
    expect(ref['kind'], 'chat');
    expect(ref['node'], 'ta1');
    expect(ref['who'], 'agent');
    expect(ref['session'], _session);
    expect(ref['text'], 'The first part.');
    // The card the harness echoes draws it, and the composer is a message
    // again.
    await tester.dragUntilVisible(
      find.text('The queue, then.'),
      find.byKey(const ValueKey('transcript-list')),
      const Offset(0, 300),
    );
    expect(find.text('The queue, then.'), findsOneWidget);
    expect(find.text('Reply'), findsNothing);
  });

  testWidgets('the answer to a thread stays in that thread', (tester) async {
    final rig = await _connected();
    await _pump(tester, rig);
    final card = find.byKey(const ValueKey('node-ta1-t-review-1'));
    await tester.dragUntilVisible(
      card,
      find.byKey(const ValueKey('transcript-list')),
      const Offset(0, 300),
    );
    await tester.tap(
      find.descendant(of: card, matching: find.byTooltip('Reply to thread')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Thread'), findsWidgets);
    await _answer(tester, 'The queue, on the phone, in the queue list.');
    final thread = _sentThread(rig.harness);
    expect(thread['id'], 't-review-1');
    final ref = asMap((thread['refs'] as List).single);
    expect(ref['node'], 'ta1');
    expect(ref['text'], 'The queue, on the phone.');
  });

  testWidgets('a second reply answers the second message, not the first', (
    tester,
  ) async {
    final rig = await _connected();
    await _pump(tester, rig);
    await tester.tap(find.byKey(const ValueKey('reply-node-ta1-head')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('composer-field')),
      'For the first answer.',
    );
    await tester.pump();
    final user = find.byKey(const ValueKey('reply-node-tu1'));
    await tester.dragUntilVisible(
      user,
      find.byKey(const ValueKey('transcript-list')),
      const Offset(0, 300),
    );
    await tester.tap(user);
    await tester.pumpAndSettle();
    expect(find.text('You'), findsWidgets);
    await tester.tap(find.byKey(const Key('composer-send')));
    await _settle(tester);
    final ref = asMap((_sentThread(rig.harness)['refs'] as List).single);
    expect(ref['node'], 'tu1');
    expect(ref['who'], 'you');
  });

  testWidgets('the words and the reply survive leaving the screen', (
    tester,
  ) async {
    final rig = await _connected();
    await _pump(tester, rig);
    await tester.tap(find.byKey(const ValueKey('reply-node-ta1-head')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('composer-field')),
      'Not sent yet.',
    );
    await tester.pump();
    expect(rig.app.drafts.text('session:$_session'), 'Not sent yet.');
    // Another page opens over the screen and goes: the controller and the
    // drafts are the app's, and the reply still names the message.
    final navigator = Navigator.of(tester.element(find.byType(SessionScreen)));
    navigator.push<void>(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Elsewhere')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Elsewhere'), findsOneWidget);
    navigator.pop();
    await tester.pumpAndSettle();
    expect(rig.app.sessionController(_session).reply?.refs.single.node, 'ta1');
    expect(rig.app.drafts.text('session:$_session'), 'Not sent yet.');
    expect(find.text('Reply'), findsWidgets);
    expect(find.textContaining('The first part.'), findsWidgets);
  });

  testWidgets('cancelling the reply leaves a message of one\'s own', (
    tester,
  ) async {
    final rig = await _connected();
    await _pump(tester, rig);
    await tester.tap(find.byKey(const ValueKey('reply-node-ta1-head')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Cancel reply'));
    await tester.pumpAndSettle();
    expect(rig.app.sessionController(_session).reply, isNull);
    await _answer(tester, 'A message of my own.');
    final block = rig.harness.promptBlocks.last.last;
    expect(asMap(block['_harness']).containsKey('thread'), isFalse);
  });

  testWidgets('a reply card and its actions fit 320 points', (tester) async {
    final rig = await _connected();
    await _pump(tester, rig, width: 320);
    expect(tester.takeException(), isNull);
    expect(find.byTooltip('Reply to thread'), findsNWidgets(2));
  });
}
