// A probe for the Android audio session the voice backends play through, run
// on a real phone or an emulator to read what the platform actually did.
//
//   tool/voice_audio_probe.sh
//
// It is not part of the app: it builds the same `PlatformVoiceAndroidAudio`
// and `FlutterTtsVoiceSpeech` the app builds, and measures the same reply on
// the same device twice -- once the way the app used to play it, once through
// this change -- so the two are read side by side.
//
//   1. The live path.  flutter_webrtc's own defaults are put on the platform
//      (its `AndroidAudioConfiguration.communication`, which is what the app
//      played with when it named nothing), the microphone is opened -- that is
//      what starts `AudioSwitch`, which is what holds the mode -- and the
//      platform is described.  Then the app's own output is applied
//      (`PlatformVoiceAndroidAudio.beginLive`) and the same is read again.
//      `mode` and `stream` are the answer: in `MODE_IN_COMMUNICATION` (3) the
//      framework makes STREAM_VOICE_CALL (0) the stream the keys and the
//      slider move.
//
//   2. The clip path.  The same reply is spoken twice, and the platform's own
//      account of the active player -- its attributes and the stream they map
//      to -- is read from inside each utterance.  The first is the engine as
//      the app left it (never told its attributes); the second is the app's
//      own audio session.
//
// Everything it prints is under the `HarnessVoiceProbe` tag in logcat.
//
// See docs/voice-android-audio.md for what a run on a device looks like.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:harness_client/src/services/voice_android_audio_io.dart';
import 'package:harness_client/src/services/voice_audio_io.dart';
import 'package:harness_client/src/voice/voice_android_audio.dart';
import 'package:harness_client/src/voice/voice_backend.dart';

/// What the probe says, so a run lasts long enough to change the volume
/// while it speaks.
const _reply =
    'This is the harness output voice, speaking on the stream the volume '
    'keys control. Turn the media volume down and this reply gets quieter.';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _ProbeApp());

  await _livePath();
  await _clipPath();
  _log('done', null);
}

/// What the app played a live session through before this change:
/// flutter_webrtc's `AndroidAudioConfiguration.communication`, which is what
/// its `AudioSwitch` defaults to when the app names nothing.
Future<void> _livePath() async {
  _log('live before', null);
  try {
    await Helper.setAndroidAudioConfiguration(
      AndroidAudioConfiguration.communication,
    ).timeout(const Duration(seconds: 5));
  } catch (error) {
    _log('live before: configuration refused', {'error': '$error'});
  }
  // Opening the microphone is what starts the audio switch, and the switch is
  // what holds the mode; describing without it reads a platform nothing has
  // touched yet.
  final beforeMic = await _openMicrophone();
  final before = defaultVoiceAndroidAudio();
  _log('live before', await before.describe());
  await _closeMicrophone(beforeMic);

  // The app's own answer, applied the way a live session applies it.
  final after = defaultVoiceAndroidAudio();
  await after.beginLive();
  final afterMic = await _openMicrophone();
  _log('live after', await after.describe());
  await _closeMicrophone(afterMic);
  await after.endLive();
}

/// The microphone a live session opens, or null when the permission was
/// refused: the probe still runs, it just cannot start the audio switch.
Future<MediaStream?> _openMicrophone() async {
  try {
    // A device with no microphone, or an emulator that never answers, must not
    // take the whole run with it.
    return await navigator.mediaDevices
        .getUserMedia(<String, dynamic>{'audio': true, 'video': false})
        .timeout(const Duration(seconds: 5));
  } catch (error) {
    _log('microphone refused', {'error': '$error'});
    return null;
  }
}

Future<void> _closeMicrophone(MediaStream? stream) async {
  if (stream == null) return;
  for (final track in stream.getAudioTracks()) {
    try {
      await track.stop();
    } catch (_) {}
  }
  try {
    await stream.dispose();
  } catch (_) {}
}

/// The same reply, with and without the app's own audio session.
Future<void> _clipPath() async {
  // The engine as the app left it: never told its attributes, no session
  // claimed, which is exactly what the clip provider did before this change.
  final untouched = FlutterTtsVoiceSpeech(
    androidAudio: const _UntouchedAndroidAudio(),
  );
  _log('clip before', null);
  await _speakAndRead('clip before', untouched, defaultVoiceAndroidAudio());

  final audio = defaultVoiceAndroidAudio();
  final configured = FlutterTtsVoiceSpeech(androidAudio: audio);
  await audio.beginSpeech();
  _log('clip after begin', await audio.describe());
  await _speakAndRead('clip after', configured, audio);
  await audio.endSpeech();
  _log('clip after end', await audio.describe());
  await untouched.stop();
  await configured.stop();
}

Future<void> _speakAndRead(
  String label,
  VoiceSpeech speech,
  VoiceAndroidAudio audio,
) async {
  final reading = _readWhileSpeaking(audio);
  await speech.speak(_reply);
  _log('$label playing', await reading);
}

/// The platform's state taken about a second and a half into the utterance,
/// while the player is actually playing: the state a volume change acts on.
Future<Map<String, Object?>?> _readWhileSpeaking(VoiceAndroidAudio audio) async {
  await Future<void>.delayed(const Duration(milliseconds: 1500));
  return audio.describe();
}

void _log(String step, Map<String, Object?>? state) {
  final fields = state == null
      ? '-'
      : state.entries.map((entry) => '${entry.key}=${entry.value}').join(' ');
  // `print` reaches logcat under the `flutter` tag; `debugPrint` is throttled.
  // ignore: avoid_print
  print('HarnessVoiceProbe $step $fields');
}

/// The platform before the app says anything about it: no session claimed and
/// the engine's own attributes.  It still describes itself, which is the
/// reading the before/after comparison needs.
class _UntouchedAndroidAudio implements VoiceAndroidAudio {
  const _UntouchedAndroidAudio();

  @override
  AndroidVoiceOutput get output => AndroidVoiceOutput.standard;

  @override
  Future<Map<String, Object?>?> describe() async =>
      const AndroidAudioChannel().describe(AndroidVoiceOutput.standard);

  @override
  Future<void> beginLive() async {}

  @override
  Future<void> endLive() async {}

  @override
  Future<void> beginSpeech() async {}

  @override
  Future<void> speechAttributes(Object tts) async {}

  @override
  Future<void> endSpeech() async {}
}

class _ProbeApp extends StatelessWidget {
  const _ProbeApp();

  @override
  Widget build(BuildContext context) => const MaterialApp(
    home: Scaffold(
      backgroundColor: Color(0xFF0D0D0F),
      body: Center(
        child: Text(
          'Voice audio probe',
          style: TextStyle(color: Color(0xFFF2EEE8)),
        ),
      ),
    ),
  );
}
