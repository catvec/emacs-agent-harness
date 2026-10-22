// What a person needs to read a tool call, without a widget: its text made
// clean, its input as labelled fields, the time it took, the evidence a
// hand-in carries, and what the transcript keeps of a call's result.
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/models/task.dart';
import 'package:harness_client/src/models/tool_display.dart';
import 'package:harness_client/src/models/transcript.dart';

ToolView _tool({
  String? tool,
  Object? input,
  String? output,
  bool isError = false,
  Map<String, Object?> meta = const {},
  String status = 'completed',
}) => ToolView(
  callId: 'c1',
  tool: tool,
  input: input,
  output: output,
  isError: isError,
  meta: meta,
  status: status,
);

void main() {
  group('text', () {
    test('a colored terminal\'s escape sequences are taken out', () {
      expect(
        cleanToolText('\x1B[1m\x1B[31merror\x1B[0m: no such file\x1B[K'),
        'error: no such file',
      );
    });

    test(
      'every line ends one way, and a progress bar keeps its last state',
      () {
        expect(cleanToolText('a\r\nb\r\n'), 'a\nb\n');
        expect(cleanToolText('10%\r50%\r100%\ndone'), '100%\ndone');
      },
    );

    test('the end of the last line is not a line', () {
      expect(toolTextLines(''), isEmpty);
      expect(toolTextLines('one'), ['one']);
      expect(toolTextLines('one\ntwo\n'), ['one', 'two']);
      expect(toolTextLines('one\n\ntwo'), ['one', '', 'two']);
      expect(linesLabel(1), '1 line');
      expect(linesLabel(35), '35 lines');
    });

    test('a long text is built in pieces, and the pieces are the text', () {
      expect(toolTextChunks(''), isEmpty);
      expect(toolTextChunks('one\ntwo\n'), ['one\ntwo']);
      final lines = [for (var i = 1; i <= 200; i++) 'line $i'];
      final chunks = toolTextChunks(lines.join('\n'), maxLines: 80);
      expect(chunks, hasLength(3));
      expect(chunks.first.split('\n'), hasLength(80));
      expect(chunks.join('\n'), lines.join('\n'));
      // Characters count too: a few very long lines are pieces of their own.
      final wide = ['a' * 30, 'b' * 30, 'c' * 30];
      expect(toolTextChunks(wide.join('\n'), maxChars: 70), [
        '${wide[0]}\n${wide[1]}',
        wide[2],
      ]);
      // And one line no page could lay out is cut where it is.
      final one = toolTextChunks('x' * 25 + '\nend', maxChars: 10);
      expect(one, ['x' * 10, 'x' * 10, 'x' * 5 + '\nend']);
      expect(one.join(), 'x' * 25 + '\nend');
    });

    test('a duration is said as a person says it', () {
      expect(durationLabel(0.03), '30 ms');
      expect(durationLabel(1.24), '1.2 s');
      expect(durationLabel(17.4), '17 s');
      expect(durationLabel(125), '2m 05s');
      expect(durationLabel(null), '');
      expect(durationLabel('soon'), '');
      expect(durationLabel(-1), '');
    });

    test('a tool reached through an MCP server is the tool', () {
      expect(baseToolName('hand_in'), 'hand_in');
      expect(baseToolName('mcp__harness__hand_in'), 'hand_in');
      expect(baseToolName('mcp__other__a__b'), 'b');
      expect(baseToolName('made__up'), 'made__up');
      expect(baseToolName(null), '');
      expect(
        HandInReport.of(
          _tool(tool: 'mcp__harness__hand_in', input: {'summary': 'Done'}),
        ),
        isNotNull,
      );
    });

    test('a file is named by its last part', () {
      expect(baseName('/tmp/a/b/shot.png'), 'shot.png');
      expect(baseName('shot.png'), 'shot.png');
      expect(baseName('/tmp/a/'), 'a');
    });
  });

  group('what a call said', () {
    test('is cleaned once for as long as it stays the same', () {
      final tool = _tool(output: '\x1B[31mred\x1B[0m\nline two\n');
      final first = outputOf(tool);
      expect(first.text, 'red\nline two\n');
      expect(first.lines, 2);
      // The text of a long result is not made again with every frame.
      expect(identical(outputOf(tool).text, first.text), isTrue);
      tool.output = 'now one line';
      expect(outputOf(tool).text, 'now one line');
      expect(outputOf(tool).lines, 1);
      tool.output = null;
      expect(outputOf(tool).lines, 0);
      expect(outputOf(_tool(output: ' \n ')).lines, 0);
    });
  });

  group('the fields of a call\'s input', () {
    test('a command is a command, its line breaks real ones', () {
      final fields = toolFields({'command': 'cd app\nflutter test'});
      expect(fields, hasLength(1));
      expect(fields.single.style, ToolFieldStyle.command);
      expect(fields.single.text, 'cd app\nflutter test');
      expect(fields.single.lineCount, 2);
    });

    test('an edit is the text it takes out and the text it puts in', () {
      final fields = toolFields({
        'path': 'lib/a.dart',
        'old_string': 'a\nb',
        'new_string': 'c',
        'replace_all': false,
      });
      expect(fields.map((field) => field.name), [
        'path',
        'old_string',
        'new_string',
        'replace_all',
      ]);
      expect(fields.map((field) => field.style), [
        ToolFieldStyle.scalar,
        ToolFieldStyle.removed,
        ToolFieldStyle.added,
        ToolFieldStyle.scalar,
      ]);
      expect(fields[3].text, 'false');
    });

    test('prose is prose, and a long text or a file\'s content is code', () {
      final fields = toolFields({
        'summary': '## Done\n\n- one',
        'content': 'line one',
        'pattern': 'x' * 120,
        'note': 'short',
      });
      expect(fields[0].style, ToolFieldStyle.prose);
      expect(fields[1].style, ToolFieldStyle.code);
      expect(fields[2].style, ToolFieldStyle.code);
      expect(fields[3].style, ToolFieldStyle.prose);
    });

    test('nothing is shown for what was not given', () {
      expect(toolFields(null), isEmpty);
      expect(toolFields(''), isEmpty);
      expect(toolFields('  '), isEmpty);
      expect(
        toolFields({'a': null, 'b': '', 'c': [], 'd': <String, Object?>{}}),
        isEmpty,
      );
    });

    test('a list of plain values is a line, anything nested is JSON', () {
      final fields = toolFields({
        'paths': ['a', 'b', 3],
        'evidence': [
          {'image': 'x.png'},
        ],
      });
      expect(fields[0].text, 'a, b, 3');
      expect(fields[0].style, ToolFieldStyle.scalar);
      expect(fields[1].style, ToolFieldStyle.code);
      expect(fields[1].text, contains('"image": "x.png"'));
    });

    test('an input that is only text has one field, with no name', () {
      final fields = toolFields('ls -la');
      expect(fields.single.name, '');
      expect(fields.single.text, 'ls -la');
    });

    test('copying the input gives the value, or each field after its name', () {
      expect(inputAsText(toolFields({'command': 'ls'})), 'ls');
      expect(
        inputAsText(toolFields({'path': 'a.dart', 'content': 'x\ny'})),
        'path: a.dart\ncontent:\nx\ny',
      );
      expect(inputAsText(const []), '');
    });
  });

  group('a failed call', () {
    test('says what went wrong, not the banner before it', () {
      final tool = _tool(
        isError: true,
        output:
            'Analyzing app...\n\n  error • Undefined name \'theme\' • a.dart:3\n'
            '1 issue found.',
      );
      expect(errorPreview(tool), startsWith('error • Undefined name'));
    });

    test('falls back to its first line, and is cut when long', () {
      expect(
        errorPreview(_tool(output: '\n\n  Something happened  \nmore')),
        'Something happened',
      );
      expect(errorPreview(_tool(output: 'x' * 400), max: 20), hasLength(20));
      expect(errorPreview(_tool(output: '  \n ')), '');
      expect(errorPreview(_tool()), '');
    });
  });

  group('evidence', () {
    test(
      'as the call asked for it: one of image, video, file, code, note, call',
      () {
        final image = EvidenceItem.fromWire({
          'image': '/tmp/s/shot.png',
          'caption': 'A screenshot',
        })!;
        expect(image.kind, 'image');
        expect(image.isMedia, isTrue);
        expect(image.label, 'A screenshot');
        expect(image.path, '/tmp/s/shot.png');

        final call = EvidenceItem.fromWire({'tool_call': 'bash#2'})!;
        expect(call.kind, 'tool-call');
        expect(call.reference, 'bash#2');
        expect(call.label, 'bash#2');

        final code = EvidenceItem.fromWire({
          'code': 'ok',
          'language': 'text',
          'caption': 'The run',
        })!;
        expect(code.kind, 'code');
        expect(code.text, 'ok');
        expect(code.language, 'text');

        expect(
          EvidenceItem.fromWire({'note': 'Checked by hand'})!.kind,
          'note',
        );
        expect(EvidenceItem.fromWire('A bare note')!.text, 'A bare note');
        expect(EvidenceItem.fromWire(''), isNull);
        expect(EvidenceItem.fromWire({'caption': 'nothing else'}), isNull);
        expect(EvidenceItem.fromWire(7), isNull);
      },
    );

    test('as the harness resolved it: a kind, and the call as it was', () {
      final call = EvidenceItem.fromWire({
        'kind': 'tool-call',
        'call-id': 'x',
        'tool': 'bash',
        'title': 'Bash: ls',
        'input': '{"command":"ls"}',
        'output': 'a\nb',
        'is-error': true,
        'caption': 'Listing',
      })!;
      expect(call.kind, 'tool-call');
      expect(call.title, 'Bash: ls');
      expect(call.input, contains('"command": "ls"'));
      expect(call.output, 'a\nb');
      expect(call.isError, isTrue);
      expect(call.label, 'Listing');

      // The harness cuts what it keeps of a long input: when it no longer
      // parses it is shown as it is.
      final cut = EvidenceItem.fromWire({
        'kind': 'tool-call',
        'tool': 'bash',
        'input': '{"command":"echo aaaaaaaa…',
      })!;
      expect(cut.input, '{"command":"echo aaaaaaaa…');
      expect(cut.label, 'bash');

      final note = EvidenceItem.fromWire({'kind': 'note', 'text': 'Hello'})!;
      expect(note.text, 'Hello');
      final file = EvidenceItem.fromWire({
        'kind': 'file',
        'path': '/tmp/x/notes.txt',
        'extension': 'txt',
      })!;
      expect(file.label, 'notes.txt');
      expect(file.isMedia, isTrue);
    });
  });

  group('the evidence in a task\'s report', () {
    test('reads the same as the harness writes it and as it was asked for', () {
      final written = TaskReport.fromWire({
        'summary': 'Done',
        'evidence': [
          {'kind': 'image', 'path': '/tmp/s/shot.png', 'caption': 'A shot'},
          {'kind': 'image', 'path': '/tmp/s/other.png'},
          {'kind': 'video', 'path': '/tmp/s/run.mp4', 'caption': 'A run'},
          {'kind': 'file', 'path': '/tmp/s/notes.txt'},
          {'kind': 'code', 'code': 'ok', 'caption': 'The analyzer'},
          {'kind': 'code', 'code': 'ok'},
          {'kind': 'tool-call', 'tool': 'bash', 'caption': 'The tests'},
          {'kind': 'note', 'text': 'Checked by hand'},
        ],
      });
      expect(written.evidenceLines, [
        'Screenshot: A shot',
        'Screenshot: other.png',
        'Video: A run',
        'File: notes.txt',
        'Code: The analyzer',
        'Code: snippet',
        'Tool call: The tests',
        'Checked by hand',
      ]);
      final asked = TaskReport.fromWire({
        'evidence': [
          {'image': 'screenshots/chat.png', 'caption': 'Chat'},
          {'tool_call': 'bash#2'},
          {'note': 'flutter test: 38 passing'},
          {'caption': 'says nothing'},
        ],
      });
      expect(asked.evidenceLines, [
        'Screenshot: Chat',
        'Tool call: bash#2',
        'flutter test: 38 passing',
      ]);
    });
  });

  group('the report a hand-in call handed in', () {
    final input = {
      'problem': 'The cards are hard to read',
      'summary': '## Done\n\nIt reads.',
      'reproduction': 'Open a task',
      'evidence': [
        {'image': '/tmp/a.png', 'caption': 'A shot'},
        {'tool_call': 'bash'},
      ],
      'no_merge': true,
    };

    test('is what the harness kept on the result, which it resolved', () {
      final report = HandInReport.of(
        _tool(
          tool: 'hand_in',
          input: input,
          meta: {
            'report': {
              'problem': 'Resolved problem',
              'summary': 'Resolved summary',
              'evidence': [
                {'kind': 'image', 'path': '/tmp/a.png', 'caption': 'A shot'},
              ],
              'cannot-continue': true,
            },
          },
        ),
      )!;
      expect(report.problem, 'Resolved problem');
      expect(report.summary, 'Resolved summary');
      expect(report.evidence.single.kind, 'image');
      expect(report.cannotContinue, isTrue);
      // The flag the call asked for is in its input, not on the report.
      expect(report.noMerge, isTrue);
    });

    test('is what the call asked for until the harness says more', () {
      final report = HandInReport.of(_tool(tool: 'hand_in', input: input))!;
      expect(report.problem, 'The cards are hard to read');
      expect(report.reproduction, 'Open a task');
      expect(report.evidence.map((item) => item.kind), ['image', 'tool-call']);
      expect(report.noMerge, isTrue);
      expect(report.cannotContinue, isFalse);
    });

    test('says what the task cannot do however the key is written', () {
      for (final key in [
        'cannot_continue',
        'cannot-continue',
        'cannotContinue',
      ]) {
        final report = HandInReport.of(
          _tool(
            tool: 'hand_in',
            meta: {
              'report': {'summary': 'Stuck', key: true},
            },
          ),
        )!;
        expect(report.cannotContinue, isTrue, reason: key);
        expect(report.noMerge, isFalse, reason: key);
      }
    });

    test('is only for a hand-in call, and only when it says something', () {
      expect(HandInReport.of(_tool(tool: 'bash', input: input)), isNull);
      expect(HandInReport.of(_tool(tool: 'hand_in')), isNull);
      expect(
        HandInReport.of(_tool(tool: 'hand_in', input: {'summary': ''})),
        isNull,
      );
    });
  });

  group('what the transcript keeps of a result', () {
    test('how long it took, that it was refused, and the report', () {
      final transcript = TranscriptState();
      transcript.applyNode({
        'id': 'n1',
        'kind': 'tool-call',
        'tool': 'write_file',
        'call-id': 'c1',
        'title': 'Write file: /etc/hosts',
        'input': {'path': '/etc/hosts'},
      });
      transcript.applyNode({
        'id': 'n2',
        'kind': 'tool-result',
        'call-id': 'c1',
        'output': 'Refused.',
        'is-error': true,
        'meta': {'duration': 0.5, 'denied': true},
      });
      final tool = transcript.items.single.tool!;
      expect(tool.isDenied, isTrue);
      expect(tool.isFailed, isTrue);
      expect(tool.duration, 0.5);
      expect(tool.output, 'Refused.');
    });

    test('a call that ran is not refused, and a null is no time', () {
      final transcript = TranscriptState();
      transcript.applyNode({
        'id': 'n1',
        'kind': 'tool-call',
        'tool': 'bash',
        'call-id': 'c1',
        'input': {'command': 'ls'},
      });
      transcript.applyNode({
        'id': 'n2',
        'kind': 'tool-result',
        'call-id': 'c1',
        'output': 'a',
        'is-error': null,
        'meta': {'duration': null, 'denied': null},
      });
      final tool = transcript.items.single.tool!;
      expect(tool.isDenied, isFalse);
      expect(tool.isFailed, isFalse);
      expect(tool.duration, isNull);
    });

    test('it comes with the live updates too: the node follows the chunk', () {
      final transcript = TranscriptState();
      transcript.apply({
        'sessionUpdate': 'tool_call',
        'toolCallId': 'c1',
        'title': 'Hand in',
        'status': 'in_progress',
        'rawInput': {'summary': 'Done'},
        '_harness': {'nodeId': 'n1', 'tool': 'hand_in'},
      });
      expect(transcript.items.single.tool!.isRunning, isTrue);
      transcript.apply({
        'sessionUpdate': 'tool_call_update',
        'toolCallId': 'c1',
        'status': 'completed',
        'rawOutput': 'Handed in.',
        '_harness': {'nodeId': 'n2'},
      });
      transcript.apply({
        'sessionUpdate': '_harness/node',
        'node': {
          'id': 'n2',
          'kind': 'tool-result',
          'call-id': 'c1',
          'output': 'Handed in.',
          'meta': {
            'duration': 0.03,
            'report': {'summary': 'Done', 'problem': 'Why'},
          },
        },
      });
      final tool = transcript.items.single.tool!;
      expect(tool.isRunning, isFalse);
      expect(tool.duration, 0.03);
      final report = HandInReport.of(tool)!;
      expect(report.problem, 'Why');
      expect(report.summary, 'Done');
    });
  });
}
