import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'voice_backend.dart';
import 'voice_pipeline.dart';

/// Where on the pipe a blip sits.  The position is the stage's place in the
/// pipeline, never how long anything spent there: [audio] is the microphone's
/// own level before the speech filter, then the speech the filter kept, the
/// words, the agent's processing and the audio out.
enum VoiceRibbonBand { audio, speech, words, processing, audioOut }

extension VoiceRibbonBandCopy on VoiceRibbonBand {
  /// The word under the band, a noun or a noun phrase.
  String get label => switch (this) {
    VoiceRibbonBand.audio => 'Audio',
    VoiceRibbonBand.speech => 'Speech',
    VoiceRibbonBand.words => 'Words',
    VoiceRibbonBand.processing => 'Processing',
    VoiceRibbonBand.audioOut => 'Audio out',
  };

  /// The one-line tooltip of the band: what its data is.
  String get help => switch (this) {
    VoiceRibbonBand.audio => 'Microphone level before the speech filter',
    VoiceRibbonBand.speech => 'Speech kept for transcription',
    VoiceRibbonBand.words => 'Speech to text',
    VoiceRibbonBand.processing => 'Agent work',
    VoiceRibbonBand.audioOut => 'Playback',
  };

  /// Its fraction along the ribbon, and its angle around the compact ring
  /// (0 is twelve o'clock, running clockwise).
  double get fraction => index / VoiceRibbonBand.values.length;

  /// Where the stage's bars sit across the ribbon: the middle of its
  /// own stretch of the pill, so the five stages read as one
  /// continuous sequence of bars rather than five columns.
  double get centre => const [0.075, 0.27, 0.465, 0.66, 0.865][index];
}

/// The shape of one blip: the stage, drawn so that it is recognisable
/// without its colour.  [level] is the microphone's own bars.
enum VoiceRibbonForm {
  level,
  accepted,
  transcribing,
  transcribed,
  inTurn,
  answered,
  ready,
  held,
  handed,
  speaking,
  spoken,
  interrupted,
  dropped,
  failed,
}

extension VoiceRibbonFormCopy on VoiceRibbonForm {
  /// Whether the pipe is waiting on this stage to report.  Only these
  /// warble, and they warble in place.
  bool get waits => switch (this) {
    VoiceRibbonForm.transcribing ||
    VoiceRibbonForm.inTurn ||
    VoiceRibbonForm.ready ||
    VoiceRibbonForm.held ||
    VoiceRibbonForm.handed => true,
    _ => false,
  };

  /// Whether the blip clears after its linger.
  bool get terminal => switch (this) {
    VoiceRibbonForm.answered ||
    VoiceRibbonForm.dropped ||
    VoiceRibbonForm.failed ||
    VoiceRibbonForm.spoken ||
    VoiceRibbonForm.interrupted => true,
    _ => false,
  };

  /// Whether the form is a loss: an accepted burst or reply that stopped.
  bool get lost => switch (this) {
    VoiceRibbonForm.dropped || VoiceRibbonForm.failed => true,
    _ => false,
  };
}

/// One mark on the ribbon: a real id at a real stage.
@immutable
class VoiceRibbonBlip {
  const VoiceRibbonBlip({
    required this.id,
    required this.band,
    required this.form,
    required this.label,
    this.level,
    this.tone = VoiceRibbonTone.quiet,
    this.at,
    this.ended,
    this.lane = 0,
  });

  /// The backend's stable id: `u-N`, `r-N`, `n-N`, or `input`.
  final String id;
  final VoiceRibbonBand band;
  final VoiceRibbonForm form;

  /// The words of the blip: its id, its stage, its measurement and its
  /// reason.  It is what a screen reader and a tooltip say.
  final String label;

  /// The microphone's level, 0..1, for the [VoiceRibbonForm.level] blip.
  /// Null is "no level measured", which is drawn hollow, never as silence.
  final double? level;

  final VoiceRibbonTone tone;

  /// When the blip reached its stage, and when the pipe ended it.
  final DateTime? at;
  final DateTime? ended;

  /// Its row among the blips of its own band, so two real bursts in one
  /// stage are two marks rather than one drawn over the other.
  final int lane;

  bool get waits => form.waits;
  bool get terminal => form.terminal;

