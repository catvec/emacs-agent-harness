import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/voice/clip_voice_backend.dart';
import 'package:harness_client/src/voice/voice_audio.dart';

void main() {
  group('PCM framing', () {
    test('carries a partial sample into the next chunk', () {
      final framer = PcmFramer(sampleRate: 16000, frameMillis: 20);
      final bytes = Uint8List.fromList([
        1, 0, 2, 0, 3, 0,
      ]);
      expect(framer.add(bytes), isEmpty);
      final frames = framer.add(Uint8List.fromList(List<int>.filled(637, 7)));
      expect(frames, hasLength(1));
      expect(frames.single.length, 320);
      expect(frames.single[0], 1);
      expect(frames.single[1], 2);
      expect(frames.single[2], 3);
    });

    test('the same stream cut differently makes the same frames', () {
      final samples = List<int>.generate(1280, (i) => i - 640);
      final bytes = Uint8List(samples.length * 2);
      final view = ByteData.sublistView(bytes);
      for (var i = 0; i < samples.length; i++) {
        view.setInt16(i * 2, samples[i], Endian.little);
      }
      final all = PcmFramer().add(bytes);
      final pieces = <Int16List>[];
      final framer = PcmFramer();
      for (var offset = 0; offset < bytes.length; offset += 333) {
        final end = (offset + 333).clamp(0, bytes.length);
        pieces.addAll(framer.add(bytes.sublist(offset, end)));
      }
      expect(pieces.length, all.length);
      for (var i = 0; i < all.length; i++) {
        expect(pieces[i], all[i]);
      }
    });
  });

  group('WAV', () {
    test('writes a mono 16-bit header the readers understand', () {
      final samples = Int16List.fromList([0, 1000, -1000, 32767, -32768]);
      final wav = encodeWav(samples, sampleRate: 16000);
      expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
      expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
      final view = ByteData.sublistView(wav);
      expect(view.getUint16(20, Endian.little), 1);
      expect(view.getUint16(22, Endian.little), 1);
      expect(view.getUint32(24, Endian.little), 16000);
      expect(view.getUint16(34, Endian.little), 16);
      expect(view.getUint32(40, Endian.little), samples.length * 2);
      expect(wav.length, 44 + samples.length * 2);
      expect(view.getInt16(44 + 2 * 3, Endian.little), 32767);
      expect(wavDuration(wav), const Duration(microseconds: 312));
    });

    test('refuses bytes that are not a WAV', () {
      expect(wavDuration(Uint8List.fromList(List<int>.filled(80, 0))), isNull);
      expect(wavDuration(Uint8List(10)), isNull);
    });
  });

  group('voice activity', () {
    const config = VoiceActivityConfig(
      startThreshold: 0.02,
      endThreshold: 0.01,
      startHold: Duration(milliseconds: 100),
      endSilence: Duration(milliseconds: 300),
      preRoll: Duration(milliseconds: 100),
      trailingKeep: Duration(milliseconds: 100),
      minUtterance: Duration(milliseconds: 200),
      maxUtterance: Duration(seconds: 5),
    );

    Int16List tone({int frames = 1, double amplitude = 0.2}) =>
        voiceFrame(samples: 320 * frames, amplitude: amplitude);

    test('a room with no speech makes no clip', () {
      final vad = VoiceActivityDetector(config: config);
      for (var i = 0; i < 60; i++) {
        expect(vad.addFrame(tone(amplitude: 0.001)), isEmpty);
      }
      expect(vad.speaking, isFalse);
      expect(vad.flush(), isNull);
    });

    test('speech followed by a pause makes one clip', () {
      final vad = VoiceActivityDetector(config: config);
      final out = <VoiceUtterance>[];
      for (var i = 0; i < 8; i++) {
        out.addAll(vad.addFrame(tone(amplitude: 0.2)));
      }
      expect(vad.speaking, isTrue);
      for (var i = 0; i < 20; i++) {
        out.addAll(vad.addFrame(tone(amplitude: 0.001)));
      }
      expect(out, hasLength(1));
      final clip = out.single;
      expect(clip.duration.inMilliseconds, greaterThan(140));
      expect(clip.duration.inMilliseconds, lessThan(400));
      expect(clip.level, closeTo(1.0, 0.1));
      expect(vad.speaking, isFalse);
    });

    test('a short burst is a tap, not an utterance', () {
      final vad = VoiceActivityDetector(config: config);
      final out = <VoiceUtterance>[];
      for (var i = 0; i < 3; i++) {
        out.addAll(vad.addFrame(tone(amplitude: 0.2)));
      }
      for (var i = 0; i < 20; i++) {
        out.addAll(vad.addFrame(tone(amplitude: 0.001)));
      }
      expect(out, isEmpty);
    });

    test('a long utterance is cut at the maximum', () {
      final vad = VoiceActivityDetector(config: config);
      final out = <VoiceUtterance>[];
      for (var i = 0; i < 400; i++) {
        out.addAll(vad.addFrame(tone(amplitude: 0.2)));
      }
      expect(out, isNotEmpty);
      expect(
        out.first.duration,
        lessThanOrEqualTo(config.maxUtterance + const Duration(milliseconds: 20)),
      );
    });

    test('flush hands over the words that are still being said', () {
      final vad = VoiceActivityDetector(config: config);
      for (var i = 0; i < 20; i++) {
        vad.addFrame(tone(amplitude: 0.2));
      }
      expect(vad.speaking, isTrue);
      final clip = vad.flush();
      expect(clip, isNotNull);
      expect(clip!.samples, isNotEmpty);
      expect(vad.speaking, isFalse);
    });

    test('the level follows the room', () {
      final vad = VoiceActivityDetector(config: config);
      vad.addFrame(tone(amplitude: 0.001));
      final quiet = vad.level;
      for (var i = 0; i < 12; i++) {
        vad.addFrame(tone(amplitude: 0.2));
      }
      expect(vad.level, greaterThan(quiet));
      expect(vad.level, lessThanOrEqualTo(1));
    });
  });
}
