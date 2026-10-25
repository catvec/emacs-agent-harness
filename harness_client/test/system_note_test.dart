// The notes the harness writes into a conversation for itself: a compaction,
// and the hints.
//
// A compaction replaces the conversation up to it with a summary, which can
// be thousands of words.  The app drew all of it, small and centred, in the
// middle of the conversation: a page of text nobody asked for, saying again
// what the messages around it said -- one made right after a task was handed
// in repeats the report, and the person who opens the session on its last
// message finds the end of it.  It is one line now, that says what was done
// and how much there is of it, and opens to the summary, as the markdown it
// was written in, when it is tapped.  A hint that is long (what the tool
// slots did while the machine was busy, an error with all that the provider
// said) is cut to its first lines the same way, and a short one is shown
// whole, as it always was.
//
//   HARNESS_SHOTS=/some/directory flutter test test/system_note_test.dart
//
// also writes pictures of what is drawn: the end of a session that was
// handed in, with the summary folded and opened.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/models/transcript.dart';
import 'package:harness_client/src/ui/adaptive/platform_style.dart';
import 'package:harness_client/src/ui/format.dart';
import 'package:harness_client/src/ui/theme/harness_theme.dart';
import 'package:harness_client/src/ui/widgets/transcript_view.dart';

import 'support/harness_wire.dart';
import 'support/real_fonts.dart';

/// What the harness recorded on the compaction that was made while the prompt
/// cache was about to lapse, as it goes over the wire.
const _precompact = <String, Object?>{
  'compacted-head': 'n9',
  'model': 'claude:haiku',
  'compaction': 'brief',
  'context': 'sample',
  'input-tokens': 45107,
  'summary-tokens': 2743,
  'precompact': {'choice': 'brief', 'expires': 1792805461.49},
};

/// A summary in the shape a model writes one: headings, lists, the words of
/// the conversation, [steps] lines of what was done.  Its first heading and
/// its last line are what a test looks for.
String _summary({int steps = 60}) {
  final text = StringBuffer()
    ..writeln('# Handoff summary')
    ..writeln()
    ..writeln('## 1. Goals')
    ..writeln()
    ..writeln(
      'The user asked for the system notes to stand where they happened.',
    )
    ..writeln()
    ..writeln('## 2. What was done')
    ..writeln();
  for (var step = 1; step <= steps; step++) {
    text.writeln(
      '- Step $step: read `lib/src/models/transcript.dart` and put every '
      'item after the item of the node it follows, whatever order the '
      'updates came in, then ran the tests of the app again.',
    );
  }
  text
    ..writeln()
    ..writeln('## 6. Pending user request')
    ..writeln()
    ..writeln('Nothing is unanswered at the end of this summary.');
  return text.toString();
}

const _lastWords = 'Nothing is unanswered at the end of this summary.';

/// The end of a session that was handed in and compacted: the report, the
/// notes around the compaction, and the person's answer.
TranscriptState _handedIn({
  String summary = '',
  Map<String, Object?> meta = _precompact,
  int before = 0,
}) {
  final conversation = WireConversation();
  for (var i = 0; i < before; i++) {
    conversation.say('Earlier message $i of the conversation.');
  }
  conversation
    ..say('All evidence is in place. Handing in with the pictures.')
    ..call('hand', 'hand_in', title: 'Hand in the finished work: Notes')
    ..node('tool-result', {
      'call-id': 'hand',
      'output': 'Handed in: ## What was wrong\n\n3 pieces of evidence.',
      'meta': {
        'report': {
          'problem': 'A note stood below messages that came after it.',
          'summary': 'The report: what was wrong, and what changed.',
          'evidence': [
            {'kind': 'note', 'text': 'It is drawn between them now.'},
          ],
        },
        'task-id': 't-1',
      },
    })
    ..hint('Handed in for review')
    ..hint('Compacting context: a brief summary by Haiku 5.5…')
    ..node('compaction', {
      'content': summary.isEmpty ? _summary() : summary,
      'meta': meta,
    })
    ..hint('Compacted: 45.1k tokens → brief summary')
    ..user(
      'the hand in contents were also display in this very long system '
      'message, is that fixed?',
    );
  final transcript = TranscriptState();
  for (final node in conversation.nodes) {
    transcript.applyNode(node);
  }
  transcript.finish();
  return transcript;
}

