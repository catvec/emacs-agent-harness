import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/models/workspace.dart';
import 'package:harness_client/src/models/workspace_speech.dart';
import 'package:harness_client/src/models/workspace_speech_claim.dart';
import 'package:harness_client/src/state/workspace_controller.dart';
import 'package:harness_client/src/ui/theme/harness_theme.dart';
import 'package:harness_client/src/ui/adaptive/platform_style.dart';
import 'package:harness_client/src/ui/widgets/workspace_speech_panel.dart';
import 'package:harness_client/src/voice/clip_voice_backend.dart';
import 'package:harness_client/src/voice/voice_backend.dart';
import 'package:harness_client/src/voice/workspace_speech_player.dart';

/// A floor that answers claims and advances from a script, and records what
/// it was asked, so the player's queue and claim are exercised without a
/// harness.
class ScriptedFloor implements WorkspaceSpeechGateway {
  ScriptedFloor({this.claimable = true});

  /// Whether this client is given the entry it claims.
  bool claimable;

  /// The client the floor says holds the entry, when it is not this one.
  String? holder;

  final List<String> claims = <String>[];
  final List<Map<String, Object?>> advances = <Map<String, Object?>>[];

  @override
  Future<WorkspaceSpeechClaim> claim(
    String workspace,
    String entry, {
    required String client,
  }) async {
    claims.add(entry);
    return WorkspaceSpeechClaim(
      claimed: claimable,
      holder: claimable ? client : holder,
    );
  }

  @override
  Future<WorkspaceSpeech> advance(
    String workspace,
    String entry, {
    String outcome = 'finished',
    String? why,
  }) async {
    advances.add({'entry': entry, 'outcome': outcome, 'why': why});
    return WorkspaceSpeech(workspace: workspace);
  }
}

WorkspaceSpeechEntry _entry({
  String id = 'sp-1',
  String thread = 'th-1',
  String title = 'Kitchen renovation',
  String state = 'speaking',
  String preview = 'The quote is accepted.',
}) => WorkspaceSpeechEntry(
  id: id,
  workspace: 'w1',
  thread: thread,
  threadTitle: title,
  state: state,
  preview: preview,
  text: preview,
);

WorkspaceSpeech _floor({
  WorkspaceSpeechEntry? speaking,
  List<WorkspaceSpeechEntry> waiting = const [],
  String? solo,
  String? soloTitle,
  bool hold = false,
  int revision = 1,
  List<WorkspaceSpeechEntry> recent = const [],
}) => WorkspaceSpeech(
  workspace: 'w1',
  revision: revision,
  hold: hold,
  solo: solo,
  soloTitle: soloTitle,
  speaking: speaking,
  waiting: waiting,
  count: waiting.length,
  active: speaking?.thread ?? solo,
  recent: recent,
);

WorkspaceController _controller(WorkspaceSpeech? floor) =>
    WorkspaceController.preview(
      workspace: const WorkspaceSummary(
        id: 'w1',
        name: 'Home',
        threads: [
          WorkspaceThread(id: 'th-1', title: 'Kitchen renovation'),
          WorkspaceThread(id: 'th-2', title: 'Garden lights'),
        ],
      ),
      speech: floor,
    );

Widget _wrap(Widget child) => HarnessStyle(
  style: HarnessPlatformStyle.material,
  child: MaterialApp(
    theme: HarnessTheme.material(Brightness.light),
    home: Scaffold(body: child),
  ),
);

