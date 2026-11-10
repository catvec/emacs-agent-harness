import 'package:flutter/foundation.dart';

import 'voice_controller.dart';
import 'voice_models.dart';

/// What the compact buddy says the call is doing.
///
/// The words are the ones the voice contract uses
/// (`docs/voice-realtime.md`, "UI states"), with the app's own real states
/// (`Paused`, `Approval needed`, `Ended`) and an honest [unknown] when no
/// state can be named.  Every value is a noun phrase or an adjective.
enum BuddyPhase {
  off,
  starting,
  listening,
  hearing,
  transcribing,
  working,
  holdingReply,
  speaking,
  interrupted,
  muted,
  paused,
  approval,
  ending,
  ended,
  failed,
  unknown,
}

extension BuddyPhaseCopy on BuddyPhase {
  String get label => switch (this) {
    BuddyPhase.off => 'Off',
    BuddyPhase.starting => 'Starting',
    BuddyPhase.listening => 'Listening',
    BuddyPhase.hearing => 'Hearing you',
    BuddyPhase.transcribing => 'Transcribing',
    BuddyPhase.working => 'Working',
    BuddyPhase.holdingReply => 'Holding reply',
    BuddyPhase.speaking => 'Speaking',
    BuddyPhase.interrupted => 'Interrupted',
    BuddyPhase.muted => 'Muted',
    BuddyPhase.paused => 'Paused',
    BuddyPhase.approval => 'Approval needed',
    BuddyPhase.ending => 'Ending',
    BuddyPhase.ended => 'Ended',
    BuddyPhase.failed => 'Failed',
    BuddyPhase.unknown => 'Status unknown',
  };
}

/// What the microphone is actually doing, from the controller's contract.
///
/// `Mic live` means the call holds capture open; `Mic muted` and
/// `Mic paused` mean it does not.  No meter or activity may be drawn for a
/// state that is not [live].
enum BuddyMic { off, starting, live, muted, paused, closing }

extension BuddyMicCopy on BuddyMic {
  String get label => switch (this) {
    BuddyMic.off => 'Mic off',
    BuddyMic.starting => 'Mic starting',
    BuddyMic.live => 'Mic live',
    BuddyMic.muted => 'Mic muted',
    BuddyMic.paused => 'Mic paused',
    BuddyMic.closing => 'Mic closing',
  };
}

/// The output side of a conversation that may be speaking while the person
/// is also being heard.  It is kept apart from [BuddyPhase] so the compact
/// card can show both at once.
enum BuddyOutput { idle, speaking, held, working }

extension BuddyOutputCopy on BuddyOutput {
  String get label => switch (this) {
    BuddyOutput.idle => '',
    BuddyOutput.speaking => 'Speaking',
    BuddyOutput.held => 'Reply held',
    BuddyOutput.working => 'Working',
  };
}

/// The connection the workspace and its call depend on.
enum BuddyConnection { connected, reconnecting, offline }

extension BuddyConnectionCopy on BuddyConnection {
  String get label => switch (this) {
    BuddyConnection.connected => 'Connected',
    BuddyConnection.reconnecting => 'Reconnecting',
    BuddyConnection.offline => 'Offline',
  };
}

/// The whole state a compact surface draws, resolved from the real
/// controller.  It is immutable so a widget test can state one directly.
@immutable
class BuddyStatus {
  const BuddyStatus({
    required this.phase,
    required this.mic,
    this.output = BuddyOutput.idle,
    this.levelReported = false,
  });

  final BuddyPhase phase;
  final BuddyMic mic;
  final BuddyOutput output;

  /// Whether the provider has reported a level in this call.
  final bool levelReported;

  /// The output state that the status word does not already name.  When the
  /// person speaks while a reply is held or being played, both are true and
  /// the card shows the second one on its activity line.
  BuddyOutput get extraOutput {
    final primary = switch (phase) {
      BuddyPhase.speaking => BuddyOutput.speaking,
      BuddyPhase.holdingReply => BuddyOutput.held,
      BuddyPhase.working => BuddyOutput.working,
      _ => BuddyOutput.idle,
    };
    if (output == BuddyOutput.idle || output == primary) {
      return BuddyOutput.idle;
    }
    return output;
  }

