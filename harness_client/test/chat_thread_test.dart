// A reply in a thread of the conversation: the harness's <thread> block, the
// data a message of the user's keeps beside its words, and the card that draws
// both.  The words of a reply are the card's; the message keeps none of them.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/models/chat_thread.dart';
import 'package:harness_client/src/models/transcript.dart';
import 'package:harness_client/src/ui/adaptive/platform_style.dart';
import 'package:harness_client/src/ui/theme/harness_theme.dart';
import 'package:harness_client/src/ui/widgets/chat_threads.dart';
import 'package:harness_client/src/ui/widgets/transcript_view.dart';

const _agentRef = ChatThreadRef(
  kind: 'chat',
  node: 'n1',
  who: 'agent',
  session: 's1',
  text: 'The parser is split in three.',
);

Map<String, Object?> _threadData({
  String? id = 't-abc',
  String? status,
  String response = 'Keep it that way.',
}) => {
  if (id != null) 'id': id,
  if (status != null) 'status': status,
  'refs': [_agentRef.toWire()],
  'response': response,
};

String _markup(
  Map<String, Object?> data, {
  String response = 'Keep it that way.',
}) {
  final id = data['id'];
  final tag = id == null ? '<thread>' : '<thread id="$id">';
  final quote = (data['refs'] as List)
      .map((ref) => (ref as Map)['text'])
      .join('\n\n');
  return '$tag\n<quote>$quote</quote>\n$response\n</thread>';
}

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  double width = 390,
  double height = 844,
  bool screen = false,
}) async {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    HarnessStyle(
      style: HarnessPlatformStyle.material,
      child: MaterialApp(
        theme: HarnessTheme.material(Brightness.dark),
        home: Scaffold(
          body: SafeArea(
            child: screen
                ? child
                : SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: child,
                  ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('the reply a message of the user keeps', () {
    test('is its quote and the words, never in the message body twice', () {
      final data = _threadData(status: 'closed');
      final node = {
        'id': 'n2',
        'kind': 'user',
        'content': 'Agreed.\n\n${_markup(data)}',
        'blocks': [
          {'type': 'text', 'text': _markup(data), 'thread': data},
        ],
      };
      final chat = ChatThreadText.fromNode(node);
      expect(chat.body, 'Agreed.');
      expect(chat.threads, hasLength(1));
      final thread = chat.threads.single;
      expect(thread.id, 't-abc');
      expect(thread.status, 'closed');
      expect(thread.isClosed, isTrue);
      expect(thread.response, 'Keep it that way.');
      expect(thread.refs.single.sourceLabel, 'Agent');
      expect(thread.refs.single.text, 'The parser is split in three.');
      expect(thread.label, 'Thread');
    });

    test('without blocks is read from the markup it carries', () {
      final data = _threadData();
      final chat = ChatThreadText.fromNode({
        'id': 'n2',
        'kind': 'user',
        'content': _markup(data),
      });
      expect(chat.body, isEmpty);
      expect(chat.threads.single.response, 'Keep it that way.');
      expect(chat.threads.single.quote, 'The parser is split in three.');
      expect(
        chat.threads.single.refs,
        isEmpty,
        reason: 'an agent writes a quote, not structured references',
      );
    });

    test('a local echo is the card from the first keystroke', () {
      final transcript = TranscriptState(sessionId: 's1');
      final data = _threadData();
      final item = transcript.addLocalUser('Keep it that way.', thread: data);
      expect(item.text, isEmpty, reason: 'the bubble keeps no words');
      expect(item.threads.single.response, 'Keep it that way.');
      expect(item.threads.single.id, 't-abc');
      expect(item.threads.single.refs.single.node, 'n1');
      // The harness holds it for the running turn, and sends the response
      // alone: the answer is under the card, never in the bubble too.
      transcript.syncPending([
        (id: 'n-2', text: 'Keep it that way.', sender: null),
      ]);
      expect(item.text, isEmpty);
      expect(item.threads.single.response, 'Keep it that way.');
      expect(item.pending, isTrue);
    });

    test('a reply to a thread sends its references, not its words', () {
      final thread = ChatThread.fromMarkup(
        id: 't-1',
        quote: 'What about the tests?',
        response: 'They pass.',
      );
      final data = thread.replyData();
      expect(data['id'], 't-1');
      final refs = data['refs'] as List;
      expect(refs, hasLength(1));
      expect((refs.single as Map)['kind'], 'chat');
      expect((refs.single as Map)['text'], 'What about the tests?');
      expect(
        data.containsKey('response'),
        isFalse,
        reason: 'the text of the block is the response',
      );
    });

    test('the composer keeps the message it answers', () {
      const draft = ChatReplyDraft(refs: [_agentRef], threadId: 't-abc');
      expect(draft.label, 'Thread');
      expect(draft.sourceLabel, 'Agent');
      expect(draft.excerpt, 'The parser is split in three.');
      expect(draft.threadData()['id'], 't-abc');
      const fresh = ChatReplyDraft(refs: [_agentRef]);
      expect(fresh.label, 'Message');
      expect(fresh.threadData().containsKey('id'), isFalse);
    });
  });

  group('the strict <thread> form', () {
    test('a block between two paragraphs leaves one paragraph break', () {
      final parsed = parseThreadMarkup(
        'First.\n\n${_markup(_threadData())}\n\nLast.',
      );
      expect(parsed.body, 'First.\n\nLast.');
      expect(parsed.threads, hasLength(1));
    });

    test('a block in code is an example, not a reply', () {
      for (final text in [
        'Look:\n\n```\n${_markup(_threadData())}\n```',
        'Look: `${_markup(_threadData())}`',
      ]) {
        final parsed = parseThreadMarkup(text);
        expect(parsed.threads, isEmpty, reason: text);
        expect(parsed.body, contains('<thread'));
      }
    });

    test('a form the harness would refuse is no reply', () {
      for (final text in [
        '<THREAD>\n<quote>q</quote>\nr\n</THREAD>',
        '<thread id=t>\n<quote>q</quote>\nr\n</thread>',
        '<thread foo="bar">\n<quote>q</quote>\nr\n</thread>',
        '<thread status="done">\n<quote>q</quote>\nr\n</thread>',
        '<thread>\n<quote>q</quote>\n<reply>r</reply>\n</thread>',
        '<thread>\n<quote>q</quote>\nr',
        '<thread>\n<quote>q</quote>r <quote>x</quote>\n</thread>',
      ]) {
        expect(parseThreadMarkup(text).threads, isEmpty, reason: text);
      }
    });

    test('a status alone is a block, and an unknown status is not', () {
      final closed = parseThreadMarkup(
        '<thread id="t-1" status="closed">\n'
        '</thread>',
      );
      expect(closed.threads.single.status, 'closed');
      expect(closed.threads.single.response, isEmpty);
      expect(
        parseThreadMarkup('<thread id="t-1" status="Done">\n</thread>').threads,
        isEmpty,
      );
    });
  });

  group('the card of a reply', () {
    testWidgets('names its thread, its state, its quote and its answer', (
      tester,
    ) async {
      final thread = ChatThread(
        id: 't-2f1a',
        status: 'closed',
        refs: const [_agentRef],
        response: 'Agreed: three parts, not two.',
      );
      await _pump(
        tester,
        ChatThreadCard(thread: thread, onReply: () {}, onOpenThread: () {}),
      );
      expect(find.text('Thread'), findsOneWidget);
      expect(find.text('Closed'), findsOneWidget);
      expect(find.text('Agent'), findsOneWidget);
      expect(find.text('The parser is split in three.'), findsOneWidget);
      expect(find.text('Agreed: three parts, not two.'), findsOneWidget);
      expect(find.byTooltip('Reply to thread'), findsOneWidget);
      expect(find.byTooltip('Thread'), findsOneWidget);
    });

    testWidgets('a new thread says so, and has no state', (tester) async {
      await _pump(
        tester,
        const ChatThreadCard(
          thread: ChatThread(response: 'A first word.', quote: 'Why?'),
        ),
      );
      expect(find.text('New thread'), findsOneWidget);
      expect(find.text('Open'), findsNothing);
      expect(find.text('Closed'), findsNothing);
      expect(find.text('A first word.'), findsOneWidget);
    });

    testWidgets('a long answer folds and opens again', (tester) async {
      final answer = '${'A sentence of the answer. ' * 80}THE END';
      await _pump(
        tester,
        ChatThreadCard(
          thread: ChatThread(id: 't-1', response: answer),
        ),
      );
      expect(find.text('More'), findsOneWidget);
      expect(find.textContaining('THE END'), findsNothing);
      await tester.ensureVisible(find.text('More'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('More'));
      await tester.pumpAndSettle();
      expect(find.textContaining('THE END'), findsOneWidget);
      expect(find.text('Less'), findsOneWidget);
      await tester.ensureVisible(find.text('Less'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Less'));
      await tester.pumpAndSettle();
      expect(find.textContaining('THE END'), findsNothing);
    });

    testWidgets('a long quote folds without hiding the answer', (tester) async {
      final quote = '${'A quoted line. ' * 40}THE QUOTE END';
      await _pump(
        tester,
        ChatThreadCard(
          thread: ChatThread(id: 't-1', quote: quote, response: 'The answer.'),
        ),
      );
      expect(find.text('The answer.'), findsOneWidget);
      expect(find.textContaining('THE QUOTE END'), findsNothing);
      expect(find.text('More'), findsOneWidget);
      await tester.tap(find.text('More'));
      await tester.pumpAndSettle();
      expect(find.textContaining('THE QUOTE END'), findsOneWidget);
    });

    testWidgets('tapping a quote shows the message it is of', (tester) async {
      ChatThreadRef? shown;
      await _pump(
        tester,
        ChatThreadCard(
          thread: const ChatThread(id: 't-1', refs: [_agentRef]),
          onShowRef: (ref) => shown = ref,
        ),
      );
      await tester.tap(find.text('Agent'));
      await tester.pump();
      expect(shown?.node, 'n1');
      expect(shown?.session, 's1');
    });

    testWidgets('a card at 320 with large text does not overflow', (
      tester,
    ) async {
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await _pump(
        tester,
        ChatThreadCard(
          thread: const ChatThread(
            id: 't-1',
            status: 'open',
            refs: [_agentRef],
            response: 'The answer.',
          ),
          onReply: () {},
          onOpenThread: () {},
        ),
        width: 320,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('the reply bar over the composer', () {
    testWidgets('names the reply, the thread and whose words it answers', (
      tester,
    ) async {
      var cancelled = false;
      await _pump(
        tester,
        ChatReplyBar(
          draft: const ChatReplyDraft(refs: [_agentRef], threadId: 't-abc'),
          onCancel: () => cancelled = true,
        ),
      );
      expect(find.text('Reply'), findsOneWidget);
      expect(find.text('· Thread'), findsOneWidget);
      expect(find.text('· Agent'), findsOneWidget);
      expect(find.text('The parser is split in three.'), findsOneWidget);
      await tester.tap(find.byTooltip('Cancel reply'));
      expect(cancelled, isTrue);
    });

    testWidgets("a message of one's own says Message", (tester) async {
      await _pump(
        tester,
        ChatReplyBar(
          draft: const ChatReplyDraft(refs: [_agentRef]),
          onCancel: () {},
        ),
      );
      expect(find.text('· Message'), findsOneWidget);
      expect(find.text('· Thread'), findsNothing);
    });

    testWidgets('fits 320 points at twice the text', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await _pump(
        tester,
        ChatReplyBar(
          draft: const ChatReplyDraft(refs: [_agentRef], threadId: 't-abc'),
          onCancel: () {},
        ),
        width: 320,
      );
      expect(tester.takeException(), isNull);
      expect(find.byTooltip('Cancel reply'), findsOneWidget);
      expect(find.text('· Thread'), findsOneWidget);
    });
  });

  group('a message with a reply in the transcript', () {
    TranscriptItem userItem() => TranscriptItem(
      key: 'node-n2',
      nodeId: 'n2',
      kind: TranscriptKind.user,
      text: 'Agreed.',
      sender: 'You',
      threads: [
        ChatThread(
          id: 't-1',
          status: 'closed',
          refs: const [_agentRef],
          response: 'Keep it that way.',
        ),
      ],
    );

    TranscriptItem agentItem() => TranscriptItem(
      key: 'node-n3',
      nodeId: 'n3',
      kind: TranscriptKind.assistant,
      text: 'Then it is done.',
      sender: 'Agent',
      threads: [
        ChatThread.fromMarkup(
          id: 't-2',
          quote: 'What about the tests?',
          response: 'They pass, all 44.',
        ),
      ],
    );

    testWidgets('draws its words and its cards, and answers both', (
      tester,
    ) async {
      final replied = <String>[];
      final threaded = <String>[];
      await _pump(
        tester,
        TranscriptView(
          items: [userItem(), agentItem()],
          showThinking: true,
          sessionId: 's1',
          onReply: (item) => replied.add(item.nodeId ?? ''),
          onReplyThread: (item, thread) =>
              threaded.add('${item.nodeId}/${thread.id}'),
        ),
        height: 1200,
        screen: true,
      );
      expect(find.text('Agreed.'), findsOneWidget);
      expect(find.text('Keep it that way.'), findsOneWidget);
      expect(find.text('Then it is done.'), findsOneWidget);
      expect(find.text('They pass, all 44.'), findsOneWidget);
      // One action on each message, one on each card.
      expect(find.byTooltip('Reply'), findsNWidgets(2));
      expect(find.byTooltip('Reply to thread'), findsNWidgets(2));
      await tester.tap(find.byTooltip('Reply').first);
      await tester.tap(find.byTooltip('Reply to thread').last);
      expect(replied, ['n2']);
      expect(threaded, ['n3/t-2']);
    });

    testWidgets('a message of the agent that is only a reply draws the card', (
      tester,
    ) async {
      final item = TranscriptItem(
        key: 'node-n4',
        nodeId: 'n4',
        kind: TranscriptKind.assistant,
        // What the node says before it was read, as the agent wrote it.
        text: '<thread id="t-3">\n<quote>Is it ready?</quote>\nYes.\n</thread>',
        sender: 'Agent',
      );
      await _pump(
        tester,
        TranscriptView(items: [item], showThinking: true, sessionId: 's1'),
        height: 500,
        screen: true,
      );
      expect(find.text('Yes.'), findsOneWidget);
      expect(find.textContaining('<thread'), findsNothing);
    });

    testWidgets('the quoted message is brought into view', (tester) async {
      final items = [
        for (var index = 0; index < 30; index++)
          TranscriptItem(
            key: 'node-n$index',
            nodeId: 'n$index',
            kind: TranscriptKind.assistant,
            text: 'Message $index',
            sender: 'Agent',
          ),
      ];
      await _pump(
        tester,
        TranscriptView(
          items: items,
          showThinking: true,
          focusNodeId: 'n3',
          focusTick: 1,
        ),
        screen: true,
      );
      await tester.pumpAndSettle();
      final found = find.byKey(const ValueKey('node-n3'));
      expect(found, findsOneWidget);
      final rect = tester.getRect(found);
      final screen = tester.getRect(find.byType(TranscriptView));
      expect(rect.top, greaterThanOrEqualTo(screen.top - 1));
      expect(rect.bottom, lessThanOrEqualTo(screen.bottom + 1));
    });
  });
}