void main() {
  group('the floor', () {
    test('reads what the harness answered', () {
      final floor = WorkspaceSpeech.fromWire({
        'workspace': 'w1',
        'revision': 7,
        'hold': false,
        'solo': 'th-1',
        'solo-title': 'Kitchen renovation',
        'speaking': {
          'id': 'sp-1',
          'thread': 'th-1',
          'thread-title': 'Kitchen renovation',
          'state': 'speaking',
          'preview': 'The quote is accepted.',
          'played': 4.0,
        },
        'waiting': [
          {
            'id': 'sp-2',
            'thread': 'th-2',
            'thread-title': 'Garden lights',
            'state': 'queued',
            'held': 'Solo',
            'preview': 'The timer works.',
          },
        ],
        'count': 1,
      });
      expect(floor.revision, 7);
      expect(floor.solo, 'th-1');
      expect(floor.speaking!.played, 4.0);
      expect(floor.waiting.single.held, 'Solo');
      expect(floor.heldEntries.single.thread, 'th-2');
      expect(floor.stateLabel, 'Solo');
    });

    test('a stale answer never rolls the floor back', () {
      final fresh = _floor(revision: 9);
      final stale = _floor(revision: 4);
      expect(WorkspaceSpeech.newer(fresh, stale), same(fresh));
      expect(WorkspaceSpeech.newer(stale, fresh), same(fresh));
      // The same revision is taken: a client may need its own answer.
      final again = _floor(revision: 9, solo: 'th-1');
      expect(WorkspaceSpeech.newer(fresh, again), same(again));
    });

    test('names every state in a noun phrase', () {
      expect(_floor().stateLabel, 'No speech');
      expect(_floor(speaking: _entry()).stateLabel, 'Speaking');
      expect(
        _floor(
          waiting: [_entry(id: 'sp-2', state: 'queued')],
        ).stateLabel,
        '1 waiting',
      );
      expect(_floor(solo: 'th-1', soloTitle: 'Kitchen').stateLabel, 'Solo');
      expect(_floor(hold: true).stateLabel, 'Held');
      expect(_floor(recent: [_entry(state: 'finished')]).stateLabel, 'Idle');
    });

    test('a finished entry says what became of it', () {
      expect(_entry(state: 'finished').outcomeWord, 'Spoken');
      expect(_entry(state: 'failed').outcomeWord, 'Failed');
      expect(_entry(state: 'cancelled').outcomeWord, 'Cancelled');
    });
  });

  group('the player', () {
    test('says the speaking entry once and reports it', () async {
      final floor = ScriptedFloor();
      final speech = RecordingVoiceSpeech();
      final player = WorkspaceSpeechPlayer(
        gateway: floor,
        speech: () => speech,
        client: 'phone',
      );
      final pumping = player.pump(_floor(speaking: _entry()));
      await Future<void>.delayed(Duration.zero);
      expect(speech.spoken, ['The quote is accepted.']);
      expect(player.playing, isTrue);
      speech.finish();
      await pumping;
      expect(player.playing, isFalse);
      expect(floor.claims, ['sp-1']);
      expect(floor.advances.single['outcome'], 'finished');
    });

    test('a second pump while speaking claims nothing', () async {
      final floor = ScriptedFloor();
      final speech = RecordingVoiceSpeech();
      final player = WorkspaceSpeechPlayer(
        gateway: floor,
        speech: () => speech,
        client: 'phone',
      );
      final pumping = player.pump(_floor(speaking: _entry()));
      await Future<void>.delayed(Duration.zero);
      await player.pump(_floor(speaking: _entry(), revision: 2));
      expect(floor.claims, ['sp-1']);
      speech.finish();
      await pumping;
    });

    test('another client holding the floor keeps this one quiet', () async {
      final floor = ScriptedFloor(claimable: false)..holder = 'desktop';
      final speech = RecordingVoiceSpeech();
      final player = WorkspaceSpeechPlayer(
        gateway: floor,
        speech: () => speech,
        client: 'phone',
      );
      await player.pump(_floor(speaking: _entry()));
      expect(speech.spoken, isEmpty);
      expect(floor.advances, isEmpty);
      expect(player.playing, isFalse);
    });

    test('a held floor starts nothing, and a hold stops quietly', () async {
      final floor = ScriptedFloor();
      final speech = RecordingVoiceSpeech();
      final player = WorkspaceSpeechPlayer(
        gateway: floor,
        speech: () => speech,
        client: 'phone',
      );
      await player.pump(_floor(speaking: _entry(), hold: true));
      expect(speech.spoken, isEmpty);
      final pumping = player.pump(_floor(speaking: _entry()));
      await Future<void>.delayed(Duration.zero);
      expect(speech.spoken, hasLength(1));
      // The hold keeps the words: they are not reported cancelled.
      await player.pump(_floor(speaking: _entry(), hold: true, revision: 3));
      expect(speech.stops, 1);
      expect(floor.advances, isEmpty);
      speech.finish();
      await pumping;
    });

    test('a client told to stay quiet says nothing', () async {
      final floor = ScriptedFloor();
      final speech = RecordingVoiceSpeech();
      final player = WorkspaceSpeechPlayer(
        gateway: floor,
        speech: () => speech,
        client: 'phone',
        speakReplies: false,
      );
      await player.pump(_floor(speaking: _entry()));
      expect(speech.spoken, isEmpty);
      expect(floor.claims, isEmpty);
    });

    test('a failed engine is reported failed, not finished', () async {
      final floor = ScriptedFloor();
      final speech = _FailingSpeech();
      final player = WorkspaceSpeechPlayer(
        gateway: floor,
        speech: () => speech,
        client: 'phone',
      );
      await player.pump(_floor(speaking: _entry()));
      expect(floor.advances.single['outcome'], 'failed');
      expect(floor.advances.single['why'], 'Playback failed');
    });

    test('an interruption reports the words cancelled', () async {
      final floor = ScriptedFloor();
      final speech = RecordingVoiceSpeech();
      final player = WorkspaceSpeechPlayer(
        gateway: floor,
        speech: () => speech,
        client: 'phone',
      );
      final pumping = player.pump(_floor(speaking: _entry()));
      await Future<void>.delayed(Duration.zero);
      await player.interrupt();
      expect(floor.advances.single['outcome'], 'cancelled');
      expect(floor.advances.single['why'], 'Interrupted');
      speech.finish();
      await pumping;
      // A completion after an interruption reports nothing more.
      expect(floor.advances, hasLength(1));
    });

    test('an entry that yields before it is said is not reported', () async {
      final floor = ScriptedFloor();
      final speech = RecordingVoiceSpeech();
      final player = WorkspaceSpeechPlayer(
        gateway: floor,
        speech: () => speech,
        client: 'phone',
      );
      await player.pump(_floor());
      expect(floor.claims, isEmpty);
      expect(floor.advances, isEmpty);
    });
  });

  group('the panel', () {
    testWidgets('draws the speaker, the queue in order and the solo', (
      tester,
    ) async {
      final controller = _controller(
        _floor(
          speaking: _entry(),
          waiting: [
            _entry(
              id: 'sp-2',
              thread: 'th-2',
              title: 'Garden lights',
              state: 'queued',
              preview: 'The timer works.',
            ),
          ],
        ),
      );
      await tester.pumpWidget(
        _wrap(WorkspaceSpeechPanel(controller: controller)),
      );
      // The speaker is the band's first line: no category heading above it,
      // and the queue is a count on that same line.
      expect(find.text('Kitchen renovation'), findsOneWidget);
      expect(find.text('1 waiting'), findsOneWidget);
      expect(find.text('Garden lights'), findsOneWidget);
      expect(find.text('The timer works.'), findsOneWidget);
      expect(
        find.byKey(const Key('workspace-speech-solo-sp-2')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('workspace-speech-hold')), findsOneWidget);
    });

    testWidgets('a solo on a waiting thread offers the way out in its row', (
      tester,
    ) async {
      final controller = _controller(
        _floor(
          solo: 'th-2',
          soloTitle: 'Garden lights',
          waiting: [
            _entry(
              id: 'sp-2',
              thread: 'th-2',
              title: 'Garden lights',
              state: 'queued',
              preview: 'The timer works.',
            ).copyWithHeld('Solo'),
          ],
        ),
      );
      await tester.pumpWidget(
        _wrap(WorkspaceSpeechPanel(controller: controller)),
      );
      // The soloed thread is the one speaking, so its line names the solo;
      // the row's own action is the way out of it.
      expect(find.text('Solo · Garden lights'), findsOneWidget);
      expect(find.byKey(const Key('workspace-speech-held-sp-2')), findsNothing);
      expect(
        find.byKey(const Key('workspace-speech-unsolo-sp-2')),
        findsOneWidget,
      );
      expect(find.text('Leave'), findsOneWidget);
    });

    testWidgets('a solo on a thread that is not waiting keeps its own line', (
      tester,
    ) async {
      final controller = _controller(
        _floor(
          solo: 'th-1',
          soloTitle: 'Kitchen renovation',
          waiting: [
            _entry(
              id: 'sp-2',
              thread: 'th-2',
              title: 'Garden lights',
              state: 'queued',
              preview: 'The timer works.',
            ),
          ],
        ),
      );
      await tester.pumpWidget(
        _wrap(WorkspaceSpeechPanel(controller: controller)),
      );
      // A solo is never a state the person cannot leave, even when the
      // soloed thread has nothing waiting in the queue.
      expect(find.text('Solo · Kitchen renovation'), findsOneWidget);
      expect(find.byKey(const Key('workspace-speech-unsolo')), findsOneWidget);
      expect(find.text('Leave'), findsOneWidget);
    });

    testWidgets('a held floor offers the resume', (tester) async {
      final controller = _controller(
        _floor(speaking: _entry(state: 'held'), hold: true),
      );
      await tester.pumpWidget(
        _wrap(WorkspaceSpeechPanel(controller: controller)),
      );
      expect(find.text('Held · Kitchen renovation'), findsOneWidget);
      expect(find.byKey(const Key('workspace-speech-resume')), findsOneWidget);
      expect(find.text('Resume'), findsOneWidget);
    });

    testWidgets('nothing to say draws nothing', (tester) async {
      final controller = _controller(_floor());
      await tester.pumpWidget(
        _wrap(WorkspaceSpeechPanel(controller: controller)),
      );
      expect(find.byKey(const Key('workspace-speech-panel')), findsNothing);
    });

    testWidgets(
      'the band is one column of rows, with no gap over the speaker',
      (tester) async {
        final controller = _controller(
          _floor(
            speaking: _entry(),
            waiting: [
              for (var i = 2; i < 6; i++)
                _entry(
                  id: 'sp-$i',
                  thread: 'th-$i',
                  title: 'Thread $i',
                  state: 'queued',
                  preview: 'Something to say.',
                ),
            ],
          ),
        );
        await tester.pumpWidget(
          _wrap(
            Align(
              alignment: Alignment.bottomCenter,
              child: WorkspaceSpeechPanel(controller: controller),
            ),
          ),
        );
        final band = tester.getRect(
          find.byKey(const Key('workspace-speech-panel')),
        );
        final speaker = tester.getRect(
          find.byKey(const Key('workspace-speech-speaking')),
        );
        // The speaker line starts at the band's top: the band has no heading
        // over it to leave a gap, only the row's own 6 points of padding and
        // the text's ascent.
        expect(speaker.top - band.top, lessThan(20));
        // Every row is a compact row of the page, not a block with its own
        // breathing room: a waiting thread and its words cost under 40 points.
        for (var i = 2; i < 6; i++) {
          final rowHeight = tester
              .getRect(find.byKey(Key('workspace-speech-waiting-sp-$i')))
              .height;
          expect(rowHeight, lessThan(20), reason: 'sp-$i');
        }
        expect(band.height, lessThan(210));
        // A row's action is on the row it acts on, not at the far end of the
        // page.
        final solo = tester.getRect(
          find.byKey(const Key('workspace-speech-solo-sp-2')),
        );
        final row = tester.getRect(
          find.byKey(const Key('workspace-speech-waiting-sp-2')),
        );
        expect(solo.right, lessThanOrEqualTo(band.right));
        expect((solo.center.dy - row.center.dy).abs(), lessThan(18));
      },
    );

    testWidgets(
      'every row puts its actions in the band\'s one right-hand column',
      (tester) async {
        final controller = _controller(
          _floor(
            speaking: _entry(),
            waiting: [
              _entry(
                id: 'sp-2',
                thread: 'th-2',
                title: 'Garden lights',
                state: 'queued',
              ),
              _entry(
                id: 'sp-3',
                thread: 'th-3',
                title: 'Harness memory',
                state: 'queued',
              ),
            ],
          ),
        );
        await tester.pumpWidget(
          _wrap(WorkspaceSpeechPanel(controller: controller)),
        );
        final skip = tester.getRect(
          find.byKey(const Key('workspace-speech-skip')),
        );
        final hold = tester.getRect(
          find.byKey(const Key('workspace-speech-hold')),
        );
        final garden = tester.getRect(
          find.byKey(const Key('workspace-speech-solo-sp-2')),
        );
        final memory = tester.getRect(
          find.byKey(const Key('workspace-speech-solo-sp-3')),
        );
        // The speaker's Skip and Hold and both waiting Solo buttons end on one
        // edge: a waiting thread's action is under the speaker's last action,
        // not at an offset of its own.
        expect(hold.right, garden.right);
        expect(hold.right, memory.right);
        expect(hold.left, garden.left);
        expect(hold.left, memory.left);
        // The speaker's two actions sit side by side, so Skip ends where Hold
        // starts.
        expect(skip.right, hold.left);
      },
    );

    testWidgets('the column holds at a larger text size', (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = _controller(
        _floor(
          speaking: _entry(),
          waiting: [
            _entry(
              id: 'sp-2',
              thread: 'th-2',
              title: 'Garden lights',
              state: 'queued',
            ),
          ],
        ),
      );
      await tester.pumpWidget(
        HarnessStyle(
          style: HarnessPlatformStyle.material,
          child: MaterialApp(
            theme: HarnessTheme.material(Brightness.light),
            home: MediaQuery(
              data: const MediaQueryData(
                size: Size(1200, 900),
                textScaler: TextScaler.linear(1.5),
              ),
              child: Scaffold(
                body: WorkspaceSpeechPanel(controller: controller),
              ),
            ),
          ),
        ),
      );
      final hold = tester.getRect(
        find.byKey(const Key('workspace-speech-hold')),
      );
      final garden = tester.getRect(
        find.byKey(const Key('workspace-speech-solo-sp-2')),
      );
      expect(hold.right, garden.right);
      expect(hold.left, garden.left);
      // The targets grow with the text rather than shrinking to keep the
      // column.
      expect(hold.height, greaterThanOrEqualTo(36));
      expect(garden.width, greaterThanOrEqualTo(36));
    });
    testWidgets('every control keeps an accessible target', (tester) async {
      final controller = _controller(
        _floor(
          speaking: _entry(),
          waiting: [
            _entry(
              id: 'sp-2',
              thread: 'th-2',
              title: 'Garden lights',
              state: 'queued',
            ),
          ],
        ),
      );
      await tester.pumpWidget(
        _wrap(WorkspaceSpeechPanel(controller: controller)),
      );
      for (final key in const [
        'workspace-speech-hold',
        'workspace-speech-skip',
        'workspace-speech-solo-sp-2',
      ]) {
        final size = tester.getSize(find.byKey(Key(key)));
        expect(size.height, greaterThanOrEqualTo(36), reason: key);
        expect(size.width, greaterThanOrEqualTo(36), reason: key);
      }
    });

    testWidgets('a phone draws the strip and the queue in its sheet', (
      tester,
    ) async {
      final controller = _controller(
        _floor(
          speaking: _entry(),
          waiting: [
            _entry(
              id: 'sp-2',
              thread: 'th-2',
              title: 'Garden lights',
              state: 'queued',
              preview: 'The timer works.',
            ),
          ],
        ),
      );
      await tester.pumpWidget(
        _wrap(WorkspaceSpeechPanel(controller: controller, compact: true)),
      );
      expect(find.byKey(const Key('workspace-speech-strip')), findsOneWidget);
      expect(find.text('Kitchen renovation'), findsOneWidget);
      expect(find.text('1 waiting'), findsOneWidget);
      // The queue is one tap away, and it names every thread.
      await tester.tap(find.byKey(const Key('workspace-speech-strip')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('workspace-speech-sheet-waiting')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('workspace-speech-sheet-thread-sp-2')),
        findsOneWidget,
      );
      expect(find.text('Solo'), findsOneWidget);
    });

    testWidgets('the tooltips are noun phrases', (tester) async {
      final controller = _controller(
        _floor(
          speaking: _entry(),
          waiting: [
            _entry(
              id: 'sp-2',
              thread: 'th-2',
              title: 'Garden lights',
              state: 'queued',
            ),
          ],
        ),
      );
      await tester.pumpWidget(
        _wrap(WorkspaceSpeechPanel(controller: controller)),
      );
      final semantics = tester.getSemantics(
        find.byKey(const Key('workspace-speech-hold')),
      );
      expect(semantics.tooltip, 'Speech · hold');
      final solo = tester.getSemantics(
        find.byKey(const Key('workspace-speech-solo-sp-2')),
      );
      expect(solo.tooltip, 'Speech · solo');
      final skip = tester.getSemantics(
        find.byKey(const Key('workspace-speech-skip')),
      );
      expect(skip.tooltip, 'Speech · skip');
    });
  });

  group('the controller', () {
    test('soloes, leaves solo and skips through the harness', () async {
      final controller = _controller(
        _floor(
          speaking: _entry(),
          waiting: [_entry(id: 'sp-2', thread: 'th-2', state: 'queued')],
        ),
      );
      // A preview keeps its floor: the actions reach no harness, and the
      // panel still says what the harness last said.
      await controller.soloSpeech('th-1');
      await controller.clearSolo();
      await controller.skipSpeech();
      await controller.clearSpeech();
      expect(controller.speech!.speaking!.id, 'sp-1');
    });
  });
}

class _FailingSpeech implements VoiceSpeech {
  @override
  Future<void> speak(String text) async => throw StateError('no engine');

  @override
  Future<void> stop() async {}
}

extension on WorkspaceSpeechEntry {
  WorkspaceSpeechEntry copyWithHeld(String held) => WorkspaceSpeechEntry(
    id: id,
    workspace: workspace,
    thread: thread,
    threadTitle: threadTitle,
    session: session,
    node: node,
    source: source,
    text: text,
    preview: preview,
    state: state,
    at: at,
    why: why,
    outcome: outcome,
    held: held,
    played: played,
  );
}
