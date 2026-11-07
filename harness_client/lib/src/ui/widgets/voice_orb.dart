import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../voice/voice_models.dart';

/// The colour a phase lends the screen: warm while listening, green while the
/// agent thinks, a brighter green while it speaks, grey when muted.
Color voicePhaseColor(VoicePhase phase) => switch (phase) {
  VoicePhase.listening => const Color(0xFFE07A4F),
  VoicePhase.hearing => const Color(0xFFFF9A62),
  VoicePhase.connecting => const Color(0xFFC9A469),
  VoicePhase.transcribing => const Color(0xFFD6A65E),
  VoicePhase.thinking => const Color(0xFF5FAE84),
  VoicePhase.speaking => const Color(0xFF74C99A),
  VoicePhase.interrupted => const Color(0xFFC9A469),
  VoicePhase.approval => const Color(0xFFE2B85D),
  VoicePhase.muted => const Color(0xFF8B8B93),
  VoicePhase.paused => const Color(0xFFC9A469),
  VoicePhase.ended => const Color(0xFF8B8B93),
  VoicePhase.failed => const Color(0xFFE0645B),
  VoicePhase.idle => const Color(0xFF8B8B93),
};

/// A quiet mark of the voice: a soft core whose rings answer the microphone,
/// and whose colour is the state of the conversation.
class VoiceOrb extends StatefulWidget {
  const VoiceOrb({
    super.key,
    required this.phase,
    required this.level,
    this.size = 210,
    this.animate = true,
  });

  final VoicePhase phase;
  final double level;
  final double size;

  /// False for a still picture: the rings stay where they are.
  final bool animate;

  @override
  State<VoiceOrb> createState() => _VoiceOrbState();
}

class _VoiceOrbState extends State<VoiceOrb>
    with SingleTickerProviderStateMixin {
  late final AnimationController _breath = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 3200),
  );

  @override
  void initState() {
    super.initState();
    if (widget.animate) _breath.repeat();
  }

  @override
  void didUpdateWidget(VoiceOrb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.animate && !_breath.isAnimating) {
      _breath.repeat();
    } else if (!widget.animate && _breath.isAnimating) {
      _breath.stop();
    }
  }

  @override
  void dispose() {
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final motion = MediaQuery.maybeOf(context)?.disableAnimations == true
        ? 0.0
        : null;
    return Semantics(
      label: 'Voice ${widget.phase.label.toLowerCase()}',
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: _breath,
          builder: (context, _) {
            final t = motion ?? _breath.value;
            return CustomPaint(
              size: Size.square(widget.size),
              painter: _VoiceOrbPainter(
                phase: widget.phase,
                level: widget.level.clamp(0.0, 1.0),
                time: t,
              ),
            );
          },
        ),
      ),
    );
  }
}

class _VoiceOrbPainter extends CustomPainter {
  const _VoiceOrbPainter({
    required this.phase,
    required this.level,
    required this.time,
  });

  final VoicePhase phase;
  final double level;
  final double time;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final shortest = size.shortestSide;
    final color = voicePhaseColor(phase);
    final speaking = phase == VoicePhase.speaking;
    final listening =
        phase == VoicePhase.listening ||
        phase == VoicePhase.hearing ||
        phase == VoicePhase.transcribing;
    final active = listening || speaking || phase == VoicePhase.thinking;
    final pulse = 0.5 + 0.5 * math.sin(time * math.pi * 2);
    final level = this.level.clamp(0.0, 1.0);
    final core =
        shortest * (0.19 + level * 0.035 + (active ? pulse * 0.006 : 0));

    // The glow: a low, wide wash of the phase's colour.
    final glowRadius = shortest * (0.47 + pulse * 0.02 + level * 0.04);
    canvas.drawCircle(
      center,
      glowRadius,
      Paint()
        ..shader = RadialGradient(
          colors: [
            color.withValues(alpha: active ? 0.32 : 0.12),
            color.withValues(alpha: 0.08),
            Colors.transparent,
          ],
          stops: const [0.0, 0.55, 1.0],
        ).createShader(Rect.fromCircle(center: center, radius: glowRadius)),
    );

    // Three rings, each breathing a little out of step with the others.
    for (var i = 0; i < 3; i++) {
      final offset = i * 0.17;
      final wave = 0.5 + 0.5 * math.sin((time + offset) * math.pi * 2);
      final radius =
          shortest * (0.27 + i * 0.065) +
          wave * shortest * 0.012 +
          level * shortest * (0.02 + i * 0.012);
      final alpha = active
          ? (0.40 - i * 0.09) * (0.7 + wave * 0.3)
          : 0.13 - i * 0.03;
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = color.withValues(alpha: alpha.clamp(0.0, 1.0)),
      );
    }

    // A dotted ring, slowly turning, which makes the mark feel alive without
    // moving the core.
    final dots = 40;
    final dotRadius = shortest * 0.40;
    for (var i = 0; i < dots; i++) {
      final angle = (i / dots) * math.pi * 2 + time * math.pi * 0.18;
      final reach = dotRadius + math.sin(angle * 3 + time * math.pi * 2) * 2.5;
      final point = center + Offset(math.cos(angle), math.sin(angle)) * reach;
      final strong = (math.sin(angle * 2 + time * math.pi * 2) + 1) / 2;
      canvas.drawCircle(
        point,
        1.1 + strong * 0.7,
        Paint()
          ..color = color.withValues(
            alpha: active ? 0.18 + strong * 0.22 : 0.10,
          ),
      );
    }

    // The core: a small sun, brighter with the voice.
    final coreColor = Color.lerp(Colors.white, color, 0.45)!;
    canvas.drawCircle(
      center,
      core,
      Paint()
        ..shader = RadialGradient(
          colors: [
            Colors.white.withValues(alpha: active ? 0.96 : 0.7),
            coreColor.withValues(alpha: 0.92),
            color.withValues(alpha: 0.75),
          ],
          stops: const [0.0, 0.45, 1.0],
        ).createShader(Rect.fromCircle(center: center, radius: core)),
    );
    canvas.drawCircle(
      center,
      core * 1.55,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0
        ..color = color.withValues(alpha: active ? 0.28 : 0.10),
    );
  }

  @override
  bool shouldRepaint(_VoiceOrbPainter oldDelegate) =>
      oldDelegate.phase != phase ||
      oldDelegate.level != level ||
      oldDelegate.time != time;
}
