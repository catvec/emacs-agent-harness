// Pictures of what is written in Markdown, as the app draws it on a phone: a
// finished task on the board (the preview on its card) and a conversation
// (what is sent to it, what it answers, the summary a compaction leaves, and
// the report the task was handed in with, which is read in the task's
// conversation).  Drawn with the fonts of a phone.
//
//   HARNESS_SHOTS=/some/directory flutter test test/markdown_screenshots_test.dart
//
// writes a PNG for each case there.  Without HARNESS_SHOTS the cases still
// run (they draw, and check that the words are there), and write nothing.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/app.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';
import 'support/phone_fonts.dart';
import 'support/real_fonts.dart';

const _problem =
    'The report of a finished task is shown as it was typed, with its '
    '**asterisks** and `backticks` in the text, so it cannot be read.';

const _summary = '''
## What was wrong

The task board showed a handed-in report as plain text: its headings were lines that begin with `##`, its bold words sat between asterisks, and a link was `[text](url)` in full.

## What I changed

- **The report** draws the problem, the summary, how to reproduce it and the evidence as Markdown
- **The card** shows the words of the summary, without their syntax
- see [the review notes](https://example.com/review) for the pictures

## Checked

```
flutter test        All tests passed!
flutter analyze     No issues found!
```
''';

const _reproduction =
    '1. Open the **Tasks** tab of the app\n'
    '2. Open the finished task *Render the hand-in*\n'
    '3. Read its report';

const _sessionId = 's-markdown';

/// The width of a phone, in points.
const _width = 390.0;

class _Case {
  const _Case(
    this.file,
    this.where, {
    this.height = 844,
    this.apple = false,
    this.dark = false,
  });
  final String file;
  final String where;
  final double height;
  final bool apple;
  final bool dark;
}

const _cases = [
  _Case('markdown-board-card', 'board'),
  // The conversation of the task, its hand-in open: tall enough to show the
  // whole report.
  _Case('markdown-task-report', 'report', height: 1560),
  _Case('markdown-conversation', 'session', height: 1100),
  _Case('markdown-compaction-open', 'compaction', height: 1100),
  _Case('markdown-conversation-ios', 'session', height: 1100, apple: true),
  _Case('markdown-task-report-dark', 'report', height: 1560, dark: true),
  _Case(
    'markdown-compaction-open-dark',
    'compaction',
    height: 1100,
    dark: true,
  ),
];

Map<String, Object?> _task(DateTime now) => {
  'id': 'task-md',
  'name': 'Render the hand-in',
  'prompt': 'Draw the report of a finished task as Markdown.',
  'state': 'done',
  'column': 'done',
  'priority': 'medium',
  'project': '/Users/noah/Code/emacs-agent-harness/',
  'cwd': '/Users/noah/Code/emacs-agent-harness/.worktrees/task-render/',
  'branch': 'task/render-hand-in',
  'created':
      now.subtract(const Duration(hours: 2)).millisecondsSinceEpoch / 1000,
  'updated':
      now.subtract(const Duration(minutes: 10)).millisecondsSinceEpoch / 1000,
  'verified': true,
  'report': {
    'summary': _summary,
    'problem': _problem,
    'reproduction': _reproduction,
    'evidence': [
      {
        'kind': 'image',
        'path': '/tmp/harness/shots/board.png',
        'caption': 'The board, with the report drawn',
      },
      {
        'kind': 'code',
        'language': 'text',
        'code': 'flutter test\n00:09 +312: All tests passed!',
        'caption': 'The suite',
      },
      {
        'kind': 'note',
        'text':
            'Checked on a `390 × 844` phone, in the **light** and dark themes.',
      },
    ],
    'at':
        now.subtract(const Duration(minutes: 12)).millisecondsSinceEpoch / 1000,
  },
};

/// A second finished task, whose summary is a few lines of Markdown.
Map<String, Object?> _otherTask(DateTime now) => {
  'id': 'task-md2',
  'name': 'Fold the compaction summary',
  'prompt': 'A compaction leaves a summary a page long.',
  'state': 'done',
  'column': 'done',
  'priority': 'low',
  'project': '/Users/noah/Code/emacs-agent-harness/',
  'cwd': '/Users/noah/Code/emacs-agent-harness/.worktrees/task-fold/',
  'branch': 'task/fold-compaction-summary',
  'created':
      now.subtract(const Duration(days: 1)).millisecondsSinceEpoch / 1000,
  'updated':
      now.subtract(const Duration(hours: 5)).millisecondsSinceEpoch / 1000,
  'verified': true,
  'report': {
    'summary':
        '**Folded** the summary under its line: tap *Context compacted* to '
        'read it. See [the issue](https://example.com/issue).',
    'problem': 'A compaction summary filled the screen.',
    'evidence': [
      {'kind': 'note', 'text': 'Folded by default.'},
    ],
  },
};

Map<String, Object?> _session(DateTime now) => {
  'id': _sessionId,
  'name': 'Markdown in a conversation',
  'kind': 'main',
  'project': '/Users/noah/Code/emacs-agent-harness/',
  'cwd': '/Users/noah/Code/emacs-agent-harness/',
  'model': 'claude:claude-fable-5-1',
  'permissionMode': 'auto',
  'status': 'idle',
  'created':
      now.subtract(const Duration(hours: 1)).millisecondsSinceEpoch / 1000,
  'updated':
      now.subtract(const Duration(minutes: 1)).millisecondsSinceEpoch / 1000,
  'lastMessage': now.millisecondsSinceEpoch / 1000,
  'contextWindow': 200000,
  'todos': <Object?>[],
  'pending': <Object?>[],
  'queue': <Object?>[],
};

