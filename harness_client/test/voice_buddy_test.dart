import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/voice/voice_backend.dart';
import 'package:harness_client/src/voice/voice_buddy.dart';
import 'package:harness_client/src/voice/voice_models.dart';

import 'support/voice_fakes.dart';

Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  group('buddy status follows the reported controller state', () {
    test('no call is off, with the microphone off', () {
      final status = buddyStatusFor(null);
      expect(status.phase, BuddyPhase.off);
      expect(status.phase.label, 'Off');
      expect(status.mic, BuddyMic.off);
      expect(status.mic.label, 'Mic off');
      expect(status.showsLevel, isFalse);
    });

    test('a starting backend is Starting, not Listening', () {
      final rig = Rig();
      rig.controller.started = true;
      rig.controller.phase = VoicePhase.connecting;
      final status = buddyStatusFor(rig.controller);
      expect(status.phase, BuddyPhase.starting);
      expect(status.mic, BuddyMic.starting);
      expect(rig.controller.microphoneOpen, isFalse);
    });

    test('listening is the backend listening, with capture live', () {
      final rig = Rig();
      rig.controller.started = true;
      rig.controller.phase = VoicePhase.listening;
      final status = buddyStatusFor(rig.controller);
      expect(status.phase, BuddyPhase.listening);
      expect(status.phase.label, 'Listening');
      expect(status.mic, BuddyMic.live);
      expect(rig.controller.microphoneOpen, isTrue);
    });

    test('speech onset is Hearing you before any transcript exists', () {
      final rig = Rig();
      rig.controller.started = true;
      rig.controller.phase = VoicePhase.listening;
      rig.controller.speechActive = true;
      expect(buddyPhaseFor(rig.controller), BuddyPhase.hearing);
      expect(buddyPhaseFor(rig.controller).label, 'Hearing you');
      rig.controller.speechActive = false;
      rig.controller.phase = VoicePhase.hearing;
      expect(buddyPhaseFor(rig.controller), BuddyPhase.hearing);
    });

    test('transcribing, thinking and speaking keep their own words', () {
      final rig = Rig();
      rig.controller.started = true;
      rig.controller.phase = VoicePhase.transcribing;
      expect(buddyPhaseFor(rig.controller), BuddyPhase.transcribing);
      expect(buddyPhaseFor(rig.controller).label, 'Transcribing');
      rig.controller.phase = VoicePhase.thinking;
      expect(buddyPhaseFor(rig.controller), BuddyPhase.working);
      expect(buddyPhaseFor(rig.controller).label, 'Working');
      rig.controller.phase = VoicePhase.speaking;
      expect(buddyPhaseFor(rig.controller), BuddyPhase.speaking);
      expect(buddyPhaseFor(rig.controller).label, 'Speaking');
    });

    test('mute, pause, approval, interruption and ending are distinct', () {
      final rig = Rig();
      rig.controller.started = true;
      rig.controller.phase = VoicePhase.listening;
      rig.controller.muted = true;
      expect(buddyPhaseFor(rig.controller), BuddyPhase.muted);
      expect(buddyMicFor(rig.controller), BuddyMic.muted);
      expect(rig.controller.microphoneOpen, isFalse);

      rig.controller.muted = false;
      rig.controller.paused = true;
      expect(buddyPhaseFor(rig.controller), BuddyPhase.paused);
      expect(buddyMicFor(rig.controller), BuddyMic.paused);
      expect(rig.controller.microphoneOpen, isFalse);

      rig.controller.paused = false;
      rig.session.blocked = true;
      expect(buddyPhaseFor(rig.controller), BuddyPhase.approval);
      expect(buddyPhaseFor(rig.controller).label, 'Approval needed');
      expect(buddyMicFor(rig.controller), BuddyMic.live);

      rig.session.blocked = false;
      rig.controller.phase = VoicePhase.interrupted;
      expect(buddyPhaseFor(rig.controller), BuddyPhase.interrupted);
      expect(buddyPhaseFor(rig.controller).label, 'Interrupted');

      rig.controller.paused = true;
      expect(
        buddyPhaseFor(rig.controller),
        BuddyPhase.paused,
        reason: 'pause is a real state that outranks an old interruption',
      );
    });

    test('ending is the actual stop, and ended is after it', () async {
      final rig = Rig();
      final backend = rig.backend..stopGate = Completer<void>();
      await rig.controller.start();
      await settle();
      final stopping = rig.controller.stop();
      await settle();
      expect(rig.controller.stopping, isTrue);
      expect(buddyPhaseFor(rig.controller), BuddyPhase.ending);
      expect(buddyPhaseFor(rig.controller).label, 'Ending');
      expect(buddyMicFor(rig.controller), BuddyMic.closing);
      backend.stopGate!.complete();
      await stopping;
      expect(rig.controller.stopping, isFalse);
      expect(buddyPhaseFor(rig.controller), BuddyPhase.ended);
      expect(buddyMicFor(rig.controller), BuddyMic.off);
    });

    test('failure and an unknown reported phase are said honestly', () {
      final rig = Rig();
      rig.controller.started = true;
      rig.controller.phase = VoicePhase.failed;
      expect(buddyPhaseFor(rig.controller), BuddyPhase.failed);
      expect(buddyPhaseFor(rig.controller).label, 'Failed');
      expect(buddyMicFor(rig.controller), BuddyMic.off);

      rig.controller.phase = VoicePhase.unknown;
      expect(buddyPhaseFor(rig.controller), BuddyPhase.unknown);
      expect(buddyPhaseFor(rig.controller).label, 'Status unknown');
    });
  });

  group('simultaneous states', () {
    test('hearing a person while a reply plays shows both', () {
      final rig = Rig();
      rig.controller.started = true;
      rig.controller.phase = VoicePhase.speaking;
      rig.controller.speechActive = true;
      final status = buddyStatusFor(rig.controller);
      expect(status.phase, BuddyPhase.hearing);
      expect(status.mic, BuddyMic.live);
      expect(status.output, BuddyOutput.speaking);
      expect(status.extraOutput, BuddyOutput.speaking);
      expect(status.extraOutput.label, 'Speaking');
    });

    test('hearing a person while a reply is held shows Reply held', () async {
      final rig = Rig();
      await rig.controller.start();
      await settle();
      rig.backend.emit(const VoiceHeldEvent('The merge queue has two tasks.'));
      rig.backend.emit(const VoiceSpeechEvent(true));
      rig.backend.emit(const VoicePhaseEvent(VoicePhase.hearing));
      await settle();
      final status = buddyStatusFor(rig.controller);
      expect(status.phase, BuddyPhase.hearing);
      expect(status.output, BuddyOutput.held);
      expect(status.extraOutput, BuddyOutput.held);
      expect(status.extraOutput.label, 'Reply held');
      await rig.controller.stop();
    });

    test('the agent working while a person is heard shows both', () {
      final rig = Rig();
      rig.controller.started = true;
      rig.controller.phase = VoicePhase.hearing;
      rig.session.working = true;
      final status = buddyStatusFor(rig.controller);
      expect(status.phase, BuddyPhase.hearing);
      expect(status.output, BuddyOutput.working);
      expect(status.extraOutput, BuddyOutput.working);
      expect(status.extraOutput.label, 'Working');
    });

    test('a held reply while the agent works is its own state', () async {
      final rig = Rig();
      await rig.controller.start();
      await settle();
      rig.session.working = true;
      rig.backend.emit(const VoiceHeldEvent('Held answer'));
      rig.backend.emit(const VoicePhaseEvent(VoicePhase.thinking));
      await settle();
      final status = buddyStatusFor(rig.controller);
      expect(status.phase, BuddyPhase.working);
      expect(status.output, BuddyOutput.held);
      expect(status.extraOutput, BuddyOutput.held);
      await rig.controller.stop();
    });
  });

  group('microphone activity is only what was reported', () {
    test('a level exists only after the backend reports one', () async {
      final rig = Rig();
      await rig.controller.start();
      await settle();
      var status = buddyStatusFor(rig.controller);
      expect(rig.controller.levelReported, isFalse);
      expect(status.showsLevel, isFalse);
      rig.backend.emit(const VoiceLevelEvent(0.4));
      await settle();
      status = buddyStatusFor(rig.controller);
      expect(rig.controller.levelReported, isTrue);
      expect(rig.controller.level, 0.4);
      expect(status.mic, BuddyMic.live);
      expect(status.showsLevel, isTrue);
      await rig.controller.toggleMute();
      status = buddyStatusFor(rig.controller);
      expect(status.mic, BuddyMic.muted);
      expect(status.showsLevel, isFalse);
      await rig.controller.stop();
    });

    test('a provider with no levels has no meter', () async {
      final rig = Rig();
      rig.controller.started = true;
      rig.controller.phase = VoicePhase.listening;
      expect(buddyStatusFor(rig.controller).showsLevel, isFalse);
    });

    test('idle, muted and paused never look like recording', () {
      final rig = Rig();
      final states = <BuddyMic>[];
      states.add(buddyMicFor(null));
      rig.controller.started = true;
      rig.controller.phase = VoicePhase.connecting;
      states.add(buddyMicFor(rig.controller));
      rig.controller.phase = VoicePhase.listening;
      rig.controller.muted = true;
      states.add(buddyMicFor(rig.controller));
      rig.controller.muted = false;
      rig.controller.paused = true;
      states.add(buddyMicFor(rig.controller));
      rig.controller.paused = false;
      rig.controller.phase = VoicePhase.ended;
      states.add(buddyMicFor(rig.controller));
      expect(states, [
        BuddyMic.off,
        BuddyMic.starting,
        BuddyMic.muted,
        BuddyMic.paused,
        BuddyMic.off,
      ]);
      expect(states.map((microphone) => microphone.label), [
        'Mic off',
        'Mic starting',
        'Mic muted',
        'Mic paused',
        'Mic off',
      ]);
    });
  });

  test('the copy never invents a transfer or transcoding stage', () {
    final labels = <String>[
      for (final phase in BuddyPhase.values) phase.label,
      for (final microphone in BuddyMic.values) microphone.label,
      for (final output in BuddyOutput.values) output.label,
      for (final connection in BuddyConnection.values) connection.label,
    ];
    for (final label in labels) {
      final lower = label.toLowerCase();
      expect(lower, isNot(contains('upload')));
      expect(lower, isNot(contains('transfer')));
      expect(lower, isNot(contains('transcod')));
      expect(lower, isNot(contains('progress')));
    }
    expect(
      BuddyPhase.values.map((phase) => phase.label),
      containsAll(<String>[
        'Off',
        'Starting',
        'Listening',
        'Hearing you',
        'Transcribing',
        'Working',
        'Holding reply',
        'Speaking',
        'Interrupted',
        'Muted',
        'Ending',
        'Failed',
      ]),
    );
  });

  test('the Emacs status precedence is mirrored', () {
    final rig = Rig();
    rig.controller.started = true;
    // A blocked conversation outranks a stale phase, but pause outranks both.
    rig.controller.phase = VoicePhase.thinking;
    rig.session.blocked = true;
    expect(buddyPhaseFor(rig.controller), BuddyPhase.approval);
    rig.controller.paused = true;
    expect(buddyPhaseFor(rig.controller), BuddyPhase.paused);
    // Working outranks muted: the words must say the agent works while the
    // microphone line says it is muted.
    rig.controller.paused = false;
    rig.session.blocked = false;
    rig.controller.muted = true;
    expect(buddyPhaseFor(rig.controller), BuddyPhase.working);
    expect(buddyMicFor(rig.controller), BuddyMic.muted);
  });

  test('a controller state never leaks a transfer label into the model', () {
    final rig = Rig();
    final status = buddyStatusFor(rig.controller);
    expect(status.phase.label, 'Off');
    expect(status.mic.label, 'Mic off');
  });
}
