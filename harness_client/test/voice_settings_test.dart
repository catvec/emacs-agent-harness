import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/voice/voice_settings.dart';

void main() {
  group('voice settings', () {
    test('the defaults are the local clip path', () {
      const settings = VoiceSettings();
      expect(settings.provider, VoiceProvider.clip);
      expect(settings.clipDelivery, ClipDelivery.transcript);
      expect(settings.speakReplies, isTrue);
      expect(settings.realtimeModel, 'gpt-live-1');
      expect(settings.effectiveSpeechEndpoint('ws://a.test:9999/acp'),
          'http://a.test:8080/inference');
      expect(
        settings.configuredFor('ws://a.test:9999/acp'),
        isTrue,
        reason: 'the harness host suggests a speech endpoint',
      );
      expect(settings.effectiveSpeechEndpoint(''), '');
      expect(settings.configuredFor(''), isFalse);
    });

    test('an explicit endpoint wins, and a blank one falls back', () {
      const settings = VoiceSettings(
        speechEndpoint: 'https://speech.example/inference',
      );
      expect(
        settings.effectiveSpeechEndpoint('ws://a.test:9999/acp'),
        'https://speech.example/inference',
      );
      expect(
        settings.copyWith(speechEndpoint: '  ').effectiveSpeechEndpoint(
          'a.test:9999',
        ),
        'http://a.test:8080/inference',
      );
    });

    test('an audio prompt needs no speech endpoint', () {
      const settings = VoiceSettings(clipDelivery: ClipDelivery.audioPrompt);
      expect(settings.configuredFor(''), isTrue);
    });

    test('live needs a realtime endpoint', () {
      const settings = VoiceSettings(provider: VoiceProvider.live);
      expect(settings.configuredFor('ws://a.test:9999'), isFalse);
      expect(
        settings
            .copyWith(realtimeEndpoint: 'https://api.openai.com/v1')
            .configuredFor(''),
        isTrue,
      );
    });

    test('round-trips through the store, version 2 and all', () {
      const settings = VoiceSettings(
        provider: VoiceProvider.clip,
        speechEndpoint: 'https://speech.example/inference',
        outputVoice: 'Samantha',
        outputVoiceLocale: 'en-US',
        speechRate: 0.42,
        speechPitch: 1.25,
        speechVolume: 0.6,
      );
      final json = settings.toJson();
      expect(json['version'], 2);
      expect(json['outputVoice'], 'Samantha');
      expect(json['outputVoiceLocale'], 'en-US');
      expect(json['speechRate'], 0.42);
      expect(json['speechPitch'], 1.25);
      expect(json['speechVolume'], 0.6);
      final decoded = VoiceSettings.fromJson(
        jsonDecode(jsonEncode(json)),
      );
      expect(decoded, settings);
      expect(decoded.hashCode, settings.hashCode);
    });

    test('a version 1 document loads with the output defaults', () {
      // What the app wrote before the output voice existed.
      final decoded = VoiceSettings.fromJson(<String, Object?>{
        'version': 1,
        'provider': 'live',
        'clipDelivery': 'audioPrompt',
        'speechEndpoint': 'https://speech.example/inference',
        'speechModel': 'whisper-1',
        'speechToken': 'speech-secret',
        'language': 'en',
        'speakReplies': false,
        'realtimeEndpoint': 'https://api.openai.com/v1',
        'realtimeModel': 'gpt-live-1',
        'realtimeToken': 'realtime-secret',
        'realtimeVoice': 'vale',
      });
      expect(decoded.provider, VoiceProvider.live);
      expect(decoded.realtimeVoice, 'vale');
      expect(decoded.speakReplies, isFalse);
      expect(decoded.outputVoice, '');
      expect(decoded.outputVoiceLocale, '');
      expect(decoded.speechRate, isNull, reason: 'the normal rate');
      expect(decoded.speechPitch, VoiceSettings.defaultSpeechPitch);
      expect(decoded.speechVolume, VoiceSettings.defaultSpeechVolume);
      expect(decoded, isNot(const VoiceSettings(provider: VoiceProvider.live)));
    });

    test('the defaults write no rate at all', () {
      final json = const VoiceSettings().toJson();
      expect(
        json.containsKey('speechRate'),
        isFalse,
        reason: 'the normal rate is the absence of a setting',
      );
      expect(json['speechPitch'], 1.0);
      expect(json['speechVolume'], 1.0);
      expect(VoiceSettings.fromJson(json), const VoiceSettings());
    });

    test('a damaged output value falls back per key', () {
      final decoded = VoiceSettings.fromJson(<String, Object?>{
        'version': 2,
        // A voice that is not text is no voice at all.
        'outputVoice': 42,
        'outputVoiceLocale': false,
        // Out of the documented pitch range, and not finite.
        'speechPitch': 9.5,
        'speechVolume': 'loud',
        // A rate that is not a number is no rate.
        'speechRate': 'fast',
      });
      expect(decoded.outputVoice, '');
      expect(decoded.outputVoiceLocale, '');
      expect(decoded.speechPitch, 1.0);
      expect(decoded.speechVolume, 1.0);
      expect(decoded.speechRate, isNull);
    });

    test('a stored rate is kept, even one outside a range not yet known', () {
      // The platform's range is discovered at run time; a rate is checked
      // against it where it is used, not in the file.
      expect(
        VoiceSettings.fromJson(<String, Object?>{'speechRate': 0.85}).speechRate,
        0.85,
      );
      expect(
        VoiceSettings.fromJson(<String, Object?>{'speechRate': '0.85'}).speechRate,
        isNull,
        reason: 'a number arriving as text was not chosen here',
      );
      expect(
        VoiceSettings.fromJson(<String, Object?>{
          'speechRate': double.infinity,
        }).speechRate,
        isNull,
      );
    });

    test('the output fields take part in equality and hashCode', () {
      const base = VoiceSettings();
      expect(base, const VoiceSettings());
      expect(base.hashCode, const VoiceSettings().hashCode);
      for (final next in <VoiceSettings>[
        base.copyWith(outputVoice: 'Samantha'),
        base.copyWith(outputVoiceLocale: 'en-US'),
        base.copyWith(speechRate: 0.5),
        base.copyWith(speechPitch: 1.5),
        base.copyWith(speechVolume: 0.5),
      ]) {
        expect(next, isNot(base));
        expect(next.hashCode, isNot(base.hashCode));
      }
    });

    test('the output fields copy, and a rate can be cleared', () {
      const settings = VoiceSettings(
        outputVoice: 'Samantha',
        outputVoiceLocale: 'en-US',
        speechRate: 0.5,
      );
      final changed = settings.copyWith(speechPitch: 1.5);
      expect(changed.outputVoice, 'Samantha');
      expect(changed.speechRate, 0.5);
      expect(changed.speechPitch, 1.5);
      final cleared = changed.copyWith(speechRate: 0.8, clearSpeechRate: true);
      expect(cleared.speechRate, isNull);
    });

    test('knows which numbers an engine accepts', () {
      expect(VoiceSettings.pitchInRange(0.5), isTrue);
      expect(VoiceSettings.pitchInRange(2.0), isTrue);
      expect(VoiceSettings.pitchInRange(0.49), isFalse);
      expect(VoiceSettings.pitchInRange(2.01), isFalse);
      expect(VoiceSettings.pitchInRange(double.nan), isFalse);
      expect(VoiceSettings.volumeInRange(0.0), isTrue);
      expect(VoiceSettings.volumeInRange(1.0), isTrue);
      expect(VoiceSettings.volumeInRange(-0.01), isFalse);
      expect(VoiceSettings.volumeInRange(1.01), isFalse);
      expect(VoiceSettings.rateInRange(null, min: 0.0, max: 1.5), isTrue);
      expect(VoiceSettings.rateInRange(0.25, min: 0.25, max: 2.0), isTrue);
      expect(VoiceSettings.rateInRange(0.24, min: 0.25, max: 2.0), isFalse);
      expect(
        VoiceSettings.rateInRange(double.infinity, min: 0.0, max: 1.5),
        isFalse,
      );
    });

    test('round-trips through the store', () {
      const settings = VoiceSettings(
        provider: VoiceProvider.live,
        clipDelivery: ClipDelivery.audioPrompt,
        speechEndpoint: 'https://speech.example/inference',
        speechModel: 'whisper-1',
        speechToken: 'speech-secret',
        language: 'en',
        speakReplies: false,
        realtimeEndpoint: 'https://api.openai.com/v1',
        realtimeModel: 'gpt-live-1',
        realtimeToken: 'realtime-secret',
        realtimeVoice: 'vale',
      );
      final decoded = VoiceSettings.fromJson(
        jsonDecode(jsonEncode(settings.toJson())),
      );
      expect(decoded, settings);
      expect(decoded.hashCode, settings.hashCode);
    });

    test('a damaged value keeps the defaults, key by key', () {
      final decoded = VoiceSettings.fromJson(<String, Object?>{
        'provider': 7,
        'clipDelivery': 'nonsense',
        'speechEndpoint': 'https://x.test/inference',
        'speakReplies': 'yes',
        'realtimeToken': 3,
      });
      expect(decoded.provider, VoiceProvider.clip);
      expect(decoded.clipDelivery, ClipDelivery.transcript);
      expect(decoded.speechEndpoint, 'https://x.test/inference');
      expect(decoded.speakReplies, isTrue);
      expect(decoded.realtimeToken, '');
      expect(VoiceSettings.fromJson(null), const VoiceSettings());
      expect(VoiceSettings.fromJson('not a map'), const VoiceSettings());
    });

    test('knows the host of every address the app stores', () {
      expect(harnessHostAddress('ws://192.168.1.5:9999/acp'), '192.168.1.5');
      expect(harnessHostAddress('wss://harness.example/acp'), 'harness.example');
      expect(harnessHostAddress('harness.example:9999'), 'harness.example');
      expect(harnessHostAddress('http://[::1]:9999'), '[::1]');
      expect(harnessHostAddress(''), isNull);
      expect(harnessHostAddress('   '), isNull);
      expect(harnessHostAddress('://bad'), isNull);
    });
  });
}
