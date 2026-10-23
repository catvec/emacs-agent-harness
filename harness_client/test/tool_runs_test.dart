// Which calls of a transcript fold into a run under one summary line.  They are
// the Emacs chat's rules (`harness-chat--regroup`), kept here so that a stretch
// of looking around is one line in both: only the calls of the tools on the
// harness's allow list fold, with the thinking between them; any other item,
// and any call that is not on the list, ends the run; and a call a summary
// would hide something from the person in stays out of every run.
//
// Plain Dart, so these are tried without a widget: the transcript is built
// from nodes as the harness writes them, and the catalogue is the real one
// (`support/harness_tools.json`), not a list made up here.
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/models/tool_catalogue.dart';
import 'package:harness_client/src/models/tool_runs.dart';
import 'package:harness_client/src/models/transcript.dart';

import 'support/harness_tools.dart';
import 'support/transcript_log.dart';

/// The tools of the harness as `tools/list` serves them.
final _tools = ToolCatalogue.fromWire(harnessToolSpecs());

/// What a transcript is cut into, as a line: `run[c1 t c2]` is a run of two
/// calls with a thought between them, and each item that stands alone is its
/// own word (`call:c3`, `thinking`, `text`, `user`, `hint`).
String _shape(Iterable<TranscriptSegment> segments) => segments
    .map(
      (segment) => switch (segment) {
        ItemSegment(:final item) => switch (item.kind) {
          TranscriptKind.tool => 'call:${item.tool!.callId}',
          TranscriptKind.thinking => 'thinking',
          TranscriptKind.user => 'user',
          TranscriptKind.assistant => 'text',
          TranscriptKind.hint => 'hint',
          _ => item.kind.name,
        },
        RunSegment(:final run) =>
          'run[${run.members.map((member) => member.isThinking ? 't' : member.tool!.callId).join(' ')}]',
      },
    )
    .join(' ');

List<TranscriptSegment> _segments(
  TranscriptLog log, {
  ToolCatalogue? tools,
  Set<String> waiting = const {},
}) => segmentTranscript(log.items, tools: tools ?? _tools, waiting: waiting);

