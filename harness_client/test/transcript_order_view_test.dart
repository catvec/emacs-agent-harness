// A system note on the screen: between the messages around it, where the
// harness recorded it, and not among older ones where its update came.
//
//   HARNESS_SHOTS=/some/directory flutter test test/transcript_order_view_test.dart
//
// also writes two pictures of what is drawn, each the transcript as its
// updates came in (what the app drew before it ordered them) beside the
// transcript in the order the harness recorded it: a note recorded while a
// conversation is being loaded, and a mode switched on in the middle of a
// conversation, which a phone read after it had been away.  Without
// HARNESS_SHOTS the cases still draw and check the order, and write nothing.
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

/// A conversation on a phone, and a note the harness records while the phone
/// is loading it: non-interactive mode switched on.
({TranscriptState transcript, String note}) _loading() {
  final conversation = WireConversation()
    ..user('Refactor the parser, and run the tests when you are done.')
    ..say('I will start with the tokenizer.')
    ..call('c1', 'read_file', title: 'Read file: lib/tokenizer.dart')
    ..result('c1')
    ..say('The tokenizer is clean. Now the parser itself.')
    ..call('c2', 'grep', title: 'Search files: parseExpression')
    ..result('c2')
    ..say('Done: the parser is split in three, and the tests pass.');
  // What the harness replays is the conversation as it is when it begins.
  final replay = conversation.replay();
  // The note is recorded while it goes out: it reaches the phone in the
  // middle of it, after the third node's updates.
  final note = conversation.hint('non-interactive on');
  final transcript = TranscriptState();
  var sent = 0;
  for (final update in replay) {
    transcript.apply(update);
    // Each node is two updates: its own and the whole node.
    if (++sent == 6) {
      for (final announced in WireConversation.updates(note, live: true)) {
        transcript.apply(announced);
      }
    }
  }
  return (transcript: transcript, note: 'non-interactive on');
}

/// A mode switched on in the middle of a conversation that a phone was away
/// from: it was connected while the first messages came, its connection was
/// lost while the note and the messages after it were recorded, and the
/// newest message reached it when it was back, before it read the
/// conversation again.
({TranscriptState transcript, String note}) _midConversation() {
  final conversation = WireConversation()
    ..user('Refactor the parser, and run the tests when you are done.')
    ..say('I will start with the tokenizer.')
    ..call('c1', 'read_file', title: 'Read file: lib/tokenizer.dart')
    ..result('c1')
    ..hint('non-interactive on')
    ..say('The tokenizer is clean. Now the parser itself.')
    ..call('c2', 'grep', title: 'Search files: parseExpression')
    ..result('c2')
    ..say('Done: the parser is split in three, and the tests pass.');
  final transcript = TranscriptState();
  void announce(Iterable<Wire> nodes) {
    for (final node in nodes) {
      for (final update in WireConversation.updates(node, live: true)) {
        transcript.apply(update);
      }
    }
  }

  // The first four nodes came while it was connected.
  announce(conversation.nodes.take(4));
  // The note and the three after it were recorded while it was away.
  // The newest node reached it when it was back.
  announce(conversation.nodes.skip(8));
  // Then it read the whole conversation again.
  for (final update in conversation.replay()) {
    transcript.apply(update);
  }
  return (transcript: transcript, note: 'non-interactive on');
}

