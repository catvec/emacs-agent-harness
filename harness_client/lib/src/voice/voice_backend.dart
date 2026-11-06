import 'dart:async';
import 'dart:typed_data';

import '../models/session.dart';
import 'voice_models.dart';

/// What a voice backend says to the screen.
sealed class VoiceBackendEvent {
  const VoiceBackendEvent();
}

class VoicePhaseEvent extends VoiceBackendEvent {
  const VoicePhaseEvent(this.phase);
  final VoicePhase phase;
}

class VoiceLevelEvent extends VoiceBackendEvent {
  const VoiceLevelEvent(this.level);
  final double level;
}

class VoiceCaptionEvent extends VoiceBackendEvent {
  const VoiceCaptionEvent(this.speaker, this.text, {this.finalized = false});
  final VoiceSpeaker speaker;
  final String text;
  final bool finalized;
}

class VoicePromptEvent extends VoiceBackendEvent {
  const VoicePromptEvent(this.prompt);
  final VoicePrompt prompt;
}

/// A live provider asked the agent to do something.  [callId] is the
/// provider's own id for the request, which its result is returned under.
class VoiceDelegateEvent extends VoiceBackendEvent {
  const VoiceDelegateEvent(this.text, {this.callId});
  final String text;
  final String? callId;
}

class VoiceFailureEvent extends VoiceBackendEvent {
  const VoiceFailureEvent(this.problem);
  final VoiceProblem problem;
}

class VoiceProblemCleared extends VoiceBackendEvent {
  const VoiceProblemCleared();
}

class VoiceEndedEvent extends VoiceBackendEvent {
  const VoiceEndedEvent();
}

/// How the voice screen talks to one agent turn at a time.
abstract class VoiceBackend {
  Stream<VoiceBackendEvent> get events;

  Future<void> start();

  Future<void> setMuted(bool muted);

  /// Stop the voice output now.  This never cancels the agent's work: what the
  /// agent is doing keeps running, and its next reply is spoken when it is
  /// done (unless the screen is closed).
  Future<void> interrupt();

  /// Say [text], the agent's reply, in the voice provider's voice.
  Future<void> speak(String text);

  Future<void> stop();
}

/// The microphone, as a stream of PCM16 mono chunks.  The platform's own
/// capture is hidden behind this so that the clip backend can be tested
/// without a device.
abstract class VoiceMicrophone {
  int get sampleRate;

  Stream<Uint8List> get frames;

  Future<void> start();

  Future<void> setMuted(bool muted);

  Future<void> stop();
}

/// Speech synthesis for the clip provider.  The live provider speaks through
/// its own stream and does not use this.
abstract class VoiceSpeech {
  Future<void> speak(String text);

  Future<void> stop();
}

/// Turns a WAV clip into text.
abstract class VoiceTranscriber {
  /// [endpoint] is the speech endpoint after [VoiceSettings] resolution.
  Future<String> transcribe(
    Uint8List wav, {
    required String endpoint,
    required String model,
    required String token,
    required String language,
  });

  Future<void> dispose();
}

/// What the live backend needs to open its stream.
class LiveVoiceConfig {
  const LiveVoiceConfig({
    required this.endpoint,
    required this.model,
    required this.token,
    required this.voice,
    required this.language,
    required this.instructions,
    required this.sessionId,
    required this.sessionTitle,
    required this.cwd,
    required this.history,
  });

  final String endpoint;
  final String model;
  final String token;
  final String voice;
  final String language;

  /// The voice model's own prompt: what it is, how to delegate, and how to
  /// behave while the agent works.
  final String instructions;
  final String sessionId;
  final String sessionTitle;
  final String cwd;

  /// A short, plain-text account of the latest conversation, so the voice
  /// model can answer "what is it doing?" without asking the agent.
  final List<String> history;

  LiveVoiceConfig copyWith({String? instructions, List<String>? history}) =>
      LiveVoiceConfig(
        endpoint: endpoint,
        model: model,
        token: token,
        voice: voice,
        language: language,
        instructions: instructions ?? this.instructions,
        sessionId: sessionId,
        sessionTitle: sessionTitle,
        cwd: cwd,
        history: history ?? this.history,
      );
}

/// One live connection: a WebRTC peer connection in production, a script in
/// a test.  It carries the mic, the provider's audio and a JSON data channel.
abstract class LiveVoiceConnection {
  /// The provider's messages from the data channel.
  Stream<Map<String, Object?>> get messages;

  Future<void> connect(LiveVoiceConfig config);

  Future<void> send(Map<String, Object?> message);

  Future<void> setMuted(bool muted);

  /// Silence or resume the provider's audio, for an interruption.
  Future<void> setRemoteAudioEnabled(bool enabled);

  Future<void> dispose();
}

/// A session the voice screen can send to and hear from.
abstract class VoiceSessionBridge {
  /// Whether the agent is working now.
  bool get working;

  /// Whether the harness waits for an answer in the conversation (a
  /// permission or a question).  Voice never answers those itself.
  bool get blocked;

  /// The model the session runs, when it says.
  String? get model;

  String get sessionId;

  String get sessionTitle;

  String get cwd;

  /// The last few completed turns, oldest first, for the live provider's
  /// context.
  List<String> get history;

  Future<void> send(VoicePrompt prompt);

  /// Called once for every assistant reply that completes while listening.
  void addReplyListener(void Function(String text) listener);

  void removeReplyListener(void Function(String text) listener);

  /// Called when the conversation's own state changes: it started or stopped
  /// working, or it now waits for an answer.
  void addSessionListener(void Function() listener);

  void removeSessionListener(void Function() listener);
}

/// A title for the voice model's conversation, from the session it belongs to.
String voiceSessionLabel(SessionSummary? summary) {
  final title = summary?.displayTitle.trim() ?? '';
  return title.isEmpty ? 'this conversation' : title;
}
