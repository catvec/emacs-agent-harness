import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/voice/voice_backend.dart';
import 'package:harness_client/src/voice/voice_models.dart';
import 'package:harness_client/src/voice/voice_settings.dart';

import 'support/voice_fakes.dart';

Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  test('starts the configured backend and listens', () async {
    final rig = Rig();
    await rig.controller.start();
    await settle();
    expect(rig.backend.started, isTrue);
    expect(rig.builtAt, 'ws://harness.test:9999/acp');
    expect(rig.controller.phase, VoicePhase.listening);
    expect(rig.controller.displayPhase, VoicePhase.listening);
    expect(rig.controller.captions, isEmpty);
    await rig.controller.stop();
  });

  test('an unconfigured live provider fails before a backend starts', () async {
    final rig = Rig(
      settings: const VoiceSettings(provider: VoiceProvider.live),
    );
    await rig.controller.start();
    expect(rig.backend.started, isFalse);
    expect(rig.controller.phase, VoicePhase.failed);
    expect(rig.controller.problem?.label, 'Not configured');
    expect(rig.controller.problem?.recoverable, isFalse);
  });

  test('a partial caption grows in place and then settles', () async {
    final rig = Rig();
    await rig.controller.start();
    await settle();
    rig.backend.emit(
      const VoiceCaptionEvent(VoiceSpeaker.you, 'hel', finalized: false),
    );
    await settle();
    rig.backend.emit(
      const VoiceCaptionEvent(VoiceSpeaker.you, 'hello', finalized: true),
    );
    await settle();
    expect(rig.controller.captions, hasLength(1));
    expect(rig.controller.captions.single.text, 'hello');
    expect(rig.controller.captions.single.finalized, isTrue);
    rig.backend.emit(
      const VoiceCaptionEvent(VoiceSpeaker.agent, 'hi', finalized: true),
    );
    await settle();
    expect(rig.controller.captions, hasLength(2));
    expect(rig.controller.captions.last.speaker, VoiceSpeaker.agent);
    await rig.controller.stop();
  });

  test(
    'a prompt goes to the session and is shown as the person said it',
    () async {
      final rig = Rig();
      await rig.controller.start();
      await settle();
      rig.backend.emit(
        const VoicePromptEvent(VoicePrompt(text: 'open the task')),
      );
      await settle();
      expect(rig.session.sent.single.text, 'open the task');
      expect(
        rig.controller.captions.map((caption) => caption.text),
        contains('open the task'),
      );
      await rig.controller.stop();
    },
  );

  test('an audio prompt goes to the session as a clip', () async {
    final rig = Rig();
    await rig.controller.start();
    await settle();
    final audio = VoicePrompt(audio: Uint8List.fromList([1, 2, 3]));
    rig.backend.emit(VoicePromptEvent(audio));
    await settle();
    expect(rig.session.sent.single.audio, audio.audio);
    expect(rig.session.sent.single.text, isNull);
    await rig.controller.stop();
  });

  test('a completed assistant reply is shown and spoken', () async {
    final rig = Rig();
    await rig.controller.start();
    await settle();
    rig.session.reply('all tests pass');
    await settle();
    expect(rig.backend.spoken, ['all tests pass']);
    expect(rig.controller.captions.last.speaker, VoiceSpeaker.agent);
    expect(rig.controller.captions.last.text, 'all tests pass');
    await rig.controller.stop();
  });

  test('with spoken replies off the reply is still transcribed', () async {
    final rig = Rig(
      settings: const VoiceSettings(
        clipDelivery: ClipDelivery.audioPrompt,
        speakReplies: false,
      ),
    );
    await rig.controller.start();
    await settle();
    rig.session.reply('quiet');
    await settle();
    expect(rig.backend.spoken, isEmpty);
    expect(rig.controller.captions.last.text, 'quiet');
    await rig.controller.stop();
  });

  test(
    'the conversation’s state is the phase until the provider says one',
    () async {
      final rig = Rig();
      await rig.controller.start();
      await settle();
      rig.session.working = true;
      rig.session.changed();
      expect(rig.controller.displayPhase, VoicePhase.thinking);
      rig.session.working = false;
      rig.session.blocked = true;
      rig.session.changed();
      expect(rig.controller.displayPhase, VoicePhase.approval);
      rig.session.blocked = false;
      rig.session.changed();
      expect(rig.controller.displayPhase, VoicePhase.listening);
      await rig.controller.stop();
    },
  );

  test('mute and interrupt reach the provider and the screen', () async {
    final rig = Rig();
    await rig.controller.start();
    await settle();
    await rig.controller.toggleMute();
    await settle();
    expect(rig.backend.muted, isTrue);
    expect(rig.controller.muted, isTrue);
    expect(rig.controller.displayPhase, VoicePhase.muted);
    await rig.controller.toggleMute();
    await settle();
    expect(rig.backend.muted, isFalse);
    expect(rig.controller.displayPhase, VoicePhase.listening);
    await rig.controller.interrupt();
    expect(rig.backend.interrupts, 1);
    expect(rig.controller.phase, VoicePhase.interrupted);
    await rig.controller.stop();
  });

  test('a recoverable problem leaves the session listening', () async {
    final rig = Rig();
    await rig.controller.start();
    await settle();
    rig.backend.emit(
      const VoiceFailureEvent(VoiceProblem('Transcription failed')),
    );
    await settle();
    expect(rig.controller.problem?.label, 'Transcription failed');
    expect(rig.controller.phase, VoicePhase.listening);
    expect(rig.controller.displayPhase, VoicePhase.listening);
    rig.backend.emit(const VoicePhaseEvent(VoicePhase.listening));
    await settle();
    expect(rig.controller.problem, isNull);
    await rig.controller.stop();
  });

  test('a fatal problem fails and closes the backend', () async {
    final rig = Rig();
    await rig.controller.start();
    await settle();
    rig.backend.emit(
      const VoiceFailureEvent(
        VoiceProblem('Microphone unavailable', recoverable: false),
      ),
    );
    await settle();
    expect(rig.controller.phase, VoicePhase.failed);
    expect(rig.controller.problem?.recoverable, isFalse);
    expect(rig.backend.stopped, isTrue);
  });

  test('a changed provider restarts the backend and is saved', () async {
    final rig = Rig();
    await rig.controller.start();
    await settle();
    final next = rig.controller.settings.copyWith(
      provider: VoiceProvider.live,
      realtimeEndpoint: 'https://api.openai.com/v1',
    );
    await rig.controller.updateSettings(next);
    await settle();
    expect(rig.saved, [next]);
    expect(rig.builtWith, next);
    expect(rig.controller.settings, next);
    await rig.controller.stop();
  });

  test('a change that only speaks less does not restart the stream', () async {
    final rig = Rig();
    await rig.controller.start();
    await settle();
    final next = rig.controller.settings.copyWith(speakReplies: false);
    await rig.controller.updateSettings(next);
    expect(rig.saved, [next]);
    expect(rig.controller.phase, VoicePhase.listening);
    await rig.controller.stop();
  });

  test('stop ends the screen and lets the session go', () async {
    final rig = Rig();
    await rig.controller.start();
    await settle();
    expect(rig.session.replies, hasLength(1));
    expect(rig.session.sessions, hasLength(1));
    await rig.controller.stop();
    expect(rig.controller.phase, VoicePhase.ended);
    expect(rig.session.replies, isEmpty);
    expect(rig.session.sessions, isEmpty);
    expect(rig.backend.stopped, isTrue);
  });

  test(
    'the factory is not called again when a started screen is stopped',
    () async {
      final rig = Rig();
      await rig.controller.start();
      await rig.controller.stop();
      await rig.controller.stop();
      expect(rig.controller.phase, VoicePhase.ended);
    },
  );

  int occurrences(String needle, String haystack) =>
      needle.allMatches(haystack).length;

  test('speech holds a reply before its transcript exists', () async {
    final rig = Rig();
    await rig.controller.start();
    await settle();
    rig.backend.emit(const VoiceSpeechEvent(true));
    await settle();
    rig.session.reply('All tests pass.');
    await settle();
    expect(rig.backend.spoken, isEmpty);
    expect(rig.controller.holdingOutput, isTrue);

    rig.backend.emit(
      const VoicePromptEvent(
        VoicePrompt(
          text: 'open the merge queue',
          id: 'u-1',
          pending: ['The sidecar held this.'],
        ),
      ),
    );
    await settle();
    await settle();
    expect(rig.session.sent, hasLength(1));
    final prompt = rig.session.sent.single;
    expect(prompt.text, contains('open the merge queue'));
    expect(prompt.text, contains('<voice-turn-context>'));
    expect(prompt.text, contains('All tests pass.'));
    expect(prompt.text, contains('The sidecar held this.'));
    expect(occurrences('All tests pass.', prompt.text!), 1);
    expect(occurrences('The sidecar held this.', prompt.text!), 1);
    expect(rig.backend.spoken, isEmpty);

    // The same provider event is not a second prompt.
    rig.backend.emit(
      const VoicePromptEvent(
        VoicePrompt(text: 'open the merge queue', id: 'u-1'),
      ),
    );
    await settle();
    expect(rig.session.sent, hasLength(1));

    // Consumed output is context, not a stale replay after speech ends.
    rig.backend.emit(const VoiceSpeechEvent(false));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(rig.backend.spoken, isEmpty);
    await rig.controller.stop();
  });

  test('a false trigger releases held output after its grace', () async {
    final rig = Rig(pendingReleaseDelay: const Duration(milliseconds: 25));
    await rig.controller.start();
    await settle();
    rig.backend.emit(const VoicePhaseEvent(VoicePhase.transcribing));
    await settle();
    rig.session.reply('The parser is ready.');
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(rig.backend.spoken, isEmpty, reason: 'a transcript is pending');
    rig.backend.emit(const VoiceSpeechEvent(false));
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(rig.backend.spoken, isEmpty, reason: 'still transcribing');
    rig.backend.emit(const VoicePhaseEvent(VoicePhase.listening));
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(rig.backend.spoken, ['The parser is ready.']);
    await rig.controller.stop();
  });

  test(
    'a real utterance consumes the held reply instead of replaying it',
    () async {
      final rig = Rig(pendingReleaseDelay: const Duration(milliseconds: 25));
      await rig.controller.start();
      await settle();
      rig.backend.emit(const VoiceSpeechEvent(true));
      await settle();
      rig.session.reply('Stale update.');
      await settle();
      rig.backend.emit(const VoiceSpeechEvent(false));
      rig.backend.emit(
        const VoicePromptEvent(VoicePrompt(text: 'what changed', id: 'u-1')),
      );
      await settle();
      expect(rig.session.sent.single.text, contains('Stale update.'));
      rig.backend.emit(const VoicePhaseEvent(VoicePhase.listening));
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(rig.backend.spoken, isEmpty);
      await rig.controller.stop();
    },
  );

  test('pause and mute drop held output and never replay it', () async {
    final rig = Rig(pendingReleaseDelay: const Duration(milliseconds: 25));
    await rig.controller.start();
    await settle();
    rig.backend.emit(const VoiceSpeechEvent(true));
    await settle();
    rig.session.reply('During speech.');
    await settle();
    await rig.controller.pause();
    expect(rig.controller.paused, isTrue);
    expect(rig.backend.paused, isTrue);
    expect(rig.controller.displayPhase, VoicePhase.paused);
    rig.backend.emit(const VoiceSpeechEvent(false));
    rig.backend.emit(const VoicePhaseEvent(VoicePhase.listening));
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(rig.backend.spoken, isEmpty);
    await rig.controller.resume();
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(rig.backend.spoken, isEmpty, reason: 'resume replays nothing');
    expect(rig.controller.displayPhase, VoicePhase.listening);

    rig.backend.emit(const VoiceSpeechEvent(true));
    await settle();
    rig.session.reply('While muted.');
    await settle();
    await rig.controller.toggleMute();
    rig.backend.emit(const VoiceSpeechEvent(false));
    rig.backend.emit(const VoicePhaseEvent(VoicePhase.muted));
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(rig.backend.spoken, isEmpty);
    expect(rig.controller.muted, isTrue);
    await rig.controller.stop();
  });

  test('a backend-held reply follows the speech gate', () async {
    final rig = Rig(pendingReleaseDelay: const Duration(milliseconds: 25));
    await rig.controller.start();
    await settle();
    rig.backend.emit(const VoiceSpeechEvent(true));
    await settle();
    rig.backend.emit(const VoiceHeldEvent('Backend held.'));
    await settle();
    expect(rig.controller.holdingOutput, isTrue);
    rig.backend.emit(const VoiceSpeechEvent(false));
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(rig.backend.spoken, ['Backend held.']);
    await rig.controller.stop();
  });

  test('a media button toggles pause and stops with the screen', () async {
    final rig = Rig();
    await rig.controller.start();
    await settle();
    expect(rig.media.starts, 1);
    rig.media.press();
    await settle();
    expect(rig.controller.paused, isTrue);
    rig.media.press();
    await settle();
    expect(rig.controller.paused, isFalse);
    await rig.controller.stop();
    expect(rig.media.stops, 1);
  });

  test('pending context keeps the full result over its pieces', () async {
    final rig = Rig();
    await rig.controller.start();
    await settle();
    rig.backend.emit(const VoiceSpeechEvent(true));
    await settle();
    rig.backend.emit(
      const VoicePromptEvent(
        VoicePrompt(
          text: 'what changed',
          id: 'u-1',
          pending: ['The parser is ready.', 'The parser is ready. Tests pass.'],
        ),
      ),
    );
    await settle();
    final prompt = rig.session.sent.single;
    expect(occurrences('The parser is ready.', prompt.text!), 1);
    expect(occurrences('Tests pass.', prompt.text!), 1);
    await rig.controller.stop();
  });

  test('a prompt id is sent once and late prompts still arrive', () async {
    final rig = Rig();
    await rig.controller.start();
    await settle();
    rig.backend.emit(
      const VoicePromptEvent(VoicePrompt(text: 'second', id: 'u-2')),
    );
    rig.backend.emit(
      const VoicePromptEvent(VoicePrompt(text: 'first', id: 'u-1')),
    );
    rig.backend.emit(
      const VoicePromptEvent(VoicePrompt(text: 'first again', id: 'u-1')),
    );
    await settle();
    expect(rig.session.sent.map((prompt) => prompt.displayText), [
      'second',
      'first',
    ]);
    await rig.controller.stop();
  });
}
