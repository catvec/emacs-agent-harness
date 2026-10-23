// A tool call in the transcript, as the person reads it: closed until it is
// opened, then what it was given and what it said, as text and not as JSON; a
// result of any length opens on a page of its own; a call that failed or was
// refused says so without being opened and can be closed like any other; and
// the call that hands a task's work in shows its report, even though it is
// the last thing in the transcript, below the fold.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/models/transcript.dart';
import 'package:harness_client/src/ui/adaptive/platform_style.dart';
import 'package:harness_client/src/ui/theme/harness_theme.dart';
import 'package:harness_client/src/ui/widgets/tool_body.dart';
import 'package:harness_client/src/ui/widgets/tool_card.dart';
import 'package:harness_client/src/ui/widgets/transcript_view.dart';

import 'support/tool_showcase.dart';

/// The transcript the nodes make, as the app builds it when it reads a
/// session again.
TranscriptState _transcript(Iterable<Map<String, Object?>> nodes) {
  final transcript = TranscriptState();
  for (final node in nodes) {
    transcript.applyNode(node);
  }
  transcript.finish();
  return transcript;
}

/// The call [callId] of the showcase session, and its result.
List<Map<String, Object?>> _call(String callId) => [
  for (final node in toolShowcaseNodes())
    if (node['call-id'] == callId) node,
];

Widget _app(
  TranscriptState transcript, {
  HarnessPlatformStyle style = HarnessPlatformStyle.material,
  bool streaming = false,
}) => HarnessStyle(
  style: style,
  child: MaterialApp(
    theme: HarnessTheme.material(Brightness.light),
    home: Scaffold(
      body: TranscriptView(
        items: transcript.items,
        showThinking: true,
        streaming: streaming,
      ),
    ),
  ),
);

Future<void> _pump(
  WidgetTester tester,
  TranscriptState transcript, {
  HarnessPlatformStyle style = HarnessPlatformStyle.material,
  bool streaming = false,
}) async {
  // A phone, 390 × 844 points.
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(_app(transcript, style: style, streaming: streaming));
  await _settle(tester);
}

/// Time passes, in the steps an animation takes: a first frame starts it.
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

/// The heading of the card of the call, to tap.
Finder _header(String title) => find.textContaining(title);

