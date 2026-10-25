// What a person writes for a person is Markdown: the report a task is handed
// in with, the messages of a conversation.  The app draws it as Markdown --
// headings, lists, bold, code, links -- and never as the characters it was
// typed with (`##`, `**`, backticks, `](url)`).
//
// Two places drew it as typed: a finished task on the board (the preview on its
// card) and, in a conversation, the messages the person and the harness send,
// the summary a compaction leaves and the report a task was handed in with (the
// `hand_in` card of the task's conversation, which is where a task is read).
// The harness sends the Markdown itself, untouched.
//
// Drawn with the fonts of a phone, since the test font's wide letters squeeze
// the board's header.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/app.dart';
import 'package:harness_client/src/models/task.dart';
import 'package:harness_client/src/models/tool_display.dart';
import 'package:harness_client/src/models/transcript.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:harness_client/src/ui/adaptive/platform_style.dart';
import 'package:harness_client/src/ui/theme/harness_theme.dart';
import 'package:harness_client/src/ui/widgets/transcript_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';
import 'support/real_fonts.dart';

const _problem =
    'The report of a finished task is shown as it was typed, with its '
    '**asterisks** and `backticks` in the text.';

const _summary = '''
## What was wrong

The board showed the *summary* of a hand-in as plain text.

- **Reports** are drawn as Markdown now
- a card shows the words, without the syntax
- see [the review notes](https://example.com/review)

```
flutter test test/markdown_rendering_test.dart
```
''';

const _reproduction = '1. Open the **Tasks tab**\n2. Tap the *Done column*';

Map<String, Object?> _report() => {
  'summary': _summary,
  'problem': _problem,
  'reproduction': _reproduction,
  'evidence': [
    {'kind': 'note', 'text': 'Checked on a `390 × 844` phone.'},
    {
      'kind': 'code',
      'language': 'text',
      'code': 'No issues found!',
      'caption': 'The analyzer',
    },
    {'kind': 'image', 'path': '/tmp/shots/board.png', 'caption': 'The board'},
  ],
  'at': DateTime.now().millisecondsSinceEpoch / 1000,
};

Map<String, Object?> _task({
  String column = 'done',
  required Map<String, Object?> report,
}) => {
  'id': 'task-md',
  'name': 'Render the hand-in',
  'prompt': 'Draw the report of a finished task as Markdown.',
  'state': column,
  'column': column,
  'priority': 'medium',
  'project': '/Users/noah/Code/emacs-agent-harness/',
  'cwd': '/Users/noah/Code/emacs-agent-harness/.worktrees/task-render/',
  'branch': 'task/render-hand-in',
  'created': DateTime.now().millisecondsSinceEpoch / 1000 - 7200,
  'updated': DateTime.now().millisecondsSinceEpoch / 1000 - 600,
  'verified': column == 'done',
  'report': report,
};

typedef _Run = ({String text, TextStyle? style, GestureRecognizer? recognizer});

/// Every run of text on the screen with the style it is drawn in: what
/// Markdown becomes (bold, a link, code) is told by the run's style, which
/// the characters of the text cannot tell.
List<_Run> _runs() {
  final runs = <_Run>[];
  void walk(InlineSpan span, TextStyle? inherited) {
    if (span is! TextSpan) return;
    final style = inherited == null ? span.style : inherited.merge(span.style);
    final text = span.text;
    if (text != null && text.isNotEmpty) {
      runs.add((text: text, style: style, recognizer: span.recognizer));
    }
    for (final child in span.children ?? const <InlineSpan>[]) {
      walk(child, style);
    }
  }

  for (final element in find.byType(EditableText).evaluate()) {
    final editable = element.widget as EditableText;
    walk(
      editable.controller.buildTextSpan(
        context: element,
        style: editable.style,
        withComposing: false,
      ),
      null,
    );
  }
  for (final element in find.byType(RichText).evaluate()) {
    walk((element.widget as RichText).text, null);
  }
  return runs;
}

/// The run of text [text] (a code block's has a line break after it).
_Run _run(String text) => _runs().firstWhere(
  (run) => run.text.trim() == text,
  orElse: () => fail('No run of text "$text" is drawn.'),
);

