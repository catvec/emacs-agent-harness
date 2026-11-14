import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/services/voice_android_audio_io.dart';
import 'package:harness_client/src/voice/clip_voice_backend.dart';
import 'package:harness_client/src/voice/live_protocol.dart';
import 'package:harness_client/src/voice/live_voice_backend.dart';
import 'package:harness_client/src/voice/voice_android_audio.dart';
import 'package:harness_client/src/voice/voice_audio.dart';
import 'package:harness_client/src/voice/voice_backend.dart';
import 'package:harness_client/src/voice/voice_settings.dart';

/// What a backend asked the Android audio session to do, in order.
class RecordingAndroidAudio implements VoiceAndroidAudio {
  RecordingAndroidAudio({this.output = AndroidVoiceOutput.standard});

  @override
  final AndroidVoiceOutput output;

  final List<String> calls = <String>[];
  Map<String, Object?>? described;

  @override
  Future<Map<String, Object?>?> describe() async => described;

  @override
  Future<void> beginLive() async => calls.add('beginLive');

  @override
  Future<void> endLive() async => calls.add('endLive');

  @override
  Future<void> beginSpeech() async => calls.add('beginSpeech');

  @override
  Future<void> speechAttributes(Object tts) async => calls.add('attributes');

  @override
  Future<void> endSpeech() async => calls.add('endSpeech');
}

const _vad = VoiceActivityConfig(
  startHold: Duration(milliseconds: 60),
  endSilence: Duration(milliseconds: 120),
  preRoll: Duration(milliseconds: 60),
  trailingKeep: Duration(milliseconds: 60),
  minUtterance: Duration(milliseconds: 100),
  maxUtterance: Duration(seconds: 10),
);

Future<void> _settle() => Future<void>.delayed(Duration.zero);