void main() {
  group('a call', () {
    testWidgets('is closed, and nothing of what is in it is built', (
      tester,
    ) async {
      await _pump(tester, _transcript(_call('call-test')));
      expect(
        find.textContaining('flutter test --reporter expanded'),
        findsOneWidget,
      );
      // What it took, and how much it said, are on the line under the title.
      expect(find.text('Command · 17 s · 35 lines'), findsOneWidget);
      expect(find.text('INPUT'), findsNothing);
      expect(find.text('OUTPUT'), findsNothing);
      expect(find.byType(ToolText), findsNothing);
    });

    testWidgets('opens to its input and its output, and closes again', (
      tester,
    ) async {
      await _pump(tester, _transcript(_call('call-test')));
      await _tap(tester, _header('Bash: cd harness_client'));
      expect(find.text('INPUT'), findsOneWidget);
      expect(find.text('OUTPUT'), findsOneWidget);
      // The command, after a prompt, not a JSON object holding it.
      expect(find.text(r'$ '), findsOneWidget);
      expect(
        find.text('cd harness_client && flutter test --reporter expanded'),
        findsOneWidget,
      );
      expect(find.textContaining('"command"'), findsNothing);
      expect(find.textContaining('Resolving dependencies...'), findsOneWidget);

      await _tap(tester, _header('Bash: cd harness_client'));
      expect(find.text('INPUT'), findsNothing);
      expect(find.byType(ToolText), findsNothing);
    });

    testWidgets('is shown with what it was given as the text it was', (
      tester,
    ) async {
      await _pump(tester, _transcript(_call('call-edit')));
      await _tap(tester, _header('Edit file: lib/src/ui/widgets'));
      // The path, the text taken out and the text put in, in the lines they
      // were written in: no `\n` in quotes anywhere.
      expect(find.text('old_string'), findsOneWidget);
      expect(find.text('new_string'), findsOneWidget);
      expect(
        find.textContaining(
          '    if (widget.item.tool?.isFailed == true) _open = true;\n  }',
        ),
        findsOneWidget,
      );
      expect(find.textContaining(r'\n'), findsNothing);
      expect(find.textContaining('replace_all'), findsOneWidget);
      expect(
        find.text('Edited lib/src/ui/widgets/tool_card.dart (1 replacement).'),
        findsOneWidget,
      );
      // It said one line and was given short texts: there is no more to read.
      expect(find.text('Open full view'), findsNothing);
    });

    testWidgets('cuts a long result to a screenful, and shows all of it', (
      tester,
    ) async {
      await _pump(tester, _transcript(_call('call-test')));
      await _tap(tester, _header('Bash: cd harness_client'));
      expect(
        find.textContaining('00:17 +148: All tests passed!'),
        findsNothing,
      );
      expect(find.text('Show all 35 lines'), findsOneWidget);

      await _tap(tester, find.text('Show all 35 lines'));
      expect(
        find.textContaining('00:17 +148: All tests passed!'),
        findsOneWidget,
      );
      expect(find.text('Show less'), findsOneWidget);

      await _tap(tester, find.text('Show less'));
      expect(
        find.textContaining('00:17 +148: All tests passed!'),
        findsNothing,
      );
      expect(find.text('Show all 35 lines'), findsOneWidget);
    });

    testWidgets('that failed says so, and why, before it is opened', (
      tester,
    ) async {
      await _pump(tester, _transcript(_call('call-analyze')));
      expect(find.text('Failed'), findsOneWidget);
      // The line that says what went wrong, not the banner before it.
      expect(
        find.textContaining("error • Undefined name 'theme'"),
        findsOneWidget,
      );
      expect(find.text('ERROR'), findsNothing);

      await _tap(tester, _header('Bash: flutter analyze'));
      expect(find.text('ERROR'), findsOneWidget);
      expect(find.text('Failed'), findsOneWidget);
    });

    testWidgets('that failed can be closed, and stays closed', (tester) async {
      final transcript = _transcript(_call('call-analyze'));
      await _pump(tester, transcript);
      await _tap(tester, _header('Bash: flutter analyze'));
      expect(find.text('ERROR'), findsOneWidget);
      await _tap(tester, _header('Bash: flutter analyze'));
      expect(find.text('ERROR'), findsNothing);

      // The conversation goes on, and the page is built again with it.
      await tester.pumpWidget(_app(transcript));
      await _settle(tester);
      expect(find.text('ERROR'), findsNothing);
      expect(find.text('Failed'), findsOneWidget);
    });

    testWidgets('that the permission system refused is not a failure', (
      tester,
    ) async {
      await _pump(tester, _transcript(_call('call-write')));
      expect(find.text('Denied'), findsOneWidget);
      expect(find.text('Failed'), findsNothing);
      expect(
        find.textContaining('lies outside the directories'),
        findsOneWidget,
      );
      await _tap(tester, _header('Write file: /etc/hosts'));
      // What it says is the reason it never ran, not output.
      expect(find.text('REASON'), findsOneWidget);
      expect(find.text('OUTPUT'), findsNothing);
      expect(find.textContaining('path  /etc/hosts'), findsOneWidget);
    });

    testWidgets('that said nothing says so', (tester) async {
      final transcript = _transcript([
        {
          'id': 'a',
          'kind': 'tool-call',
          'tool': 'bash',
          'call-id': 'c',
          'title': 'Bash: true',
          'input': {'command': 'true'},
        },
        {'id': 'b', 'kind': 'tool-result', 'call-id': 'c', 'output': ''},
      ]);
      await _pump(tester, transcript);
      await _tap(tester, _header('Bash: true'));
      expect(find.text('(no output)'), findsOneWidget);
    });

    testWidgets('that has not finished says it waits', (tester) async {
      final transcript = TranscriptState()
        ..apply({
          'sessionUpdate': 'tool_call',
          'toolCallId': 'c',
          'title': 'Bash: sleep 60',
          'status': 'in_progress',
          'rawInput': {'command': 'sleep 60'},
          '_harness': {'nodeId': 'n1', 'tool': 'bash'},
        });
      await _pump(tester, transcript, streaming: true);
      // A running call is not opened for the person: one line, and a spinner.
      expect(find.text('INPUT'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await _tap(tester, _header('Bash: sleep 60'));
      expect(find.text(r'$ '), findsOneWidget);
      expect(find.text('Waiting for the result…'), findsOneWidget);
    });

    testWidgets('names the files it handed back', (tester) async {
      final transcript = _transcript([
        {
          'id': 'a',
          'kind': 'tool-call',
          'tool': 'read_file',
          'call-id': 'c',
          'title': 'Read file: shot.png',
          'input': {'path': 'shot.png'},
        },
        {
          'id': 'b',
          'kind': 'tool-result',
          'call-id': 'c',
          'output': 'An image.',
          'attachments': [
            {'name': 'shot.png', 'path': '/tmp/shot.png'},
          ],
        },
      ]);
      await _pump(tester, transcript);
      await _tap(tester, _header('Read file: shot.png'));
      expect(find.text('ATTACHMENTS'), findsOneWidget);
      expect(find.text('shot.png'), findsWidgets);
    });

    testWidgets('looks the same, and opens the same, on an Apple phone', (
      tester,
    ) async {
      await _pump(
        tester,
        _transcript(_call('call-test')),
        style: HarnessPlatformStyle.cupertino,
      );
      await _tap(tester, _header('Bash: cd harness_client'));
      expect(find.text('INPUT'), findsOneWidget);
      expect(find.text('Show all 35 lines'), findsOneWidget);
    });
  });

  group('a long result', () {
    testWidgets('opens on a page of its own, to the last line of it', (
      tester,
    ) async {
      await _pump(tester, _transcript(_call('call-test')));
      await _tap(tester, _header('Bash: cd harness_client'));
      await _tap(tester, find.text('Open full view'));
      // The page says what the call was, in full, and what it said.
      expect(find.text('Command'), findsOneWidget);
      expect(find.text('Done'), findsOneWidget);
      expect(
        find.text(
          'Bash: cd harness_client && flutter test --reporter expanded',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('00:17 +148: All tests passed!'),
        findsOneWidget,
      );
      expect(find.textContaining('Resolving dependencies...'), findsOneWidget);
      expect(find.text('Show all 35 lines'), findsNothing);
    });

    testWidgets('is built a screenful at a time on that page', (tester) async {
      final lines = [for (var i = 1; i <= 1000; i++) 'line $i of the log'];
      final transcript = _transcript([
        {
          'id': 'a',
          'kind': 'tool-call',
          'tool': 'bash',
          'call-id': 'c',
          'title': 'Bash: make',
          'input': {'command': 'make'},
        },
        {
          'id': 'b',
          'kind': 'tool-result',
          'call-id': 'c',
          'output': lines.join('\n'),
        },
      ]);
      await _pump(tester, transcript);
      await _tap(tester, _header('Bash: make'));
      // Cut in the card, with the number of lines said.
      expect(find.text('Show all 1000 lines'), findsOneWidget);
      await _tap(tester, find.text('Open full view'));
      expect(find.textContaining('line 1 of the log'), findsOneWidget);
      // A thousand lines are not all built to open the page.
      expect(find.textContaining('line 1000 of the log'), findsNothing);
      await tester.dragUntilVisible(
        find.textContaining('line 1000 of the log'),
        find.byKey(const ValueKey('tool-detail')),
        const Offset(0, -2000),
        maxIteration: 80,
      );
      expect(find.textContaining('line 1000 of the log'), findsOneWidget);
    });

    testWidgets('is copied whole, and the button says so', (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await _pump(tester, _transcript(_call('call-test')));
      await _tap(tester, _header('Bash: cd harness_client'));
      // The output's button is the second: the input has one before it.
      await _tap(tester, find.byIcon(Icons.copy_rounded).last);
      expect(copied, toolShowcaseTestLog());
      expect(find.text('Copied'), findsOneWidget);
      // And it goes back to a button a moment later.
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('Copied'), findsNothing);
    });
  });

  group('the call that hands the work in', () {
    testWidgets('shows its report, not its JSON', (tester) async {
      await _pump(tester, _transcript(_call('call-hand-in')));
      expect(find.text('PROBLEM'), findsNothing);
      await _tap(tester, _header('Hand in the finished work'));
      expect(find.text('PROBLEM'), findsOneWidget);
      expect(find.text('SUMMARY'), findsOneWidget);
      expect(find.text('TO REPRODUCE'), findsOneWidget);
      expect(find.text('EVIDENCE'), findsOneWidget);
      // The summary is the markdown it was written in: a heading and a list.
      expect(find.text('What was wrong'), findsOneWidget);
      expect(find.textContaining('## What was wrong'), findsNothing);
      expect(find.textContaining(r'\n'), findsNothing);
      expect(find.textContaining('"summary"'), findsNothing);
      expect(find.text('INPUT'), findsNothing);
    });

    testWidgets('lists the evidence, the pictures by their name', (
      tester,
    ) async {
      await _pump(tester, _transcript(_call('call-hand-in')));
      await _tap(tester, _header('Hand in the finished work'));
      final caption = find.textContaining('A bash call opened');
      await tester.ensureVisible(caption);
      await tester.pump();
      expect(caption, findsOneWidget);
      expect(find.text('android-tool-call.png'), findsOneWidget);
      expect(find.text('The analyzer'), findsOneWidget);
      expect(
        find.textContaining('The images are on the harness machine'),
        findsOneWidget,
      );
    });

    testWidgets('lets a call it quotes open to what it said', (tester) async {
      await _pump(tester, _transcript(_call('call-hand-in')));
      await _tap(tester, _header('Hand in the finished work'));
      final quoted = find.text('The whole client suite passes: 148 tests');
      expect(quoted, findsOneWidget);
      expect(find.text('Show all 35 lines'), findsNothing);
      await _tap(tester, quoted);
      expect(find.text('Show all 35 lines'), findsOneWidget);
      expect(find.textContaining('Resolving dependencies...'), findsOneWidget);
      await _tap(tester, quoted);
      expect(find.text('Show all 35 lines'), findsNothing);
    });

    for (final (flag, words) in [
      ('cannot_continue', 'This task cannot continue: it waits for you'),
      ('no_merge', 'Nothing to merge: verifying it completes the task'),
    ]) {
      testWidgets('says so when it asked for $flag', (tester) async {
        final transcript = _transcript([
          {
            'id': 'a',
            'kind': 'tool-call',
            'tool': 'hand_in',
            'call-id': 'c',
            'title': 'Hand in: why',
            'input': {
              'problem': 'Why',
              'summary': 'Because',
              'evidence': <Object?>[],
              flag: true,
            },
          },
          {'id': 'b', 'kind': 'tool-result', 'call-id': 'c', 'output': 'ok'},
        ]);
        await _pump(tester, transcript);
        await _tap(tester, _header('Hand in: why'));
        expect(find.text(words), findsOneWidget);
        expect(find.text('EVIDENCE'), findsNothing);
      });
    }

    testWidgets('when it was refused shows what the harness said', (
      tester,
    ) async {
      final transcript = _transcript([
        {
          'id': 'a',
          'kind': 'tool-call',
          'tool': 'hand_in',
          'call-id': 'c',
          'title': 'Hand in: why',
          'input': {'problem': 'Why', 'summary': 'Because', 'evidence': []},
        },
        {
          'id': 'b',
          'kind': 'tool-result',
          'call-id': 'c',
          'output':
              'hand_in needs evidence: at least one image, video, file, code '
              'block, note or tool_call.',
          'is-error': true,
        },
      ]);
      await _pump(tester, transcript);
      expect(find.text('Failed'), findsOneWidget);
      await _tap(tester, _header('Hand in: why'));
      // No report was handed in: what was asked for, and why it was refused.
      expect(find.text('ERROR'), findsOneWidget);
      expect(find.textContaining('hand_in needs evidence'), findsWidgets);
      expect(find.text('PROBLEM'), findsNothing);
      expect(find.text('problem'), findsOneWidget);
    });

    testWidgets('is seen when it is opened: it is the last thing there is', (
      tester,
    ) async {
      // The whole session: the call is at the very end of a list longer than
      // the screen, and opening it grows it below the screen.
      await _pump(tester, _transcript(toolShowcaseNodes()));
      final list = find.byKey(const ValueKey('transcript-list'));
      expect(list, findsOneWidget);
      final viewport = tester.getRect(list);
      final header = _header('Hand in the finished work: Tool call results');
      expect(tester.getRect(header).bottom, lessThanOrEqualTo(viewport.bottom));

      await tester.tap(header);
      await _settle(tester);
      await tester.pump(const Duration(milliseconds: 600));
      // What opened is on the screen, from its top: not the gap under the
      // call, where it used to open out of sight.
      final problem = tester.getRect(find.text('PROBLEM'));
      expect(problem.top, greaterThanOrEqualTo(viewport.top));
      expect(problem.bottom, lessThanOrEqualTo(viewport.bottom));
      expect(tester.getRect(header).top, greaterThanOrEqualTo(viewport.top));
    });

    testWidgets('is seen when it is opened by a frame that takes long', (
      tester,
    ) async {
      await _pump(tester, _transcript(toolShowcaseNodes()));
      final viewport = tester.getRect(
        find.byKey(const ValueKey('transcript-list')),
      );
      final header = _header('Hand in the finished work: Tool call results');
      await tester.tap(header);
      await tester.pump();
      // One frame that takes longer than the whole of the animation, as the
      // frame of a call with a long result to build does: the animation is
      // over before the card has been laid out at the size it ends at.
      await tester.pump(const Duration(seconds: 1));
      await _settle(tester);
      final problem = tester.getRect(find.text('PROBLEM'));
      expect(problem.top, greaterThanOrEqualTo(viewport.top));
      expect(problem.bottom, lessThanOrEqualTo(viewport.bottom));
    });
  });

  group('a call that was opened', () {
    testWidgets('stays open while the page is scrolled past it and back', (
      tester,
    ) async {
      // A long conversation: the call at its end is far from its start.
      await _pump(
        tester,
        _transcript([
          for (var i = 1; i <= 30; i++)
            {
              'id': 'filler-$i',
              'kind': 'assistant',
              'content':
                  'Message $i of the conversation, which takes a few '
                  'lines on a phone, so that thirty make a long page.',
            },
          ..._call('call-hand-in'),
        ]),
      );
      final position = tester
          .state<ScrollableState>(
            find
                .descendant(
                  of: find.byKey(const ValueKey('transcript-list')),
                  matching: find.byType(Scrollable),
                )
                .first,
          )
          .position;
      await _tap(tester, _header('Hand in the finished work: Tool call'));
      expect(find.text('PROBLEM'), findsOneWidget);

      // Up the page, to the first message...
      position.jumpTo(position.minScrollExtent);
      await _settle(tester);
      expect(
        find.textContaining('Message 1 of the conversation'),
        findsOneWidget,
      );
      expect(find.byType(ToolCard), findsNothing);
      // ...and back down: the report is still open, as it was left.
      position.jumpTo(position.maxScrollExtent);
      await _settle(tester);
      expect(find.text('PROBLEM'), findsOneWidget);
    });
  });

  group('every call', () {
    for (final (width, scale) in [(320.0, 1.0), (390.0, 1.5)]) {
      testWidgets('opens without overflowing, at $width points and $scale×', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width * 3, 2532);
        tester.view.devicePixelRatio = 3.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        // One call at a time, in the transcript of its own.
        for (final id in [
          'call-read',
          'call-grep',
          'call-edit',
          'call-test',
          'call-analyze',
          'call-write',
          'call-hand-in',
        ]) {
          final nodes = _call(id);
          await tester.pumpWidget(
            MediaQuery(
              data: MediaQueryData(
                size: Size(width, 844),
                textScaler: TextScaler.linear(scale),
              ),
              child: _app(_transcript(nodes)),
            ),
          );
          await _settle(tester);
          final title = '${nodes.first['title']}';
          await _tap(tester, find.textContaining(title.split(':').first));
          // A failure here is the framework's: a RenderFlex that overflows.
          expect(tester.takeException(), isNull, reason: id);
          await tester.pumpWidget(const SizedBox());
        }
      });
    }
  });

  group('a conversation', () {
    testWidgets('opens on its latest message', (tester) async {
      await _pump(tester, _transcript(toolShowcaseNodes()));
      final scrollable = tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byKey(const ValueKey('transcript-list')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(scrollable.position.maxScrollExtent, greaterThan(0));
      expect(
        scrollable.position.pixels,
        closeTo(scrollable.position.maxScrollExtent, 1),
      );
      expect(find.textContaining('Hand in the finished work'), findsOneWidget);
    });
  });

  test('a call has the icon and the word of what it is', () {
    ToolView tool(String name, {String? kind}) =>
        ToolView(callId: name, tool: name, kind: kind);
    expect(toolLabel(tool('hand_in')), 'Hand-in');
    expect(toolLabel(tool('bash', kind: 'execute')), 'Command');
    expect(toolLabel(tool('made_up')), 'Tool');
    expect(toolIcon(tool('hand_in')), Icons.assignment_turned_in_outlined);
    expect(toolIcon(tool('bash', kind: 'execute')), Icons.terminal_rounded);
    expect(toolIcon(tool('made_up')), Icons.build_outlined);
  });
}