/// None of the characters Markdown is typed with is on the screen.
void _expectNoSyntax() {
  for (final syntax in const ['**', '## ', '](', '`']) {
    expect(
      find.textContaining(syntax),
      findsNothing,
      reason: 'the screen shows "$syntax" as it was typed',
    );
  }
}

Future<void> _settle(WidgetTester tester, [int rounds = 10]) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  await loadRealFonts();

  // The task board of a harness that has one task, opened on it.
  Future<void> openBoard(WidgetTester tester, Map<String, Object?> task) async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsController();
    await settings.load();
    final harness = FakeHarness();
    harness.tasks
      ..clear()
      ..['task-md'] = task;
    // The task has its conversation, which ends with the hand-in.
    if (task['report'] case final Map<String, Object?> report) {
      harness.seedHandIn('task-md', report);
    }
    final app = AppController(settings: settings, connector: harness.connector);
    await app.connect('ws://memory/acp');
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(HarnessApp(settings: settings, appController: app));
    await tester.pump();
    await _settle(tester, 8);
    await tester.tap(find.text('Tasks'));
    await _settle(tester, 6);
  }

  group('the report of a task', () {
    test('keeps its problem, and is the record the hand-in card draws', () {
      final handIn = HandInReport.fromWire(_report());
      expect(handIn.problem, _problem);
      expect(handIn.summary, _summary.trim());
      expect(handIn.reproduction, _reproduction);
      expect(handIn.evidence.map((item) => item.kind), [
        'note',
        'code',
        'image',
      ]);
      expect(handIn.evidence.first.text, 'Checked on a `390 × 844` phone.');
      expect(handIn.isEmpty, isFalse);
    });

    test('has none of what a harness from before it did not write', () {
      final handIn = HandInReport.fromWire({'summary': ' Done. '});
      expect(handIn.problem, '');
      expect(handIn.reproduction, isNull);
      expect(handIn.summary, 'Done.');
      expect(handIn.evidence, isEmpty);
    });

    test('is read from the task as the harness lists it', () {
      final task = HarnessTask.fromWire(_task(report: _report()));
      expect(task.report?.problem, _problem);
      expect(task.report?.summary, _summary.trim());
    });
  });

  group('a finished task', () {
    testWidgets('has the words of its summary on its card, not the syntax', (
      tester,
    ) async {
      await openBoard(tester, _task(report: _report()));
      expect(find.text('Render the hand-in'), findsOneWidget);
      // The first words of the summary: its heading, then what it says.
      expect(
        find.textContaining('What was wrong · The board showed'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Reports are drawn as Markdown now'),
        findsOneWidget,
      );
      _expectNoSyntax();
    });

    testWidgets('has its report in its conversation drawn as Markdown', (
      tester,
    ) async {
      await openBoard(tester, _task(report: _report()));
      // A tap on the task opens its conversation, whose last word is the
      // hand-in: a card that opens to the report.
      await tester.tap(find.text('Render the hand-in'));
      await _settle(tester, 10);
      await tester.tap(find.textContaining('Hand in the finished work'));
      await _settle(tester, 6);

      // What the report says, in the order it says it.
      for (final label in ['PROBLEM', 'SUMMARY', 'TO REPRODUCE', 'EVIDENCE']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      _expectNoSyntax();

      // The summary's heading is a heading of its own, not a line of
      // characters with two hashes in front.
      expect(find.text('What was wrong'), findsOneWidget);
      expect(_run('What was wrong').style?.fontSize, greaterThan(15));

      // Bold is bold, a link is a link, code is code.
      expect(_run('Reports').style?.fontWeight, FontWeight.w700);
      expect(_run('asterisks').style?.fontWeight, FontWeight.w700);
      expect(_run('summary').style?.fontStyle, FontStyle.italic);
      final link = _run('the review notes');
      expect(link.recognizer, isNotNull);
      expect(link.style?.decoration, TextDecoration.underline);
      expect(_run('backticks').style?.fontFamily, 'monospace');
      expect(
        _run('flutter test test/markdown_rendering_test.dart')
            .style
            ?.fontFamily,
        'monospace',
      );

      // The problem is in the report: the review shows it at the top.
      expect(
        find.textContaining('The report of a finished task is shown'),
        findsOneWidget,
      );
      // How to see it: a numbered list, its words bold and italic.
      expect(_run('Tasks tab').style?.fontWeight, FontWeight.w700);
      expect(_run('Done column').style?.fontStyle, FontStyle.italic);

      // The evidence is Markdown too: a note is drawn, a picture is named.
      expect(_run('390 × 844').style?.fontFamily, 'monospace');
      expect(find.text('The analyzer'), findsOneWidget);
      expect(find.text('The board'), findsOneWidget);

      // A piece of code opens to the code, as it does in the session.
      expect(find.text('No issues found!'), findsNothing);
      await tester.ensureVisible(find.text('The analyzer'));
      await _settle(tester, 2);
      await tester.tap(find.text('The analyzer'));
      await _settle(tester, 4);
      expect(find.text('No issues found!'), findsOneWidget);
    });

    testWidgets('says when no report was handed in, and draws what it has', (
      tester,
    ) async {
      // The round of work ended without `hand_in`: the harness recorded the
      // last message of the session instead, which is Markdown as well.
      await openBoard(
        tester,
        _task(
          column: 'review',
          report: {
            'summary': 'I **finished** the board, `tests` pass.',
            'missing': true,
            'at': DateTime.now().millisecondsSinceEpoch / 1000,
          },
        ),
      );
      expect(
        find.textContaining('I finished the board, tests pass.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Render the hand-in'));
      await _settle(tester, 10);
      // The conversation draws that last message, and its bar says that it is
      // all there is: no report was handed in.
      expect(find.textContaining('No report was handed in'), findsOneWidget);
      _expectNoSyntax();
      expect(_run('finished').style?.fontWeight, FontWeight.w700);
      expect(_run('tests').style?.fontFamily, 'monospace');
    });

    testWidgets('has a report that is only a summary', (tester) async {
      // A harness from before the problem field has none, and an old task
      // has no evidence: the report is the summary, and the card has its
      // words.
      await openBoard(
        tester,
        _task(report: {'summary': 'Plain **words** only.'}),
      );
      expect(find.textContaining('Plain words only.'), findsOneWidget);
      _expectNoSyntax();
      // In the conversation it is the hand-in card, with a summary and
      // nothing else.
      await tester.tap(find.text('Render the hand-in'));
      await _settle(tester, 10);
      await tester.tap(find.textContaining('Hand in the finished work'));
      await _settle(tester, 6);
      expect(find.text('PROBLEM'), findsNothing);
      expect(find.text('TO REPRODUCE'), findsNothing);
      expect(find.text('EVIDENCE'), findsNothing);
      expect(find.text('SUMMARY'), findsOneWidget);
      expect(_run('words').style?.fontWeight, FontWeight.w700);
      _expectNoSyntax();
    });
  });

  group('a conversation', () {
    TranscriptState transcript(Iterable<Map<String, Object?>> nodes) {
      final state = TranscriptState();
      for (final node in nodes) {
        state.applyNode(node);
      }
      state.finish();
      return state;
    }

    Future<void> show(
      WidgetTester tester,
      Iterable<Map<String, Object?>> nodes,
    ) async {
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        HarnessStyle(
          style: HarnessPlatformStyle.material,
          child: MaterialApp(
            theme: HarnessTheme.material(Brightness.light),
            home: Scaffold(
              body: TranscriptView(
                items: transcript(nodes).items,
                showThinking: true,
              ),
            ),
          ),
        ),
      );
      await _settle(tester, 4);
    }

    testWidgets('draws what the agent writes as Markdown', (tester) async {
      await show(tester, [
        {
          'id': 'a1',
          'kind': 'assistant',
          'content':
              '## Done\n\nI changed *two* files, see [the diff](https://example.com/d):\n\n'
              '- `board.dart`\n- **cards**',
        },
      ]);
      _expectNoSyntax();
      expect(find.text('Done'), findsOneWidget);
      expect(_run('two').style?.fontStyle, FontStyle.italic);
      expect(_run('the diff').recognizer, isNotNull);
      expect(_run('board.dart').style?.fontFamily, 'monospace');
      expect(_run('cards').style?.fontWeight, FontWeight.w700);
    });

    testWidgets('draws the messages sent to it as Markdown', (tester) async {
      await show(tester, [
        {
          'id': 'u1',
          'kind': 'user',
          'content': 'Please **fix** the `board`:\n\n- the cards\n- the [sheet](https://example.com/s)',
        },
        {
          'id': 'u2',
          'kind': 'user',
          'content': 'The merge has a *conflict* in `task.dart`.',
          'meta': {
            'from': {'kind': 'session', 'name': 'Merge queue'},
          },
        },
      ]);
      _expectNoSyntax();
      // Whoever sent them, they are in a bubble of their own.
      expect(find.text('You'), findsOneWidget);
      expect(find.text('Merge queue'), findsOneWidget);
      // The text of the bubble stays the bubble's color: the words, the
      // bold ones and the link.
      final ink = Theme.of(tester.element(find.byType(TranscriptView)))
          .colorScheme
          .onPrimaryContainer;
      expect(_run('Please').style?.color, ink);
      expect(_run('fix').style?.color, ink);
      expect(_run('sheet').style?.color, ink);
      expect(_run('fix').style?.fontWeight, FontWeight.w700);
      expect(_run('board').style?.fontFamily, 'monospace');
      expect(_run('sheet').recognizer, isNotNull);
      expect(find.text('the cards'), findsOneWidget);
      expect(_run('conflict').style?.fontStyle, FontStyle.italic);
      expect(_run('task.dart').style?.fontFamily, 'monospace');
    });

    testWidgets('keeps the line breaks and the plain words a person typed', (
      tester,
    ) async {
      await show(tester, [
        {
          'id': 'u1',
          'kind': 'user',
          'content': 'rename foo_bar_baz\nto fooBar; 2 * 3 * 4',
        },
      ]);
      // One line break is a line break, and a name with underscores or
      // spaced asterisks is the name and the sum.
      expect(
        find.textContaining('rename foo_bar_baz\nto fooBar; 2 * 3 * 4'),
        findsOneWidget,
      );
    });

    testWidgets('folds the summary a compaction leaves, and draws it', (
      tester,
    ) async {
      await show(tester, [
        {
          'id': 'c1',
          'kind': 'compaction',
          'content':
              '## Summary so far\n\n- **Goal**: draw Markdown\n- `done`: the board\n\n'
              'Next: the [conversation](https://example.com/c).',
          'meta': {'kind': 'brief'},
        },
      ]);
      // Folded: a line in the transcript, not a screenful of centred text.
      expect(find.textContaining('Context compacted'), findsOneWidget);
      expect(find.text('Summary so far'), findsNothing);
      _expectNoSyntax();

      await tester.tap(find.textContaining('Context compacted'));
      await _settle(tester, 4);
      expect(find.text('Summary so far'), findsOneWidget);
      _expectNoSyntax();
      expect(_run('Goal').style?.fontWeight, FontWeight.w700);
      expect(_run('done').style?.fontFamily, 'monospace');
      expect(_run('conversation').recognizer, isNotNull);

      // And folded again.
      await tester.tap(find.textContaining('Context compacted'));
      await _settle(tester, 4);
      expect(find.text('Summary so far'), findsNothing);
    });

    testWidgets('keeps a short note about a compaction on its line', (
      tester,
    ) async {
      await show(tester, [
        {
          'id': 'c1',
          'kind': 'compaction',
          'content': 'Context compacted from 214k tokens to 52k.',
        },
      ]);
      expect(
        find.textContaining('Context compacted from 214k tokens to 52k.'),
        findsOneWidget,
      );
    });

    testWidgets('draws a plan as Markdown', (tester) async {
      await show(tester, [
        {
          'id': 'p1',
          'kind': 'plan',
          'content': '1. **Read** the code\n2. Fix `it`',
        },
      ]);
      _expectNoSyntax();
      expect(_run('Read').style?.fontWeight, FontWeight.w700);
      expect(_run('it').style?.fontFamily, 'monospace');
    });

    testWidgets('leaves a hint, and a thought, as the plain words they are', (
      tester,
    ) async {
      await show(tester, [
        {'id': 'h1', 'kind': 'hint', 'content': 'Handed in for review'},
        {'id': 't1', 'kind': 'thinking', 'content': 'A *thought* is typed.'},
      ]);
      expect(find.textContaining('Handed in for review'), findsOneWidget);
      // The Emacs chat shows the thinking as it is, and so does the app.
      await tester.tap(find.text('Thought'));
      await _settle(tester, 4);
      expect(find.textContaining('A *thought* is typed.'), findsOneWidget);
    });
  });
}
