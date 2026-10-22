// What the transcript of a task's session holds once it has done some work:
// tool calls of the kinds an agent makes, with the results as the harness
// writes them (`call-id` and `is-error` in kebab case, the result's `meta`
// with its duration, the permission system's `denied`, and the report a
// `hand_in` call handed in).  The fake harness serves it as a session of its
// own, opted into with `FakeHarness.seedToolShowcase`, so the tests, the
// preview server (`tool/mock_harness_server.dart --tools`) and the
// screenshots all show the same calls.

import 'dart:convert';

const toolShowcaseId = 's-tools';
const toolShowcaseName = 'Tidy the tool cards';

/// The directory the session works in, a task's worktree.
const toolShowcaseCwd =
    '/Users/noah/Code/emacs-agent-harness/.worktrees/task-tool-cards/';

/// A test run of the kind `flutter test --reporter expanded` prints: the
/// output of a command that is longer than a phone's screen.
String toolShowcaseTestLog() {
  const names = [
    'ACP client connects and discovers capabilities',
    'ACP client pairs requests with their answers',
    'transcript reduction chunks, a tool call and its result become one call',
    'transcript reduction a final node replaces streamed text',
    'transcript reduction a refused call says so',
    'tool card opens and closes',
    'tool card shows the whole input as readable text',
    'tool card cuts a long result and shows all of it on request',
    'tool card says when there is no output',
    'tool card a failed call can be closed',
    'hand in shows its report, not its JSON',
    'hand in a refused call shows its error',
    'full view of a call opens on its own page',
    'full view copies the whole output',
    'layout the notice is under the header of a page',
    'layout tabs start on the gutter',
    'layout nothing overflows on a 320 point phone',
    'reconnect the app connects again by itself',
    'reconnect a message the harness never got goes back in the box',
    'resume the app goes back in with what it kept',
    'sign in approving in Emacs hands the device a secret',
    'websocket transport a peer that stops answering pings is found out',
    'widget flows opens a session and replays its transcript',
    'widget flows answers a permission request',
    'widget flows answers a question with a diagram',
    'widget flows opens the task board and verifies a task',
    'quota a plan says how much of its window is used',
    'usage a row per project, worktrees added',
    'server lists the methods and events as text',
    'settings the switch sits at the end of its row',
  ];
  final lines = <String>[
    'Resolving dependencies...',
    'Downloading packages...',
    'Got dependencies!',
    '00:00 +0: loading test/acp_client_test.dart',
  ];
  var passed = 0;
  var seconds = 1;
  for (final name in names) {
    passed += 4 + name.length % 5;
    seconds += name.length % 2;
    final clock = '00:${seconds.toString().padLeft(2, '0')}';
    lines.add('$clock +$passed: $name');
  }
  lines.add('00:17 +148: All tests passed!');
  return lines.join('\n');
}

/// Dart source as `read_file` prints it: a line number, a tab, the line.
String toolShowcaseSource() {
  const source = '''
import 'package:flutter/material.dart';

import '../../models/transcript.dart';

/// One tool call in the transcript: what it was, whether it worked, and
/// what it said.  The call is closed until it is opened, except while it
/// runs; what is in it is built when it is opened, not before.
class ToolCard extends StatefulWidget {
  const ToolCard({super.key, required this.tool});

  final ToolView tool;

  @override
  State<ToolCard> createState() => _ToolCardState();
}

class _ToolCardState extends State<ToolCard> {
  late bool _open = widget.tool.isRunning;

  @override
  void didUpdateWidget(ToolCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A call that has just failed shows why, once.
    if (widget.tool.isFailed && !oldWidget.tool.isFailed) _open = true;
  }

  @override
  Widget build(BuildContext context) {
    final tool = widget.tool;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Header(tool: tool, open: _open, onTap: _toggle),
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            alignment: Alignment.topCenter,
            child: _open ? _Body(tool: tool) : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }

  void _toggle() => setState(() => _open = !_open);
}
''';
  final lines = source.trimRight().split('\n');
  return [
    for (var index = 0; index < lines.length; index++)
      '${(index + 1).toString().padLeft(6)}\t${lines[index]}',
  ].join('\n');
}

const _grepOutput = '''
lib/src/ui/widgets/transcript_view.dart:573:class _ToolCardState extends State<_ToolCard> {
lib/src/ui/widgets/transcript_view.dart:574:  late bool _open;
lib/src/ui/widgets/transcript_view.dart:575:  bool _inputOpen = false;
lib/src/ui/widgets/transcript_view.dart:580:    _open =
lib/src/ui/widgets/transcript_view.dart:588:    if (widget.item.tool?.isFailed == true) _open = true;
lib/src/ui/widgets/transcript_view.dart:615:              onTap: () => setState(() => _open = !_open),
lib/src/ui/widgets/transcript_view.dart:670:                      _open
lib/src/ui/widgets/transcript_view.dart:781:              crossFadeState: _open''';

