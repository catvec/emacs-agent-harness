// A message of the user's says how far it got, and only from the receipt the
// harness wrote on its node (`meta.receipt`): a message the harness holds says
// "Queued" by not being a node yet, one the provider answered says
// "Delivered" while it is the newest of the conversation, and one whose
// request failed, is being tried again, or was cut off says so on itself.
//
//   HARNESS_SHOTS=/some/directory flutter test test/message_receipt_test.dart
//
// also writes a picture of the marks, one on each state.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/models/transcript.dart';
import 'package:harness_client/src/ui/adaptive/platform_style.dart';
import 'package:harness_client/src/ui/theme/harness_theme.dart';
import 'package:harness_client/src/ui/widgets/transcript_view.dart';

import 'support/harness_wire.dart';
import 'support/real_fonts.dart';

/// A message of the user's, with [state] as its delivery receipt.
Wire _sent(WireConversation conversation, String text, String state) =>
    conversation.user(text, {
      'meta': {
        'receipt': {'state': state, 'at': 1000.0, 'attempt': 1},
      },
    });

/// The transcript of [nodes], read as the harness sends them.
TranscriptState _read(List<Wire> nodes) {
  final transcript = TranscriptState();
  for (final node in nodes) {
    for (final update in WireConversation.updates(node, live: false)) {
      transcript.apply(update);
    }
  }
  return transcript;
}

