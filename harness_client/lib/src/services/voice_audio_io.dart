import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:record/record.dart';

import '../voice/voice_backend.dart';

/// The platform microphone, as 16 kHz mono PCM16.  The clip backend's voice
/// activity detector wants small, regular frames; the recorder's own stream
/// buffer is set to 50 ms so that a pause is noticed quickly.
class RecordVoiceMicrophone implements VoiceMicrophone {
  RecordVoiceMicrophone({this.sampleRate = 16000});

  @override
  final int sampleRate;

  final AudioRecorder _recorder = AudioRecorder();
  final _frames = StreamController<Uint8List>.broadcast();
  StreamSubscription<Uint8List>? _subscription;
  bool _open = false;
  bool _muted = false;
  bool _headerChecked = false;
  final BytesBuilder _head = BytesBuilder(copy: false);

  @override
  Stream<Uint8List> get frames => _frames.stream;

  @override
  Future<void> start() async {
    if (_open) return;
    if (!await _recorder.hasPermission()) {
      throw StateError('Microphone permission denied');
    }
    final stream = await _recorder.startStream(
      RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: sampleRate,
        numChannels: 1,
        bitRate: sampleRate * 16,
        autoGain: true,
        echoCancel: true,
        noiseSuppress: true,
        streamBufferSize: 1600,
      ),
    );
    _open = true;
    _subscription = stream.listen(
      _onData,
      onError: (Object error) {
        if (!_frames.isClosed) _frames.addError(error);
      },
    );
  }

  /// Some platforms put a 44-byte RIFF header in front of a PCM stream.  A
  /// decoder cannot make a WAV of a WAV, so a header is skipped once.
  void _onData(Uint8List bytes) {
    if (bytes.isEmpty) return;
    if (_headerChecked) {
      if (!_muted && !_frames.isClosed) _frames.add(bytes);
      return;
    }
    _head.add(bytes);
    if (_head.length < 12) return;
    final all = _head.takeBytes();
    _headerChecked = true;
    final wav =
        all.length >= 44 &&
        all[0] == 0x52 &&
        all[1] == 0x49 &&
        all[2] == 0x46 &&
        all[3] == 0x46;
    final body = wav ? all.sublist(44) : all;
    if (body.isNotEmpty && !_muted && !_frames.isClosed) _frames.add(body);
  }

  @override
  Future<void> setMuted(bool muted) async {
    _muted = muted;
    try {
      if (muted) {
        await _recorder.pause();
      } else if (_open) {
        await _recorder.resume();
      }
    } catch (_) {
      // Pausing is an optimisation; the _muted flag is what decides.
    }
  }

  @override
  Future<void> stop() async {
    if (!_open) return;
    _open = false;
    await _subscription?.cancel();
    _subscription = null;
    try {
      await _recorder.stop();
    } finally {
      await _recorder.dispose();
      if (!_frames.isClosed) await _frames.close();
    }
  }
}

/// The platform's speech engine, for the clip provider's readable replies.
///
/// It is configured for simultaneous recording and playback on Apple
/// platforms: the microphone stays open while the agent speaks, so a person
/// can talk over it and the clip backend can stop it.  The session is shared
/// with WebRTC, which sets the same category while it is live.
class FlutterTtsVoiceSpeech implements VoiceSpeech {
  FlutterTtsVoiceSpeech({this.language = ''});

  final String language;
  final FlutterTts _tts = FlutterTts();
  bool _configured = false;

  Future<void> _configure() async {
    if (_configured) return;
    _configured = true;
    try {
      await _tts.awaitSpeakCompletion(true);
      await _tts.setSpeechRate(0.5);
      await _tts.setPitch(1.0);
      await _tts.setVolume(1.0);
      if (language.isNotEmpty) await _tts.setLanguage(language);
      if (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS) {
        await _tts.setSharedInstance(true);
        await _tts.setIosAudioCategory(
          IosTextToSpeechAudioCategory.playAndRecord,
          const [
            IosTextToSpeechAudioCategoryOptions.allowBluetooth,
            IosTextToSpeechAudioCategoryOptions.defaultToSpeaker,
            IosTextToSpeechAudioCategoryOptions.mixWithOthers,
          ],
          IosTextToSpeechAudioMode.voicePrompt,
        );
      }
    } catch (_) {
      // A platform without one of these knobs still speaks with its defaults.
    }
  }

  @override
  Future<void> speak(String text) async {
    await _configure();
    await _tts.speak(text);
  }

  @override
  Future<void> stop() async {
    try {
      await _tts.stop();
    } catch (_) {
      // An engine that is not speaking has nothing to stop.
    }
  }
}
