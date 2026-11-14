import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/voice/voice_backend.dart';
import 'package:harness_client/src/voice/voice_models.dart';
import 'package:harness_client/src/voice/voice_pipeline.dart';
import 'package:harness_client/src/voice/voice_settings.dart';
import 'package:harness_client/src/voice/voice_turn_completion.dart';

import 'support/voice_fakes.dart';

void main() {
  final fixture = jsonDecode(
    File('test/fixtures/voice-turn-completion.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  group('shared voice turn contract', () {
    for (final example in fixture['classification'] as List) {
      test('classification: ${example['text']} / ${example['truncated']}', () {
        expect(
          classifyVoiceTurn(
            example['text'] as String,
            truncated: example['truncated'] == true,
          ).name,
          example['reason'],
        );
      });
    }
    for (final example in fixture['recovery'] as List) {
      test('recovery: ${example['text']}', () {
        expect(isVoiceTurnRecovery(example['text'] as String), example['matches']);
      });
    }
  });

  test('named pause content still respects a hard recording cut', () {
    expect(classifyVoiceTurn('Add a button called hold on.', truncated: true),
        VoiceTurnReason.cutOff);
  });

  test('WH-question preposition exception cannot excuse dangling articles or conjunctions', () {
    expect(classifyVoiceTurn('What should I put in the?'), VoiceTurnReason.cutOff);
    expect(classifyVoiceTurn('Which branch should I use if?'), VoiceTurnReason.cutOff);
  });

  Future<Rig> start(WidgetTester tester, {int pendingTextLimit = 100000}) async {
    final rig = Rig(
      settings: const VoiceSettings(clipDelivery: ClipDelivery.transcript),
      pendingReleaseDelay: const Duration(milliseconds: 50),
      pendingTextLimit: pendingTextLimit,
    );
    await rig.controller.start();
    await tester.pump();
    addTearDown(() async {
      await rig.controller.stop();
      rig.controller.dispose();
    });
    return rig;
  }

  void prompt(Rig rig, String text, String id, {bool truncated = false}) {
    rig.backend.emit(VoicePromptEvent(VoicePrompt(
      text: text,
      id: id,
      segmentId: id,
      truncated: truncated,
    )));
  }

  void accepted(Rig rig, String id) => rig.backend.emit(VoiceSegmentEvent(
    id: id,
    stage: VoiceSegmentStage.accepted,
  ));

  testWidgets('ordinary grace is 1.2 seconds, with immediate captions only', (tester) async {
    final rig = await start(tester);
    prompt(rig, 'Please fix the failing tests.', 'u1');
    await tester.pump();
    expect(rig.controller.pendingSpeech, 'Please fix the failing tests.');
    expect(rig.controller.pendingReason, VoiceTurnReason.grace);
    expect(rig.controller.captions.single.text, 'Please fix the failing tests.');
    expect(rig.controller.conversation.turns, isEmpty);
    expect(rig.backend.turnHeld, isTrue);
    await tester.pump(const Duration(milliseconds: 1199));
    expect(rig.session.sent, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    expect(rig.session.sent.single.text, 'Please fix the failing tests.');
    expect(rig.controller.conversation.turns.single.sent, 'Please fix the failing tests.');
    expect(rig.controller.pendingSpeech, isEmpty);
    expect(rig.backend.turnHeld, isFalse);
  });

  testWidgets('re-onset before deadline cancels it; complete continuation joins in order', (tester) async {
    final rig = await start(tester);
    prompt(rig, 'Open the change.', 'u1');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1190));
    rig.backend.emit(const VoiceSpeechEvent(true));
    accepted(rig, 'u2');
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    expect(rig.session.sent, isEmpty);
    expect(rig.controller.canSendPending, isFalse);
    await rig.controller.sendPendingNow();
    expect(rig.session.sent, isEmpty);
    rig.backend.emit(const VoiceSpeechEvent(false));
    prompt(rig, 'And add a regression.', 'u2');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1199));
    expect(rig.session.sent, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    expect(rig.session.sent.single.text, 'Open the change. And add a regression.');
    expect(rig.session.sent.single.displayText, 'Open the change. And add a regression.');
    expect(rig.controller.pipelineState.turns.single.segmentIds, ['u1', 'u2']);
    expect(rig.controller.pipelineState.segments.map((s) => s.stage),
        everyElement(VoicePipelineStage.answered));
    expect(rig.backend.committedSources.last, ['u1', 'u2']);
  });

  testWidgets('explicit intent, fragments and hard cuts never expire into a send', (tester) async {
    for (final example in [
      ('Fix the test, one second.', false, VoiceTurnReason.continuation),
      ('Let me think.', false, VoiceTurnReason.continuation),
      ('Change the handler because.', false, VoiceTurnReason.cutOff),
      ('The sentence looks finished.', true, VoiceTurnReason.cutOff),
    ]) {
      final rig = await start(tester);
      prompt(rig, example.$1, 'u1', truncated: example.$2);
      await tester.pump();
      expect(rig.controller.pendingReason, example.$3);
      await tester.pump(const Duration(minutes: 5));
      expect(rig.session.sent, isEmpty);
      expect(rig.controller.pendingSpeech, example.$1);
      expect(rig.backend.turnHeld, isTrue);
      await tester.runAsync(rig.controller.stop);
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('a later complete chunk can finish a hold without rewriting its words', (tester) async {
    final rig = await start(tester);
    prompt(rig, 'I want you to', 'u1', truncated: true);
    await tester.pump();
    await tester.pump(const Duration(seconds: 20));
    prompt(rig, 'fix the the parser.', 'u2');
    await tester.pump();
    expect(rig.controller.pendingReason, VoiceTurnReason.grace);
    await tester.pump(const Duration(milliseconds: 1200));
    expect(rig.session.sent.single.text, 'I want you to fix the the parser.');
    expect(rig.controller.conversation.turns.single.raw, 'I want you to fix the the parser.');
  });

  testWidgets('late and out-of-order transcripts block override and preserve source order', (tester) async {
    final rig = await start(tester);
    accepted(rig, 'u1');
    accepted(rig, 'u2');
    prompt(rig, 'then fix the tests.', 'u2');
    await tester.pump();
    await tester.pump(const Duration(seconds: 10));
    expect(rig.controller.canSendPending, isFalse);
    await rig.controller.sendPendingNow();
    expect(rig.session.sent, isEmpty);
    prompt(rig, 'Read the code,', 'u1');
    await tester.pump();
    expect(rig.controller.pendingSpeech, 'Read the code, then fix the tests.');
    await tester.pump(const Duration(milliseconds: 1199));
    expect(rig.session.sent, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    expect(rig.session.sent.single.text, 'Read the code, then fix the tests.');
    expect(rig.controller.pipelineState.turns.single.segmentIds, ['u1', 'u2']);
  });

  testWidgets('empty/dropped input unblocks grace without clearing the draft', (tester) async {
    final rig = await start(tester);
    prompt(rig, 'Open the report.', 'u1');
    accepted(rig, 'u2');
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    rig.backend.emit(const VoiceSegmentEvent(
      id: 'u2', stage: VoiceSegmentStage.dropped, drop: VoiceSegmentDrop.noWords,
    ));
    await tester.pump();
    expect(rig.controller.pendingSpeech, 'Open the report.');
    await tester.pump(const Duration(milliseconds: 1200));
    expect(rig.session.sent.single.text, 'Open the report.');
    expect(rig.controller.pipelineState.segments.last.drop, VoiceSegmentDrop.noWords);
  });

  testWidgets('failed transcription retains earlier words as a cut-off, not success', (tester) async {
    final rig = await start(tester);
    prompt(rig, 'Open the report.', 'u1');
    accepted(rig, 'u2');
    rig.backend.emit(const VoiceSegmentEvent(
      id: 'u2', stage: VoiceSegmentStage.failed, detail: 'offline',
    ));
    rig.backend.emit(const VoiceFailureEvent(VoiceProblem('Transcription failed')));
    rig.backend.emit(const VoicePhaseEvent(VoicePhase.listening));
    await tester.pump();
    expect(rig.controller.pendingReason, VoiceTurnReason.cutOff);
    expect(rig.controller.problem?.label, 'Transcription failed');
    await tester.pump(const Duration(minutes: 5));
    expect(rig.session.sent, isEmpty);
    prompt(rig, 'go on', 'u3');
    await tester.pump();
    expect(rig.session.sent.single.text, 'Open the report.');
    expect(rig.controller.pipelineState.segments[1].stage, VoicePipelineStage.failed);
  });

  testWidgets('failed middle audio stays cut-off after later complete words', (tester) async {
    final rig = await start(tester);
    prompt(rig, 'First words.', 'u1');
    accepted(rig, 'missing');
    rig.backend.emit(const VoiceSegmentEvent(id: 'missing', stage: VoiceSegmentStage.failed));
    prompt(rig, 'Later words.', 'u3');
    await tester.pump();
    expect(rig.controller.pendingReason, VoiceTurnReason.cutOff);
    await tester.pump(const Duration(minutes: 2));
    expect(rig.session.sent, isEmpty);
    prompt(rig, 'continue', 'u4');
    await tester.pump();
    expect(rig.session.sent.single.text, 'First words. Later words.');
  });

  for (final captionOnly in [false, true]) {
    testWidgets('out-of-order ${captionOnly ? 'caption' : 'delegated'} recovery follows onset order', (tester) async {
      final rig = await start(tester);
      accepted(rig, 'earlier');
      accepted(rig, 'recovery');
      if (captionOnly) {
        rig.backend.emit(const VoiceCaptionEvent(
          VoiceSpeaker.you, 'Go on.', finalized: true, segmentId: 'recovery',
        ));
      } else {
        prompt(rig, 'Go on.', 'recovery');
      }
      await tester.pump();
      expect(rig.session.sent, isEmpty);
      prompt(rig, 'I want you to', 'earlier');
      await tester.pump();
      expect(rig.session.sent.single.text, 'I want you to');
      expect(rig.controller.pipelineState.turns.single.segmentIds, ['earlier', 'recovery']);
      await tester.pump(const Duration(seconds: 5));
      expect(rig.session.sent, hasLength(1));
    });
  }

  testWidgets('pending and delivered stable IDs deduplicate; unnumbered repeats are words', (tester) async {
    final rig = await start(tester);
    prompt(rig, 'Hold on.', 'u1');
    prompt(rig, 'Hold on.', 'u1');
    rig.backend.emit(const VoicePromptEvent(VoicePrompt(text: 'yes')));
    rig.backend.emit(const VoicePromptEvent(VoicePrompt(text: 'yes')));
    await tester.pump();
    expect(rig.controller.pendingSpeech, 'Hold on. yes yes');
    await rig.controller.sendPendingNow();
    prompt(rig, 'Hold on.', 'u1');
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    expect(rig.session.sent.single.text, 'Hold on. yes yes');
    expect(rig.controller.pendingSpeech, isEmpty);
  });

  for (final cue in ['continue', 'Please go on.', 'go on, please']) {
    testWidgets('standalone $cue releases once without becoming request text', (tester) async {
      final rig = await start(tester);
      prompt(rig, 'I want you to', 'u1');
      await tester.pump();
      prompt(rig, cue, 'u2');
      await tester.pump();
      expect(rig.session.sent.single.text, 'I want you to');
      expect(rig.controller.captions.last.text, cue);
      expect(rig.controller.pipelineState.turns.single.segmentIds, ['u1', 'u2']);
      await tester.pump(const Duration(seconds: 5));
      expect(rig.session.sent, hasLength(1));
    });
  }

  testWidgets('no-pending recovery and embedded recovery remain unchanged requests', (tester) async {
    final rig = await start(tester);
    for (final text in ['Please go on.', 'Continue with the refactor']) {
      prompt(rig, text, text);
      await tester.pump();
      expect(rig.session.sent.where((p) => p.text == text), isEmpty);
      await tester.pump(const Duration(milliseconds: 1200));
      expect(rig.session.sent.last.text, text);
    }
  });

  testWidgets('recovery also waits for active speech and any outstanding transcription', (tester) async {
    final rig = await start(tester);
    prompt(rig, 'I want you to', 'u1');
    rig.backend.emit(const VoiceSpeechEvent(true));
    accepted(rig, 'u3');
    prompt(rig, 'continue', 'u2');
    await tester.pump();
    expect(rig.session.sent, isEmpty);
    rig.backend.emit(const VoiceSpeechEvent(false));
    await tester.pump();
    expect(rig.session.sent, isEmpty);
    rig.backend.emit(const VoiceSegmentEvent(
      id: 'u3', stage: VoiceSegmentStage.dropped, drop: VoiceSegmentDrop.noWords,
    ));
    await tester.pump();
    expect(rig.session.sent.single.text, 'I want you to');
  });

  testWidgets('manual override is exactly once, including an unresolved session send', (tester) async {
    final rig = await start(tester);
    rig.session.hold = true;
    prompt(rig, 'The unfinished change because', 'u1');
    await tester.pump();
    final sent = rig.controller.sendPendingNow();
    await tester.pump();
    await rig.controller.sendPendingNow();
    expect(rig.session.sent.single.text, 'The unfinished change because');
    rig.session.pending.single.complete();
    await sent;
    expect(rig.controller.pipelineState.segments.single.stage, VoicePipelineStage.answered);
  });

  testWidgets('output remains held through long pauses and cannot release on listening', (tester) async {
    final rig = await start(tester);
    prompt(rig, 'Let me think.', 'u1');
    await tester.pump();
    rig.session.reply('Earlier result.');
    rig.backend.emit(const VoicePhaseEvent(VoicePhase.listening));
    await tester.pump();
    await tester.pump(const Duration(minutes: 3));
    expect(rig.backend.spoken, isEmpty);
    expect(rig.backend.turnHeld, isTrue);
    expect(rig.controller.holdingReply, isTrue);
    prompt(rig, 'go on', 'u2');
    await tester.pump();
    expect(rig.backend.spoken, isEmpty, reason: 'stale output is not replayed');
    expect(rig.backend.turnHeld, isFalse);
    expect(rig.controller.pipelineState.replies.single.stage, VoiceReplyStage.dropped);
  });

  testWidgets('final live caption hold suppresses output without inventing a delegation', (tester) async {
    final rig = await start(tester);
    accepted(rig, 'u1');
    rig.backend.emit(const VoiceCaptionEvent(
      VoiceSpeaker.you, 'Hold on.', finalized: true, segmentId: 'u1',
    ));
    await tester.pump();
    expect(rig.controller.pendingSpeech, 'Hold on.');
    expect(rig.controller.canSendPending, isFalse);
    rig.backend.emit(const VoicePhaseEvent(VoicePhase.listening));
    await tester.pump(const Duration(minutes: 2));
    expect(rig.backend.turnHeld, isTrue);
    expect(rig.session.sent, isEmpty);
    rig.backend.emit(const VoiceCaptionEvent(
      VoiceSpeaker.you, 'Continue.', finalized: true, segmentId: 'u2',
    ));
    await tester.pump();
    expect(rig.controller.pendingSpeech, isEmpty);
    expect(rig.backend.turnHeld, isFalse);
    expect(rig.session.sent, isEmpty);
  });

  for (final manual in [false, true]) {
    testWidgets('newer caption-only hold blocks late earlier delegation until ${manual ? 'override' : 'recovery'}', (tester) async {
      final rig = await start(tester);
      accepted(rig, 'earlier');
      accepted(rig, 'newer');
      rig.backend.emit(const VoiceCaptionEvent(
        VoiceSpeaker.you, 'Hold on.', finalized: true, segmentId: 'newer',
      ));
      await tester.pump();
      prompt(rig, 'Fix the tests.', 'earlier');
      await tester.pump();
      expect(rig.controller.pendingReason, VoiceTurnReason.continuation);
      await tester.pump(const Duration(minutes: 2));
      expect(rig.session.sent, isEmpty);
      expect(rig.backend.turnHeld, isTrue);
      if (manual) {
        expect(rig.controller.canSendPending, isTrue);
        await rig.controller.sendPendingNow();
      } else {
        rig.backend.emit(const VoiceCaptionEvent(
          VoiceSpeaker.you, 'Continue.', finalized: true, segmentId: 'recovery',
        ));
        await tester.pump();
      }
      expect(rig.session.sent.single.text, 'Fix the tests.');
      expect(rig.controller.pendingSpeech, isEmpty);
    });
  }

  testWidgets('caption recovery consumes delayed delegation without an orphan source', (tester) async {
    final rig = await start(tester);
    prompt(rig, 'I want you to', 'u1');
    accepted(rig, 'recovery-input');
    rig.backend.emit(const VoiceCaptionEvent(
      VoiceSpeaker.you, 'Go on.', finalized: true, segmentId: 'recovery-input',
    ));
    await tester.pump();
    expect(rig.session.sent.single.text, 'I want you to');
    expect(rig.controller.pipelineState.turns.single.segmentIds, ['u1', 'recovery-input']);
    rig.backend.emit(const VoicePromptEvent(VoicePrompt(
      text: 'Go on.', id: 'late-recovery-call', segmentId: 'recovery-input',
    )));
    await tester.pump();
    expect(rig.backend.discardedPrompts, ['late-recovery-call']);
    expect(rig.session.sent, hasLength(1));
    prompt(rig, 'A new request.', 'u3');
    await tester.pump();
    await rig.controller.sendPendingNow();
    expect(rig.backend.committedSources.last, ['u3']);
    expect(rig.session.sent.last.text, 'A new request.');
  });

  testWidgets('caption-before-delegate does not repeat words or leave speech busy', (tester) async {
    final rig = await start(tester);
    accepted(rig, 'greeting');
    rig.backend.emit(const VoiceCaptionEvent(
      VoiceSpeaker.you, 'Hello.', finalized: true, segmentId: 'greeting',
    ));
    await tester.pump();
    expect(rig.controller.pendingSpeech, isEmpty);
    accepted(rig, 'u1');
    rig.backend.emit(const VoiceCaptionEvent(
      VoiceSpeaker.you, 'Fix the test, hold on.', finalized: true, segmentId: 'u1',
    ));
    await tester.pump();
    prompt(rig, 'Fix the test, hold on.', 'u1');
    await tester.pump();
    expect(rig.controller.pendingSpeech, 'Fix the test, hold on.');
    expect(rig.controller.canSendPending, isTrue);
    await rig.controller.sendPendingNow();
    expect(rig.session.sent.single.text, 'Fix the test, hold on.');
  });

  for (final action in ['mute', 'pause', 'stop', 'fatal', 'ended', 'session', 'workspace']) {
    testWidgets('$action cancels timer/draft/inflight; late words never submit', (tester) async {
      final rig = await start(tester);
      prompt(rig, 'Open the report.', 'u1');
      accepted(rig, 'u2');
      await tester.pump();
      switch (action) {
        case 'mute':
          await rig.controller.toggleMute();
          await rig.controller.toggleMute();
        case 'pause':
          await rig.controller.pause();
          await rig.controller.resume();
        case 'stop':
          await tester.runAsync(rig.controller.stop);
        case 'fatal':
          rig.backend.emit(const VoiceFailureEvent(VoiceProblem(
            'Microphone unavailable', recoverable: false,
          )));
        case 'ended':
          rig.backend.emit(const VoiceEndedEvent());
        case 'session':
          rig.session.sessionId = 'another-session';
          rig.session.changed();
        case 'workspace':
          rig.session.cwd = '/another/workspace';
          rig.session.changed();
      }
      await tester.pump();
      prompt(rig, 'Late words.', 'u2');
      await tester.pump();
      await tester.pump(const Duration(minutes: 2));
      expect(rig.session.sent, isEmpty);
      expect(rig.controller.pendingSpeech, isEmpty);
      expect(rig.controller.pipelineState.segments.map((s) => s.stage),
          everyElement(VoicePipelineStage.dropped));
    }, timeout: const Timeout(Duration(seconds: 30)));
  }

  testWidgets('backend replacement cancels immediately, before settings persistence', (tester) async {
    final rig = await start(tester);
    prompt(rig, 'Open the report.', 'u1');
    await tester.pump();
    await tester.runAsync(() async {
      final replaced = rig.controller.updateSettings(
        rig.controller.settings.copyWith(speechModel: 'new'),
      );
      expect(rig.controller.pendingSpeech, isEmpty);
      await replaced;
    });
    await tester.pump(const Duration(seconds: 5));
    expect(rig.session.sent, isEmpty);
    expect(rig.controller.pendingSpeech, isEmpty);
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('one delegated combined prompt completes every source segment', (tester) async {
    final rig = await start(tester);
    accepted(rig, 'u1');
    accepted(rig, 'u2');
    rig.backend.emit(const VoicePromptEvent(VoicePrompt(
      text: 'Fix the parser and its tests.', id: 'delegate',
      segmentId: 'u1', segmentIds: ['u1', 'u2'],
    )));
    await tester.pump();
    await rig.controller.sendPendingNow();
    expect(rig.session.sent, hasLength(1));
    expect(rig.controller.pipelineState.turns.single.segmentIds, ['u1', 'u2']);
    expect(rig.controller.pipelineState.segments.map((s) => s.stage),
        everyElement(VoicePipelineStage.answered));
  });

  testWidgets('pending text bound stops capture visibly without clipping or sending', (tester) async {
    final rig = await start(tester, pendingTextLimit: 20);
    const words = 'Full words beyond the safe limit, hold on.';
    prompt(rig, words, 'u1');
    await tester.pump();
    expect(rig.controller.phase, VoicePhase.failed);
    expect(rig.controller.problem?.label, 'Unsent speech limit');
    expect(rig.controller.pendingSpeech, words);
    expect(rig.controller.captions.last.text, words);
    // Subscription cancellation can resume through a root-zone future before
    // the asynchronous backend shutdown returns to the test clock.
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(rig.backend.stopped, isTrue);
    expect(rig.controller.canSendPending, isFalse);
    await tester.pump(const Duration(minutes: 2));
    expect(rig.session.sent, isEmpty);
    expect(rig.controller.pipelineState.segments.single.stage, VoicePipelineStage.dropped);
  });
}
