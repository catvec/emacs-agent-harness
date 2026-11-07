import 'package:flutter/material.dart';

import '../theme/harness_theme.dart';

/// A panel with a halftone/dither field instead of a gradient.
///
/// The pattern is a 4x4 Bayer matrix drawn as small squares, so it reads as
/// a printed dot screen: the same material the Hermes pages use for their
/// portraits.  It is static, cheap, and sits under the child, which keeps
/// the text on plain paper.
class DitherPanel extends StatelessWidget {
  const DitherPanel({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
    this.radius = 2,
    this.color = HarnessColors.oxide,
    this.base = 0.045,
    this.strength = 0.16,
    this.border = true,
    this.cell = 3,
  });

  final Widget child;
  final EdgeInsets padding;
  final double radius;
  final Color color;
  final double base;
  final double strength;
  final bool border;
  final double cell;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Stack(
        children: [
          Positioned.fill(
            child: ColoredBox(color: color.withValues(alpha: base)),
          ),
          Positioned.fill(
            child: CustomPaint(
              painter: _DitherPainter(
                color: color.withValues(alpha: strength),
                cell: cell,
              ),
            ),
          ),
          if (border)
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(radius),
                    border: Border.all(
                      color: color.withValues(alpha: 0.55),
                    ),
                  ),
                ),
              ),
            ),
          Padding(padding: padding, child: child),
        ],
      ),
    );
  }
}

class _DitherPainter extends CustomPainter {
  const _DitherPainter({required this.color, required this.cell});

  final Color color;
  final double cell;

  // A 4x4 ordered-dither threshold matrix, 0..15.
  static const _bayer = <int>[
    0, 8, 2, 10,
    12, 4, 14, 6,
    3, 11, 1, 9,
    15, 7, 13, 5,
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final columns = (size.width / cell).ceil();
    final rows = (size.height / cell).ceil();
    // A soft diagonal fall-off: dense at the top-left, sparse at the
    // bottom-right, so the field has a direction without a gradient.
    for (var y = 0; y < rows; y++) {
      for (var x = 0; x < columns; x++) {
        final threshold = _bayer[(y % 4) * 4 + (x % 4)];
        final fall = 1 - (x + y) / (columns + rows).clamp(1, 1 << 20);
        if (threshold / 15 > fall * 0.72) continue;
        canvas.drawRect(
          Rect.fromLTWH(x * cell, y * cell, cell - 0.6, cell - 0.6),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_DitherPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.cell != cell;
}