final _summary =
    '''
## What was wrong

A tool call's result was drawn as raw JSON and plain text in two small boxes that scroll inside the page. A long result could not be read, and the one call that matters most when a task is done, `hand_in`, showed its report as one line of escaped JSON.

## What I changed

- **Input** is a list of labelled fields. A command is shown as the command, a long text keeps its line breaks, and an edit shows the text it removes and the text it puts in its place.
- **Output** is cut to a screenful with *Show all ${toolShowcaseTestLog().split('\n').length} lines*, can be copied, and opens on a page of its own where the whole of it can be read and selected.
- **A refused call** says *Denied* and why, in amber; one that failed says *Failed*, in red, and shows its error on the line under its title.
- **`hand_in`** shows its report: the problem, the summary as written, how to reproduce it and every piece of evidence, the calls it quotes opening to what they said.

## Checked

`flutter analyze` finds nothing, and all 148 tests pass; the new cards are drawn in the screenshots below.''';

const _problem =
    'Tool call results are hard to read in the harness app: they are raw '
    'JSON in a small scrolling box, and a long result or a hand-in cannot '
    'be opened up to read.';

final _reproduction =
    '1. Open a task\'s session in the app.\n'
    '2. Tap the *Hand in the finished work* call at the end: its report is '
    'a screenful of text, then the evidence.\n'
    '3. Tap *Bash: flutter test* and *Show all '
    '${toolShowcaseTestLog().split('\n').length} lines*.';