Widget _app(
  TranscriptState transcript, {
  HarnessPlatformStyle style = HarnessPlatformStyle.material,
  GlobalKey? boundary,
}) {
  Widget view = TranscriptView(
    items: transcript.displayItems,
    showThinking: true,
  );
  if (boundary != null) {
    // A picture of it has the paper the app is on behind it, not nothing.
    view = RepaintBoundary(
      key: boundary,
      child: ColoredBox(color: HarnessColors.paper, child: view),
    );
  }
  return HarnessStyle(
    style: style,
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: HarnessTheme.material(Brightness.light),
      home: Scaffold(body: view),
    ),
  );
}

/// A phone, 390 × 844 points.
Future<void> _pump(
  WidgetTester tester,
  TranscriptState transcript, {
  HarnessPlatformStyle style = HarnessPlatformStyle.material,
  GlobalKey? boundary,
}) async {
  tester.view.physicalSize = const Size(780, 1688);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(_app(transcript, style: style, boundary: boundary));
  await _settle(tester);
}

/// Time passes, in the steps an animation takes.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await _settle(tester);
}

/// The line a compaction is folded under.
Finder get _compaction => find.textContaining('Context compacted');

/// The scrolling of the transcript list, the first of the scrollables in it
/// (a message the person wrote is selectable text, which has one of its own).
ScrollableState _list(WidgetTester tester) => tester.state<ScrollableState>(
  find
      .descendant(
        of: find.byKey(const ValueKey('transcript-list')),
        matching: find.byType(Scrollable),
      )
      .first,
);

