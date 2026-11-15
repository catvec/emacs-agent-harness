// Flutter's windowing API is experimental.  The desktop buddy's own window
// uses it on purpose, and this is the one place that turns the feature on;
// see docs/design/workspace-voice-buddy.md.
//
// ignore_for_file: implementation_imports, invalid_use_of_internal_member

import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/src/foundation/_features.dart' show isWindowingEnabled;

import 'app.dart';
import 'src/state/settings_controller.dart';
import 'src/voice/voice_settings.dart';

Future<void> main() async {
  // The windowing owner is made when the binding starts, so the feature must
  // be on before that.  Phones and the web keep the in-app card.
  if (!kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.linux ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.windows)) {
    isWindowingEnabled = true;
  }
  WidgetsFlutterBinding.ensureInitialized();
  // The screenshot run drives the browser through the semantics tree.
  if (const bool.fromEnvironment('E2E')) {
    SemanticsBinding.instance.ensureSemantics();
  }
  final settings = SettingsController();
  // What the device remembers of its harness is read before the first frame,
  // so that a device that is signed in opens on its harness and not on a
  // form for an address and a secret it already holds.  A preference store
  // that does not answer must not keep the app from starting: after a moment
  // the form shows, and what is remembered arrives when the store does.
  await settings.load().timeout(const Duration(seconds: 1), onTimeout: () {});
  await _seedForEndToEndRun(settings);
  runApp(HarnessApp(settings: settings));
}

/// Point the app at a local peer, for the on-device media run only.
///
/// `--dart-define=E2E=true` is the same seam the screenshot run uses; the
/// addresses come from two more defines, and nothing here runs in a
/// build without them.  The alternative is typing an address and a
/// realtime endpoint into the app's forms through the emulator's
/// accessibility service, which on a software-emulated guest takes
/// minutes per field and is not what the media run is testing.  The
/// app's own connect screen, session list, voice screen and capture
/// path are the same either way.
Future<void> _seedForEndToEndRun(SettingsController settings) async {
  const acp = String.fromEnvironment('E2E_ACP');
  const realtime = String.fromEnvironment('E2E_REALTIME');
  if (acp.isEmpty || realtime.isEmpty) return;
  await settings.rememberConnectionDetails(acp, '');
  await settings.setVoiceSettings(
    settings.voiceSettings.copyWith(
      provider: VoiceProvider.live,
      realtimeEndpoint: realtime,
      realtimeModel: const String.fromEnvironment(
        'E2E_REALTIME_MODEL',
        defaultValue: 'local-test-receiver',
      ),
    ),
  );
}

