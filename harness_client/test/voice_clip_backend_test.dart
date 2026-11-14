import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/voice/clip_voice_backend.dart';
import 'package:harness_client/src/voice/voice_audio.dart';
import 'package:harness_client/src/voice/voice_backend.dart';
import 'package:harness_client/src/voice/voice_models.dart';
import 'package:harness_client/src/voice/voice_settings.dart';

const _vad = VoiceActivityConfig(
  startHold: Duration(milliseconds: 60),
  endSilence: Duration(milliseconds: 120),
  preRoll: Duration(milliseconds: 60),
  trailingKeep: Duration(milliseconds: 60),
  minUtterance: Duration(milliseconds: 100),
  maxUtterance: Duration(seconds: 10),
);

Uint8List _bytes(Int16List samples) {
  final data = ByteData(samples.length * 2);
  for (var i = 0; i < samples.length; i++) {
    data.setInt16(i * 2, samples[i], Endian.little);
  }
  return data.buffer.asUint8List();
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void _hearUtterance(MemoryVoiceMicrophone mic, {int speechFrames = 6}) {
  for (var i = 0; i < speechFrames; i++) {
    mic.hear(_bytes(voiceFrame(samples: 320, amplitude: 0.2)));
  }
  for (var i = 0; i < 10; i++) {
    mic.hear(_bytes(voiceFrame(samples: 320, amplitude: 0.001)));
  }
}

ClipVoiceBackend _backend(
  MemoryVoiceMicrophone mic,
  VoiceTranscriber transcriber, {
  ClipDelivery delivery = ClipDelivery.transcript,
  VoiceActivityConfig vadConfig = _vad,
}) => ClipVoiceBackend(
  microphone: mic,
  transcriber: transcriber,
  speech: RecordingVoiceSpeech(),
  delivery: delivery,
  endpoint: 'https://speech.test/inference',
  model: '',
  token: '',
  language: 'en',
  speakReplies: false,
  vadConfig: vadConfig,
);

void main() {
  test('prompt copies preserve capture metadata', () {
    const ordinary = VoicePrompt(text: 'ordinary');
    expect(ordinary.truncated, isFalse);
    const cut = VoicePrompt(
      text: 'unfinished',
      id: 'u-1',
      segmentId: 's-1',
      segmentIds: ['s-1', 's-2'],
      truncated: true,
    );
    final copy = cut.copyWith(text: 'unfinished and more');
    expect(copy.truncated, isTrue);
    expect(copy.id, cut.id);
    expect(copy.segmentId, cut.segmentId);
    expect(copy.segmentIds, ['s-1', 's-2']);
    expect(copy.copyWith(truncated: false).truncated, isFalse);
  });

  for (final delivery in ClipDelivery.values) {
    test('recording-limit metadata survives $delivery, not normal silence', () async {
      final mic = MemoryVoiceMicrophone();
      final backend = _backend(
        mic,
        ScriptedVoiceTranscriber(['first part', 'continued thought']),
        delivery: delivery,
        vadConfig: const VoiceActivityConfig(
          startHold: Duration(milliseconds: 60),
          endSilence: Duration(milliseconds: 120),
          preRoll: Duration(milliseconds: 60),
          trailingKeep: Duration(milliseconds: 60),
          minUtterance: Duration(milliseconds: 100),
          maxUtterance: Duration(milliseconds: 300),
        ),
      );
      final events = <VoiceBackendEvent>[];
      backend.events.listen(events.add);
      await backend.start();
      _hearUtterance(mic, speechFrames: 20);
      await _settle();
      await _settle();
      final prompts = events.whereType<VoicePromptEvent>().map((event) => event.prompt);
      expect(prompts.map((prompt) => prompt.truncated), [true, false]);
      expect(prompts.map((prompt) => prompt.id), ['u-1', 'u-2']);
      await backend.stop();
    });
  }

  for (final action in ['mute', 'pause']) {
    for (final failure in [false, true]) {
      test('$action cancels queued/in-flight transcription, stale failure=$failure', () async {
        final mic = MemoryVoiceMicrophone();
        final transcriber = _DeferredTranscriber();
        final backend = _backend(mic, transcriber);
        final events = <VoiceBackendEvent>[];
        backend.events.listen(events.add);
        await backend.start();
        _hearUtterance(mic);
        _hearUtterance(mic);
        await _settle();
        expect(transcriber.results, hasLength(1));
        expect(
          events.whereType<VoiceSegmentEvent>().where((event) => event.stage == VoiceSegmentStage.accepted),
          hasLength(2),
        );
        if (action == 'mute') {
          await backend.setMuted(true);
          await backend.setMuted(false);
        } else {
          await backend.pause();
          await backend.resume();
        }
        await _settle();
        expect(events.whereType<VoicePhaseEvent>().last.phase, VoicePhase.listening);
        final cancelled = events.whereType<VoiceSegmentEvent>().where(
          (event) => event.drop == VoiceSegmentDrop.cancelled,
        );
        expect(cancelled.map((event) => event.id), ['u-1', 'u-2']);

        // A new generation can run even while the old network call hangs.
        _hearUtterance(mic);
        await _settle();
        expect(transcriber.results, hasLength(2));
        if (failure) {
          transcriber.results.first.completeError(StateError('stale failure'));
        } else {
          transcriber.results.first.complete('stale words');
        }
        await _settle();
        expect(events.whereType<VoicePromptEvent>(), isEmpty);
        expect(events.whereType<VoiceFailureEvent>(), isEmpty);
        expect(events.whereType<VoicePhaseEvent>().last.phase, VoicePhase.transcribing);
        transcriber.results.last.complete('fresh words');
        await _settle();
        final prompt = events.whereType<VoicePromptEvent>().single.prompt;
        expect(prompt.text, 'fresh words');
        expect(prompt.segmentId, 'u-3');
        expect(events.whereType<VoiceCaptionEvent>().single.text, 'fresh words');
        expect(transcriber.results, hasLength(2), reason: 'cancelled queue never transcribed');
        await backend.stop();
      });
    }
  }

  test('mute invalidates capture before platform mute finishes', () async {
    final mic = _DelayedMuteMicrophone();
    final transcriber = _DeferredTranscriber();
    final backend = _backend(mic, transcriber);
    final events = <VoiceBackendEvent>[];
    backend.events.listen(events.add);
    await backend.start();
    _hearUtterance(mic);
    await _settle();
    final muted = backend.setMuted(true);
    transcriber.results.single.complete('too late');
    _hearUtterance(mic); // The platform has not muted, but the backend has.
    await _settle();
    expect(events.whereType<VoicePromptEvent>(), isEmpty);
    expect(transcriber.results, hasLength(1));
    expect(
      events.whereType<VoiceSegmentEvent>().where((event) => event.drop == VoiceSegmentDrop.cancelled),
      hasLength(1),
    );
    mic.muteReady.complete();
    await muted;
    await backend.stop();
  });

  test('stop accounts for cancelled transcription without a stale prompt', () async {
    final mic = MemoryVoiceMicrophone();
    final transcriber = _DeferredTranscriber();
    final backend = _backend(mic, transcriber);
    final events = <VoiceBackendEvent>[];
    backend.events.listen(events.add);
    await backend.start();
    _hearUtterance(mic);
    _hearUtterance(mic);
    await _settle();
    await backend.stop();
    transcriber.results.single.completeError(StateError('closed request'));
    await _settle();
    expect(events.whereType<VoicePromptEvent>(), isEmpty);
    expect(events.whereType<VoiceFailureEvent>(), isEmpty);
    expect(events.whereType<VoiceCaptionEvent>(), isEmpty);
    final cancelled = events.whereType<VoiceSegmentEvent>().where(
      (event) => event.drop == VoiceSegmentDrop.cancelled,
    );
    expect(cancelled.map((event) => event.id), ['u-1', 'u-2']);
    expect(events.last, isA<VoiceEndedEvent>());
  });

  test('a spoken sentence becomes one transcribed prompt', () async {
    final mic = MemoryVoiceMicrophone();
    final transcriber = ScriptedVoiceTranscriber(['open the merge queue task']);
    final speech = RecordingVoiceSpeech();
    final backend = ClipVoiceBackend(
      microphone: mic,
      transcriber: transcriber,
      speech: speech,
      delivery: ClipDelivery.transcript,
      endpoint: 'https://speech.test/inference',
      model: '',
      token: '',
      language: 'en',
      speakReplies: true,
      vadConfig: _vad,
    );
    final events = <VoiceBackendEvent>[];
    backend.events.listen(events.add);
    await backend.start();
    await _settle();
    expect(
      events.whereType<VoicePhaseEvent>().last.phase,
      VoicePhase.listening,
    );

    for (var i = 0; i < 6; i++) {
      mic.hear(_bytes(voiceFrame(samples: 320, amplitude: 0.2)));
    }
    for (var i = 0; i < 10; i++) {
      mic.hear(_bytes(voiceFrame(samples: 320, amplitude: 0.001)));
    }
    await _settle();
    await _settle();

    expect(transcriber.heard, hasLength(1));
    final duration = wavDuration(transcriber.heard.single);
    expect(duration, isNotNull);
    expect(duration!.inMilliseconds, greaterThanOrEqualTo(100));
    expect(
      events.whereType<VoiceCaptionEvent>().map((event) => event.text),
      contains('open the merge queue task'),
    );
    final prompt = events.whereType<VoicePromptEvent>().single;
    expect(prompt.prompt.text, 'open the merge queue task');
    expect(prompt.prompt.audio, isNull);
    expect(prompt.prompt.truncated, isFalse);
    expect(prompt.prompt.segmentIds, [prompt.prompt.segmentId]);
    expect(events.whereType<VoicePhaseEvent>().last.phase, VoicePhase.thinking);
    await backend.stop();
  });

  test(
    'an audio prompt carries the WAV itself and needs no speech server',
    () async {
      final mic = MemoryVoiceMicrophone();
      final transcriber = ScriptedVoiceTranscriber(['never asked']);
      final backend = ClipVoiceBackend(
        microphone: mic,
        transcriber: transcriber,
        speech: RecordingVoiceSpeech(),
        delivery: ClipDelivery.audioPrompt,
        endpoint: '',
        model: '',
        token: '',
        language: '',
        speakReplies: false,
        vadConfig: _vad,
      );
      final events = <VoiceBackendEvent>[];
      backend.events.listen(events.add);
      await backend.start();
      await _settle();
      for (var i = 0; i < 6; i++) {
        mic.hear(_bytes(voiceFrame(samples: 320, amplitude: 0.2)));
      }
      for (var i = 0; i < 10; i++) {
        mic.hear(_bytes(voiceFrame(samples: 320, amplitude: 0.001)));
      }
      await _settle();
      await _settle();
      final prompt = events.whereType<VoicePromptEvent>().single;
      expect(prompt.prompt.audio, isNotNull);
      expect(wavDuration(prompt.prompt.audio!), isNotNull);
      expect(prompt.prompt.text, isNull);
      expect(transcriber.heard, isEmpty);
      expect(
        events.whereType<VoiceCaptionEvent>().single.text,
        'Voice message',
      );
      await backend.stop();
    },
  );

  test('muting the microphone stops the clip from growing', () async {
    final mic = MemoryVoiceMicrophone();
    final transcriber = ScriptedVoiceTranscriber(['should not be heard']);
    final backend = ClipVoiceBackend(
      microphone: mic,
      transcriber: transcriber,
      speech: RecordingVoiceSpeech(),
      delivery: ClipDelivery.transcript,
      endpoint: 'https://speech.test/inference',
      model: '',
      token: '',
      language: '',
      speakReplies: false,
      vadConfig: _vad,
    );
    final events = <VoiceBackendEvent>[];
    backend.events.listen(events.add);
    await backend.start();
    await _settle();
    await backend.setMuted(true);
    expect(mic.muted, isTrue);
    for (var i = 0; i < 6; i++) {
      mic.hear(_bytes(voiceFrame(samples: 320, amplitude: 0.2)));
    }
    for (var i = 0; i < 10; i++) {
      mic.hear(_bytes(voiceFrame(samples: 320, amplitude: 0.001)));
    }
    await _settle();
    expect(transcriber.heard, isEmpty);
    expect(events.whereType<VoicePhaseEvent>().last.phase, VoicePhase.muted);
    await backend.setMuted(false);
    await _settle();
    expect(
      events.whereType<VoicePhaseEvent>().last.phase,
      VoicePhase.listening,
    );
    await backend.stop();
  });

  test('a reply is spoken and can be interrupted', () async {
    final mic = MemoryVoiceMicrophone();
    final speech = RecordingVoiceSpeech();
    final backend = ClipVoiceBackend(
      microphone: mic,
      transcriber: ScriptedVoiceTranscriber(const []),
      speech: speech,
      delivery: ClipDelivery.audioPrompt,
      endpoint: '',
      model: '',
      token: '',
      language: '',
      speakReplies: true,
      vadConfig: _vad,
    );
    final events = <VoiceBackendEvent>[];
    backend.events.listen(events.add);
    await backend.start();
    await _settle();

    final speaking = backend.speak('all tests pass');
    await _settle();
    expect(speech.spoken, ['all tests pass']);
    expect(events.whereType<VoicePhaseEvent>().last.phase, VoicePhase.speaking);
    speech.finish();
    await speaking;
    await _settle();
    expect(
      events.whereType<VoicePhaseEvent>().last.phase,
      VoicePhase.listening,
    );

    final again = backend.speak('more words');
    await _settle();
    await backend.interrupt();
    await again;
    expect(speech.stops, greaterThan(0));
    await backend.stop();
  });

  test('a transcription failure is a problem, not the end', () async {
    final mic = MemoryVoiceMicrophone();
    final backend = ClipVoiceBackend(
      microphone: mic,
      transcriber: _BrokenTranscriber(),
      speech: RecordingVoiceSpeech(),
      delivery: ClipDelivery.transcript,
      endpoint: 'https://speech.test/inference',
      model: '',
      token: '',
      language: '',
      speakReplies: false,
      vadConfig: _vad,
    );
    final events = <VoiceBackendEvent>[];
    backend.events.listen(events.add);
    await backend.start();
    await _settle();
    for (var i = 0; i < 6; i++) {
      mic.hear(_bytes(voiceFrame(samples: 320, amplitude: 0.2)));
    }
    for (var i = 0; i < 10; i++) {
      mic.hear(_bytes(voiceFrame(samples: 320, amplitude: 0.001)));
    }
    await _settle();
    await _settle();
    final failure = events.whereType<VoiceFailureEvent>().single;
    expect(failure.problem.label, 'Transcription failed');
    expect(failure.problem.recoverable, isTrue);
    expect(
      events.whereType<VoicePhaseEvent>().last.phase,
      VoicePhase.listening,
    );
    await backend.stop();
  });

  test('the gate fires before the utterance and holds the reply', () async {
    const gateVad = VoiceActivityConfig(
      gateHold: Duration(milliseconds: 20),
      gateEndSilence: Duration(milliseconds: 80),
      startHold: Duration(milliseconds: 100),
      endSilence: Duration(milliseconds: 120),
      preRoll: Duration(milliseconds: 60),
      trailingKeep: Duration(milliseconds: 60),
      minUtterance: Duration(milliseconds: 100),
      maxUtterance: Duration(seconds: 10),
    );
    final mic = MemoryVoiceMicrophone();
    final transcriber = ScriptedVoiceTranscriber(['open the task']);
    final speech = RecordingVoiceSpeech();
    final backend = ClipVoiceBackend(
      microphone: mic,
      transcriber: transcriber,
      speech: speech,
      delivery: ClipDelivery.transcript,
      endpoint: 'https://speech.test/inference',
      model: '',
      token: '',
      language: 'en',
      speakReplies: true,
      vadConfig: gateVad,
    );
    final events = <VoiceBackendEvent>[];
    backend.events.listen(events.add);
    await backend.start();
    await _settle();

    mic.hear(_bytes(voiceFrame(samples: 320, amplitude: 0.2)));
    await _settle();
    expect(events.whereType<VoiceSpeechEvent>().single.active, isTrue);
    expect(transcriber.heard, isEmpty, reason: 'no full transcript yet');

    await backend.speak('Held reply.');
    await _settle();
    expect(speech.spoken, isEmpty);
    expect(events.whereType<VoiceHeldEvent>().single.text, 'Held reply.');

    // The tap was not words: the gate lets go and the screen listens.
    for (var i = 0; i < 4; i++) {
      mic.hear(_bytes(voiceFrame(samples: 320, amplitude: 0.001)));
    }
    await _settle();
    expect(events.whereType<VoiceSpeechEvent>().last.active, isFalse);
    expect(
      events.whereType<VoicePhaseEvent>().last.phase,
      VoicePhase.listening,
    );
    expect(transcriber.heard, isEmpty);

    // A real utterance arrives; its prompt carries the held reply as
    // context instead of the reply being spoken first.
    for (var i = 0; i < 6; i++) {
      mic.hear(_bytes(voiceFrame(samples: 320, amplitude: 0.2)));
    }
    for (var i = 0; i < 8; i++) {
      mic.hear(_bytes(voiceFrame(samples: 320, amplitude: 0.001)));
    }
    await _settle();
    await _settle();
    final prompt = events.whereType<VoicePromptEvent>().single;
    expect(prompt.prompt.text, 'open the task');
    expect(prompt.prompt.pending, ['Held reply.']);
    expect(speech.spoken, isEmpty);
    await backend.stop();
  });

  test('speaker echo does not interrupt, a louder voice does', () async {
    const echoVad = VoiceActivityConfig(
      gateHold: Duration(milliseconds: 20),
      echoHold: Duration(milliseconds: 100),
      echoThreshold: 0.055,
      endSilence: Duration(milliseconds: 120),
      preRoll: Duration(milliseconds: 60),
      trailingKeep: Duration(milliseconds: 60),
      minUtterance: Duration(milliseconds: 100),
      maxUtterance: Duration(seconds: 10),
    );
    final mic = MemoryVoiceMicrophone();
    final speech = RecordingVoiceSpeech();
    final backend = ClipVoiceBackend(
      microphone: mic,
      transcriber: ScriptedVoiceTranscriber(['never']),
      speech: speech,
      delivery: ClipDelivery.transcript,
      endpoint: 'https://speech.test/inference',
      model: '',
      token: '',
      language: 'en',
      speakReplies: true,
      vadConfig: echoVad,
    );
    final events = <VoiceBackendEvent>[];
    backend.events.listen(events.add);
    await backend.start();
    await _settle();
    unawaited(backend.speak('A long spoken reply.'));
    await _settle();
    for (var i = 0; i < 8; i++) {
      mic.hear(_bytes(voiceFrame(samples: 320, amplitude: 0.03)));
    }
    await _settle();
    expect(
      events.whereType<VoiceSpeechEvent>(),
      isEmpty,
      reason: 'speaker echo opened the gate',
    );
    expect(speech.stops, 0);
    for (var i = 0; i < 8; i++) {
      mic.hear(_bytes(voiceFrame(samples: 320, amplitude: 0.2)));
    }
    await _settle();
    expect(events.whereType<VoiceSpeechEvent>().single.active, isTrue);
    expect(speech.stops, greaterThan(0), reason: 'the person took the floor');
    await backend.stop();
  });

  test('pause closes the microphone and resume opens it again', () async {
    final mic = MemoryVoiceMicrophone();
    final backend = ClipVoiceBackend(
      microphone: mic,
      transcriber: ScriptedVoiceTranscriber(['never']),
      speech: RecordingVoiceSpeech(),
      delivery: ClipDelivery.transcript,
      endpoint: '',
      model: '',
      token: '',
      language: '',
      speakReplies: false,
      vadConfig: _vad,
    );
    final events = <VoiceBackendEvent>[];
    backend.events.listen(events.add);
    await backend.start();
    await _settle();
    await backend.pause();
    await _settle();
    expect(mic.muted, isTrue);
    expect(events.whereType<VoicePhaseEvent>().last.phase, VoicePhase.paused);
    mic.hear(_bytes(voiceFrame(samples: 320, amplitude: 0.2)));
    await _settle();
    expect(events.whereType<VoiceSpeechEvent>(), isEmpty);
    await backend.resume();
    await _settle();
    expect(mic.muted, isFalse);
    expect(
      events.whereType<VoicePhaseEvent>().last.phase,
      VoicePhase.listening,
    );
    await backend.stop();
  });
}

class _DelayedMuteMicrophone extends MemoryVoiceMicrophone {
  final muteReady = Completer<void>();

  @override
  Future<void> setMuted(bool value) async {
    if (value) await muteReady.future;
    await super.setMuted(value);
  }
}

class _DeferredTranscriber implements VoiceTranscriber {
  final results = <Completer<String>>[];

  @override
  Future<String> transcribe(
    Uint8List wav, {
    required String endpoint,
    required String model,
    required String token,
    required String language,
  }) {
    final result = Completer<String>();
    results.add(result);
    return result.future;
  }

  @override
  Future<void> dispose() async {}
}

class _BrokenTranscriber implements VoiceTranscriber {
  @override
  Future<String> transcribe(
    Uint8List wav, {
    required String endpoint,
    required String model,
    required String token,
    required String language,
  }) async {
    throw StateError('the speech server is down');
  }

  @override
  Future<void> dispose() async {}
}