Widget _screen(String title, List<TranscriptItem> items) => Column(
  children: [
    Container(
      width: double.infinity,
      color: const Color(0xFF10123A),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Text(
        title,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
    Expanded(child: TranscriptView(items: items, showThinking: true)),
  ],
);

Future<void> _draw(WidgetTester tester, List<TranscriptItem> items) async {
  tester.view.physicalSize = const Size(390 * 2, 800 * 2);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    HarnessStyle(
      style: HarnessPlatformStyle.material,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: HarnessTheme.material(Brightness.light),
        home: Scaffold(body: _screen('Delivery receipts', items)),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final shots = Platform.environment['HARNESS_SHOTS'];
  setUpAll(loadRealFonts);

  group('the receipt of a message', () {
    test('is read from the node the harness wrote it on, and nothing else', () {
      final conversation = WireConversation()
        ..user('go')
        ..say('Working on it.');
      final transcript = _read(conversation.nodes);
      // A message with no receipt is no message with a state: the harness
      // observed nothing of it, so the app says nothing.
      expect(transcript.displayItems.first.receipt, isNull);
      expect(transcript.displayItems.last.receipt, isNull);

      // A receipt the client does not know is no receipt either: a harness
      // from a later version must not make the app draw a word of its own.
      transcript.apply({
        'sessionUpdate': '_harness/node',
        'node': {
          ...conversation.nodes.first,
          'meta': {
            'receipt': {'state': 'read-by-model'},
          },
        },
      });
      expect(transcript.displayItems.first.receipt, isNull);
    });

    test('carries the state, when it was reached and which try it was', () {
      final conversation = WireConversation();
      _sent(conversation, 'go', 'retrying');
      final item = _read(conversation.nodes).displayItems.single;
      final receipt = item.receipt!;
      expect(receipt.state, 'retrying');
      expect(receipt.attempt, 1);
      expect(receipt.at, isNotNull);
      expect(receipt.word, 'Retrying');
      expect(receipt.isDelivered, isFalse);
    });

    test('says what was observed, and no more, in one line', () {
      String help(String state, {int? attempt}) => DeliveryReceipt(
        state: state,
        at: DateTime(2026, 11, 19, 14, 27),
        attempt: attempt,
      ).help;
      expect(help('sending'), 'Sending · in the request, no answer yet');
      expect(
        help('retrying', attempt: 2),
        'Retrying · the request failed, another try under way · attempt 2',
      );
      expect(
        help('delivered'),
        'Delivered 14:27 · provider answered the request · '
        'model reading not observable',
      );
      expect(help('failed'), 'Failed · the request ended in an error');
      expect(
        help('unconfirmed'),
        "Unconfirmed · the request was cancelled, the provider's answer unknown",
      );
      for (final state in DeliveryReceipt.states) {
        expect(
          help(state),
          isNot(contains('\n')),
          reason: 'a tooltip that wraps moves the text under the pointer',
        );
      }
    });
  });

  group('the marks on the transcript', () {
    testWidgets('stand on the newest message alone when delivered', (
      tester,
    ) async {
      final conversation = WireConversation();
      _sent(conversation, 'first', 'delivered');
      conversation.say('Done.');
      _sent(conversation, 'second', 'delivered');
      final transcript = _read(conversation.nodes);
      await _draw(tester, transcript.displayItems);

      // One delivered mark, on the newest message: a transcript of many sent
      // messages is never a column of ticks.
      expect(find.text('Delivered'), findsOneWidget);
      final mark = find.byKey(const ValueKey('receipt-node-n3'));
      expect(mark, findsOneWidget);
      expect(find.byKey(const ValueKey('receipt-node-n1')), findsNothing);
    });

    testWidgets('say so on themselves while in flight or failed', (
      tester,
    ) async {
      final conversation = WireConversation();
      _sent(conversation, 'in flight', 'sending');
      _sent(conversation, 'trying again', 'retrying');
      _sent(conversation, 'went wrong', 'failed');
      _sent(conversation, 'cut off', 'unconfirmed');
      final transcript = _read(conversation.nodes);
      await _draw(tester, transcript.displayItems);

      for (final word in ['Sending', 'Retrying', 'Failed', 'Unconfirmed']) {
        expect(find.text(word), findsOneWidget, reason: word);
      }
      // Each says what it means, on one line.
      final tooltip = tester.widget<Tooltip>(
        find.byKey(const ValueKey('receipt-node-n3')),
      );
      expect(tooltip.message, 'Failed · the request ended in an error');
    });

    testWidgets('are none for a message the harness holds', (tester) async {
      final conversation = WireConversation();
      conversation.user('go');
      final transcript = _read(conversation.nodes);
      // A message sent while the agent works waits for the turn's next step:
      // the harness holds it, and it is no node, so no receipt.
      transcript.addLocalUser('also check the docs');
      transcript.syncPending([
        (id: 'n-2', text: 'also check the docs', sender: null),
      ]);
      await _draw(tester, transcript.displayItems);

      expect(find.text('You · Queued'), findsOneWidget);
      for (final word in ['Sending', 'Retrying', 'Delivered', 'Failed']) {
        expect(find.text(word), findsNothing, reason: word);
      }
    });

    testWidgets('move off the message the next one takes them from', (
      tester,
    ) async {
      final conversation = WireConversation();
      final first = _sent(conversation, 'first', 'delivered');
      final transcript = _read(conversation.nodes);
      await _draw(tester, transcript.displayItems);
      expect(find.text('Delivered'), findsOneWidget);

      // The next message arrives, and is delivered in its turn: the mark
      // stands on it, and comes off the message it stood on.
      final second = _sent(conversation, 'second', 'delivered');
      for (final node in [first, second]) {
        transcript.apply({
          'sessionUpdate': '_harness/node',
          'node': {
            ...node,
            'meta': {
              'receipt': {'state': 'delivered', 'at': 1001.0, 'attempt': 1},
            },
          },
        });
      }
      await _draw(tester, transcript.displayItems);
      expect(find.text('Delivered'), findsOneWidget);
      expect(find.byKey(const ValueKey('receipt-node-n2')), findsOneWidget);
      expect(find.byKey(const ValueKey('receipt-node-n1')), findsNothing);
    });

    testWidgets('show a request cut off as unconfirmed, never delivered', (
      tester,
    ) async {
      final conversation = WireConversation();
      final message = _sent(conversation, 'go', 'sending');
      final transcript = _read(conversation.nodes);
      await _draw(tester, transcript.displayItems);
      expect(find.text('Sending'), findsOneWidget);

      // The harness was stopped, and settled the receipt it left in flight:
      // the provider may have had the message, and nothing here can tell.
      transcript.apply({
        'sessionUpdate': '_harness/node',
        'node': {
          ...message,
          'meta': {
            'receipt': {'state': 'unconfirmed', 'at': 1002.0, 'attempt': 1},
          },
        },
      });
      await _draw(tester, transcript.displayItems);
      expect(find.text('Unconfirmed'), findsOneWidget);
      expect(find.text('Delivered'), findsNothing);
      expect(find.text('Sending'), findsNothing);
    });
  });

  testWidgets('a picture of the marks, one on each state', (tester) async {
    final conversation = WireConversation();
    _sent(conversation, 'Read the parser and summarize it.', 'sending');
    conversation.say('It splits a statement into tokens.');
    _sent(conversation, 'Now run the tests on it.', 'retrying');
    _sent(conversation, 'And then the whole suite.', 'failed');
    _sent(conversation, 'Push the branch too.', 'unconfirmed');
    // The newest one is delivered, so its mark stands: the others say what
    // became of them on themselves.
    _sent(conversation, 'Commit it when it passes.', 'delivered');
    final transcript = _read(conversation.nodes);
    await _draw(tester, transcript.displayItems);

    expect(find.text('Sending'), findsOneWidget);
    expect(find.text('Retrying'), findsOneWidget);
    expect(find.text('Failed'), findsOneWidget);
    expect(find.text('Unconfirmed'), findsOneWidget);
    expect(find.text('Delivered'), findsOneWidget);

    if (shots != null) {
      await tester.runAsync(() async {
        final boundary = tester.firstRenderObject<RenderRepaintBoundary>(
          find.byType(RepaintBoundary).first,
        );
        final image = await boundary.toImage(pixelRatio: 2);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('$shots/message-receipts.png');
        file.parent.createSync(recursive: true);
        file.writeAsBytesSync(data!.buffer.asUint8List());
      });
    }
  });
}