  /// A meter is drawn only for a live microphone whose backend reports
  /// levels.  The live stream reports none, so it gets the words and no
  /// invented activity.
  bool get showsLevel => mic == BuddyMic.live && levelReported;
}

BuddyMic buddyMicFor(VoiceController? voice) {
  if (voice == null) return BuddyMic.off;
  if (voice.stopping) return BuddyMic.closing;
  if (!voice.started || voice.phase.finished) return BuddyMic.off;
  if (voice.phase == VoicePhase.connecting) return BuddyMic.starting;
  if (voice.paused) return BuddyMic.paused;
  if (voice.muted) return BuddyMic.muted;
  return BuddyMic.live;
}

BuddyOutput buddyOutputFor(VoiceController? voice) {
  if (voice == null) return BuddyOutput.idle;
  if (voice.phase == VoicePhase.speaking) return BuddyOutput.speaking;
  if (voice.holdingReply) return BuddyOutput.held;
  if (voice.bridge.working) return BuddyOutput.working;
  return BuddyOutput.idle;
}

/// The status word, with the precedence of the Emacs live status
/// (`harness-voice-live--status`) so both clients say the same thing for
/// the same reported state.
BuddyPhase buddyPhaseFor(VoiceController? voice) {
  if (voice == null) return BuddyPhase.off;
  if (voice.stopping) return BuddyPhase.ending;
  if (voice.phase == VoicePhase.failed) return BuddyPhase.failed;
  if (voice.phase == VoicePhase.connecting) return BuddyPhase.starting;
  if (voice.paused) return BuddyPhase.paused;
  if (voice.bridge.blocked) return BuddyPhase.approval;
  if (voice.phase == VoicePhase.interrupted) {
    return BuddyPhase.interrupted;
  }
  if (voice.speechActive || voice.phase == VoicePhase.hearing) {
    return BuddyPhase.hearing;
  }
  if (voice.phase == VoicePhase.transcribing) return BuddyPhase.transcribing;
  if (voice.phase == VoicePhase.thinking) return BuddyPhase.working;
  if (voice.phase == VoicePhase.speaking) return BuddyPhase.speaking;
  if (voice.holdingReply) return BuddyPhase.holdingReply;
  if (voice.bridge.working) return BuddyPhase.working;
  if (voice.muted) return BuddyPhase.muted;
  if (voice.phase == VoicePhase.listening) return BuddyPhase.listening;
  if (voice.phase == VoicePhase.approval) return BuddyPhase.approval;
  if (voice.phase == VoicePhase.ended) return BuddyPhase.ended;
  if (voice.phase == VoicePhase.idle) return BuddyPhase.off;
  return BuddyPhase.unknown;
}

BuddyStatus buddyStatusFor(VoiceController? voice) => BuddyStatus(
  phase: buddyPhaseFor(voice),
  mic: buddyMicFor(voice),
  output: buddyOutputFor(voice),
  levelReported: voice?.levelReported ?? false,
);

/// A small immutable view of a buddy, for the card.
@immutable
class BuddyViewModel {
  const BuddyViewModel({
    required this.workspaceName,
    required this.threadTitle,
    required this.connection,
    required this.connectionDetail,
    required this.providerLabel,
    required this.status,
    required this.muted,
    required this.paused,
    required this.starting,
    required this.running,
    required this.canStart,
    required this.canEnd,
    required this.canMute,
    required this.canPause,
    required this.canInterrupt,
    required this.canRetry,
    this.problem,
    this.note,
    this.level = 0,
  });

  /// The selected workspace's name, or the one the running call is pinned
  /// to when the selection changed under it.
  final String workspaceName;

  /// The thread the call is attached to (or, while off, the active one).
  final String? threadTitle;

  final BuddyConnection connection;

  /// The harness address, for the connection's tooltip.  Data, not copy.
  final String connectionDetail;

  /// `Clip` or `Live`: the configured voice provider.
  final String providerLabel;

  final BuddyStatus status;
  final bool muted;
  final bool paused;
  final bool starting;
  final bool running;

  /// Whether a call can begin on the active thread's live session.
  final bool canStart;

  /// Whether End may be pressed (starting or running).
  final bool canEnd;
  final bool canMute;
  final bool canPause;
  final bool canInterrupt;

  /// Whether Retry is offered after a problem.
  final bool canRetry;

  /// The controller's problem, as its own label and detail (data).
  final VoiceProblem? problem;