  VoiceRibbonBlip copyWith({int? lane}) => VoiceRibbonBlip(
    id: id,
    band: band,
    form: form,
    label: label,
    level: level,
    tone: tone,
    at: at,
    ended: ended,
    lane: lane ?? this.lane,
  );

  /// Whether it is still drawn at [now]: a terminal blip lingers for
  /// [VoiceRibbon.linger] and then clears without advancing.
  bool visibleAt(DateTime now) {
    if (!terminal) return true;
    final endedAt = ended;
    if (endedAt == null) return true;
    return now.difference(endedAt) <= VoiceRibbon.linger;
  }
}

/// What a blip's colour says.  It is never the only cue: the form and the
/// words say the same thing.
enum VoiceRibbonTone { quiet, working, active, current, success, failure }

/// The ribbon's stage words, its shapes and the blips a snapshot makes of
/// them.  One instance serves both the linear ribbon and the compact ring:
/// they differ only in [geometry].
@immutable
class VoiceRibbon {
  const VoiceRibbon({
    required this.blips,
    required this.summary,
    this.motion = true,
  });

  final List<VoiceRibbonBlip> blips;

  /// The words of the whole pipe, which are the same in both forms.
  final String summary;

  /// False under reduced motion: no warble, every form still.
  final bool motion;

  /// How long a dropped, failed or completed blip stays before it clears.
  static const linger = Duration(milliseconds: 2500);

  /// How many times a second a waiting blip is redrawn.
  ///
  /// This is the host's refresh of the breath, not the breath itself: the
  /// breath takes [warbleBreath], so the redraws sample it at this many
  /// points.  Redrawing at the breath's own rate would sample the same phase
  /// every time and the swell would stand still.
  static const warbleFramesPerSecond = 5;

  /// Seconds one full breath of a waiting blip takes.
  ///
  /// A breath is the swell out and back: slow enough to read as waiting rather
  /// than as a pulse, and longer than the redraw interval on purpose, so the
  /// redraws land on different points of it.
  static const warbleBreath = Duration(milliseconds: 1600);

  /// The blips drawn at [now], oldest first.
  List<VoiceRibbonBlip> visibleAt(DateTime now) =>
      blips.where((blip) => blip.visibleAt(now)).toList();

  /// The warble's own phase at [now], in 0..1: 0 is the trough of the breath
  /// and 0.5 the crest.  A shape that waits scales by this, so it swells and
  /// settles instead of stepping between two frames.
  ///
  /// The breath is its own period, not the redraw interval: sampling a sine
  /// once per period gives the same phase every time, and the swell stands
  /// still — a blink dressed up as a breath.
  double warblePhaseAt(DateTime now) {
    if (!motion) return 0.0;
    final seconds = now.millisecondsSinceEpoch / 1000.0;
    final breath = warbleBreath.inMicroseconds / Duration.microsecondsPerSecond;
    return (math.sin(seconds / breath * 2 * math.pi) + 1) / 2;
  }

  /// The blips of one band at [now], oldest first, with their lanes.
  List<VoiceRibbonBlip> bandAt(VoiceRibbonBand band, DateTime now) {
    var lane = 0;
    return [
      for (final blip in visibleAt(now))
        if (blip.band == band) blip.copyWith(lane: lane++),
    ];
  }

  /// The shape a blip draws at [now].  A waiting blip's frame changes with
  /// the clock, and nothing else moves without an event.
  ///
  /// A one-row form has no height to swell, so it shows the breath as two
  /// glyphs instead.  The frame follows the breath rather than the redraw:
  /// crossing at the breath's own pace reads as a swell, while flipping at
  /// the redraw rate is a blink.
  int frameAt(DateTime now) {
    if (!motion) return 0;
    return warblePhaseAt(now) >= 0.5 ? 1 : 0;
  }

  /// When the ribbon next changes by itself, or null when only an event
  /// can change it.  A host redraws then instead of running a ticker.
  Duration? nextChange(DateTime now) {
    Duration? next;
    void consider(Duration wait) {
      if (wait.isNegative) return;
      if (next == null || wait < next!) next = wait;
    }

    if (motion && visibleAt(now).any((blip) => blip.waits)) {
      consider(
        Duration(
          milliseconds: 1000 ~/ warbleFramesPerSecond,
        ),
      );
    }
    for (final blip in visibleAt(now)) {
      if (!blip.terminal) continue;
      final endedAt = blip.ended;
      if (endedAt == null) continue;
      final deadline = endedAt.add(linger).difference(now);
      if (!deadline.isNegative) consider(deadline);
    }
    return next;
  }

