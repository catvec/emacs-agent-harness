import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../voice/voice_pipeline.dart';
import '../../voice/voice_ribbon.dart';
import 'voice_ribbon.dart';

/// The voice pipe as one control: a continuous pill of stage bars, and, on a
/// surface too small for the pill, the same bars around a ring.
///
/// It draws a [VoicePipelineSnapshot] and decides nothing: a cluster moves
/// only when the snapshot says the stage it waits on reported, so the picture
/// is of real events, not an animation that runs by itself.
///
/// The control carries no words: no stage key, no legend, no count, no
/// status line and no way into the details.  The stages are told apart by
/// their bar shapes and colours, and a screen reader hears the pipe and each
/// cluster from the [Semantics] nodes.  Every measurement and every id lives
/// in the voice settings, which is the only way in.
class VoicePipelineView extends StatefulWidget {
  const VoicePipelineView({
    super.key,
    required this.snapshot,
    this.compact = false,
    this.clock,
  });

  final VoicePipelineSnapshot snapshot;

  /// A collapsed, mini or picture-in-picture surface: the same clusters
  /// around a ring instead of the pill.  A full-size surface keeps the pill
  /// at every text size, so large text never turns it into a ring.
  final bool compact;

  /// What "now" is for the level's freshness.  A test or a preview passes
  /// its own; the app reads the clock.
  final DateTime Function()? clock;

  /// The pill's height on a full-size surface.
  static const pillHeight = 46.0;

  /// The ring's side on a compact surface.
  static const ringSide = 104.0;

  @override
  State<VoicePipelineView> createState() => _VoicePipelineViewState();
}

class _VoicePipelineViewState extends State<VoicePipelineView> {
  Timer? _staleTimer;
  DateTime? _staleDeadline;

  @override
  void initState() {
    super.initState();
    _scheduleStaleCheck();
  }

  @override
  void didUpdateWidget(VoicePipelineView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.snapshot.levelAt != widget.snapshot.levelAt) {
      _scheduleStaleCheck();
    }
  }

  @override
  void dispose() {
    _staleTimer?.cancel();
    super.dispose();
  }

  /// One wake-up for the moment the last level becomes too old to stand for
  /// the present, so a frozen meter turns into "no data" rather than
  /// pretending to be a quiet room.
  void _scheduleStaleCheck() {
    final snapshot = widget.snapshot;
    final at = snapshot.levelAt;
    if (!snapshot.levelSeen || at == null) {
      _staleTimer?.cancel();
      _staleTimer = null;
      _staleDeadline = null;
      return;
    }
    final deadline = at.add(VoicePipelineSnapshot.staleAfter);
    if (deadline == _staleDeadline) return;
    _staleTimer?.cancel();
    _staleDeadline = deadline;
    final now = _now;
    final wait = deadline.difference(now);
    _staleTimer = Timer(wait.isNegative ? Duration.zero : wait, () {
      _staleTimer = null;
      _staleDeadline = null;
      if (mounted) setState(() {});
    });
  }

  DateTime get _now => (widget.clock ?? DateTime.now)();

  bool get _motion => MediaQuery.maybeOf(context)?.disableAnimations != true;

  @override
  Widget build(BuildContext context) {
    final now = _now;
    final snapshot = widget.snapshot;
    final ribbon = VoiceRibbon.fromSnapshot(snapshot, now, motion: _motion);
    return LayoutBuilder(
      builder: (context, constraints) {
        final room = constraints.maxHeight;
        // A compact surface draws the ring when it has the room for one; a
        // surface with too little room draws nothing at all rather than a
        // broken ring.  The pill shrinks to the room it has and never turns
        // into a ring for its text size.
        if (widget.compact) {
          final side = math.min(
            VoicePipelineView.ringSide,
            room.isFinite ? room : VoicePipelineView.ringSide,
          );
          if (side < 44) return const SizedBox.shrink();
          return Center(
            child: VoiceRibbonView(
              key: const Key('voice-pipeline-ring'),
              form: VoiceRibbonPresentation.polar,
              clock: widget.clock,
              height: side,
              ribbon: ribbon,
            ),
          );
        }
        final height = math.min(
          VoicePipelineView.pillHeight,
          room.isFinite ? math.max(16.0, room) : VoicePipelineView.pillHeight,
        );
        return Center(
          child: VoiceRibbonView(
            key: const Key('voice-pipeline-ribbon'),
            clock: widget.clock,
            height: height,
            ribbon: ribbon,
          ),
        );
      },
    );
  }
}