  /// A safe-lifecycle note: `No live episode`, `Voice setup`, `Call lost`,
  /// `Connection lost`; null when there is nothing to say.
  final String? note;

  final double level;

  bool get showsLevel => status.showsLevel;
  BuddyOutput get extraOutput => status.extraOutput;
  bool get showsProblem => problem != null;
  bool get ended => status.phase == BuddyPhase.ended;
  bool get failed => status.phase == BuddyPhase.failed;
  bool get ending => status.phase == BuddyPhase.ending;
}

/// The tone of the buddy's ring: the one thing on the circle that changes.
///
/// It is a *group* of the phases that mean the same thing at a glance, not a
/// new state: every value is derived from a [BuddyStatus] the controller
/// already reports, and the glyph and the words beside the circle carry the
/// exact phase.
enum BuddyRingTone {
  /// No call, or one that has stopped: an outline, no fill.
  neutral,

  /// The call is open and the microphone or the player is really moving.
  live,

  /// The capture gate heard speech, before any transcript exists.
  hearing,

  /// The call is between stages: starting, transcribing, working, held back,
  /// waiting on an approval.
  attention,

  /// Capture is closed by the person, paused, interrupted or stopping.
  muted,

  /// The backend reported a failure.
  failed,

  /// No phase can be named.
  unknown,
}

/// How the circle draws the last reported state.
///
/// It holds no state of its own and runs nothing on a clock: the widget that
/// draws it changes only when a report changes [tone], [weight], [dashed] or
/// [pulse].
@immutable
class BuddyRing {
  const BuddyRing({
    required this.tone,
    required this.word,
    required this.micWord,
    required this.weight,
    this.dashed = false,
    this.pulse = false,
    this.gap = false,
  });

  final BuddyRingTone tone;

  /// The status word, the same one the bar and the card show.
  final String word;

  /// The microphone word, so a reader never has to infer capture from colour.
  final String micWord;

  /// The ring's stroke width, in logical pixels.
  final double weight;

  /// A broken ring: capture is closed by the person, or the conversation is
  /// paused.  The gap is the non-colour cue for `Muted` and `Paused`.
  final bool dashed;

  /// Whether the ring may follow a reported level.  It is off whenever the
  /// microphone is not live or the backend reports no levels, and the widget
  /// turns it off again under reduced motion.
  final bool pulse;

  /// A gap at the top of the ring: a reply is held back while the person may
  /// still be heard.
  final bool gap;

  /// The whole state on one line, for a tooltip or a screen reader.
  String get label => 'Status · $word · $micWord';
}

/// The ring for a status, from the same resolved fields the card and the bar
/// use.  Every branch reads a reported value; nothing here invents a stage.
BuddyRing buddyRingFor(BuddyStatus status) {
  final tone = switch (status.phase) {
    BuddyPhase.off || BuddyPhase.ended => BuddyRingTone.neutral,
    BuddyPhase.failed => BuddyRingTone.failed,
    BuddyPhase.unknown => BuddyRingTone.unknown,
    BuddyPhase.listening || BuddyPhase.speaking => BuddyRingTone.live,
    BuddyPhase.hearing => BuddyRingTone.hearing,
    BuddyPhase.starting ||
    BuddyPhase.transcribing ||
    BuddyPhase.working ||
    BuddyPhase.holdingReply ||
    BuddyPhase.approval => BuddyRingTone.attention,
    BuddyPhase.interrupted ||
    BuddyPhase.muted ||
    BuddyPhase.paused ||
    BuddyPhase.ending => BuddyRingTone.muted,
  };
  return BuddyRing(
    tone: tone,
    word: status.phase.label,
    micWord: status.mic.label,
    // Speech heard gets a heavier ring: a second, shape-level cue beside the
    // colour and the word.
    weight: status.phase == BuddyPhase.hearing ? 4 : 3,
    dashed:
        status.phase == BuddyPhase.muted || status.phase == BuddyPhase.paused,
    // Only a state whose words are about capture may move with the capture
    // level: a speaking or working call has nothing to say about the
    // microphone's loudness, so its ring stays still.
    pulse:
        status.showsLevel &&
        (status.phase == BuddyPhase.listening ||
            status.phase == BuddyPhase.hearing),
    gap: status.phase == BuddyPhase.holdingReply,
  );
}
