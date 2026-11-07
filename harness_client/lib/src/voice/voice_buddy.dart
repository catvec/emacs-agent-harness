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
