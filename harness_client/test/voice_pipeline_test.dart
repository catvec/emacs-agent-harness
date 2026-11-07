import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/voice/voice_backend.dart';
import 'package:harness_client/src/voice/voice_controller.dart';
import 'package:harness_client/src/voice/voice_models.dart';
import 'package:harness_client/src/voice/voice_pipeline.dart';
import 'package:harness_client/src/voice/voice_settings.dart';

import 'support/voice_fakes.dart';

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

DateTime _now() => DateTime(2026, 11, 7, 12, 0, 0);

void main() {
  group('the pipe keeps only what the stages report', () {
    test(
      'a level is not speech: nothing appears until the filter keeps it',
      () {
        final tracker = VoicePipelineTracker(clock: _now);
        tracker.begin();
        tracker.input(VoiceInputState.live);
        tracker.level(0.42);
        tracker.gate(true);

        final listening = tracker.snapshot;
        expect(listening.segments, isEmpty);
        expect(listening.levelSeen, isTrue);
        expect(listening.level, 0.42);
        expect(
          listening.summary(_now()),
          'Mic · live · Level · 42% · Speech · heard · Voice · silent',
        );

        tracker.accept('u-1', duration: const Duration(milliseconds: 1400));
        final kept = tracker.snapshot;
        expect(kept.segments.single.stage, VoicePipelineStage.accepted);
        expect(kept.segments.single.column, VoicePipelineColumn.filter);
        expect(kept.accepted, 1);
        expect(kept.dropped, 0);
        expect(kept.countLabel, '1 accepted');
      },
    );

    test('a burst the filter dropped is shown as dropped, with why', () {
      final tracker = VoicePipelineTracker(clock: _now);
      tracker.begin();
      tracker.input(VoiceInputState.live);
      tracker.reject(duration: const Duration(milliseconds: 80));

      final snapshot = tracker.snapshot;
      expect(snapshot.segments.single.stage, VoicePipelineStage.dropped);
      expect(snapshot.segments.single.drop, VoiceSegmentDrop.tooShort);
      expect(snapshot.segments.single.column, VoicePipelineColumn.filter);
      expect(snapshot.accepted, 0);
      expect(snapshot.dropped, 1);
      expect(snapshot.countLabel, '1 dropped');
      expect(snapshot.details.single, contains('too short'));
    });

    test('a segment waits at each stage and never skips one', () {
      final tracker = VoicePipelineTracker(clock: _now);
      tracker.begin();
      tracker.input(VoiceInputState.live);
      tracker.accept('u-1', duration: const Duration(seconds: 1));

      tracker.transcribing('u-1');
      expect(
        tracker.snapshot.segments.single.stage,
        VoicePipelineStage.transcribing,
      );
      tracker.transcript('u-1', 'open the merge');
      expect(
        tracker.snapshot.segments.single.stage,
        VoicePipelineStage.transcribing,
        reason: 'a partial is not the final',
      );
      expect(tracker.snapshot.segments.single.text, 'open the merge');
      expect(tracker.snapshot.segments.single.revision, 1);

      tracker.transcript('u-1', 'open the merge queue', finalized: true);
      final transcribed = tracker.snapshot.segments.single;
      expect(transcribed.stage, VoicePipelineStage.transcribed);
      expect(transcribed.column, VoicePipelineColumn.transcript);
      expect(transcribed.revision, 2);
      expect(transcribed.text, 'open the merge queue');

      tracker.turnSent('t-1', segmentId: 'u-1');
      expect(tracker.snapshot.segments.single.stage, VoicePipelineStage.inTurn);
      expect(tracker.snapshot.segments.single.column, VoicePipelineColumn.turn);
      expect(tracker.snapshot.turnLabel, 'Turn · working');

      tracker.replyReady('The queue has two tasks.', turnId: 't-1');
      expect(
        tracker.snapshot.segments.single.stage,
        VoicePipelineStage.answered,
      );
      expect(tracker.snapshot.turns.single.label, 'replied');

      tracker.turnDone('t-1');
      expect(tracker.snapshot.turnLabel, 'Turn · done');
    });

    test(
      'a duplicate, late or out-of-order event changes nothing it should not',
      () {
        final tracker = VoicePipelineTracker(clock: _now);
        tracker.begin();
        tracker.input(VoiceInputState.live);

        // The accept was lost: the utterance is really being transcribed.
        tracker.transcribing('u-1');
        expect(
          tracker.snapshot.segments.single.stage,
          VoicePipelineStage.transcribing,
        );

        tracker.accept('u-1', duration: const Duration(seconds: 1));
        expect(tracker.snapshot.segments, hasLength(1));
        expect(tracker.ignoredEvents, 1, reason: 'a duplicate accept');

        tracker.transcript('u-1', 'first words', finalized: true);
        tracker.transcript('u-1', 'an older partial');
        expect(
          tracker.snapshot.segments.single.stage,
          VoicePipelineStage.transcribed,
          reason: 'a late partial must not move it backwards',
        );
        expect(tracker.snapshot.segments.single.text, 'an older partial');
        expect(tracker.snapshot.segments.single.revision, 2);

        tracker.drop('u-1');
        expect(
          tracker.snapshot.segments.single.stage,
          VoicePipelineStage.dropped,
        );
        final before = tracker.ignoredEvents;
        tracker.transcript('u-1', 'words after the drop', finalized: true);
        tracker.accept('u-1');
        tracker.transcribing('u-1');
        expect(
          tracker.snapshot.segments.single.stage,
          VoicePipelineStage.dropped,
          reason: 'nothing resurrects a dropped segment',
        );
        expect(
          tracker.snapshot.segments.single.text,
          isNot('words after the drop'),
        );
        expect(tracker.ignoredEvents, greaterThan(before));
        expect(tracker.snapshot.segments, hasLength(1));
      },
    );

    test(
      'several utterances can feed one turn, and a turn can answer twice',
      () {
        final tracker = VoicePipelineTracker(clock: _now);
        tracker.begin();
        tracker.input(VoiceInputState.live);
        for (final id in ['u-1', 'u-2']) {
          tracker.accept(id, duration: const Duration(seconds: 1));
          tracker.transcript(id, 'words $id', finalized: true);
        }
        tracker.turnSent('t-1', segmentId: 'u-1');
        tracker.turnSent('t-1', segmentId: 'u-2');
        expect(tracker.snapshot.turns, hasLength(1));
        final turn = tracker.snapshot.turns.single;
        expect(turn.segmentIds, ['u-1', 'u-2']);
        expect(
          tracker.snapshot.segments.map((segment) => segment.stage),
          everyElement(VoicePipelineStage.inTurn),
        );

        tracker.replyReady('first sentence', turnId: 't-1');
        tracker.replyReady('second sentence', turnId: 't-1');
        expect(tracker.snapshot.turns.single.replyIds, hasLength(2));
        expect(
          tracker.snapshot.details,
          contains('t-1 · replied · 2 utterances · 2 replies'),
        );
      },
    );

    test('the speaker tells ready and held apart from speaking', () {
      final tracker = VoicePipelineTracker(clock: _now);
      tracker.begin();
      tracker.input(VoiceInputState.live);

      final id = tracker.replyReady('The tests pass.');
      expect(tracker.snapshot.output, VoiceOutputState.ready);
      expect(tracker.snapshot.speakerLabel, 'Voice · ready');

      tracker.replyHeld(id);
      expect(tracker.snapshot.output, VoiceOutputState.held);
      expect(tracker.snapshot.speakerLabel, 'Voice · held');

      // Audio from nowhere does not move a held reply on.
      tracker.playback(playing: true);
      expect(tracker.snapshot.replies.single.stage, VoiceReplyStage.held);
      expect(tracker.snapshot.output, VoiceOutputState.speaking);
      tracker.playback(playing: false);

      tracker.replyReleased(id);
      tracker.replyHanded(id);
      expect(tracker.snapshot.output, VoiceOutputState.handed);
      expect(tracker.snapshot.speakerLabel, 'Voice · handed');

      tracker.playback(playing: true, replyId: id);
      expect(tracker.snapshot.replies.single.stage, VoiceReplyStage.speaking);
      expect(tracker.snapshot.output, VoiceOutputState.speaking);

      tracker.playback(playing: false, replyId: id);
      expect(tracker.snapshot.replies.single.stage, VoiceReplyStage.spoken);
      expect(tracker.snapshot.spoken, 1);
      expect(tracker.snapshot.output, VoiceOutputState.silent);
    });

    test('handed text is not spoken, and a stale stop ends nothing', () {
      final tracker = VoicePipelineTracker(clock: _now);
      tracker.begin();
      tracker.input(VoiceInputState.live);
      final id = tracker.replyReady('On the way.');
      tracker.replyHanded(id);

      // A provider that finished a reply it was handed never reported a
      // start: the stop does not claim it was heard.
      tracker.playback(playing: false, replyId: id);
      expect(tracker.snapshot.replies.single.stage, VoiceReplyStage.handed);
      expect(tracker.snapshot.spoken, 0);

      tracker.playback(playing: true, replyId: id, generation: 4);
      expect(tracker.snapshot.replies.single.stage, VoiceReplyStage.speaking);
      tracker.playback(playing: false, replyId: id, generation: 3);
      expect(
        tracker.snapshot.replies.single.stage,
        VoiceReplyStage.speaking,
        reason: 'an older playback cannot end a newer one',
      );
      tracker.playback(playing: false, replyId: id, generation: 4);
      expect(tracker.snapshot.replies.single.stage, VoiceReplyStage.spoken);
    });

    test('an interruption stops what was playing and never resurrects it', () {
      final tracker = VoicePipelineTracker(clock: _now);
      tracker.begin();
      tracker.input(VoiceInputState.live);
      final first = tracker.replyReady('A long answer.');
      tracker.replyHanded(first);
      tracker.playback(playing: true, replyId: first);
      final second = tracker.replyReady('A second answer.');
      tracker.replyHanded(second);

      tracker.interrupted();
      expect(
        tracker.snapshot.replies.map((reply) => reply.stage),
        everyElement(VoiceReplyStage.interrupted),
      );
      expect(tracker.snapshot.output, VoiceOutputState.interrupted);

      final before = tracker.ignoredEvents;
      tracker.playback(playing: true, replyId: first, generation: 9);
      tracker.playback(playing: false, replyId: first, generation: 9);
      expect(tracker.snapshot.replies.first.stage, VoiceReplyStage.interrupted);
      expect(tracker.snapshot.playing, isFalse);
      expect(tracker.ignoredEvents, greaterThan(before));
    });

    test('capture and playback are shown at the same time', () {
      final tracker = VoicePipelineTracker(clock: _now);
      tracker.begin();
      tracker.input(VoiceInputState.live);
      final reply = tracker.replyReady('Still talking.');
      tracker.replyHanded(reply);
      tracker.playback(playing: true, replyId: reply);

      tracker.accept('u-1', duration: const Duration(seconds: 2));
      tracker.transcribing('u-1');
      tracker.gate(true);

      final snapshot = tracker.snapshot;
      expect(snapshot.output, VoiceOutputState.speaking);
      expect(snapshot.segments.single.stage, VoicePipelineStage.transcribing);
      expect(snapshot.speechActive, isTrue);
      expect(snapshot.summary(_now()), contains('Voice · speaking'));
      expect(snapshot.summary(_now()), contains('1 accepted'));
    });

    test('mute, pause and end drop what will not be spoken or sent', () {
      final tracker = VoicePipelineTracker(clock: _now);
      tracker.begin();
      tracker.input(VoiceInputState.live);
      tracker.accept('u-1', duration: const Duration(seconds: 1));
      tracker.transcribing('u-1');
      final held = tracker.replyReady('Held.');
      tracker.replyHeld(held);

      tracker.replyDropped(held, detail: 'muted');
      expect(tracker.snapshot.replies.single.stage, VoiceReplyStage.dropped);
      expect(tracker.snapshot.replies.single.detail, 'muted');

      tracker.drop('u-1', detail: 'ended');
      expect(
        tracker.snapshot.segments.single.stage,
        VoicePipelineStage.dropped,
      );
      expect(tracker.snapshot.segments.single.drop, VoiceSegmentDrop.cancelled);
      expect(tracker.snapshot.dropped, 1);

      tracker.input(VoiceInputState.ended);
      expect(tracker.snapshot.input, VoiceInputState.ended);
      expect(tracker.snapshot.summary(_now()), startsWith('Mic · ended'));
    });

    test('a new generation starts with nothing from the last one', () {
      final tracker = VoicePipelineTracker(clock: _now);
      tracker.begin();
      tracker.input(VoiceInputState.live);
      tracker.accept('u-1', duration: const Duration(seconds: 1));
      tracker.transcript('u-1', 'old words', finalized: true);
      final first = tracker.generation;

      tracker.begin();
      expect(tracker.generation, greaterThan(first));
      expect(tracker.snapshot.segments, isEmpty);
      expect(tracker.snapshot.turns, isEmpty);
      expect(tracker.snapshot.replies, isEmpty);
      expect(tracker.snapshot.accepted, 0);
      expect(tracker.snapshot.input, VoiceInputState.connecting);
      // The new generation's own u-1 is a different utterance.
      tracker.accept('u-1', duration: const Duration(seconds: 1));
      expect(tracker.snapshot.segments.single.text, isNull);
    });

    test('the meter says it has no data rather than showing silence', () {
      final tracker = VoicePipelineTracker(clock: _now);
      tracker.begin();
      tracker.input(VoiceInputState.live);
      final now = _now();
      expect(tracker.snapshot.levelSeen, isFalse);
      expect(tracker.snapshot.levelStale(now), isTrue);
      expect(tracker.snapshot.meterLabel(now), 'Level · no data');
      expect(tracker.snapshot.inputLabel, 'Mic · live');

      tracker.level(0.0);
      expect(tracker.snapshot.levelSeen, isTrue);
      expect(tracker.snapshot.levelStale(now), isFalse);
      expect(tracker.snapshot.meterLabel(now), 'Level · 0%');
      expect(
        tracker.snapshot.levelStale(
          now.add(
            VoicePipelineSnapshot.staleAfter + const Duration(seconds: 1),
          ),
        ),
        isTrue,
      );
    });

    test('a closed microphone has no level, not a silent one', () {
      final tracker = VoicePipelineTracker(clock: _now);
      tracker.begin();
      tracker.input(VoiceInputState.live);
      tracker.level(0.3);
      expect(tracker.snapshot.meterLabel(_now()), 'Level · 30%');
      tracker.input(VoiceInputState.muted);
      expect(tracker.snapshot.meterLabel(_now()), 'Level · no data');
      expect(tracker.snapshot.inputLabel, 'Mic · muted');
    });

    test('a problem and the input state reach the summary', () {
      final tracker = VoicePipelineTracker(clock: _now);
      tracker.begin();
      tracker.input(VoiceInputState.failed);
      tracker.problem(
        const VoiceProblem('Microphone permission denied', recoverable: false),
      );
      expect(
        tracker.snapshot.summary(_now()),
        'Mic · failed · Level · no data · Voice · silent · '
        'Microphone permission denied',
      );
      tracker.problem(null);
      expect(tracker.snapshot.summary(_now()), isNot(contains('permission')));
    });

    test('the lists stay bounded and the totals keep the rest', () {
      final tracker = VoicePipelineTracker(clock: _now);
      tracker.begin();
      tracker.input(VoiceInputState.live);
      for (var i = 1; i <= 10; i++) {
        tracker.accept('u-$i', duration: const Duration(seconds: 1));
        tracker.transcript('u-$i', 'words $i', finalized: true);
        tracker.turnSent('t-$i', segmentId: 'u-$i');
        tracker.turnDone('t-$i');
      }
      expect(tracker.snapshot.accepted, 10);
      expect(tracker.snapshot.segments.length, lessThanOrEqualTo(6));
      expect(tracker.snapshot.turns.length, lessThanOrEqualTo(3));
      expect(tracker.snapshot.segments.last.id, 'u-10');
    });

    test('durations and excerpts read as a person reads them', () {
      expect(voicePipelineDuration(const Duration(milliseconds: 640)), '640ms');
      expect(voicePipelineDuration(const Duration(milliseconds: 1400)), '1.4s');
      expect(voicePipelineDuration(const Duration(seconds: 12)), '12s');
      expect(voicePipelineExcerpt('a\n  b   c'), 'a b c');
      expect(voicePipelineExcerpt('x' * 80, max: 10), 'xxxxxxxxx…');
    });
  });

  group('the controller feeds the pipe from real decisions', () {
    test(
      'a kept utterance becomes a turn and an answer on the speaker',
      () async {
        final rig = Rig();
        await rig.controller.start();
        await settle();
        expect(rig.controller.pipelineState.input, VoiceInputState.live);

        rig.backend.emit(
          const VoiceSegmentEvent(
            id: 'u-1',
            stage: VoiceSegmentStage.accepted,
            duration: Duration(milliseconds: 1400),
            level: 0.5,
          ),
        );
        rig.backend.emit(
          const VoiceSegmentEvent(
            id: 'u-1',
            stage: VoiceSegmentStage.transcribing,
          ),
        );
        rig.backend.emit(
          const VoiceSegmentEvent(
            id: 'u-1',
            stage: VoiceSegmentStage.transcribed,
            text: 'the tests pass',
          ),
        );
        await settle();
        expect(
          rig.controller.pipelineState.segments.single.text,
          'the tests pass',
        );

        rig.backend.emit(
          const VoicePromptEvent(
            VoicePrompt(text: 'the tests pass', id: 'u-1', segmentId: 'u-1'),
          ),
        );
        await settle();
        expect(rig.session.sent.single.text, 'the tests pass');
        expect(rig.controller.pipelineState.turns.single.label, 'done');
        expect(
          rig.controller.pipelineState.segments.single.stage,
          VoicePipelineStage.inTurn,
        );
        expect(rig.controller.pipelineState.turnLabel, 'Turn · done');

        rig.session.reply('They all pass.');
        await settle();
        final reply = rig.controller.pipelineState.replies.single;
        expect(reply.stage, VoiceReplyStage.handed);
        expect(rig.backend.spoken, ['They all pass.']);
        expect(rig.backend.handed.single, reply.id);

        rig.backend.emit(VoicePlaybackEvent(playing: true, replyId: reply.id));
        await settle();
        expect(rig.controller.pipelineState.output, VoiceOutputState.speaking);
        rig.backend.emit(VoicePlaybackEvent(playing: false, replyId: reply.id));
        await settle();
        expect(rig.controller.pipelineState.spoken, 1);
        expect(rig.controller.pipelineState.output, VoiceOutputState.silent);
      },
    );

    test('a reply held for turn-taking is shown held, then spoken', () async {
      final rig = Rig(pendingReleaseDelay: const Duration(milliseconds: 20));
      await rig.controller.start();
      await settle();
      rig.backend.emit(const VoiceSpeechEvent(true));
      await settle();
      rig.session.reply('Held while you talk.');
      await settle();
      expect(
        rig.controller.pipelineState.replies.single.stage,
        VoiceReplyStage.held,
      );
      expect(rig.controller.pipelineState.output, VoiceOutputState.held);
      expect(rig.backend.spoken, isEmpty);

      rig.backend.emit(const VoiceSpeechEvent(false));
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(rig.backend.spoken, ['Held while you talk.']);
      expect(
        rig.controller.pipelineState.replies.single.stage,
        VoiceReplyStage.handed,
      );
      await rig.controller.stop();
    });

    test('a backend hold names the reply, and its release speaks it', () async {
      final rig = Rig(pendingReleaseDelay: const Duration(milliseconds: 20));
      await rig.controller.start();
      await settle();
      rig.backend.emit(const VoiceSpeechEvent(true));
      await settle();
      final id = rig.controller.pipeline.replyReady('Backend held.');
      rig.backend.emit(VoiceHeldEvent('Backend held.', id: id));
      await settle();
      expect(
        rig.controller.pipelineState.replies.single.stage,
        VoiceReplyStage.held,
      );
      rig.backend.emit(const VoiceSpeechEvent(false));
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(rig.backend.spoken, ['Backend held.']);
      expect(rig.backend.handed, [id]);
      await rig.controller.stop();
    });

    test('mute drops held replies and says why', () async {
      final rig = Rig();
      await rig.controller.start();
      await settle();
      rig.backend.emit(const VoiceSpeechEvent(true));
      await settle();
      rig.session.reply('Held.');
      await settle();
      await rig.controller.toggleMute();
      await settle();
      final snapshot = rig.controller.pipelineState;
      expect(snapshot.replies.single.stage, VoiceReplyStage.dropped);
      expect(snapshot.replies.single.detail, 'muted');
      expect(snapshot.input, VoiceInputState.muted);
      expect(rig.backend.spoken, isEmpty);
      await rig.controller.stop();
    });

    test('interrupt stops the speaker and keeps the work', () async {
      final rig = Rig();
      await rig.controller.start();
      await settle();
      rig.session.reply('A long answer.');
      await settle();
      final reply = rig.controller.pipelineState.replies.single;
      rig.backend.emit(VoicePlaybackEvent(playing: true, replyId: reply.id));
      await settle();
      await rig.controller.interrupt();
      await settle();
      expect(
        rig.controller.pipelineState.replies.single.stage,
        VoiceReplyStage.interrupted,
      );
      expect(rig.controller.pipelineState.playing, isFalse);
      expect(rig.controller.displayPhase, VoicePhase.interrupted);
      await rig.controller.stop();
    });

    test('stop cancels what was waiting and closes the meter', () async {
      final rig = Rig();
      await rig.controller.start();
      await settle();
      rig.backend.emit(
        const VoiceSegmentEvent(
          id: 'u-1',
          stage: VoiceSegmentStage.accepted,
          duration: Duration(milliseconds: 500),
        ),
      );
      await settle();
      await rig.controller.stop();
      await settle();
      final snapshot = rig.controller.pipelineState;
      expect(snapshot.input, VoiceInputState.ended);
      expect(snapshot.segments.single.stage, VoicePipelineStage.dropped);
      expect(snapshot.segments.single.detail, 'cancelled');
    });

    test('an unexpected backend end reads as disconnected', () async {
      final rig = Rig();
      await rig.controller.start();
      await settle();
      rig.backend.emit(const VoiceEndedEvent());
      await settle();
      expect(rig.controller.pipelineState.input, VoiceInputState.disconnected);
      await rig.controller.stop();
    });

    test('the backend a restart replaced cannot resurrect its audio', () async {
      final first = FakeBackend();
      final second = FakeBackend();
      final built = <FakeBackend>[first, second];
      var next = 0;
      final session = FakeSession();
      final controller = VoiceController(
        settings: const VoiceSettings(clipDelivery: ClipDelivery.audioPrompt),
        bridge: session,
        harnessAddress: 'ws://harness.test:9999/acp',
        backendFactory: (settings, address) => built[next++],
        onSettingsChanged: (settings) async {},
        mediaButtons: FakeMediaButtons(),
      );
      addTearDown(controller.dispose);
      await controller.start();
      await settle();
      first.emit(
        const VoiceSegmentEvent(
          id: 'u-1',
          stage: VoiceSegmentStage.accepted,
          duration: Duration(milliseconds: 900),
        ),
      );
      await settle();
      expect(controller.pipelineState.segments, hasLength(1));

      await controller.retry();
      await settle();
      expect(next, 2);
      expect(controller.pipelineState.segments, isEmpty);
      expect(controller.pipelineState.input, VoiceInputState.live);

      // The backend that is gone still has an event in flight.
      first.emit(
        const VoiceSegmentEvent(
          id: 'u-1',
          stage: VoiceSegmentStage.transcribed,
          text: 'old words',
        ),
      );
      first.emit(const VoicePlaybackEvent(playing: true));
      await settle();
      expect(
        controller.pipelineState.segments,
        isEmpty,
        reason: 'a stopped backend cannot resurrect audio',
      );
      expect(
        controller.pipelineState.replies.where(
          (reply) => reply.stage == VoiceReplyStage.speaking,
        ),
        isEmpty,
      );
      await controller.stop();
    });

    test(
      'a turn answers in pieces, and the next turn owns its own reply',
      () async {
        final rig = Rig();
        await rig.controller.start();
        await settle();
        rig.session.hold = true;

        rig.backend.emit(
          const VoicePromptEvent(VoicePrompt(text: 'first', id: 'u-1')),
        );
        await settle();
        rig.session.reply('First piece.');
        rig.session.reply('Second piece.');
        await settle();
        final first = rig.controller.pipelineState;
        expect(first.turns, hasLength(1));
        expect(first.turns.single.replyIds, hasLength(2));
        expect(
          first.replies.map((reply) => reply.turnId),
          everyElement(first.turns.single.id),
        );

        rig.session.pending.first.complete();
        await settle();
        expect(rig.controller.pipelineState.turnLabel, 'Turn · done');

        rig.backend.emit(
          const VoicePromptEvent(VoicePrompt(text: 'second', id: 'u-2')),
        );
        await settle();
        rig.session.reply('Another answer.');
        await settle();
        final second = rig.controller.pipelineState;
        expect(second.turns, hasLength(2));
        expect(second.turns.last.replyIds, hasLength(1));
        expect(second.replies.last.turnId, second.turns.last.id);
        rig.session.pending.last.complete();
        await settle();
        await rig.controller.stop();
      },
    );

    test(
      'a settings restart begins a new pipe, and calls do not share one',
      () async {
        // A workspace call builds a fresh backend each time it connects.
        final backends = <FakeBackend>[];
        final session = FakeSession();
        final controller = VoiceController(
          settings: const VoiceSettings(clipDelivery: ClipDelivery.audioPrompt),
          bridge: session,
          harnessAddress: 'ws://harness.test:9999/acp',
          backendFactory: (settings, address) {
            final backend = FakeBackend();
            backends.add(backend);
            return backend;
          },
          onSettingsChanged: (settings) async {},
          mediaButtons: FakeMediaButtons(),
        );
        addTearDown(controller.dispose);
        await controller.start();
        await settle();
        backends.single.emit(
          const VoiceSegmentEvent(
            id: 'u-1',
            stage: VoiceSegmentStage.accepted,
            duration: Duration(milliseconds: 900),
          ),
        );
        await settle();
        expect(controller.pipelineState.segments, hasLength(1));

        await controller.updateSettings(
          const VoiceSettings(
            clipDelivery: ClipDelivery.audioPrompt,
            language: 'de',
          ),
        );
        await settle();
        expect(backends, hasLength(2));
        expect(
          controller.pipelineState.segments,
          isEmpty,
          reason: 'a provider or endpoint change starts over',
        );
        expect(controller.pipelineState.input, VoiceInputState.live);
        expect(
          controller.pipelineState.levelSeen,
          isFalse,
          reason: 'the old meter does not stand for the new backend',
        );

        // The backend that was replaced cannot advance the new pipe.
        backends.first.emit(
          const VoiceSegmentEvent(
            id: 'u-1',
            stage: VoiceSegmentStage.transcribed,
            text: 'old words',
          ),
        );
        await settle();
        expect(controller.pipelineState.segments, isEmpty);
        await controller.stop();

        // A second call is its own pipe.
        final other = Rig();
        await other.controller.start();
        await settle();
        other.backend.emit(
          const VoiceSegmentEvent(
            id: 'u-1',
            stage: VoiceSegmentStage.accepted,
            duration: Duration(milliseconds: 900),
          ),
        );
        await settle();
        expect(other.controller.pipelineState.segments, hasLength(1));
        expect(controller.pipelineState.segments, isEmpty);
        await other.controller.stop();
      },
    );

    test('a failed turn keeps its segment and says what failed', () async {
      final rig = Rig();
      await rig.controller.start();
      await settle();
      rig.backend.emit(
        const VoiceSegmentEvent(
          id: 'u-1',
          stage: VoiceSegmentStage.accepted,
          duration: Duration(milliseconds: 500),
        ),
      );
      rig.session.failNext = 'the connection dropped';
      rig.backend.emit(
        const VoicePromptEvent(
          VoicePrompt(text: 'hello', id: 'u-1', segmentId: 'u-1'),
        ),
      );
      await settle();
      final snapshot = rig.controller.pipelineState;
      expect(snapshot.turns.single.failed, isTrue);
      expect(snapshot.turnLabel, 'Turn · failed');
      expect(
        snapshot.segments.single.stage,
        VoicePipelineStage.inTurn,
        reason: 'the audio was sent; the turn is what failed',
      );
      await rig.controller.stop();
    });

    test('a segment failure reaches the pipe with its own words', () async {
      final rig = Rig();
      await rig.controller.start();
      await settle();
      rig.backend.emit(
        const VoiceSegmentEvent(
          id: 'u-1',
          stage: VoiceSegmentStage.accepted,
          duration: Duration(milliseconds: 500),
        ),
      );
      rig.backend.emit(
        const VoiceSegmentEvent(
          id: 'u-1',
          stage: VoiceSegmentStage.failed,
          detail: 'whisper: connection refused',
        ),
      );
      await settle();
      final segment = rig.controller.pipelineState.segments.single;
      expect(segment.stage, VoicePipelineStage.failed);
      expect(segment.detail, 'whisper: connection refused');
      expect(
        rig.controller.pipelineState.details.single,
        contains('whisper: connection refused'),
      );
      await rig.controller.stop();
    });
  });
}
