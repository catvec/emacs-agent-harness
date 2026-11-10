import '../voice/clip_voice_backend.dart';
import '../voice/live_protocol.dart';
import '../voice/live_voice_backend.dart';
import '../voice/voice_backend.dart';
import '../voice/voice_output.dart';
import '../voice/voice_settings.dart';
import 'voice_audio_io.dart';
import 'voice_http.dart';
import 'voice_webrtc.dart';

/// Builds the backend a [VoiceSettings] names.  This is where the app's
/// platform channels meet the pure voice code; a test passes its own factory,
/// so nothing here is loaded by `flutter test`.
VoiceBackend createVoiceBackend(
  VoiceSettings settings,
  String harnessAddress,
  VoiceSessionBridge session,
) {
  if (settings.provider == VoiceProvider.live) {
    final openAi = looksLikeOpenAiRealtime(settings.realtimeEndpoint);
    final skeleton = LiveVoiceConfig(
      endpoint: settings.realtimeEndpoint.trim(),
      model: settings.realtimeModel.trim(),
      token: settings.realtimeToken,
      voice: settings.realtimeVoice,
      language: settings.language,
      instructions: '',
      sessionId: session.sessionId,
      sessionTitle: session.sessionTitle,
      cwd: session.cwd,
      history: session.history,
    );
    final config = skeleton.copyWith(
      instructions: liveVoiceInstructions(skeleton),
    );
    return LiveVoiceBackend(
      connection: WebRtcLiveConnection(),
      protocol: LiveProtocol(openAi: openAi),
      config: config,
    );
  }
  return ClipVoiceBackend(
    microphone: RecordVoiceMicrophone(),
    transcriber: HttpVoiceTranscriber(),
    // A spoken reply is made with the same voice and parameters the setup
    // sheet's audition previews, through the same application path.
    speech: FlutterTtsVoiceSpeech(
      language: settings.language,
      params: VoiceOutputParams.forSettings(settings),
    ),
    delivery: settings.clipDelivery,
    endpoint: settings.effectiveSpeechEndpoint(harnessAddress),
    model: settings.speechModel,
    token: settings.speechToken,
    language: settings.language,
    speakReplies: settings.speakReplies,
    harnessAddress: harnessAddress,
  );
}

/// Whether [endpoint] is OpenAI's Realtime call URL rather than a generic
/// signaling endpoint.
bool looksLikeOpenAiRealtime(String endpoint) {
  final uri = Uri.tryParse(endpoint.trim());
  if (uri == null) return false;
  return uri.host.endsWith('openai.com') || uri.path.contains('/realtime');
}