List<Map<String, Object?>> _nodes() {
  var counter = 0;
  Map<String, Object?> node(
    String kind,
    String content, {
    Map<String, Object?>? meta,
  }) => {
    'id': 'n${++counter}',
    'kind': kind,
    'content': content,
    'ts': DateTime.now().millisecondsSinceEpoch / 1000 - 600 + counter * 20,
    if (meta != null) 'meta': meta,
  };
  return [
    node(
      'user',
      'Please **fix** the `task board`: it shows the report of a finished '
          'task as it was typed.\n\n- the cards\n- the [report](https://example.com/s)',
    ),
    node(
      'assistant',
      '## Done\n\nI changed *two* files:\n\n'
          '- `tasks_screen.dart`: the report is drawn as Markdown\n'
          '- `format.dart`: **markdownPreview** gives a card its words\n\n'
          '```dart\nmarkdownPreview(\'## Hi **there**\'); // Hi there\n```\n\n'
          'See [the diff](https://example.com/d).',
      meta: {'model': 'claude:claude-fable-5-1'},
    ),
    node(
      'user',
      'The merge has a *conflict* in `task.dart`; take **both** sides.',
      meta: {
        'from': {'kind': 'session', 'name': 'Merge queue'},
      },
    ),
    node(
      'compaction',
      '## Summary of the work so far\n\n'
          '- **Goal**: draw what is written in Markdown\n'
          '- **Done**: the task board, the conversation\n'
          '- **Next**: check the dark theme\n\n'
          'The files are `tasks_screen.dart` and `transcript_view.dart`; see '
          '[the plan](https://example.com/plan).',
      meta: {'kind': 'brief'},
    ),
    node('hint', 'Handed in for review'),
  ];
}

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  final shots = Platform.environment['HARNESS_SHOTS'];
  final real = await loadRealFonts();

  for (final shot in _cases) {
    testWidgets('draws ${shot.file}', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsController();
      await settings.load();
      if (shot.apple) {
        await settings.setPreviewPlatform(PreviewPlatform.cupertino);
      }
      if (shot.dark) await settings.setThemeMode(ThemeMode.dark);
      final now = DateTime.now();
      final harness = FakeHarness();
      harness.tasks
        ..clear()
        ..['task-md'] = _task(now)
        ..['task-md2'] = _otherTask(now);
      // The conversation of the task ends with the hand-in.
      harness.seedHandIn(
        'task-md',
        harness.tasks['task-md']!['report']! as Map<String, Object?>,
      );
      harness.sessions[_sessionId] = _session(now);
      harness.nodes[_sessionId] = _nodes();
      final app = AppController(
        settings: settings,
        connector: harness.connector,
      );
      await app.connect('ws://memory/acp');

      const ratio = 2.0;
      tester.view.physicalSize = Size(_width * ratio, shot.height * ratio);
      tester.view.devicePixelRatio = ratio;
      tester.view.viewPadding = const FakeViewPadding(
        top: 24 * ratio,
        bottom: 24 * ratio,
      );
      tester.view.padding = tester.view.viewPadding;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);

      Future<void> settle([int rounds = 8]) async {
        for (var i = 0; i < rounds; i++) {
          await tester.pump(const Duration(milliseconds: 120));
          // The tabs of the home screen are all there under the page that
          // opens, each with a navigation bar of the same hero tag, which
          // Cupertino pages complain of in a debug build: not what is drawn.
          if (shot.apple) tester.takeException();
        }
      }

      final boundary = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: HarnessApp(
            settings: settings,
            appController: app,
            themeBuilder: phoneFonts,
          ),
        ),
      );
      await tester.pump();
      await settle(10);

      switch (shot.where) {
        case 'board' || 'report':
          await tester.tap(find.text('Tasks'));
          await settle();
          expect(find.text('Render the hand-in'), findsOneWidget);
          if (shot.where == 'report') {
            // A tap on the task opens its conversation, which ends with the
            // hand-in: a card that opens to the report.
            await tester.tap(find.text('Render the hand-in'));
            await settle(10);
            await tester.tap(find.textContaining('Hand in the finished work'));
            await settle();
            expect(find.text('What was wrong'), findsOneWidget);
            expect(find.text('PROBLEM'), findsOneWidget);
          }
        default:
          await tester.tap(find.text('Markdown in a conversation'));
          await settle();
          expect(find.text('Done'), findsOneWidget);
          if (shot.where == 'compaction') {
            await tester.tap(find.textContaining('Context compacted'));
            await settle(10);
            expect(find.text('Summary of the work so far'), findsOneWidget);
          }
      }
      if (shots != null) {
        await tester.runAsync(() async {
          final render =
              boundary.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await render.toImage(pixelRatio: 1.5);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File('$shots/${shot.file}${real ? '' : '-ahem'}.png');
          file.parent.createSync(recursive: true);
          file.writeAsBytesSync(data!.buffer.asUint8List());
        });
      }
    });
  }
}
