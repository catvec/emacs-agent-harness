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

/// Low-latency speech activity from the capture path, before any
/// transcription exists.  The screen uses it to hold assistant output.
class VoiceSpeechEvent extends VoiceBackendEvent {
  const VoiceSpeechEvent(this.active, {this.id});
  final bool active;

  /// The provider's own name for the utterance, when its event carries one
  /// (OpenAI Realtime's `item_id`); a backend uses it as the segment id.
  final String? id;
}

/// A reply the backend did not speak because the gate closed just as it
/// arrived.  The controller adds it to its own held list so a false trigger
/// can still release it, and the next transcript carries it as context.
class VoiceHeldEvent extends VoiceBackendEvent {
  const VoiceHeldEvent(this.text, {this.id});
  final String text;

  /// The screen's id for the reply, when the backend was given one.
  final String? id;
}

class VoiceCaptionEvent extends VoiceBackendEvent {
  const VoiceCaptionEvent(
    this.speaker,
    this.text, {
    this.finalized = false,
    this.segmentId,
  });
  final VoiceSpeaker speaker;
  final String text;
  final bool finalized;

  /// The utterance the caption belongs to, when the backend knows it: a
  /// partial and its final share it, and so does the pipeline segment.
  final String? segmentId;
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

/// What the capture path's speech filter did with one burst of audio, as the
/// backend reports it.  A backend that cannot see its own filter sends no
/// such event rather than guessing from a timer.
enum VoiceSegmentStage {
  /// The filter kept it; it is waiting to be transcribed.
  accepted,

  /// Speech to text is running on it.
  transcribing,

  /// Its words arrived.
  transcribed,

  /// It did not continue: too short, no words, cancelled or broken.
  dropped,

  /// Its transcription or delivery failed.
  failed,
}

/// Why a segment stopped at the capture or transcription stage.
enum VoiceSegmentDrop {
  /// The speech filter judged the burst too short to be a request.
  tooShort,

  /// It was kept, but no words came back for it.
  noWords,

  /// Mute, pause, stop or a restart dropped it before it was sent.
  cancelled,

  /// Transcription or delivery failed.
  failed,
}

/// One burst of audio, as the pipeline's own capture path judged it.  A
/// burst is reported here even when the filter rejected it, so the screen can
/// show what did not survive; a rejected event is not audio a model heard.
class VoiceSegmentEvent extends VoiceBackendEvent {
  const VoiceSegmentEvent({
    required this.id,
    required this.stage,
    this.duration,
    this.level,
    this.text,
    this.drop,
    this.detail,
  });

  /// A stable id for one utterance within a conversation, given by the
  /// backend that made the decision.  Two events with the same id are the
  /// same utterance, even when one arrives twice.
  final String id;
  final VoiceSegmentStage stage;

  /// How much audio the segment holds; null when the event is not about a
  /// finished burst (a live provider's speech onset).
  final Duration? duration;

  /// The loudest level of the burst, 0..1, as the meter reports it.
  final double? level;

  /// The words so far.  Partial transcripts replace it, finals complete it.
  final String? text;

  final VoiceSegmentDrop? drop;

  /// The failure's own words, for the detail line.  Data, not interface copy.
  final String? detail;
}

/// The voice output device: whether audio is playing now, and for which
/// reply when the backend knows.
///
/// This is playback, not text generation and not "the provider was handed
/// text": a backend emits it where its own player starts and stops.
class VoicePlaybackEvent extends VoiceBackendEvent {
  const VoicePlaybackEvent({
    required this.playing,
    this.replyId,
    this.generation = 0,
  });

  final bool playing;

  /// The reply whose audio this is, when the backend can name it.
  final String? replyId;

  /// The backend's generation counter, which interruption and stop change, so
  /// a completion from an earlier playback is recognisable as stale.
  final int generation;
}

/// The agent's reply was handed to the voice provider, which has not said
/// that it is playing it.  A live provider answers in its own time; claiming
/// `speaking` here would report text generation as speech.
class VoiceReplyHandedEvent extends VoiceBackendEvent {
  const VoiceReplyHandedEvent(this.replyId);
  final String replyId;
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
  ///
  /// [replyId] is the screen's stable id for it, which the backend returns on
  /// its playback events so the screen can tell which reply is playing.
  Future<void> speak(String text, {String? replyId});

  /// Stop the microphone and the provider's audio while keeping the
  /// conversation open.  A paused call resumes with [resume]; it is not
  /// [stop].
  Future<void> pause();

  /// Resume a paused call with the same session and settings.
  Future<void> resume();

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