  /// The one line of words naming every band, in pipe order.
  static String get legend =>
      VoiceRibbonBand.values.map((band) => band.label).join(' · ');

  /// The blips a snapshot makes: one per real id.
  ///
  /// A turn is deliberately not a blip of its own.  The segments that fed it
  /// are bars in the processing band already, and a separate turn mark would
  /// draw one utterance in two places and suggest that one reply answers one
  /// utterance.  A reply is one blip of its own on the audio-out band, with
  /// the stage the provider actually reported.
  static VoiceRibbon fromSnapshot(
    VoicePipelineSnapshot snapshot,
    DateTime now, {
    bool motion = true,
  }) {
    final blips = <VoiceRibbonBlip>[];

    // The microphone, while audio may really be reaching the app.
    if (snapshot.input.captureOpen ||
        snapshot.input == VoiceInputState.connecting) {
      final stale = snapshot.levelStale(now);
      blips.add(
        VoiceRibbonBlip(
          id: 'input',
          band: VoiceRibbonBand.audio,
          form: VoiceRibbonForm.level,
          label: snapshot.meterLabel(now),
          level: stale ? null : snapshot.level,
          tone: stale ? VoiceRibbonTone.quiet : VoiceRibbonTone.active,
        ),
      );
    }

    for (final segment in snapshot.segments) {
      final form = _segmentForm(segment);
      blips.add(
        VoiceRibbonBlip(
          id: segment.id,
          band: bandOfSegment(segment),
          form: form,
          label: _segmentLabel(segment),
          tone: _tone(form),
          ended: segment.endedAt,
        ),
      );
    }

    for (final reply in snapshot.replies) {
      final form = _replyForm(reply.stage);
      blips.add(
        VoiceRibbonBlip(
          id: reply.id,
          band: VoiceRibbonBand.audioOut,
          form: form,
          label: _replyLabel(reply),
          tone: _tone(form),
          ended: reply.endedAt,
        ),
      );
    }

    return VoiceRibbon(
      blips: List.unmodifiable(blips),
      summary: snapshot.summary(now),
      motion: motion,
    );
  }

  /// The band a segment is drawn in.
  ///
  /// A dropped or failed segment keeps the band it had reached, which the
  /// pipeline records as the column it stopped in: a burst the filter
  /// rejected stays in the speech band, one whose words were empty stops in
  /// the words band, and one that failed between them keeps the transcript's
  /// place.  A loss is drawn where it happened, never at the next step.
  static VoiceRibbonBand bandOfSegment(VoiceSegment segment) {
    if (segment.stage != VoicePipelineStage.dropped &&
        segment.stage != VoicePipelineStage.failed) {
      return switch (segment.stage) {
        VoicePipelineStage.accepted => VoiceRibbonBand.speech,
        VoicePipelineStage.transcribing ||
        VoicePipelineStage.transcribed => VoiceRibbonBand.words,
        VoicePipelineStage.inTurn ||
        VoicePipelineStage.answered => VoiceRibbonBand.processing,
        VoicePipelineStage.dropped || VoicePipelineStage.failed =>
          VoiceRibbonBand.speech,
      };
    }
    return switch (segment.column) {
      VoicePipelineColumn.filter => VoiceRibbonBand.speech,
      VoicePipelineColumn.transcript => VoiceRibbonBand.words,
      VoicePipelineColumn.turn => VoiceRibbonBand.processing,
    };
  }

  static VoiceRibbonForm _segmentForm(VoiceSegment segment) =>
      switch (segment.stage) {
        VoicePipelineStage.accepted => VoiceRibbonForm.accepted,
        VoicePipelineStage.transcribing => VoiceRibbonForm.transcribing,
        VoicePipelineStage.transcribed => VoiceRibbonForm.transcribed,
        VoicePipelineStage.inTurn => VoiceRibbonForm.inTurn,
        VoicePipelineStage.answered => VoiceRibbonForm.answered,
        VoicePipelineStage.dropped =>
          segment.drop == VoiceSegmentDrop.failed
              ? VoiceRibbonForm.failed
              : VoiceRibbonForm.dropped,
        VoicePipelineStage.failed => VoiceRibbonForm.failed,
      };

