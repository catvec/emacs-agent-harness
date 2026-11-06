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

void main() {
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
