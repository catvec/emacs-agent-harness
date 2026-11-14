import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../voice/voice_android_audio.dart';

/// The real platform: the one that reaches `flutter_webrtc`, the speech
/// engine and this app's own Kotlin.
///
/// Every call is best effort and reported as data, never thrown: a phone whose
/// OEM refused an audio call must still speak, and a build without the Kotlin
/// bridge must still run.
class PlatformVoiceAndroidAudio implements VoiceAndroidAudio {
  PlatformVoiceAndroidAudio({
    this.output = AndroidVoiceOutput.standard,
    AndroidAudioChannel channel = const AndroidAudioChannel(),
  }) : _channel = channel;

  @override
  final AndroidVoiceOutput output;

  final AndroidAudioChannel _channel;

  bool get _isAndroid => defaultTargetPlatform == TargetPlatform.android;

  @override
  Future<Map<String, Object?>?> describe() async {
    if (!_isAndroid) return null;
    return _channel.describe(output);
  }

  @override
  Future<void> beginLive() async {
    if (!_isAndroid) return;
    _report('beginLive', await _channel.begin(output));
    // The playout track's own attributes are read once, when the audio device
    // module is made inside `initialize`, before any peer connection exists.
    // This is the call that decides which stream WebRTC's voice plays on, so it
    // comes before anything else that would make the module with the defaults
    // (`USAGE_VOICE_COMMUNICATION`, and therefore the call stream).
    try {
      await WebRTC.initialize(
        options: <String, dynamic>{
          'androidAudioConfiguration': output.webrtcConfiguration,
        },
      );
    } catch (_) {
      // A build without the WebRTC plugin opens its own connection.
    }
    // The route switcher holds the mode and the focus, and is configured before
    // it starts (it starts when the microphone opens).  Without this it holds
    // `MODE_IN_COMMUNICATION`, in which the framework makes the call stream the
    // one the volume keys and the framework's own volume control address.
    try {
      await Helper.setAndroidAudioConfiguration(
        AndroidAudioConfiguration(
          manageAudioFocus: true,
          androidAudioMode: _mode,
          androidAudioFocusMode: _focus,
          androidAudioStreamType: _stream,
          androidAudioAttributesUsageType: _usage,
          androidAudioAttributesContentType: _contentType,
          forceHandleAudioRouting: output.forceAudioRouting,
        ),
      );
    } catch (_) {
      // A refusal here is not a reason to keep the microphone closed.
    }
  }

  @override
  Future<void> endLive() async {
    if (!_isAndroid) return;
    try {
      await Helper.clearAndroidCommunicationDevice();
    } catch (_) {
      // Nothing was selected on a platform that never opened a device.
    }
    _report('endLive', await _channel.end(output));
  }

  @override
  Future<void> beginSpeech() async {
    if (!_isAndroid) return;
    _report('beginSpeech', await _channel.begin(output));
  }

  @override
  Future<void> speechAttributes(Object tts) async {
    if (!_isAndroid) return;
    if (tts is! FlutterTts) return;
    // The engine's own attributes are what decide its stream, and the plugin
    // exposes one call for them.  It sets
    // `USAGE_ASSISTANCE_NAVIGATION_GUIDANCE`, which
    // `AudioAttributes.toVolumeStreamType` maps to the same `STREAM_MUSIC`
    // that [output] names, so the keys and the slider move this reply too.
    try {
      await tts.setAudioAttributesForNavigation();
    } catch (_) {
      // An engine or a build without the call keeps its own attributes.
    }
  }

  @override
  Future<void> endSpeech() async {
    if (!_isAndroid) return;
    _report('endSpeech', await _channel.end(output));
  }

  /// The platform's own description of the audio state, on one line, for a
  /// device check that reads `adb logcat -s HarnessVoiceAudio` (the Kotlin side
  /// logs the same state under that tag).
  void _report(String step, Map<String, Object?>? state) {
    if (state == null) return;
    final fields = state.entries
        .map((entry) => '${entry.key}=${entry.value}')
        .join(' ');
    debugPrint('HarnessVoiceAudio $step $fields');
  }

  AndroidAudioMode get _mode => switch (output.mode) {
    AndroidVoiceMode.normal => AndroidAudioMode.normal,
    AndroidVoiceMode.inCommunication => AndroidAudioMode.inCommunication,
  };

  AndroidAudioFocusMode get _focus => switch (output.focus) {
    AndroidVoiceFocus.gain => AndroidAudioFocusMode.gain,
    AndroidVoiceFocus.gainTransient => AndroidAudioFocusMode.gainTransient,
  };

  AndroidAudioStreamType get _stream => switch (output.streamType) {
    AndroidVoiceStreamType.music => AndroidAudioStreamType.music,
    AndroidVoiceStreamType.voiceCall => AndroidAudioStreamType.voiceCall,
  };

  AndroidAudioAttributesUsageType get _usage => switch (output.usage) {
    AndroidVoiceUsage.media => AndroidAudioAttributesUsageType.media,
    AndroidVoiceUsage.assistant => AndroidAudioAttributesUsageType.assistant,
    AndroidVoiceUsage.navigation =>
      AndroidAudioAttributesUsageType.assistanceNavigationGuidance,
  };

  AndroidAudioAttributesContentType get _contentType =>
      switch (output.contentType) {
        AndroidVoiceContentType.speech =>
          AndroidAudioAttributesContentType.speech,
        AndroidVoiceContentType.music =>
          AndroidAudioAttributesContentType.music,
      };
}

/// The app's own Kotlin, through `app.harness/voice_audio`.
///
/// The native side owns the two things neither plugin can be asked for: the
/// activity's volume control stream, which is what the hardware keys follow
/// while the screen is in front, and the `AudioManager` mode and focus a
/// closed session leaves behind.
class AndroidAudioChannel {
  const AndroidAudioChannel();

  static const channel = MethodChannel('app.harness/voice_audio');

  /// Claim the media volume keys, and put the mode and focus where [output]
  /// wants them.  Answers the platform's description of itself, or null when
  /// this build has no native bridge.
  Future<Map<String, Object?>?> begin(AndroidVoiceOutput output) =>
      _invoke('begin', <String, Object?>{'output': output.toMap()});

  /// Give the keys, the mode and the focus back.
  Future<Map<String, Object?>?> end(AndroidVoiceOutput output) =>
      _invoke('end', <String, Object?>{'output': output.toMap()});

  /// What the platform is doing now.
  Future<Map<String, Object?>?> describe(AndroidVoiceOutput output) =>
      _invoke('describe', <String, Object?>{'output': output.toMap()});

  Future<Map<String, Object?>?> _invoke(
    String method,
    Map<String, Object?> arguments,
  ) async {
    try {
      final answer = await channel.invokeMethod<Object?>(method, arguments);
      if (answer is Map) return Map<String, Object?>.from(answer);
      return null;
    } catch (_) {
      // No native bridge on this platform or build.
      return null;
    }
  }
}

/// The [VoiceAndroidAudio] this build uses, given the platform it runs on.
///
/// A platform that is not Android gets an object whose every call is a no-op,
/// so the backends can ask unconditionally and only Android hears anything.
VoiceAndroidAudio defaultVoiceAndroidAudio() {
  if (defaultTargetPlatform == TargetPlatform.android) {
    return PlatformVoiceAndroidAudio();
  }
  return const SilentVoiceAndroidAudio();
}
