import 'package:flutter/foundation.dart';

/// What a voice screen is doing, in the words it puts under the orb.
///
/// The order is the order of a conversation: connect, listen, hear something,
/// transcribe it, let the agent think, speak the reply.  [muted], [interrupted],
/// [approval] and [failed] are states a conversation can be put into beside
/// that, not steps of it.
enum VoicePhase {
  idle,
  connecting,
  listening,
  hearing,
  transcribing,
  thinking,
  speaking,
  muted,
  paused,
  interrupted,
  approval,
  ended,
  failed,

  /// A provider named a phase this client does not know.  The honest
  /// answer is that the state is unknown, not the last state it saw.
  unknown,
}

extension VoicePhaseLabel on VoicePhase {
  /// The status line of the voice screen.  A noun phrase or an adjective, as
  /// every label in the app is: not a sentence.
  String get label => switch (this) {
    VoicePhase.idle => 'Idle',
    VoicePhase.connecting => 'Connecting',
    VoicePhase.listening => 'Listening',
    VoicePhase.hearing => 'Hearing you',
    VoicePhase.transcribing => 'Transcribing',
    VoicePhase.thinking => 'Thinking',
    VoicePhase.speaking => 'Speaking',
    VoicePhase.muted => 'Muted',
    VoicePhase.paused => 'Paused',
    VoicePhase.interrupted => 'Interrupted',
    VoicePhase.approval => 'Approval needed',
    VoicePhase.ended => 'Ended',
    VoicePhase.failed => 'Failed',
    VoicePhase.unknown => 'Status unknown',
  };

  /// Whether the microphone may be open in this phase.
  bool get hearsMicrophone =>
      this == VoicePhase.listening ||
      this == VoicePhase.hearing ||
      this == VoicePhase.thinking ||
      this == VoicePhase.speaking ||
      this == VoicePhase.transcribing;

  /// Whether the conversation is over, whether it ended well or not.
  bool get finished => this == VoicePhase.ended || this == VoicePhase.failed;
}

/// Who said a caption.
enum VoiceSpeaker { you, agent }

extension VoiceSpeakerLabel on VoiceSpeaker {
  String get label => switch (this) {
    VoiceSpeaker.you => 'You',
    VoiceSpeaker.agent => 'Agent',
  };
}

/// One line of the live transcript under the orb.
@immutable
class VoiceCaption {
  const VoiceCaption({
    required this.speaker,
    required this.text,
    this.finalized = false,
    this.sequence = 0,
  });

  final VoiceSpeaker speaker;
  final String text;

  /// False while the speaker is still being transcribed: the line grows in
  /// place rather than becoming a new one on every delta.
  final bool finalized;

  /// Keeps two identical lines apart: a person can say "yes" twice.
  final int sequence;

  VoiceCaption copyWith({String? text, bool? finalized, int? sequence}) =>
      VoiceCaption(
        speaker: speaker,
        text: text ?? this.text,
        finalized: finalized ?? this.finalized,
        sequence: sequence ?? this.sequence,
      );

  @override
  bool operator ==(Object other) =>
      other is VoiceCaption &&
      other.speaker == speaker &&
      other.text == text &&
      other.finalized == finalized &&
      other.sequence == sequence;

  @override
  int get hashCode => Object.hash(speaker, text, finalized, sequence);
}

/// What went wrong, as the voice screen says it and as a log can read it.
@immutable
class VoiceProblem {
  const VoiceProblem(this.label, {this.detail, this.recoverable = true});

  /// A noun phrase for the person, e.g. `Microphone unavailable`.
  final String label;

  /// The exception or server's own words, shown small under the label.  Not
  /// interface copy: data from the thing that failed.
  final String? detail;

  /// Whether the session can go on after it: a sentence that could not be
  /// transcribed is recoverable, a closed microphone is not.
  final bool recoverable;

  @override
  String toString() => detail == null ? label : '$label · $detail';
}

/// One thing a voice backend asks the session to send.
@immutable
class VoicePrompt {
  const VoicePrompt({
    this.text,
    this.audio,
    this.pending,
    this.displayText,
    this.id,
    this.segmentId,
  });

  /// The words to send, if the provider transcribed the utterance.  A
  /// controller may append explicit pending-update context to this before
  /// [VoiceSessionBridge.send]; [displayText] stays what the person said.
  final String? text;

  /// A WAV clip, when the provider sends the audio itself.
  final Uint8List? audio;

  /// Assistant output that was held while the person spoke, if any.  Each
  /// piece travels with the transcript as context, never as a stale replay.
  final List<String>? pending;

  /// The caption and local echo for the utterance, without context.
  final String? displayText;

  /// A stable id for the utterance, so a repeated provider event reaches the
  /// session once.  Null when the provider has no id.
  final String? id;

  /// The pipeline segment that carried these words, when the backend names
  /// one.  It is the same id its [VoiceSegmentEvent]s use, which need not be
  /// the provider's id (a live provider names a delegation, not an onset).
  final String? segmentId;

  bool get isEmpty => (text == null || text!.trim().isEmpty) && audio == null;

  String? get spokenText => displayText ?? text;

  VoicePrompt copyWith({
    String? text,
    String? displayText,
    List<String>? pending,
  }) => VoicePrompt(
    text: text ?? this.text,
    audio: audio,
    pending: pending ?? this.pending,
    displayText: displayText ?? this.displayText,
    id: id,
    segmentId: segmentId,
  );
}