LiveVoiceConfig _liveConfig() => LiveVoiceConfig(
  endpoint: 'https://api.openai.com/v1',
  model: 'gpt-live-1',
  token: 'ek_test',
  voice: 'vale',
  language: 'en',
  instructions: 'be brief',
  sessionId: 's1',
  sessionTitle: 'Build the thing',
  cwd: '/tmp/project',
  history: const ['Person: hello'],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the output both voice backends play through', () {
    test('is the stream media volume controls', () {
      const output = AndroidVoiceOutput.standard;
      expect(output.usage, AndroidVoiceUsage.media);
      expect(output.streamType, AndroidVoiceStreamType.music);
      expect(output.mode, AndroidVoiceMode.normal);
      expect(output.contentType, AndroidVoiceContentType.speech);
      expect(output.focus, AndroidVoiceFocus.gain);
      expect(
        output.isMediaStream,
        isTrue,
        reason: 'the keys, the slider and the player must name one stream',
      );
    });

    test('a usage paired with the call stream is not the media stream', () {
      const output = AndroidVoiceOutput(
        streamType: AndroidVoiceStreamType.voiceCall,
      );
      expect(output.isMediaStream, isFalse);
    });

    test('every usage maps to the legacy stream Android maps it to', () {
      // AudioAttributes.toVolumeStreamType: the media, assistant and
      // navigation usages are all the music stream; nothing else is.
      for (final usage in AndroidVoiceUsage.values) {
        expect(usage.legacyStream, AndroidVoiceStreamType.music);
      }
    });

    test('the WebRTC configuration names the media stream and normal mode', () {
      final config = AndroidVoiceOutput.standard.webrtcConfiguration;
      expect(config['androidAudioMode'], 'normal');
      expect(config['androidAudioStreamType'], 'music');
      expect(config['androidAudioAttributesUsageType'], 'media');
      expect(config['androidAudioAttributesContentType'], 'speech');
      expect(config['androidAudioFocusMode'], 'gain');
      expect(config['manageAudioFocus'], isTrue);
      expect(
        config['forceHandleAudioRouting'],
        isFalse,
        reason: 'forcing the route starts SCO, which is call audio',
      );
    });

    test('the map the Kotlin side reads names the same output', () {
      expect(AndroidVoiceOutput.standard.toMap(), <String, Object?>{
        'usage': 'media',
        'contentType': 'speech',
        'streamType': 'music',
        'mode': 'normal',
        'focus': 'gain',
        'forceAudioRouting': false,
      });
    });
  });

  group('the microphone around a reply', () {
    test('does not bring up the Bluetooth SCO link', () {
      expect(AndroidVoiceRouting.standard.captureSco, isFalse);
    });
  });

  group('the live backend', () {
    test('configures the audio session before the connection, and gives it '
        'back after', () async {
      final audio = RecordingAndroidAudio();
      final connection = ScriptedLiveConnection();
      final backend = LiveVoiceBackend(
        connection: connection,
        protocol: const LiveProtocol(openAi: true),
        config: _liveConfig(),
        androidAudio: audio,
      );
      await backend.start();
      await _settle();
      expect(audio.calls, <String>['beginLive']);
      expect(
        connection.connected,
        isTrue,
        reason: 'the playout attributes are read when the stack is made',
      );
      await backend.stop();
      await _settle();
      expect(audio.calls, <String>['beginLive', 'endLive']);
    });

    test('gives the session back when the call fails to open', () async {
      final audio = RecordingAndroidAudio();
      final backend = LiveVoiceBackend(
        connection: _BrokenLiveConnection(),
        protocol: const LiveProtocol(openAi: true),
        config: _liveConfig(),
        androidAudio: audio,
      );
      final events = <VoiceBackendEvent>[];
      backend.events.listen(events.add);
      await backend.start();
      await _settle();
      expect(events.whereType<VoiceFailureEvent>(), hasLength(1));
      await backend.stop();
      expect(audio.calls, <String>['beginLive', 'endLive']);
    });
  });

  group('the clip backend', () {
    test('claims the audio session for the call and gives it back', () async {
      final audio = RecordingAndroidAudio();
      final backend = ClipVoiceBackend(
        microphone: MemoryVoiceMicrophone(),
        transcriber: ScriptedVoiceTranscriber(const []),
        speech: RecordingVoiceSpeech(),
        delivery: ClipDelivery.transcript,
        androidAudio: audio,
        endpoint: '',
        model: '',
        token: '',
        language: '',
        speakReplies: false,
        vadConfig: _vad,
      );
      await backend.start();
      await _settle();
      expect(audio.calls, <String>['beginSpeech']);
      await backend.stop();
      await _settle();
      expect(audio.calls, <String>['beginSpeech', 'endSpeech']);
    });

    test('gives the session back when the microphone cannot open', () async {
      final audio = RecordingAndroidAudio();
      final backend = ClipVoiceBackend(
        microphone: _BrokenMicrophone(),
        transcriber: ScriptedVoiceTranscriber(const []),
        speech: RecordingVoiceSpeech(),
        delivery: ClipDelivery.transcript,
        androidAudio: audio,
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
      expect(events.whereType<VoiceFailureEvent>(), hasLength(1));
      expect(audio.calls, <String>['beginSpeech', 'endSpeech']);
      await backend.stop();
    });
  });
  group('the bridge to the app Kotlin', () {
    test('claims the media volume keys and names the media stream', () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(AndroidAudioChannel.channel, (call) async {
            calls.add(call);
            return <String, Object?>{
              'mode': 0,
              'volumeControlStream': 3,
              'stream': 3,
            };
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(AndroidAudioChannel.channel, null),
      );
      final answer = await const AndroidAudioChannel().begin(
        AndroidVoiceOutput.standard,
      );
      expect(calls.single.method, 'begin');
      expect(
        (calls.single.arguments as Map)['output'],
        AndroidVoiceOutput.standard.toMap(),
      );
      expect(
        answer?['volumeControlStream'],
        3,
        reason: 'STREAM_MUSIC is what the hardware keys then adjust',
      );
    });

    test('a build without the bridge answers nothing, never throws', () async {
      final answer = await const AndroidAudioChannel().describe(
        AndroidVoiceOutput.standard,
      );
      expect(answer, isNull);
    });
  });
}

class _BrokenLiveConnection implements LiveVoiceConnection {
  @override
  Stream<Map<String, Object?>> get messages => const Stream.empty();

  @override
  Future<void> connect(LiveVoiceConfig config) async {
    throw StateError('the endpoint refused the call');
  }

  @override
  Future<void> send(Map<String, Object?> message) async {}

  @override
  Future<void> setMuted(bool muted) async {}

  @override
  Future<void> setRemoteAudioEnabled(bool enabled) async {}

  @override
  Future<void> dispose() async {}
}

class _BrokenMicrophone implements VoiceMicrophone {
  @override
  int get sampleRate => 16000;

  @override
  Stream<Uint8List> get frames => const Stream.empty();

  @override
  Future<void> start() async {
    throw StateError('Microphone permission denied');
  }

  @override
  Future<void> setMuted(bool muted) async {}

  @override
  Future<void> stop() async {}
}
