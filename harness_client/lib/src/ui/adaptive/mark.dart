import 'package:flutter/material.dart';

/// The Harness mark: a square bracket around three signal lines, drawn so it
/// stays crisp at any size and inherits the current foreground color.
class HarnessMark extends StatelessWidget {
  const HarnessMark({super.key, this.size = 28, this.color});

  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final tint =
        color ?? DefaultTextStyle.of(context).style.color ?? Colors.black;
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _MarkPainter(tint)),
    );
  }
}

class _MarkPainter extends CustomPainter {
  _MarkPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.width * 0.09;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final inset = size.width * 0.12;
    final left = inset;
    final right = size.width - inset;
    final top = inset;
    final bottom = size.height - inset;
    // The bracket: left, top and bottom rails, open to the right.
    final bracket = Path()
      ..moveTo(right - size.width * 0.16, top)
      ..lineTo(left + size.width * 0.10, top)
      ..quadraticBezierTo(left, top, left, top + size.height * 0.10)
      ..lineTo(left, bottom - size.height * 0.10)
      ..quadraticBezierTo(left, bottom, left + size.width * 0.10, bottom)
      ..lineTo(right - size.width * 0.16, bottom);
    canvas.drawPath(bracket, paint);
    // Three signal lines, the middle one longest.
    final linePaint = Paint()
      ..color = color
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    final cx = size.width * 0.52;
    final gap = size.height * 0.17;
    canvas.drawLine(
      Offset(cx - size.width * 0.12, size.height / 2 - gap),
      Offset(cx + size.width * 0.02, size.height / 2 - gap),
      linePaint,
    );
    canvas.drawLine(
      Offset(cx - size.width * 0.12, size.height / 2),
      Offset(cx + size.width * 0.12, size.height / 2),
      linePaint,
    );
    canvas.drawLine(
      Offset(cx - size.width * 0.12, size.height / 2 + gap),
      Offset(cx - size.width * 0.02, size.height / 2 + gap),
      linePaint,
    );
    // A dot, the live end of the signal.
    canvas.drawCircle(
      Offset(right - size.width * 0.09, size.height / 2),
      stroke * 0.62,
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_MarkPainter oldDelegate) => oldDelegate.color != color;
}

class HarnessWordmark extends StatelessWidget {
  const HarnessWordmark({
    super.key,
    this.size = 30,
    this.subtitle = 'AGENT CLIENT',
    this.color,
  });

  final double size;
  final String? subtitle;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final tint =
        color ?? DefaultTextStyle.of(context).style.color ?? Colors.black;
    final mono = Theme.of(context).textTheme.labelSmall?.copyWith(
      letterSpacing: 1.4,
      fontWeight: FontWeight.w700,
      color: tint.withValues(alpha: 0.55),
      fontSize: 10,
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        HarnessMark(size: size * 1.15, color: tint),
        const SizedBox(width: 10),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Harness',
              style: TextStyle(
                color: tint,
                fontSize: size * 0.62,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.7,
                height: 1,
              ),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 3),
              Text(subtitle!.toUpperCase(), style: mono),
            ],
          ],
        ),
      ],
    );
  }
}
