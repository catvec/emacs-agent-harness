import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../voice/voice_buddy.dart';
import '../theme/harness_theme.dart';

/// The buddy as a circle: an identity face inside a ring that says the last
/// *reported* state of the workspace's call.
///
/// The face is identity and never changes.  The ring is the only thing that
/// changes, and it changes when a report arrives: there is no clock here, no
/// sweep and no spinner.  A level, when the backend really reports one, varies
/// the ring's opacity; reduced motion removes even that, and the ring's
/// colour, thickness, dashes, gap and the badge glyph carry the state either
/// way.
///
/// The circle is never the only way to reach the call: `Mute` and `End` stay
/// beside it in the bar and on the away card.
class VoiceBuddyDot extends StatelessWidget {
  const VoiceBuddyDot({
    super.key,
    required this.status,
    required this.workspaceName,
    this.level = 0,
    this.size = 28,
    this.pulseAllowed = true,
    this.face,
  });

  final BuddyStatus status;

  /// The face's letter when no [face] is given: the workspace's own initial,
  /// so the circle names the workspace it belongs to without inventing an
  /// avatar.
  final String workspaceName;

  /// The last reported capture level, 0..1.  It moves the ring only for a live
  /// microphone whose backend reports levels, and only when [pulseAllowed].
  final double level;

  final double size;

  /// False under reduced motion, and for a surface that must stay still.
  final bool pulseAllowed;

  /// Overrides the face, such as a person's profile image.  Null draws the
  /// workspace's initial.
  final Widget? face;

  /// The ring grows with the circle but stays a ring: a 44 px circle gets a
  /// 3 px ring, the 28 px bar mark a 2 px one.
  static double ringFor(double size) => size >= 40 ? 3 : 2;

  /// The diameter a caller should reserve for [size] plus its 1 px breathing
  /// room, so a row does not jump when the circle swaps in.
  static double footprintFor(double size) => size + 2;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ring = buddyRingFor(status);
    final ringWidth = ringFor(size);
    final color = ringColor(context, ring.tone);
    final opacity = ring.pulse && pulseAllowed
        ? (0.55 + level.clamp(0.0, 1.0) * 0.45)
        : 1.0;
    final badge = math.max(12.0, size * 0.42);
    // The circle is a mark, not a button: it carries its state as an
    // accessible label and tooltip, and draws no hover popup of its own.  A
    // popup would need an Overlay, and this mark sits in the call bar, which
    // is hosted above the navigator on every page.
    return Semantics(
      key: const Key('voice-buddy-dot'),
      container: true,
      label: ring.label,
      tooltip: 'Voice buddy · ${ring.word}',
      child: ExcludeSemantics(
        child: SizedBox(
            width: size,
            height: size,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: _RingPainter(
                      color: color.withValues(alpha: opacity),
                      track: theme.colorScheme.outlineVariant,
                      weight: ringWidth,
                      dashed: ring.dashed,
                      gap: ring.gap,
                    ),
                  ),
                ),
                Positioned.fill(
                  child: Padding(
                    padding: EdgeInsets.all(ringWidth + 1),
                    child: ClipOval(
                      child:
                          face ??
                          _WorkspaceFace(
                            name: workspaceName,
                            tone: ring.tone,
                          ),
                    ),
                  ),
                ),
                Positioned(
                  right: -badge * 0.18,
                  bottom: -badge * 0.18,
                  child: _Badge(
                    diameter: badge,
                    icon: _phaseIcon(status.phase),
                    color: color,
                    background: theme.colorScheme.surfaceContainerHigh,
                  ),
                ),
              ],
            ),
        ),
      ),
    );
  }

  static IconData _phaseIcon(BuddyPhase phase) => switch (phase) {
    BuddyPhase.off => Icons.power_settings_new_rounded,
    BuddyPhase.starting => Icons.more_horiz_rounded,
    BuddyPhase.listening => Icons.hearing_rounded,
    BuddyPhase.hearing => Icons.graphic_eq_rounded,
    BuddyPhase.transcribing => Icons.text_fields_rounded,
    BuddyPhase.working => Icons.build_circle_outlined,
    BuddyPhase.holdingReply => Icons.pause_circle_outline_rounded,
    BuddyPhase.speaking => Icons.volume_up_rounded,
    BuddyPhase.interrupted => Icons.stop_circle_outlined,
    BuddyPhase.muted => Icons.mic_off_rounded,
    BuddyPhase.paused => Icons.pause_circle_outline_rounded,
    BuddyPhase.approval => Icons.front_hand_rounded,
    BuddyPhase.ending => Icons.call_end_rounded,
    BuddyPhase.ended => Icons.call_end_rounded,
    BuddyPhase.failed => Icons.error_outline_rounded,
    BuddyPhase.unknown => Icons.help_outline_rounded,
  };

  /// The ring's colour.  It is never the only cue: [BuddyRing.weight],
  /// [BuddyRing.dashed], [BuddyRing.gap], the badge glyph and the words beside
  /// the circle say the same thing.
  static Color ringColor(BuildContext context, BuddyRingTone tone) {
    final theme = Theme.of(context);
    return switch (tone) {
      BuddyRingTone.neutral => theme.colorScheme.outline,
      BuddyRingTone.live || BuddyRingTone.hearing => HarnessColors.moss,
      BuddyRingTone.attention => HarnessColors.amber,
      BuddyRingTone.muted => theme.colorScheme.onSurfaceVariant,
      BuddyRingTone.failed => theme.colorScheme.error,
      BuddyRingTone.unknown => theme.colorScheme.outline,
    };
  }
}

