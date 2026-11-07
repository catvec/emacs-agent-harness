import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/models/workspace.dart';
import 'package:harness_client/src/state/workspace_buddy_controller.dart';
import 'package:harness_client/src/voice/voice_backend.dart';
import 'package:harness_client/src/voice/voice_buddy.dart';
import 'package:harness_client/src/voice/voice_models.dart';
import 'package:harness_client/src/voice/voice_settings.dart';

import 'support/buddy_fakes.dart';
import 'support/voice_fakes.dart';

void main() {
  test('opt-in is workspace-scoped, is written, and starts no call', () async {
    final rig = BuddyRig();
    expect(rig.controller.enabled, isFalse);
    expect(rig.controller.model.status.phase, BuddyPhase.off);
    await rig.controller.enable();
    expect(rig.controller.enabled, isTrue);
    expect(rig.host.writes, [true]);
    expect(rig.host.opened, isEmpty);
    expect(rig.backends, isEmpty);
    expect(rig.controller.model.status.phase, BuddyPhase.off);
    expect(rig.controller.model.canStart, isTrue);
    await rig.controller.disable();
    expect(rig.controller.enabled, isFalse);
    expect(rig.host.writes, [true, false]);
    expect(rig.host.opened, isEmpty);
    await rig.dispose();
  });

  test('restoring the opt-in shows the card off and starts nothing', () async {
    final host = BuddyHost()..enabledIds.add('w1');
    final backends = <FakeBackend>[];
    final controller = WorkspaceBuddyController(
      host: host,
      backendFactory: (settings, address, bridge) {
        final backend = FakeBackend();
        backends.add(backend);
        return backend;
      },
      mediaButtons: FakeMediaButtons(),
    );
    expect(controller.enabled, isTrue);
    expect(controller.model.status.phase, BuddyPhase.off);
    expect(controller.model.status.mic, BuddyMic.off);
    expect(host.opened, isEmpty);
    expect(backends, isEmpty);
    controller.dispose();
    await settle();
  });

  test('turn on for one workspace does not turn it on for another', () async {
    final rig = BuddyRig();
    await rig.controller.enable();
    expect(rig.host.enabledIds, {'w1'});
    rig.host.showWorkspace(work());
    await settle();
    expect(rig.controller.enabled, isFalse);
    expect(rig.controller.model.workspaceName, 'Work');
    expect(rig.controller.model.canStart, isFalse);
    await rig.dispose();
  });

  test('one Start opens one bridge and one backend', () async {
    final rig = BuddyRig();
    await rig.start();
    expect(rig.host.opens, 1);
    expect(rig.host.opened, ['s1']);
    expect(rig.backends, hasLength(1));
    expect(rig.backends.single.started, isTrue);
    expect(rig.controller.model.status.phase, BuddyPhase.listening);
    expect(rig.controller.model.status.mic, BuddyMic.live);
    expect(rig.controller.callActive, isTrue);
    expect(rig.controller.model.canStart, isFalse);
    expect(rig.controller.model.canEnd, isTrue);
    expect(rig.controller.model.workspaceName, 'Home');
    expect(rig.controller.model.threadTitle, 'Kitchen renovation');
    await rig.controller.end();
    await settle();
    expect(rig.backends.single.stopped, isTrue);
    await rig.dispose();
  });

  test('a double Start opens one call, not two', () async {
    final rig = BuddyRig();
    await rig.controller.enable();
    final first = rig.controller.start();
    final second = rig.controller.start();
    await Future.wait([first, second]);
    await settle();
    expect(rig.host.opens, 1);
    expect(rig.backends, hasLength(1));
    expect(rig.controller.model.status.phase, BuddyPhase.listening);
    await rig.controller.end();
    await rig.dispose();
  });

  test('Start while starting is ignored', () async {
    final backend = FakeBackend()..startGate = Completer<void>();
    final rig = BuddyRig(backends: () => backend);
    await rig.controller.enable();
    final first = rig.controller.start();
    await settle();
    await rig.controller.start();
    expect(rig.host.opens, 1);
    expect(rig.backends, hasLength(1));
    expect(rig.controller.model.status.phase, BuddyPhase.starting);
    expect(rig.controller.model.status.mic, BuddyMic.starting);
    backend.startGate!.complete();
    await first;
    await settle();
    expect(rig.controller.model.status.phase, BuddyPhase.listening);
    await rig.controller.end();
    await rig.dispose();
  });

  test('End during Start closes the backend that was opening', () async {
    final backend = FakeBackend()..startGate = Completer<void>();
    final rig = BuddyRig(backends: () => backend);
    await rig.controller.enable();
    final starting = rig.controller.start();
    await settle();
    final ending = rig.controller.end();
    backend.startGate!.complete();
    await Future.wait([starting, ending]);
    await settle();
    expect(backend.stopped, isTrue);
    expect(rig.controller.voice, isNull);
    expect(rig.controller.model.status.phase, BuddyPhase.off);
    expect(rig.controller.model.status.mic, BuddyMic.off);
    expect(rig.host.session.replies, isEmpty);
    expect(rig.host.session.sessions, isEmpty);
    await rig.dispose();
  });

  test('Ending is shown while the backend is being released', () async {
    final backend = FakeBackend()..stopGate = Completer<void>();
    final rig = BuddyRig(backends: () => backend);
    await rig.start();
    final ending = rig.controller.end();
    await settle();
    expect(rig.controller.model.status.phase, BuddyPhase.ending);
    expect(rig.controller.model.status.mic, BuddyMic.closing);
    expect(rig.controller.model.canEnd, isFalse);
    backend.stopGate!.complete();
    await ending;
    await settle();
    expect(rig.controller.model.status.phase, BuddyPhase.off);
    expect(rig.controller.model.status.mic, BuddyMic.off);
    await rig.dispose();
  });

  for (final phase in [
    VoicePhase.hearing,
    VoicePhase.transcribing,
    VoicePhase.thinking,
    VoicePhase.speaking,
  ]) {
    test(
      'End during ${phase.name} releases capture and sends nothing more',
      () async {
        final rig = BuddyRig();
        await rig.start();
        rig.backends.single.emit(VoicePhaseEvent(phase));
        await settle();
        await rig.controller.end();
        await settle();
        expect(rig.backends.single.stopped, isTrue);
        expect(rig.controller.voice, isNull);
        expect(rig.controller.model.status.mic, BuddyMic.off);
        rig.backends.single.emit(
          const VoicePromptEvent(VoicePrompt(text: 'late words')),
        );
        await settle();
        expect(rig.host.session.sent, isEmpty);
        rig.host.session.reply('a late answer');
        await settle();
        expect(rig.backends.single.spoken, isEmpty);
        await rig.dispose();
      },
    );
  }

  test(
    'End during a prompt send stops capture and sends no second prompt',
    () async {
      final rig = BuddyRig();
      await rig.start();
      rig.host.session.sendGate = Completer<void>();
      rig.backends.single.emit(
        const VoicePromptEvent(VoicePrompt(text: 'one message')),
      );
      await settle();
      expect(rig.host.session.sent, hasLength(1));
      await rig.controller.end();
      await settle();
      expect(rig.controller.model.status.mic, BuddyMic.off);
      expect(rig.backends.single.stopped, isTrue);
      rig.host.session.sendGate!.complete();
      rig.backends.single.emit(
        const VoicePromptEvent(VoicePrompt(text: 'a later message')),
      );
      await settle();
      expect(rig.host.session.sent, hasLength(1));
      await rig.dispose();
    },
  );

  test(
    'repeated Start and End keeps one call and releases every one',
    () async {
      final rig = BuddyRig();
      await rig.controller.enable();
      for (var index = 0; index < 5; index++) {
        await rig.controller.start();
        await settle();
        expect(rig.backends, hasLength(index + 1));
        expect(rig.backends[index].started, isTrue);
        expect(rig.controller.model.status.phase, BuddyPhase.listening);
        await rig.controller.end();
        await settle();
        expect(rig.backends[index].stopped, isTrue);
        expect(rig.controller.voice, isNull);
      }
      expect(rig.host.session.replies, isEmpty);
      expect(rig.host.session.sessions, isEmpty);
      await rig.dispose();
    },
  );

  test('Start after End creates a new call on the same session', () async {
    final rig = BuddyRig();
    await rig.start();
    await rig.controller.end();
    await settle();
    await rig.controller.start();
    await settle();
    expect(rig.backends, hasLength(2));
    expect(rig.backends.first.stopped, isTrue);
    expect(rig.backends.last.started, isTrue);
    expect(rig.host.opened, ['s1', 's1']);
    await rig.controller.end();
    await rig.dispose();
  });

  test('an unexpected backend end stops the call and says Call lost', () async {
    final rig = BuddyRig();
    await rig.start();
    rig.backends.single.emit(const VoiceEndedEvent());
    await settle();
    expect(rig.controller.voice, isNull);
    expect(rig.backends.single.stopped, isTrue);
    expect(rig.controller.model.status.phase, BuddyPhase.off);
    expect(rig.controller.model.status.mic, BuddyMic.off);
    expect(rig.controller.model.note, 'Call lost');
    expect(rig.controller.model.canStart, isTrue);
    await rig.dispose();
  });

  test(
    'a lost harness connection ends capture and waits for a new Start',
    () async {
      final rig = BuddyRig();
      await rig.start();
      final backend = rig.backends.single;
      rig.host.setConnection(BuddyConnection.reconnecting);
      await settle();
      expect(backend.stopped, isTrue);
      expect(rig.controller.voice, isNull);
      expect(rig.controller.model.status.phase, BuddyPhase.off);
      expect(rig.controller.model.status.mic, BuddyMic.off);
      expect(rig.controller.model.note, 'Connection lost');
      expect(rig.controller.model.connection.label, 'Reconnecting');
      expect(rig.controller.model.canStart, isFalse);
      rig.host.setConnection(BuddyConnection.connected);
      await settle();
      expect(rig.controller.model.connection.label, 'Connected');
      expect(rig.controller.model.canStart, isTrue);
      // Nothing resumes by itself.
      expect(rig.host.opens, 1);
      expect(rig.controller.voice, isNull);
      await rig.controller.start();
      await settle();
      expect(rig.host.opens, 2);
      expect(rig.controller.model.note, isNull);
      await rig.controller.end();
      await rig.dispose();
    },
  );

  test('a workspace change ends the call before the card rebinds', () async {
    final rig = BuddyRig();
    await rig.start();
    final backend = rig.backends.single;
    rig.host.showWorkspace(work());
    await settle();
    expect(backend.stopped, isTrue);
    expect(rig.controller.voice, isNull);
    expect(rig.controller.enabled, isFalse);
    expect(rig.controller.model.workspaceName, 'Work');
    expect(rig.controller.model.note, 'No live episode');
    await rig.dispose();
  });

  test('a thread change in the same workspace keeps the pinned call', () async {
    final rig = BuddyRig();
    await rig.start();
    rig.host.showThread(
      const WorkspaceThread(id: 't2', title: 'Harness memory', state: 'parked'),
    );
    await settle();
    expect(rig.controller.voice, isNotNull);
    expect(rig.controller.model.threadTitle, 'Kitchen renovation');
    expect(rig.controller.model.workspaceName, 'Home');
    await rig.controller.end();
    await rig.dispose();
  });

  test('turning the buddy off keeps the workspace call in the bar', () async {
    final rig = BuddyRig();
    await rig.start();
    final backend = rig.backends.single;
    await rig.controller.disable();
    await settle();
    // The card is the away surface; the call is the app's, in the in-call
    // bar, with its microphone and End in sight.
    expect(backend.stopped, isFalse);
    expect(rig.controller.voice, isNotNull);
    expect(rig.controller.inCall, isTrue);
    expect(rig.controller.enabled, isFalse);
    expect(rig.host.opened, ['s1']);
    // End still ends it, and then the bar has nothing to show.
    await rig.controller.end();
    await settle();
    expect(backend.stopped, isTrue);
    expect(rig.controller.inCall, isFalse);
    await rig.dispose();
  });

  test('a call has a surface from Starting until it is ended', () async {
    final rig = BuddyRig();
    expect(rig.controller.inCall, isFalse);
    await rig.controller.enable();
    final start = rig.controller.start();
    expect(rig.controller.inCall, isTrue);
    await start;
    await settle();
    expect(rig.controller.inCall, isTrue);
    expect(rig.controller.callViewOpen, isFalse);
    rig.controller.callViewOpen = true;
    expect(rig.controller.callViewOpen, isTrue);
    rig.controller.callViewOpen = false;
    await rig.controller.end();
    await settle();
    expect(rig.controller.inCall, isFalse);
    await rig.dispose();
  });

  test(
    'disposal stops the backend and releases the session listeners',
    () async {
      final rig = BuddyRig();
      await rig.start();
      final backend = rig.backends.single;
      rig.controller.dispose();
      await settle();
      expect(backend.stopped, isTrue);
      expect(rig.host.session.replies, isEmpty);
      expect(rig.host.session.sessions, isEmpty);
      // A host notification after disposal must not touch the disposed state.
      rig.host.setConnection(BuddyConnection.reconnecting);
      await settle();
    },
  );

  test(
    'permission denied fails honestly and Retry starts a new call',
    () async {
      final rig = BuddyRig();
      await rig.start();
      rig.backends.single.emit(
        const VoiceFailureEvent(
          VoiceProblem(
            'Microphone permission denied',
            detail: 'NotAllowedError: permission denied',
            recoverable: false,
          ),
        ),
      );
      await settle();
      expect(rig.controller.model.status.phase, BuddyPhase.failed);
      expect(rig.controller.model.status.mic, BuddyMic.off);
      expect(
        rig.controller.model.problem?.label,
        'Microphone permission denied',
      );
      expect(rig.controller.model.problem?.detail, contains('NotAllowedError'));
      expect(rig.controller.model.canRetry, isTrue);
      expect(rig.controller.model.canStart, isTrue);
      await rig.controller.retry();
      await settle();
      expect(rig.backends, hasLength(2));
      expect(rig.backends.first.stopped, isTrue);
      expect(rig.controller.model.status.phase, BuddyPhase.listening);
      expect(rig.controller.model.problem, isNull);
      await rig.controller.end();
      await rig.dispose();
    },
  );

  test('a fatal failure is dismissed with End', () async {
    final rig = BuddyRig();
    await rig.start();
    rig.backends.single.emit(
      const VoiceFailureEvent(
        VoiceProblem('Microphone permission denied', recoverable: false),
      ),
    );
    await settle();
    expect(rig.controller.model.status.phase, BuddyPhase.failed);
    expect(rig.controller.inCall, isTrue);
    expect(rig.controller.model.canEnd, isTrue);
    await rig.controller.end();
    await settle();
    expect(rig.controller.inCall, isFalse);
    expect(rig.controller.voice, isNull);
    expect(rig.backends.single.stopped, isTrue);
    await rig.dispose();
  });

  test(
    'a recoverable problem keeps listening and Retry restarts the stream',
    () async {
      final rig = BuddyRig();
      await rig.start();
      rig.backends.single.emit(
        const VoiceFailureEvent(
          VoiceProblem('Transcription failed', detail: 'timeout'),
        ),
      );
      await settle();
      expect(rig.controller.model.status.phase, BuddyPhase.listening);
      expect(rig.controller.model.problem?.label, 'Transcription failed');
      expect(rig.controller.model.canRetry, isTrue);
      await rig.controller.retry();
      await settle();
      expect(rig.backends, hasLength(2));
      expect(rig.backends.first.stopped, isTrue);
      expect(rig.controller.model.status.phase, BuddyPhase.listening);
      await rig.controller.end();
      await rig.dispose();
    },
  );

  test('an unavailable session is a failed Start, not a recording', () async {
    final rig = BuddyRig();
    rig.host.noBridge = true;
    await rig.controller.enable();
    await rig.controller.start();
    await settle();
    expect(rig.backends, isEmpty);
    expect(rig.controller.model.status.phase, BuddyPhase.failed);
    expect(rig.controller.model.status.mic, BuddyMic.off);
    expect(rig.controller.model.problem?.label, 'Session unavailable');
    expect(rig.controller.model.note, isNull);
    await rig.dispose();
  });

  test('a throwing bridge is a failed Start with its own words', () async {
    final rig = BuddyRig();
    rig.host.bridgeError = StateError('that session is gone');
    await rig.controller.enable();
    await rig.controller.start();
    await settle();
    expect(rig.controller.model.status.phase, BuddyPhase.failed);
    expect(
      rig.controller.model.problem?.detail,
      contains('that session is gone'),
    );
    expect(rig.backends, isEmpty);
    await rig.dispose();
  });

  test('no live episode disables Start, and a call is not attempted', () async {
    final rig = BuddyRig(workspace: home(live: null));
    await rig.controller.enable();
    expect(rig.controller.model.note, 'No live episode');
    expect(rig.controller.model.canStart, isFalse);
    await rig.controller.start();
    await settle();
    expect(rig.host.opened, isEmpty);
    expect(rig.backends, isEmpty);
    await rig.dispose();
  });

  test('an unconfigured voice says Voice setup and does not start', () async {
    final rig = BuddyRig();
    rig.host.voiceSettings = const VoiceSettings(provider: VoiceProvider.live);
    await rig.controller.enable();
    expect(rig.controller.model.note, 'Voice setup');
    expect(rig.controller.model.canStart, isFalse);
    await rig.controller.start();
    await settle();
    expect(rig.host.opened, isEmpty);
    expect(rig.backends, isEmpty);
    await rig.dispose();
  });

  test('mute, pause and interrupt reach the existing controller', () async {
    final rig = BuddyRig();
    await rig.start();
    final backend = rig.backends.single;
    await rig.controller.toggleMute();
    expect(backend.muted, isTrue);
    expect(rig.controller.model.muted, isTrue);
    expect(rig.controller.model.status.mic, BuddyMic.muted);
    await rig.controller.toggleMute();
    expect(backend.muted, isFalse);
    await rig.controller.togglePause();
    expect(backend.paused, isTrue);
    expect(rig.controller.model.paused, isTrue);
    expect(rig.controller.model.status.phase, BuddyPhase.paused);
    await rig.controller.togglePause();
    expect(backend.paused, isFalse);
    await rig.controller.interrupt();
    expect(backend.interrupts, 1);
    await rig.controller.end();
    await rig.dispose();
  });

  test(
    'a changed voice setup is saved and applied to a running call',
    () async {
      final rig = BuddyRig();
      await rig.start();
      final next = rig.host.voiceSettings.copyWith(
        clipDelivery: ClipDelivery.transcript,
      );
      await rig.controller.applyVoiceSettings(next);
      await settle();
      expect(rig.host.voiceSettings, next);
      // The provider restarted, because the delivery changed.
      expect(rig.backends, hasLength(2));
      expect(rig.backends.first.stopped, isTrue);
      await rig.controller.end();
      await rig.dispose();
    },
  );
}