/// The nodes of the session, oldest first.
List<Map<String, Object?>> toolShowcaseNodes() {
  var counter = 0;
  double stamp() =>
      DateTime.now()
          .subtract(Duration(minutes: 30 - counter))
          .millisecondsSinceEpoch /
      1000;
  Map<String, Object?> node(String kind, Map<String, Object?> rest) => {
    'id': 'x${++counter}',
    'kind': kind,
    'ts': stamp(),
    ...rest,
  };
  Map<String, Object?> call(
    String callId,
    String tool,
    String title,
    Map<String, Object?> input,
  ) => node('tool-call', {
    'tool': tool,
    'call-id': callId,
    'title': title,
    'input': input,
    'meta': {'model': 'claude:claude-fable-5-1'},
  });
  Map<String, Object?> result(
    String callId,
    String output, {
    bool error = false,
    bool denied = false,
    double? duration,
    Map<String, Object?> meta = const {},
  }) => node('tool-result', {
    'call-id': callId,
    'output': output,
    'is-error': error ? true : null,
    'attachments': null,
    'meta': {
      'duration': duration ?? 0.04,
      'denied': denied ? true : null,
      'truncated': null,
      ...meta,
    },
  });

  final testLog = toolShowcaseTestLog();
  final testCommand = 'cd harness_client && flutter test --reporter expanded';
  final handInInput = <String, Object?>{
    'problem': _problem,
    'summary': _summary,
    'reproduction': _reproduction,
    'evidence': [
      {
        'image':
            '/tmp/harness-1000/$toolShowcaseId/shots/android-tool-call.png',
        'caption': 'A bash call opened: the command, and its output cut to a screenful',
      },
      {
        'image': '/tmp/harness-1000/$toolShowcaseId/shots/android-hand-in.png',
        'caption': 'The hand-in call opened: the report, then the evidence',
      },
      {
        'tool_call': 'bash',
        'caption': 'The whole client suite passes: 148 tests',
      },
      {
        'code': 'flutter analyze\nNo issues found! (ran in 2.5s)',
        'language': 'text',
        'caption': 'The analyzer',
      },
      {
        'note':
            'The images are on the harness machine, so the app names them; '
            'it cannot draw them.',
      },
    ],
  };
  final report = <String, Object?>{
    'summary': _summary,
    'problem': _problem,
    'reproduction': _reproduction,
    'evidence': [
      {
        'kind': 'image',
        'path': '/tmp/harness-1000/$toolShowcaseId/shots/android-tool-call.png',
        'extension': 'png',
        'caption': 'A bash call opened: the command, and its output cut to a screenful',
      },
      {
        'kind': 'image',
        'path': '/tmp/harness-1000/$toolShowcaseId/shots/android-hand-in.png',
        'extension': 'png',
        'caption': 'The hand-in call opened: the report, then the evidence',
      },
      {
        'kind': 'tool-call',
        'id': 'x4',
        'call-id': 'call-test',
        'tool': 'bash',
        'title': 'Bash: $testCommand',
        'input': jsonEncode({'command': testCommand}),
        'output': testLog,
        'is-error': null,
        'at': DateTime.now().millisecondsSinceEpoch / 1000,
        'caption': 'The whole client suite passes: 148 tests',
      },
      {
        'kind': 'code',
        'language': 'text',
        'code': 'flutter analyze\nNo issues found! (ran in 2.5s)',
        'caption': 'The analyzer',
      },
      {
        'kind': 'note',
        'text':
            'The images are on the harness machine, so the app names them; '
            'it cannot draw them.',
      },
    ],
    'at': DateTime.now().millisecondsSinceEpoch / 1000,
    'call-id': 'call-hand-in',
  };

  return [
    node('user', {
      'content':
          'The tool cards are hard to read. Make them show what the call '
          'did, run the tests, and hand it in.',
    }),
    node('assistant', {
      'content':
          'I\'ll read the card first, then change it, run the suite and '
          'check the analyzer.',
      'meta': {'model': 'claude:claude-fable-5-1'},
    }),
    call(
      'call-read',
      'read_file',
      'Read file: lib/src/ui/widgets/tool_card.dart',
      {'path': 'lib/src/ui/widgets/tool_card.dart', 'offset': 1, 'limit': 60},
    ),
    result('call-read', toolShowcaseSource(), duration: 0.02),
    call('call-grep', 'grep', 'Search files: _open', {
      'pattern': '_open',
      'path': 'lib/src/ui/widgets',
    }),
    result('call-grep', _grepOutput, duration: 0.11),
    call(
      'call-edit',
      'edit_file',
      'Edit file: lib/src/ui/widgets/tool_card.dart',
      {
        'path': 'lib/src/ui/widgets/tool_card.dart',
        'old_string':
            '    if (widget.item.tool?.isFailed == true) _open = true;\n'
            '  }',
        'new_string':
            '    // A call that has just failed shows why, once.\n'
            '    if (widget.tool.isFailed && !oldWidget.tool.isFailed) _open = true;\n'
            '  }',
        'replace_all': false,
      },
    ),
    result(
      'call-edit',
      'Edited lib/src/ui/widgets/tool_card.dart (1 replacement).',
      duration: 0.01,
    ),
    call('call-test', 'bash', 'Bash: $testCommand', {'command': testCommand}),
    result('call-test', testLog, duration: 17.4),
    call('call-analyze', 'bash', 'Bash: flutter analyze', {
      'command': 'cd harness_client && flutter analyze',
    }),
    result(
      'call-analyze',
      'Analyzing harness_client...\n\n'
          '  error • Undefined name \'theme\'. Try correcting the name to one '
          'that is defined, or defining the name • '
          'lib/src/ui/screens/tasks_screen.dart:1193:29 • '
          'undefined_identifier\n\n'
          '1 issue found. (ran in 11.3s)\n'
          'exit 1',
      error: true,
      duration: 11.5,
    ),
    call('call-write', 'write_file', 'Write file: /etc/hosts', {
      'path': '/etc/hosts',
      'content': '127.0.0.1 harness.local\n',
    }),
    result(
      'call-write',
      '/etc/hosts lies outside the directories this session may use, and '
          'the permission mode refused it. Work inside the project, or ask the '
          'user to allow the directory.',
      error: true,
      denied: true,
      duration: 0.0,
    ),
    node('assistant', {
      'content':
          'The analyzer error is in a file I did not touch, so the cards '
          'themselves are clean. Handing the work in.',
      'meta': {'model': 'claude:claude-fable-5-1'},
    }),
    call(
      'call-hand-in',
      'hand_in',
      'Hand in the finished work: Tool call results are hard to read in the harness app',
      handInInput,
    ),
    result(
      'call-hand-in',
      'Handed in: ## What was wrong\n\n5 pieces of evidence; the task now '
          'waits for the user\'s review, and this turn ends.',
      duration: 0.03,
      meta: {'report': report, 'task-id': 't-showcase'},
    ),
  ];
}

/// The session as `session/list` and `session/get` describe it.
Map<String, Object?> toolShowcaseSession() {
  final now = DateTime.now();
  double ago(Duration by) => now.subtract(by).millisecondsSinceEpoch / 1000;
  return {
    'id': toolShowcaseId,
    'name': toolShowcaseName,
    'kind': 'main',
    'project': '/Users/noah/Code/emacs-agent-harness/',
    'cwd': toolShowcaseCwd,
    'model': 'claude:claude-fable-5-1',
    'permissionMode': 'accept-edits',
    'status': 'idle',
    'created': ago(const Duration(hours: 1)),
    'updated': ago(const Duration(minutes: 2)),
    'lastMessage': ago(const Duration(minutes: 2)),
    'usage': {
      'input': 21000,
      'output': 3900,
      'cacheRead': 15000,
      'cost': 0.0,
      'listCost': 0.62,
      'billing': 'subscription',
      'plan': 'max',
      'context': 24800,
      'lastOutput': 600,
      'turns': 9,
    },
    'contextWindow': 200000,
    'todos': <Object?>[],
    'pending': <Object?>[],
    'queue': <Object?>[],
  };
}
