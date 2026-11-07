import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Headset and keyboard media buttons that mean "start or stop talking".
///
/// This is a seam, not a promise: a platform that exposes headset buttons
/// sends [toggle] while the voice screen is open, and a platform that does
/// not keeps the in-app Pause control as the fallback.  The screen never
/// depends on a button arriving.
abstract class VoiceMediaButtons {
  /// Begin listening for the platform's play/pause button.
  Future<void> start(VoidCallback toggle);

  /// Stop listening; called when the voice screen closes.
  Future<void> stop();
}

/// The default for a platform with no headset-button bridge.
class NoopVoiceMediaButtons implements VoiceMediaButtons {
  const NoopVoiceMediaButtons();

  @override
  Future<void> start(VoidCallback toggle) async {}

  @override
  Future<void> stop() async {}
}

/// The method channel Android's `MediaSession` uses.
///
/// The native side calls `toggle` when a headset sends play or pause; the
/// app asks it to begin and end with `start` and `stop`.  A missing plugin
/// is not an error: it means this build has no native bridge.
class PlatformVoiceMediaButtons implements VoiceMediaButtons {
  const PlatformVoiceMediaButtons();

  static const channel = MethodChannel('app.harness/voice_media_buttons');

  @override
  Future<void> start(VoidCallback toggle) async {
    channel.setMethodCallHandler((call) async {
      if (call.method == 'toggle') toggle();
    });
    try {
      await channel.invokeMethod<void>('start');
    } catch (_) {
      // No native bridge on this platform or build.
    }
  }

  @override
  Future<void> stop() async {
    channel.setMethodCallHandler(null);
    try {
      await channel.invokeMethod<void>('stop');
    } catch (_) {
      // No native bridge on this platform or build.
    }
  }
}

/// The media-button bridge this build can use.
VoiceMediaButtons defaultVoiceMediaButtons() {
  if (defaultTargetPlatform == TargetPlatform.android) {
    return const PlatformVoiceMediaButtons();
  }
  return const NoopVoiceMediaButtons();
}