Widget _screen(String title, List<TranscriptItem> items) => Expanded(
  child: Column(
    children: [
      Container(
        width: double.infinity,
        color: const Color(0xFF2B2B2B),
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
  ),
);

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  final shots = Platform.environment['HARNESS_SHOTS'];
  final real = await loadRealFonts();

  /// Draw [asItCame] and [asRecorded], one transcript twice, side by side on
  /// two phones, and write a picture of it when asked.  The finders are of
  /// the first and the second.
  Future<(Finder, Finder)> drawBoth(
    WidgetTester tester,
    String picture,
    List<TranscriptItem> asItCame,
    List<TranscriptItem> asRecorded,
  ) async {
    const ratio = 2.0;
    tester.view.physicalSize = const Size(2 * 390 * ratio, 800 * ratio);
    tester.view.devicePixelRatio = ratio;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final boundary = GlobalKey();
    await tester.pumpWidget(
      HarnessStyle(
        style: HarnessPlatformStyle.material,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: HarnessTheme.material(Brightness.light),
          home: Scaffold(
            body: RepaintBoundary(
              key: boundary,
              child: Row(
                children: [
                  _screen('Before: in the order the updates came', asItCame),
                  const VerticalDivider(width: 1),
                  _screen('Now: in the order the harness recorded', asRecorded),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    if (shots != null) {
      await tester.runAsync(() async {
        final render =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await render.toImage(pixelRatio: 1.5);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('$shots/$picture${real ? '' : '-ahem'}.png');
        file.parent.createSync(recursive: true);
        file.writeAsBytesSync(data!.buffer.asUint8List());
      });
    }
    return (
      find.byType(TranscriptView).first,
      find.byType(TranscriptView).last,
    );
  }

  /// How far down [text] is drawn in [side].
  double top(WidgetTester tester, Finder side, String text) => tester
      .getTopLeft(
        find
            .descendant(
              of: side,
              matching: find.textContaining(text, findRichText: true),
            )
            .first,
      )
      .dy;

  testWidgets('draws a note recorded while the conversation loads after it', (
    tester,
  ) async {
    final loaded = _loading();
    final transcript = loaded.transcript;
    // The same transcript twice: as its updates came in, and as the harness
    // recorded it.
    final asItCame = transcript.items;
    final asRecorded = transcript.displayItems;
    expect(shown(asItCame), isNot(shown(asRecorded)));

    final (left, right) = await drawBoth(
      tester,
      'transcript-order-loading',
      asItCame,
      asRecorded,
    );

    // The first side puts the note in the middle of older messages, the
    // second after all of them, where it is recorded.
    expect(
      top(tester, left, loaded.note),
      lessThan(top(tester, left, 'Done: the parser is split')),
      reason: 'as it came, the note is among older messages',
    );
    expect(
      top(tester, right, loaded.note),
      greaterThan(top(tester, right, 'Done: the parser is split')),
      reason: 'as the harness recorded it, the note is after them',
    );
    // And the rest of the conversation reads the same in both.
    for (final pair in [
      ('Refactor the parser', 'I will start with the tokenizer'),
      ('I will start with the tokenizer', 'Read file'),
      ('Read file', 'The tokenizer is clean'),
      ('The tokenizer is clean', 'Search files'),
    ]) {
      expect(
        top(tester, right, pair.$1),
        lessThan(top(tester, right, pair.$2)),
      );
    }
  });

  testWidgets(
    'draws a mode switched on mid-conversation between its messages',
    (tester) async {
      final loaded = _midConversation();
      final transcript = loaded.transcript;
      final (left, right) = await drawBoth(
        tester,
        'transcript-order-mid-conversation',
        transcript.items,
        transcript.displayItems,
      );

      // The note stands between the call before it and the message after it,
      // and the conversation is read from its first message to its last.
      final order = [
        'Refactor the parser',
        'I will start with the tokenizer',
        'Read file',
        loaded.note,
        'The tokenizer is clean',
        'Search files',
        'Done: the parser is split',
      ];
      for (var i = 0; i + 1 < order.length; i++) {
        expect(
          top(tester, right, order[i]),
          lessThan(top(tester, right, order[i + 1])),
          reason: '"${order[i]}" is above "${order[i + 1]}"',
        );
      }
      // As the updates came, the note stood last, below the message that came
      // after it and the one that came after that.
      expect(
        top(tester, left, loaded.note),
        greaterThan(top(tester, left, 'Done: the parser is split')),
        reason: 'as it came, the note was below the newest message',
      );
    },
  );
}
