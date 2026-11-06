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