/// The face: the workspace's initial, tinted by the ring's tone so the circle
/// still reads at a glance when the ring is thin.
class _WorkspaceFace extends StatelessWidget {
  const _WorkspaceFace({required this.name, required this.tone});

  final String name;
  final BuddyRingTone tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = switch (tone) {
      BuddyRingTone.failed => theme.colorScheme.error,
      BuddyRingTone.attention => HarnessColors.amber,
      BuddyRingTone.live || BuddyRingTone.hearing => HarnessColors.moss,
      BuddyRingTone.neutral ||
      BuddyRingTone.muted ||
      BuddyRingTone.unknown => theme.colorScheme.onSurfaceVariant,
    };
    final trimmed = name.trim();
    final initial = trimmed.isEmpty ? '?' : trimmed.substring(0, 1);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        shape: BoxShape.circle,
      ),
      child: Center(
        child: Text(
          initial.toUpperCase(),
          key: const Key('voice-buddy-face'),
          maxLines: 1,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 11,
            height: 1,
            fontWeight: FontWeight.w700,
            color: color,
          ),
        ),
      ),
    );
  }
}

/// The small glyph at the ring's lower-right: the phase's own icon, so the
/// state survives without colour.
class _Badge extends StatelessWidget {
  const _Badge({
    required this.diameter,
    required this.icon,
    required this.color,
    required this.background,
  });

  final double diameter;
  final IconData icon;
  final Color color;
  final Color background;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: diameter,
      height: diameter,
      decoration: BoxDecoration(color: background, shape: BoxShape.circle),
      alignment: Alignment.center,
      child: Icon(icon, size: diameter * 0.66, color: color),
    );
  }
}

/// Draws the ring, with an optional gap at the top and optional dashes.
class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.color,
    required this.track,
    required this.weight,
    required this.dashed,
    required this.gap,
  });

  final Color color;
  final Color track;
  final double weight;
  final bool dashed;
  final bool gap;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(
      weight / 2,
      weight / 2,
      size.width - weight,
      size.height - weight,
    );
    if (rect.width <= 0 || rect.height <= 0) return;
    // Every state starts from the same quiet track, so a thin ring still
    // reads as a circle on a light background.
    canvas.drawArc(
      rect,
      0,
      math.pi * 2,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = weight
        ..color = track.withValues(alpha: 0.55),
    );
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = weight
      ..strokeCap = StrokeCap.round
      ..color = color;
    if (dashed) {
      const segments = 12;
      final sweep = math.pi * 2 / segments;
      for (var i = 0; i < segments; i++) {
        canvas.drawArc(rect, i * sweep, sweep * 0.55, false, paint);
      }
      return;
    }
    if (gap) {
      // A gap at the top: the output is held back, not playing.
      const gapSweep = math.pi / 3;
      canvas.drawArc(
        rect,
        -math.pi / 2 + gapSweep / 2,
        math.pi * 2 - gapSweep,
        false,
        paint,
      );
      return;
    }
    canvas.drawArc(rect, 0, math.pi * 2, false, paint);
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.color != color ||
      old.track != track ||
      old.weight != weight ||
      old.dashed != dashed ||
      old.gap != gap;
}