  static VoiceRibbonForm _replyForm(VoiceReplyStage stage) => switch (stage) {
    VoiceReplyStage.ready => VoiceRibbonForm.ready,
    VoiceReplyStage.held => VoiceRibbonForm.held,
    VoiceReplyStage.handed => VoiceRibbonForm.handed,
    VoiceReplyStage.speaking => VoiceRibbonForm.speaking,
    VoiceReplyStage.spoken => VoiceRibbonForm.spoken,
    VoiceReplyStage.interrupted => VoiceRibbonForm.interrupted,
    VoiceReplyStage.dropped => VoiceRibbonForm.dropped,
    VoiceReplyStage.failed => VoiceRibbonForm.failed,
  };

  static VoiceRibbonTone _tone(VoiceRibbonForm form) => switch (form) {
    VoiceRibbonForm.transcribing ||
    VoiceRibbonForm.held => VoiceRibbonTone.working,
    VoiceRibbonForm.inTurn ||
    VoiceRibbonForm.speaking ||
    VoiceRibbonForm.handed => VoiceRibbonTone.current,
    VoiceRibbonForm.accepted ||
    VoiceRibbonForm.transcribed ||
    VoiceRibbonForm.ready ||
    VoiceRibbonForm.level => VoiceRibbonTone.active,
    VoiceRibbonForm.answered || VoiceRibbonForm.spoken => VoiceRibbonTone.success,
    VoiceRibbonForm.dropped ||
    VoiceRibbonForm.failed ||
    VoiceRibbonForm.interrupted => VoiceRibbonTone.failure,
  };

  /// A segment's blip label: its id, its stage, its length and its reason.
  static String _segmentLabel(VoiceSegment segment) {
    final parts = <String?>[
      segment.id,
      segment.stage.label,
      if (segment.duration case final duration?) voicePipelineDuration(duration),
      if (segment.dropLabel case final reason?) reason,
    ];
    return parts.whereType<String>().where((p) => p.isNotEmpty).join(' · ');
  }

  static String _replyLabel(VoiceReply reply) {
    final parts = <String?>[
      reply.id,
      reply.stage.label,
      if (reply.detail case final detail? when detail.trim().isNotEmpty) detail,
    ];
    return parts.whereType<String>().where((p) => p.isNotEmpty).join(' · ');
  }
}

/// Where the same blip is drawn in each form.
///
/// [linear] gives a fraction of the width and a lane; [polar] gives the
/// angle around a circle (twelve o'clock is 0, running clockwise) and a
/// radius factor (1 is the outer ring, less is closer in).  Both are
/// functions of the blip's band, never of how long it has been there.
@immutable
class VoiceRibbonGeometry {
  const VoiceRibbonGeometry._({
    required this.linear,
    required this.polar,
    required this.radius,
  });

  final OffsetInRibbon Function(VoiceRibbonBand band, int lane) linear;
  final double Function(VoiceRibbonBand band) polar;

  /// The radius of a lane: the outermost lane is 1, a second blip in the
  /// same band is nearer the centre.
  final double Function(int lane) radius;

  static const geometry = VoiceRibbonGeometry._(
    linear: _linearPoint,
    polar: _polarAngle,
    radius: _laneRadius,
  );

  static OffsetInRibbon _linearPoint(VoiceRibbonBand band, int lane) =>
      OffsetInRibbon(
        band == VoiceRibbonBand.audioOut ? 0.97 : band.fraction + 0.06,
        lane,
      );

  static double _polarAngle(VoiceRibbonBand band) => band.fraction * 2 * math.pi;

  static double _laneRadius(int lane) =>
      lane <= 0 ? 1.0 : math.max(0.42, 1.0 - lane * 0.26);
}

/// A point along the linear ribbon: its fraction of the width and its lane.
@immutable
class OffsetInRibbon {
  const OffsetInRibbon(this.fraction, this.lane);
  final double fraction;
  final int lane;
}