void main() {
  group('the allow list', () {
    test('is what the harness says, not a list of the app\'s own', () {
      final catalogue = ToolCatalogue.fromWire([
        {'name': 'read_file', 'label': 'Read file', 'coalescable': true},
        {'name': 'edit_file', 'label': 'Edit file', 'coalescable': false},
        {'name': 'peek', 'label': 'Peek', 'coalescable': true},
        {'name': 'poke', 'label': 'Poke'},
      ]);
      expect(catalogue.folds('read_file'), isTrue);
      // A tool the app never heard of folds when the harness says it may.
      expect(catalogue.folds('peek'), isTrue);
      expect(catalogue.folds('edit_file'), isFalse);
      // One that says nothing does not fold, nor one nobody has.
      expect(catalogue.folds('poke'), isFalse);
      expect(catalogue.folds('made_up'), isFalse);
      expect(catalogue.folds(null), isFalse);
      expect(catalogue.folds(''), isFalse);
    });

    test('is read from the answer of the harness, array and all', () {
      final catalogue = _tools;
      expect(catalogue.isEmpty, isFalse);
      // The reads and the commands among them fold ...
      for (final name in ['read_file', 'grep', 'bash', 'list_dir']) {
        expect(catalogue.folds(name), isTrue, reason: name);
      }
      // ... and what writes, asks, spawns or reaches out does not.
      for (final name in [
        'edit_file',
        'write_file',
        'ask_user',
        'spawn_agent',
        'hand_in',
        'web_fetch',
      ]) {
        expect(catalogue.folds(name), isFalse, reason: name);
      }
      // As many as the file says, no more and no fewer.
      expect({
        for (final spec in catalogue.specs)
          if (spec.coalescable) spec.name,
      }, harnessFoldableTools());
    });

    test('knows a tool by its name whichever server it came through', () {
      expect(_tools.folds('mcp__harness__read_file'), isTrue);
      expect(_tools.folds('mcp__harness__edit_file'), isFalse);
      expect(_tools.labelOf('mcp__harness__read_file'), 'Read file');
    });

    test('says what people call a tool, and falls back to its name', () {
      expect(_tools.labelOf('read_file'), 'Read file');
      expect(_tools.labelOf('grep'), 'Search files');
      expect(_tools.labelOf('made_up_tool'), 'made_up_tool');
      expect(_tools.labelOf(null), '');
    });

    test('is empty for an answer that is not a list of tools', () {
      expect(ToolCatalogue.fromWire(null).isEmpty, isTrue);
      expect(ToolCatalogue.fromWire(<String, Object?>{}).isEmpty, isTrue);
      expect(ToolCatalogue.fromWire('tools').isEmpty, isTrue);
      expect(ToolCatalogue.fromWire(<Object?>[]).isEmpty, isTrue);
      // An entry that names no tool is left out, the others stay.
      final partial = ToolCatalogue.fromWire([
        {'label': 'Nameless', 'coalescable': true},
        {'name': '  ', 'coalescable': true},
        {'name': 'read_file', 'coalescable': true},
      ]);
      expect(partial.length, 1);
      expect(partial.folds('read_file'), isTrue);
    });

    test('reads a flag the way the wire may spell it', () {
      final catalogue = ToolCatalogue.fromWire([
        {'name': 'a', 'coalescable': true},
        {'name': 'b', 'coalescable': null},
        {'name': 'c', 'coalescable': false},
        {'name': 'd', 'coalescable': 'true'},
        {'name': 'e', 'coalescable': <Object?>[]},
      ]);
      expect(
        [for (final name in 'abcde'.split('')) catalogue.folds(name)],
        [true, false, false, true, false],
      );
    });
  });

  group('a transcript', () {
    test('without a catalogue folds nothing', () {
      final log = TranscriptLog()
        ..call('c1', 'read_file')
        ..call('c2', 'grep')
        ..call('c3', 'bash');
      final shape = _shape(_segments(log, tools: ToolCatalogue.empty));
      expect(shape, 'call:c1 call:c2 call:c3');
    });

    test('folds the calls that follow one another into one run', () {
      final log = TranscriptLog()
        ..user('Look around')
        ..call('c1', 'read_file')
        ..call('c2', 'grep')
        ..call('c3', 'read_file')
        ..say('Found it');
      expect(_shape(_segments(log)), 'user run[c1 c2 c3] text');
    });

    test('folds a lone call into a run of one', () {
      final log = TranscriptLog()
        ..say('Let me look')
        ..call('c1', 'read_file');
      expect(_shape(_segments(log)), 'text run[c1]');
    });

    test('is cut where a call of another tool stands', () {
      final log = TranscriptLog()
        ..call('c1', 'read_file')
        ..call('c2', 'grep')
        ..call('c3', 'edit_file')
        ..call('c4', 'read_file')
        ..call('c5', 'write_file')
        ..call('c6', 'bash');
      expect(
        _shape(_segments(log)),
        'run[c1 c2] call:c3 run[c4] call:c5 run[c6]',
      );
    });

    test('is cut by anything that is not a call: words, hints, the user', () {
      final log = TranscriptLog()
        ..call('c1', 'read_file')
        ..say('One moment')
        ..call('c2', 'read_file')
        ..hint('The cache expired')
        ..call('c3', 'read_file')
        ..user('Stop')
        ..call('c4', 'read_file');
      expect(
        _shape(_segments(log)),
        'run[c1] text run[c2] hint run[c3] user run[c4]',
      );
    });

    test('takes the thinking between calls into the run', () {
      final log = TranscriptLog()
        ..call('c1', 'read_file')
        ..think('Is it in the other file?')
        ..call('c2', 'grep')
        ..think('Perhaps')
        ..think('Let me look')
        ..call('c3', 'read_file');
      final segments = _segments(log);
      expect(_shape(segments), 'run[c1 t c2 t t c3]');
      final run = (segments.single as RunSegment).run;
      expect(run.calls.length, 3);
      expect(run.thoughts, 3);
    });

    test(
      'leaves the thinking before the first call and after the last out',
      () {
        final log = TranscriptLog()
          ..think('Where to start?')
          ..call('c1', 'read_file')
          ..think('And now')
          ..call('c2', 'read_file')
          ..think('Done looking');
        expect(_shape(_segments(log)), 'thinking run[c1 t c2] thinking');
      },
    );

    test('does not let thinking join calls a word apart', () {
      final log = TranscriptLog()
        ..call('c1', 'read_file')
        ..think('Hm')
        ..say('Let me check')
        ..think('Right')
        ..call('c2', 'read_file');
      expect(_shape(_segments(log)), 'run[c1] thinking text thinking run[c2]');
    });

    test('does not let thinking join calls that are not on the list', () {
      final log = TranscriptLog()
        ..call('c1', 'edit_file')
        ..think('Hm')
        ..call('c2', 'read_file');
      expect(_shape(_segments(log)), 'call:c1 thinking run[c2]');
    });

    test(
      'shapes the same whether it was read at once or grew call by call',
      () {
        final all = TranscriptLog()
          ..user('Look')
          ..call('c1', 'read_file')
          ..think('Hm')
          ..call('c2', 'grep')
          ..call('c3', 'edit_file')
          ..call('c4', 'bash');
        final grown = TranscriptLog();
        var last = '';
        for (final step in <void Function(TranscriptLog)>[
          (log) => log.user('Look'),
          (log) => log.call('c1', 'read_file', result: false),
          (log) => log.think('Hm'),
          (log) => log.call('c2', 'grep', result: false),
          (log) => log.call('c3', 'edit_file', result: false),
          (log) => log.call('c4', 'bash', result: false),
        ]) {
          step(grown);
          last = _shape(_segments(grown));
        }
        expect(last, _shape(_segments(all)));
        expect(last, 'user run[c1 t c2] call:c3 run[c4]');
      },
    );
  });

  group('a call that stays out of every run', () {
    test('brings a picture', () {
      final log = TranscriptLog()
        ..call('c1', 'read_file')
        ..call(
          'c2',
          'read_file',
          attachments: [
            {'mime': 'image/png', 'path': '/tmp/shot.png'},
          ],
        )
        ..call('c3', 'read_file');
      expect(_shape(_segments(log)), 'run[c1] call:c2 run[c3]');
    });

    test('brings a video, or a picture the harness gave no type for', () {
      final log = TranscriptLog()
        ..call(
          'c1',
          'read_file',
          attachments: [
            {'mime': 'video/mp4', 'path': '/tmp/walkthrough'},
          ],
        )
        ..call(
          'c2',
          'read_file',
          attachments: [
            {'path': '/tmp/shot.PNG'},
          ],
        )
        ..call(
          'c3',
          'read_file',
          attachments: [
            {'name': 'clip.webm'},
          ],
        );
      expect(_shape(_segments(log)), 'call:c1 call:c2 call:c3');
    });

    test('brings a file that is no picture and no video', () {
      final log = TranscriptLog()
        ..call('c1', 'read_file')
        ..call(
          'c2',
          'read_file',
          attachments: [
            {'mime': 'application/pdf', 'path': '/tmp/spec.pdf'},
          ],
        )
        ..call(
          'c3',
          'read_file',
          attachments: [
            {'path': '/tmp/notes.txt'},
          ],
        );
      expect(_shape(_segments(log)), 'run[c1 c2 c3]');
    });

    test('waits for the person to allow it', () {
      final log = TranscriptLog()
        ..call('c1', 'read_file')
        ..call('c2', 'bash', result: false)
        ..call('c3', 'read_file', result: false);
      final waiting = {'c2'};
      expect(
        _shape(_segments(log, waiting: waiting)),
        'run[c1] call:c2 run[c3]',
      );
      // Allowed, it goes back where it was.
      expect(_shape(_segments(log)), 'run[c1 c2 c3]');
    });

    test('was recorded by the harness and never asked for by the agent', () {
      final log = TranscriptLog()
        ..call('c1', 'read_file')
        ..call('c2', 'read_file', from: {'kind': 'system', 'source': 'merge'})
        ..call('c3', 'read_file');
      expect(_shape(_segments(log)), 'run[c1] call:c2 run[c3]');
    });
  });

  group('the summary of a run', () {
    ToolRun runOf(TranscriptLog log) =>
        (_segments(log).whereType<RunSegment>().single).run;

    test('counts the calls by what people call them', () {
      final log = TranscriptLog()
        ..call('c1', 'read_file')
        ..call('c2', 'grep')
        ..call('c3', 'read_file')
        ..call('c4', 'read_file');
      final run = runOf(log);
      expect(run.heading, '4 tool calls');
      expect(run.detail(), 'Read file ×3, Search files');
      expect(run.summary(), '4 tool calls: Read file ×3, Search files');
    });

    test('counts the thinking folded in', () {
      final one = TranscriptLog()
        ..call('c1', 'read_file')
        ..think('Hm')
        ..call('c2', 'read_file');
      expect(runOf(one).summary(), '2 tool calls: Read file ×2 · thinking');
      final three = TranscriptLog()
        ..call('c1', 'read_file')
        ..think('a')
        ..think('b')
        ..call('c2', 'grep')
        ..think('c')
        ..call('c3', 'grep');
      expect(
        runOf(three).summary(),
        '3 tool calls: Read file, Search files ×2 · thinking ×3',
      );
      // Not when the person turned thinking off: none of it is shown.
      expect(
        runOf(three).summary(thinking: false),
        '3 tool calls: Read file, Search files ×2',
      );
    });

    test('does not count thinking that says nothing', () {
      final log = TranscriptLog()
        ..call('c1', 'read_file')
        ..think('')
        ..think('   ')
        ..call('c2', 'read_file');
      expect(runOf(log).thoughts, 0);
      expect(runOf(log).summary(), '2 tool calls: Read file ×2');
    });

    test('names a lone call as its own card does', () {
      final log = TranscriptLog()
        ..call('c1', 'read_file', title: 'Read file: lib/src/a.dart');
      final run = runOf(log);
      expect(run.heading, '1 tool call');
      expect(run.summary(), '1 tool call: Read file: lib/src/a.dart');
    });

    test(
      'names the calls of a tool by its label, and an unknown one by name',
      () {
        final log = TranscriptLog()
          ..call('c1', 'bash')
          ..call('c2', 'peek');
        final catalogue = ToolCatalogue.fromWire([
          {'name': 'bash', 'label': 'Bash', 'coalescable': true},
          {'name': 'peek', 'coalescable': true},
        ]);
        final run = segmentTranscript(
          log.items,
          tools: catalogue,
        ).whereType<RunSegment>().single.run;
        expect(run.detail(), 'Bash, peek');
      },
    );

    test('counts what failed and what was refused apart', () {
      final log = TranscriptLog()
        ..call('c1', 'read_file')
        ..call('c2', 'bash', error: true, output: 'exit 1')
        ..call('c3', 'read_file', error: true, output: 'no such file')
        ..call('c4', 'bash', error: true, denied: true, output: 'refused')
        ..call('c5', 'bash', result: false);
      final run = runOf(log);
      expect(run.calls.length, 5);
      // A refused call never ran, so it did not fail.
      expect(run.failed, 2);
      expect(run.denied, 1);
      expect(run.running, isTrue);
    });

    test('says nothing went wrong when nothing did', () {
      final log = TranscriptLog()
        ..call('c1', 'read_file')
        ..call('c2', 'grep');
      final run = runOf(log);
      expect(run.failed, 0);
      expect(run.denied, 0);
      expect(run.running, isFalse);
    });

    test('is known by its first call, which does not change as calls join', () {
      final log = TranscriptLog()..call('c1', 'read_file');
      final before = runOf(log).key;
      log.call('c2', 'grep');
      expect(runOf(log).key, before);
      expect(runOf(log).calls.length, 2);
    });
  });
}