/// How far the transcript list scrolls: a page or more, or none.
double _scrollable(WidgetTester tester) =>
    _list(tester).position.maxScrollExtent;

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The text as wide as it is on a phone, and the icons icons.
  final real = await loadRealFonts();

  group('what a compaction says of itself', () {
    test('is that the context was compacted, how, and why then', () {
      expect(
        compactionTitle({'meta': _precompact}),
        'Context compacted into a brief summary by haiku, before the prompt '
        'cache lapsed',
      );
      expect(
        compactionTitle({
          'meta': {
            'compaction': 'brief',
            'model': 'claude:haiku',
            'cowboy': {'ask': false},
          },
        }),
        'Context compacted into a brief summary by haiku, the prompt cache '
        'being cold',
      );
      // In the middle of a turn: the harness writes its keys in kebab case.
      expect(
        compactionTitle({
          'meta': {'compaction': 'summary', 'mid-turn': true},
        }),
        'Context compacted, in the middle of a turn',
      );
      expect(
        compactionTitle({
          'meta': {'compaction': 'summary', 'midTurn': true},
        }),
        'Context compacted, in the middle of a turn',
      );
    });

    test('names what was made of the conversation', () {
      String of(Map<String, Object?> meta) => compactionTitle({'meta': meta});
      expect(
        of({'compaction': 'transcript', 'file': '/tmp/t.md'}),
        'Context compacted into a transcript file',
      );
      expect(of({'compaction': 'fresh'}), 'Context compacted to start afresh');
      expect(
        of({'compaction': 'truncate', 'truncate-dropped': 12}),
        'Context compacted by cutting its oldest context away',
      );
      expect(
        of({
          'compaction': 'brief',
          'model': 'claude:haiku',
          'handoff': {'mode': 'compact', 'from': 'claude:a', 'to': 'openai:b'},
        }),
        'Context compacted to hand over to b',
      );
    });

    test('is plain for a note that says nothing of itself', () {
      expect(compactionTitle(null), 'Context compacted');
      expect(compactionTitle({'content': 'x'}), 'Context compacted');
      expect(
        compactionTitle({
          'meta': {'compaction': 'summary'},
        }),
        'Context compacted',
      );
      // A brief summary whose writer is not named is still a brief summary;
      // one from before there were kinds, made from a sample, is brief too.
      expect(
        compactionTitle({
          'meta': {'compaction': 'brief'},
        }),
        'Context compacted into a brief summary',
      );
      expect(
        compactionTitle({
          'meta': {'context': 'sample', 'model': 'claude:haiku'},
        }),
        'Context compacted into a brief summary by haiku',
      );
    });
  });

  group('counting words', () {
    test('counts what a person would, over lines', () {
      expect(wordCount(''), '0 words');
      expect(wordCount('one'), '1 word');
      expect(wordCount('one two\n\nthree  four'), '4 words');
      expect(wordCount(_summary()), contains(','));
    });
  });

  group('a long note', () {
    test('is one of more than $longNoteLines lines or '
        '$longNoteCharacters characters', () {
      expect(isLongNote('non-interactive on'), isFalse);
      expect(
        isLongNote(List.filled(longNoteLines, 'a line').join('\n')),
        isFalse,
      );
      expect(
        isLongNote(List.filled(longNoteLines + 1, 'a line').join('\n')),
        isTrue,
      );
      expect(isLongNote('x' * longNoteCharacters), isFalse);
      expect(isLongNote('x' * (longNoteCharacters + 1)), isTrue);
      // The blank lines around a note are no part of it.
      expect(isLongNote('\n\nHanded in\n\n\n\n\n\n\n\n'), isFalse);
    });
  });

  for (final style in HarnessPlatformStyle.values) {
    group('a compaction in the transcript, drawn for ${style.name},', () {
      testWidgets('is one line until it is tapped, and no page of text', (
        tester,
      ) async {
        final summary = _summary();
        await _pump(tester, _handedIn(summary: summary), style: style);

        // What it says of itself, and how much there is to read.
        expect(_compaction, findsOneWidget);
        expect(
          find.textContaining(
            'Context compacted into a brief summary by haiku, before the '
            'prompt cache lapsed',
          ),
          findsOneWidget,
        );
        expect(find.text(wordCount(summary)), findsOneWidget);
        // None of the summary is built, and the end of the conversation, the
        // person's message after it, is on the screen with the notes before
        // it: the list is no longer than a page.
        expect(find.textContaining('Step 1:'), findsNothing);
        expect(find.textContaining(_lastWords), findsNothing);
        expect(find.textContaining('Handoff summary'), findsNothing);
        expect(_scrollable(tester), lessThan(300));
        expect(
          find.textContaining('the hand in contents were also display'),
          findsOneWidget,
        );
        expect(
          tester
              .getRect(find.textContaining('the hand in contents were also'))
              .bottom,
          lessThanOrEqualTo(844),
        );
      });

      testWidgets('opens to the summary, as markdown, and folds again', (
        tester,
      ) async {
        await _pump(tester, _handedIn(), style: style);
        await _tap(tester, _compaction);

        // Markdown, not the words it was written in: the heading is a heading,
        // not "# Handoff summary", and the list has bullets, not "- ".
        expect(find.text('Handoff summary'), findsOneWidget);
        expect(find.text('# Handoff summary'), findsNothing);
        expect(find.text('1. Goals'), findsOneWidget);
        expect(find.textContaining('- Step'), findsNothing);
        expect(
          find.text(
            'The user asked for the system notes to stand where they happened.',
          ),
          findsOneWidget,
        );

        // The rest is a scroll away, in the list.
        expect(_scrollable(tester), greaterThan(1000));

        await _tap(tester, _compaction);
        expect(find.text('Handoff summary'), findsNothing);
        expect(_scrollable(tester), lessThan(300));
      });

      testWidgets('stays open while the list scrolls past it and back', (
        tester,
      ) async {
        await _pump(tester, _handedIn(before: 40), style: style);
        await _tap(tester, _compaction);
        expect(find.text('Handoff summary'), findsOneWidget);

        final scroll = _list(tester);
        final there = scroll.position.pixels;
        // Away, to the first message, a long way from the note...
        scroll.position.jumpTo(0);
        await _settle(tester);
        expect(find.textContaining('Earlier message 0'), findsOneWidget);
        // ...and back to it: it is as it was left.
        scroll.position.jumpTo(there);
        await _settle(tester);
        expect(find.text('Handoff summary'), findsOneWidget);
        expect(find.textContaining('Earlier message 0'), findsNothing);
      });
    });
  }

  group('a compaction', () {
    testWidgets('that kept no words says what was done, and has nothing to '
        'open', (tester) async {
      final transcript = TranscriptState()
        ..applyNode({
          'id': 'n1',
          'kind': 'compaction',
          'content': '',
          'meta': {'compaction': 'fresh'},
        });
      await _pump(tester, transcript);
      expect(
        find.textContaining('Context compacted to start afresh'),
        findsOneWidget,
      );
      expect(find.textContaining('word'), findsNothing);
      expect(find.byIcon(Icons.expand_more_rounded), findsNothing);
      // Tapping it does nothing.
      await tester.tap(_compaction);
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.byIcon(Icons.expand_less_rounded), findsNothing);
    });

    testWidgets('of an agent that is no harness is a plain note', (
      tester,
    ) async {
      // Plain ACP says nothing of how: the note is "Context compacted" and
      // its words, folded all the same.
      final transcript = TranscriptState()
        ..applyNode({
          'id': 'n1',
          'kind': 'compaction',
          'content': 'We talked about the parser.\nThen about the tokenizer.',
        });
      await _pump(tester, transcript);
      expect(find.text('9 words'), findsOneWidget);
      expect(find.textContaining('We talked about the parser'), findsNothing);
      await _tap(tester, _compaction);
      expect(find.textContaining('We talked about the parser'), findsOneWidget);
    });

    testWidgets('that is a line long stays on its line, as it was written', (
      tester,
    ) async {
      final transcript = TranscriptState()
        ..applyNode({
          'id': 'n1',
          'kind': 'compaction',
          'content': 'Context compacted from 214k tokens to 52k.',
        });
      await _pump(tester, transcript);
      // All of it is in the transcript, and there is nothing under it.
      expect(
        find.textContaining('Context compacted from 214k tokens to 52k.'),
        findsOneWidget,
      );
      expect(find.textContaining('word'), findsNothing);
      expect(find.byIcon(Icons.expand_more_rounded), findsNothing);
      await tester.tap(_compaction);
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(
        find.textContaining('Context compacted from 214k tokens to 52k.'),
        findsOneWidget,
      );
    });

    testWidgets('after a hand-in leaves the report in the call, once', (
      tester,
    ) async {
      await _pump(tester, _handedIn());
      // The report is what the call says, when it is opened.
      expect(
        find.textContaining('A note stood below messages that came after it.'),
        findsNothing,
      );
      await _tap(tester, find.textContaining('Hand in the finished work'));
      expect(
        find.textContaining('A note stood below messages that came after it.'),
        findsOneWidget,
      );
      expect(
        find.textContaining('The report: what was wrong, and what changed.'),
        findsOneWidget,
      );
      // The summary that follows it is a line, not a second page of it.
      expect(find.textContaining('Step 1:'), findsNothing);
      expect(_compaction, findsOneWidget);
    });
  });

  group('a hint', () {
    final slots = [
      'Slots changed due to system load (8 changes)',
      for (var i = 0; i < 8; i++)
        '15:1$i:49  Tool slots reduced from 18 to 16: system load 1.1x',
    ].join('\n');

    RenderParagraph paragraph(WidgetTester tester, String start) =>
        tester.renderObject<RenderParagraph>(find.textContaining(start));

    testWidgets('of a line or two is shown whole, and cannot be opened', (
      tester,
    ) async {
      final transcript = TranscriptState();
      for (final text in [
        'non-interactive on',
        'Slots changed due to system load (2 changes)\n'
            '12:08:02  Tool slots raised from 12 to 15\n'
            '12:08:57  Tool slots restored to 18',
        'Prompt cache about to lapse at 21:31: compacted into a brief '
            'summary, while it was still cached, so the next message sends '
            'that instead of ~872k tokens uncached',
      ]) {
        transcript.applyNode({
          'id': 'h${transcript.items.length}',
          'kind': 'hint',
          'content': text,
        });
      }
      await _pump(tester, transcript);
      expect(find.text('Show more'), findsNothing);
      expect(find.text('Show less'), findsNothing);
      for (final start in [
        'non-interactive on',
        'Slots changed due to system load (2 changes)',
        'Prompt cache about to lapse',
      ]) {
        expect(paragraph(tester, start).didExceedMaxLines, isFalse);
      }
    });

    testWidgets('of many lines is cut to its first, and opens and cuts again', (
      tester,
    ) async {
      final transcript = TranscriptState()
        ..applyNode({'id': 'h1', 'kind': 'hint', 'content': slots})
        ..applyNode({'id': 'h2', 'kind': 'hint', 'content': 'Handed in'});
      await _pump(tester, transcript);
      const first = 'Slots changed due to system load (8 changes)';
      expect(paragraph(tester, first).didExceedMaxLines, isTrue);
      final cut = tester.getSize(find.textContaining(first)).height;
      expect(find.text('Show more'), findsOneWidget);
      // The short note after it is whole.
      expect(paragraph(tester, 'Handed in').didExceedMaxLines, isFalse);

      await _tap(tester, find.text('Show more'));
      expect(paragraph(tester, first).didExceedMaxLines, isFalse);
      expect(
        tester.getSize(find.textContaining(first)).height,
        greaterThan(2 * cut),
      );
      expect(find.text('Show less'), findsOneWidget);
      expect(find.text('Show more'), findsNothing);

      await _tap(tester, find.text('Show less'));
      expect(paragraph(tester, first).didExceedMaxLines, isTrue);
      expect(find.text('Show more'), findsOneWidget);
    });

    testWidgets('that is one long line (an error) is cut too', (tester) async {
      final error =
          'Error: the provider said ${List.filled(60, 'no').join(' and ')}.';
      expect(error.length, greaterThan(longNoteCharacters));
      final transcript = TranscriptState()
        ..applyNode({'id': 'h1', 'kind': 'hint', 'content': error});
      await _pump(tester, transcript);
      expect(
        paragraph(tester, 'Error: the provider').didExceedMaxLines,
        isTrue,
      );
      await _tap(tester, find.text('Show more'));
      expect(
        paragraph(tester, 'Error: the provider').didExceedMaxLines,
        isFalse,
      );
    });
  });

  group('pictures', () {
    final shots = Platform.environment['HARNESS_SHOTS'];

    Future<void> shoot(
      WidgetTester tester,
      GlobalKey boundary,
      String name,
    ) async {
      if (shots == null) return;
      await tester.runAsync(() async {
        final render =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await render.toImage(pixelRatio: 1.0);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('$shots/$name.png');
        file.parent.createSync(recursive: true);
        file.writeAsBytesSync(data!.buffer.asUint8List());
      });
    }

    testWidgets('the end of a session that was handed in, folded and opened', (
      tester,
    ) async {
      final boundary = GlobalKey();
      await _pump(tester, _handedIn(), boundary: boundary);
      await shoot(tester, boundary, 'system-note-folded${real ? '' : '-ahem'}');

      await _tap(tester, _compaction);
      await shoot(tester, boundary, 'system-note-open${real ? '' : '-ahem'}');
      expect(find.text('Handoff summary'), findsOneWidget);
    });
  });
}
