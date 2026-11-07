import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/harness_theme.dart';

/// A VNC window with the takeover control living on its edge.
///
/// The interaction is deliberately one small, legible thing: a pill sits at
/// the bottom of the window while the agent has control.  Tapping it moves it
/// to the window's edge and draws a border around the window in the same
/// motion, so the state change is a shape you can follow rather than a
/// switch that flips somewhere else.  Tapping again lets go.
class VncTakeover extends StatefulWidget {
  const VncTakeover({
    super.key,
    required this.child,
    required this.active,
    required this.onTakeOver,
    required this.onReturnControl,
    this.available = false,
    this.preview = true,
    this.borderRadius = 18,
  });

  /// What the window shows: a browser, a screenshot, a noVNC surface.
  final Widget child;

  /// Whether the person has control of the computer.
  final bool active;
  final VoidCallback onTakeOver;
  final VoidCallback onReturnControl;

  /// The box is running and a real VNC surface is behind [child].
  final bool available;

  /// The box is staged; the window is a drawn preview.
  final bool preview;
  final double borderRadius;

  @override
  State<VncTakeover> createState() => _VncTakeoverState();
}

class _VncTakeoverState extends State<VncTakeover>
    with SingleTickerProviderStateMixin {
  late final AnimationController _motion = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 680),
  );
  late final Animation<double> _ease = CurvedAnimation(
    parent: _motion,
    curve: Curves.easeInOutCubic,
    reverseCurve: Curves.easeInOutCubic.flipped,
  );

  @override
  void initState() {
    super.initState();
    _motion.value = widget.active ? 1 : 0;
  }

  @override
  void didUpdateWidget(VncTakeover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active == widget.active) return;
    if (MediaQuery.maybeOf(context)?.disableAnimations ?? false) {
      _motion.value = widget.active ? 1 : 0;
    } else if (widget.active) {
      _motion.forward();
    } else {
      _motion.reverse();
    }
  }

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = widget.active ? HarnessColors.moss : theme.colorScheme.primary;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final height = constraints.maxHeight;
        // Docked, the pill carries the longer label ("Return control"), so
        // it is given the room to say it whole rather than cut.
        final pillWidth = widget.active
            ? math.min(width - 28, 196.0)
            : math.min(206.0, math.max(150.0, width * 0.52));
        final pillHeight = 38.0;
        final idle = Offset((width - pillWidth) / 2, height - pillHeight - 12);
        // Docked, it sits over the window's own title bar: the window's
        // content, not its chrome, is what the person came to use.
        final docked = Offset(math.max(10, width - pillWidth - 14), 8);
        return Semantics(
          container: true,
          label: widget.active
              ? 'Computer, you have control'
              : 'Computer, the agent has control',
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(widget.borderRadius),
                  child: widget.child,
                ),
              ),
              // The edge is drawn over the window, not under it: the window
              // covers its own border otherwise, and the stroke that wraps
              // it as the pill docks would never be seen.
              Positioned.fill(
                child: IgnorePointer(
                  child: AnimatedBuilder(
                    animation: _ease,
                    builder: (context, _) {
                      return CustomPaint(
                        key: const ValueKey('vnc-border'),
                        painter: VncBorderPainter(
                          progress: _ease.value,
                          active: widget.active,
                          color: color,
                          radius: widget.borderRadius,
                          preview: widget.preview,
                        ),
                      );
                    },
                  ),
                ),
              ),
              AnimatedBuilder(
                animation: _ease,
                builder: (context, _) {
                  final offset = Offset.lerp(idle, docked, _ease.value)!;
                  final travel = Curves.easeOut.transform(
                    math.min(1, _ease.value * 1.4),
                  );
                  return Positioned(
                    left: offset.dx,
                    top: offset.dy,
                    child: _TakeoverPill(
                      key: const ValueKey('vnc-pill'),
                      active: widget.active,
                      color: color,
                      width: pillWidth,
                      height: pillHeight,
                      glow: travel,
                      onTap: () {
                        if (widget.active) {
                          widget.onReturnControl();
                        } else {
                          widget.onTakeOver();
                        }
                      },
                    ),
                  );
                },
              ),
              Positioned(
                left: 14,
                bottom: pillHeight + 22,
                child: _ControlLabel(active: widget.active),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ControlLabel extends StatelessWidget {
  const _ControlLabel({required this.active});

  final bool active;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedDefaultTextStyle(
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
      style: DefaultTextStyle.of(context).style
          .merge(HarnessText.caption(context))
          .copyWith(
            color: active
                ? HarnessColors.moss
                : theme.colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
      child: Text(active ? 'Control · you' : 'Control · agent'),
    );
  }
}

class _TakeoverPill extends StatelessWidget {
  const _TakeoverPill({
    super.key,
    required this.active,
    required this.color,
    required this.width,
    required this.height,
    required this.glow,
    required this.onTap,
  });

  final bool active;
  final Color color;
  final double width;
  final double height;
  final double glow;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      toggled: active,
      label: active ? 'Return control' : 'Take over',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(2),
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 420),
            curve: Curves.easeOutCubic,
            width: width,
            height: height,
            padding: const EdgeInsets.symmetric(horizontal: 13),
            decoration: BoxDecoration(
              color: active ? color : theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(2),
              border: Border.all(
                color: active
                    ? color.withValues(alpha: 0.9)
                    : theme.colorScheme.outlineVariant,
              ),
              boxShadow: [
                BoxShadow(
                  color: color.withValues(alpha: 0.14 + 0.10 * glow),
                  blurRadius: 18 + 8 * glow,
                  offset: const Offset(0, 5),
                ),
              ],
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 240),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  child: Icon(
                    active
                        ? Icons.keyboard_return_rounded
                        : Icons.pan_tool_alt_rounded,
                    key: ValueKey(active),
                    size: 17,
                    color: active
                        ? theme.colorScheme.onPrimary
                        : theme.colorScheme.onSurface,
                  ),
                ),
                const SizedBox(width: 7),
                Flexible(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    child: Text(
                      active ? 'Return control' : 'Take over',
                      key: ValueKey(active),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: active
                            ? theme.colorScheme.onPrimary
                            : theme.colorScheme.onSurface,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Draws the edge that meets the pill.  The full outline is always there,
/// quiet; the active state draws over it as a moving stroke, so the control
/// and the window read as one object.
class VncBorderPainter extends CustomPainter {
  const VncBorderPainter({
    required this.progress,
    required this.active,
    required this.color,
    required this.radius,
    required this.preview,
  });

  final double progress;
  final bool active;
  final Color color;
  final double radius;
  final bool preview;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(
      rect.deflate(1.4),
      Radius.circular(radius),
    );
    final base = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = color.withValues(alpha: preview ? 0.18 : 0.24);
    canvas.drawRRect(rrect, base);

    if (progress <= 0) return;
    final path = Path()..addRRect(rrect);
    final metric = path.computeMetrics().first;
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = active ? 2.2 : 1.6
      ..strokeCap = StrokeCap.round
      ..color = color.withValues(alpha: 0.82);
    canvas.drawPath(
      metric.extractPath(0, metric.length * progress.clamp(0, 1)),
      stroke,
    );
    if (active && progress > 0.96) {
      final glow = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7)
        ..color = color.withValues(alpha: 0.16);
      canvas.drawRRect(rrect, glow);
    }
  }

  @override
  bool shouldRepaint(VncBorderPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.active != active ||
      oldDelegate.color != color ||
      oldDelegate.preview != preview;
}
