import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../models/board.dart';

/// What drawing a source image came to: the decoded picture, or the reason it
/// is not drawn here (a type this client does not decode, a file on the
/// harness's machine).
enum BoardPictureState { decoded, absent }

/// The pictures a board draws, decoded once and kept by source: an image
/// object names its source on every frame, and decoding it again on each
/// would make a board of pictures crawl.  A source that is not a raster data
/// URI is not decoded here -- an SVG, or a path only the harness can read --
/// and the canvas names the image instead of pretending a picture is there.
class BoardPictures {
  BoardPictures();

  final Map<String, ui.Image> _images = {};
  final Set<String> _tried = {};
  int _revision = 0;

  /// How many times the pictures have changed.  Decoding is asynchronous, so
  /// the painter that asked for a picture is not the one that draws it: the
  /// revision is what tells a painter that the same store holds a new
  /// picture, and that the canvas has to be drawn again.
  int get revision => _revision;

  ui.Image? image(String? src) => src == null ? null : _images[src];

  /// Decode every source of [document] this client can, then call [onReady].
  /// Asked once per source: a source that failed is not asked again.
  Future<void> load(BoardDocument document, VoidCallback onReady) async {
    final wanted = <String>{};
    for (final object in document.objects) {
      final src = object.shape.src;
      if (src == null || src.isEmpty || _tried.contains(src)) continue;
      wanted.add(src);
    }
    if (wanted.isEmpty) return;
    var decoded = false;
    for (final src in wanted) {
      _tried.add(src);
      if (!src.startsWith('data:image/')) continue;
      final comma = src.indexOf(',');
      final header = comma > 0 ? src.substring(0, comma) : '';
      if (!header.contains('base64')) continue;
      try {
        final bytes = base64Decode(src.substring(comma + 1));
        final codec = await ui.instantiateImageCodec(bytes);
        final frame = await codec.getNextFrame();
        _images[src] = frame.image;
        decoded = true;
      } catch (_) {
        // Not a picture this client can decode: named, not faked.
      }
    }
    if (decoded) {
      _revision++;
      onReady();
    }
  }

  void dispose() {
    for (final image in _images.values) {
      image.dispose();
    }
    _images.clear();
    _tried.clear();
    _revision++;
  }
}

/// The canvas the board is drawn on: a CustomPainter that reads the
/// document's own geometry and draws it.
///
/// It draws the same primitives the engine validates -- rect, ellipse,
/// polygon, path, text and image -- placed by each view's affine matrix.  The
/// cleanup the design asks for is done here as in the engine's renderer, so a
/// picture of a board reads the same in both clients:
///
///  * a note is a sharp box with its words inset on every side, wrapped at
///    the box's width, on the engine's own line grid;
///  * a frame is a muted region with a small title tab on the frame's own
///    top-left corner, its title aligned with the frame's left line;
///  * a component is a square-cornered card with a thick top cap, its name
///    and detail on one left padding and one baseline;
///  * an image has its name above it and no card shell;
///  * a marker is a small square with its label beside it, showing the real
///    source status or nothing when there is none;
///  * raw ink is its own polyline, never smoothed;
///  * a connector is a curve with an arrowhead and its label above the
///    midpoint.
///
/// Text is never turned over: a transform places a shape, and the words of an
/// object keep their own upright baselines whatever the matrix does.
class BoardCanvasPainter extends CustomPainter {
  BoardCanvasPainter({
    required this.document,
    required this.theme,
    required this.selection,
    required this.pictures,
    this.offset = Offset.zero,
    this.scale = 1,
    this.outline = true,
    this.fontFamily,
    this.fontFallback = const [],
  }) : picturesRevision = pictures.revision;

  final BoardDocument document;
  final BoardTheme theme;
  final List<String> selection;
  final BoardPictures pictures;

  /// The pictures' revision when this painter was built.  Decoding is
  /// asynchronous, so a picture that was not there when the canvas was built
  /// arrives after it: the painter that has the new picture is a new one, and
  /// the two revisions are what say the canvas has to be drawn again.  (The
  /// store itself cannot: both painters hold the same one.)
  final int picturesRevision;

  /// The canvas point at the middle of the viewport.
  final Offset offset;
  final double scale;

  /// Whether the selection is outlined.  Off for a picture of a board nobody
  /// is standing at.
  final bool outline;

  /// The family the words of the drawing are set in: the look the
  /// canvas is drawn in, so a board reads in the app's own type and
  /// not in whatever the engine falls back to.
  final String? fontFamily;
  final List<String> fontFallback;

  /// Where a canvas point is on the painted surface.
  Offset toScreen(Offset canvas, Size size) =>
      (canvas - offset) * scale + size.center(Offset.zero);

  /// Where a point of the painted surface is on the canvas.
  Offset toCanvas(Offset screen, Size size) =>
      (screen - size.center(Offset.zero)) / scale + offset;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = theme.color('paper') ?? const Color(0xFFF5F5F0),
    );
    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.scale(scale);
    canvas.translate(-offset.dx, -offset.dy);
    for (final object in document.layered) {
      _object(canvas, object);
    }
    for (final relationship in document.connections) {
      if (relationship.hasPoints) _connector(canvas, relationship);
    }
    if (outline) {
      for (final object in document.objects) {
        if (selection.contains(object.id)) _outline(canvas, object);
      }
    }
    canvas.restore();
  }

  // ---- One object --------------------------------------------------------

  void _object(Canvas canvas, BoardObject object) {
    switch (object.kind) {
      case 'group':
        // Members are objects of their own, drawn where they are.
        return;
      case 'marker':
        _marker(canvas, object);
        return;
      case 'image':
        _image(canvas, object);
        return;
    }
    canvas.save();
    _place(canvas, object.transform);
    switch (object.kind) {
      case 'note':
        _note(canvas, object);
      case 'frame':
        _frame(canvas, object);
      case 'component':
        _component(canvas, object);
      case 'label':
        _label(canvas, object);
      default:
        _primitive(canvas, object);
    }
    canvas.restore();
  }

  void _place(Canvas canvas, BoardMatrix m) {
    if (m == BoardMatrix.identity) return;
    canvas.transform(
      Float64List.fromList([
        m.a, m.b, 0, 0, //
        m.c, m.d, 0, 0, //
        0, 0, 1, 0, //
        m.e, m.f, 0, 1, //
      ]),
    );
  }

  Color _ink(BoardObject object, String? preferred, String fallback) =>
      theme.color(preferred) ??
      theme.color(object.style.textColor) ??
      theme.color(fallback) ??
      const Color(0xFF25272C);

  TextStyle _text(BoardObject object, Color color, double size, {int weight = 400}) {
    return TextStyle(
      color: color,
      fontSize: size,
      fontWeight: switch (weight) {
        300 => FontWeight.w300,
        500 => FontWeight.w500,
        600 => FontWeight.w600,
        700 => FontWeight.w700,
        _ => FontWeight.w400,
      },
      height: 1.3,
      leadingDistribution: TextLeadingDistribution.even,
      fontFamily: fontFamily,
      fontFamilyFallback: fontFallback,
    );
  }

  /// Words on their own lines, from ([at]) as their top-left, each line at
  /// the engine's 1.3 of the size, so a block reads the same in both clients.
  void _words(
    Canvas canvas,
    String text,
    Offset at,
    TextStyle style, {
    double? maxWidth,
    int maxLines = 40,
  }) {
    if (text.isEmpty) return;
    final size = style.fontSize ?? 18;
    final lines = <String>[];
    for (final paragraph in text.split('\n')) {
      if (maxWidth == null || maxWidth <= 0) {
        lines.add(paragraph);
        continue;
      }
      var current = '';
      for (final word in paragraph.split(RegExp(r' +'))) {
        if (current.isEmpty) {
          current = word;
        } else if (_measured('$current $word', style) <= maxWidth) {
          current = '$current $word';
        } else {
          lines.add(current);
          current = word;
        }
      }
      if (current.isNotEmpty) lines.add(current);
    }
    final truncated = lines.length > maxLines;
    final shown = truncated ? lines.sublist(0, maxLines) : lines;
    for (var index = 0; index < shown.length; index++) {
      // The last line shown says so when the rest is cut: the words
      // stop at the note's edge, they are not clipped by it.
      final text = truncated && index == shown.length - 1
          ? '${shown[index]}…'
          : shown[index];
      final painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
      painter.paint(canvas, at + Offset(0, index * boardLineHeight(size)));
      painter.dispose();
    }
  }

  /// How wide [text] is set in [style], as the canvas draws it: the
  /// font's own metrics, not an average letter.  A note wraps to the
  /// width it is really given, so a word is not pushed onto a line of
  /// its own by a guess at how wide letters are.
  double _measured(String text, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }

  void _box(Canvas canvas, Rect rect, Color? fill, Color? stroke, double width) {
    if (fill != null) canvas.drawRect(rect, Paint()..color = fill);
    if (stroke != null) {
      canvas.drawRect(
        rect,
        Paint()
          ..style = PaintingStyle.stroke
          ..color = stroke
          ..strokeWidth = width,
      );
    }
  }

  /// A note: a sharp box and its words, inset on every side.
  void _note(Canvas canvas, BoardObject object) {
    final shape = object.shape;
    if (shape.kind != 'rect') {
      _primitive(canvas, object);
      return;
    }
    final style = object.style;
    final w = shape.w;
    final h = shape.h;
    _box(
      canvas,
      Offset.zero & Size(w, h),
      theme.color(style.fill ?? 'note'),
      theme.color(style.stroke ?? 'none'),
      1,
    );
    const inset = 14.0;
    final size = style.fontSize ?? 18;
    _words(
      canvas,
      object.text,
      const Offset(inset, inset),
      _text(object, _ink(object, null, 'ink'), size),
      maxWidth: w - inset * 2,
      // Every line has to fit inside the note: the box is the note,
      // and a line whose descenders hang past it reads as a clipped
      // word rather than as a note that has more to say.
      maxLines: math.max(1, ((h - inset * 2) / boardLineHeight(size)).floor()),
    );
  }

  /// The colour words on [cap] read in, on this painter's theme.
  ///
  /// A tab is filled with a theme's accent, and its words are whichever of
  /// the theme's ink and paper reads on that accent.  Night commons fills
  /// its tabs with a bright accent, where the theme's own ink would vanish:
  /// the engine's renderer makes the same choice, so both pictures agree.
  Color _onCap(Color? cap) {
    final ink = theme.color('ink') ?? const Color(0xFF25272C);
    final paper = theme.color('paper');
    if (cap == null || paper == null) return ink;
    return _contrast(ink, cap) < _contrast(paper, cap) ? paper : ink;
  }

  /// The WCAG contrast ratio of two colours.
  static double _contrast(Color one, Color two) {
    final a = one.computeLuminance();
    final b = two.computeLuminance();
    final light = math.max(a, b);
    final dark = math.min(a, b);
    return (light + 0.05) / (dark + 0.05);
  }

  /// A frame: a muted region, a title tab on its own top-left corner, the
  /// title aligned with the frame's left line.
  void _frame(Canvas canvas, BoardObject object) {
    final shape = object.shape;
    if (shape.kind != 'rect') {
      _primitive(canvas, object);
      return;
    }
    final style = object.style;
    final w = shape.w;
    final h = shape.h;
    final stroke = theme.color(style.stroke ?? 'edge');
    _box(
      canvas,
      Offset.zero & Size(w, h),
      theme.color(style.fill ?? 'frame'),
      stroke,
      1.5,
    );
    final size = style.fontSize ?? 19;
    final title = object.name;
    final titleSize = size * 0.82;
    final tabHeight = math.max(titleSize * 1.3 + 8, size * 1.4);
    final tabWidth = math.min(
      w,
      math.max(24.0, _measured(title, _text(object, _ink(object, null, 'ink'), titleSize, weight: 500)) + 16),
    );
    final tab = Rect.fromLTWH(0, -tabHeight, tabWidth, tabHeight);
    final cap = theme.color(style.cap ?? 'accent');
    _box(
      canvas,
      tab,
      cap,
      stroke,
      1,
    );
    final tabInk = _onCap(cap);
    // The tab is above the frame's own top line, so the title is
    // too: it reads as the frame's label, aligned with the frame's
    // left line, not as the first words inside the region.
    _words(
      canvas,
      title,
      Offset(8, -tabHeight + (tabHeight - titleSize * 1.3) / 2),
      _text(object, tabInk, titleSize, weight: 500),
      maxWidth: tabWidth - 16,
      maxLines: 1,
    );
  }

  /// A component: a square-cornered card with a thick top cap, its name and
  /// detail on one left padding and one baseline grid.
  void _component(Canvas canvas, BoardObject object) {
    final shape = object.shape;
    if (shape.kind != 'rect') {
      _primitive(canvas, object);
      return;
    }
    final style = object.style;
    final w = shape.w;
    final h = shape.h;
    _box(
      canvas,
      Offset.zero & Size(w, h),
      theme.color(style.fill ?? 'card'),
      theme.color(style.stroke ?? 'edge'),
      1,
    );
    final size = style.fontSize ?? 22;
    final capHeight = style.capHeight ?? math.max(7.0, size * 0.42);
    final cap = theme.color(style.cap ?? 'accent');
    if (cap != null) {
      canvas.drawRect(Rect.fromLTWH(0, 0, w, capHeight), Paint()..color = cap);
    }
    const pad = 12.0;
    final nameTop = capHeight + 9;
    _words(
      canvas,
      object.name,
      Offset(pad, nameTop),
      _text(object, _ink(object, null, 'ink'), size, weight: 500),
      maxWidth: w - pad - 8,
      maxLines: 1,
    );
    if (object.text.isEmpty) return;
    final detailSize = math.max(12.0, size - 5);
    final detailTop = nameTop + boardLineHeight(size) + 2;
    if (detailTop + detailSize * 1.3 > h - 2) return;
    _words(
      canvas,
      object.text,
      Offset(pad, detailTop),
      _text(object, theme.color('muted') ?? const Color(0xFF4D5058), detailSize),
      maxWidth: w - pad - 8,
      maxLines: math.max(
        1,
        ((h - detailTop - 2) / boardLineHeight(detailSize)).floor(),
      ),
    );
  }

  /// Words on their own, in the object's own coordinates.
  void _label(Canvas canvas, BoardObject object) {
    final size = object.style.fontSize ?? object.shape.size;
    final words = object.text.isNotEmpty ? object.text : object.name;
    _words(
      canvas,
      words,
      Offset.zero,
      _text(object, _ink(object, object.style.fill, 'ink'), size),
    );
  }

  /// The primitives: rect, ellipse, polygon, path and text.
  void _primitive(Canvas canvas, BoardObject object) {
    final shape = object.shape;
    final style = object.style;
    final fill = theme.color(style.fill);
    final stroke = theme.color(style.stroke);
    final width = style.strokeWidth ?? 1;
    switch (shape.kind) {
      case 'rect':
        final rect = Offset.zero & Size(shape.w, shape.h);
        _box(canvas, rect, fill, stroke, width);
        if (object.text.isEmpty) return;
        final size = style.fontSize ?? 18;
        _words(
          canvas,
          object.text,
          const Offset(10, 8),
          _text(
            object,
            _ink(object, null, 'ink'),
            size,
          ),
          maxWidth: shape.w - 20,
          maxLines: math.max(
            1,
            ((shape.h - 16) / boardLineHeight(size)).floor(),
          ),
        );
      case 'ellipse':
        final rect = Rect.fromLTWH(
          -shape.rx,
          -shape.ry,
          shape.rx * 2,
          shape.ry * 2,
        );
        if (fill != null) canvas.drawOval(rect, Paint()..color = fill);
        if (stroke != null) {
          canvas.drawOval(
            rect,
            Paint()
              ..style = PaintingStyle.stroke
              ..color = stroke
              ..strokeWidth = width,
          );
        }
      case 'polygon':
        if (shape.points.length < 3) return;
        final path = Path()
          ..moveTo(shape.points.first.$1, shape.points.first.$2);
        for (final point in shape.points.skip(1)) {
          path.lineTo(point.$1, point.$2);
        }
        path.close();
        if (fill != null) canvas.drawPath(path, Paint()..color = fill);
        if (stroke != null) {
          canvas.drawPath(
            path,
            Paint()
              ..style = PaintingStyle.stroke
              ..color = stroke
              ..strokeWidth = width
              ..strokeJoin = StrokeJoin.miter,
          );
        }
      case 'path':
        final path = _pathOf(shape.segments);
        if (shape.raw) {
          // A person's ink: its own polyline, never smoothed.
          canvas.drawPath(
            path,
            Paint()
              ..style = PaintingStyle.stroke
              ..color = stroke ?? _ink(object, null, 'ink')
              ..strokeWidth = style.strokeWidth ?? 2.4
              ..strokeCap = StrokeCap.round
              ..strokeJoin = StrokeJoin.round,
          );
          return;
        }
        if (fill != null) canvas.drawPath(path, Paint()..color = fill);
        if (stroke != null) {
          canvas.drawPath(
            path,
            Paint()
              ..style = PaintingStyle.stroke
              ..color = stroke
              ..strokeWidth = width
              ..strokeJoin = StrokeJoin.miter,
          );
        }
      case 'text':
        final size = style.fontSize ?? shape.size;
        _words(
          canvas,
          shape.text.isNotEmpty ? shape.text : object.text,
          Offset.zero,
          _text(object, _ink(object, style.fill, 'ink'), size),
        );
      default:
        return;
    }
  }

  Path _pathOf(List<BoardPathSegment> segments) {
    final path = Path();
    for (final segment in segments) {
      final n = segment.numbers;
      switch (segment.command) {
        case 'M':
          if (n.length >= 2) path.moveTo(n[0], n[1]);
        case 'L':
          if (n.length >= 2) path.lineTo(n[0], n[1]);
        case 'C':
          if (n.length >= 6) path.cubicTo(n[0], n[1], n[2], n[3], n[4], n[5]);
        case 'Q':
          if (n.length >= 4) path.quadraticBezierTo(n[0], n[1], n[2], n[3]);
        case 'Z':
          path.close();
      }
    }
    return path;
  }

  /// An image: its name above it, no card shell.  A source this client cannot
  /// draw is named where the picture would be and outlined by a thin rule, so
  /// nothing claims a picture is there when it is not.
  void _image(Canvas canvas, BoardObject object) {
    final shape = object.shape;
    if (shape.kind != 'image') return;
    final size = object.style.fontSize ?? 15;
    final name = object.name.isNotEmpty
        ? object.name
        : (shape.name ?? shape.src ?? 'image');
    final width = math.max(shape.w, 40.0);
    final picture = pictures.image(shape.src);
    canvas.save();
    _place(canvas, object.transform);
    _words(
      canvas,
      name,
      Offset(0, -size * 1.6),
      _text(
        object,
        theme.color(object.style.textColor ?? 'muted') ??
            const Color(0xFF4D5058),
        size,
        weight: 500,
      ),
      maxWidth: width,
      maxLines: 2,
    );
    final rect = Offset.zero & Size(shape.w, shape.h);
    if (picture != null) {
      canvas.drawImageRect(
        picture,
        Rect.fromLTWH(0, 0, picture.width.toDouble(), picture.height.toDouble()),
        rect,
        Paint()..filterQuality = FilterQuality.medium,
      );
    } else {
      canvas.drawRect(
        rect,
        Paint()
          ..style = PaintingStyle.stroke
          ..color = (theme.color('edge') ?? const Color(0xFF55545F))
              .withValues(alpha: 0.45)
          ..strokeWidth = 1,
      );
    }
    canvas.restore();
  }

  /// A task marker: a small square, its label beside it on the same baseline,
  /// showing what the real source says now -- or the object's own words when
  /// there is no source, never a status invented for it.
  void _marker(Canvas canvas, BoardObject object) {
    final style = object.style;
    final size = style.fontSize ?? 14;
    const square = 13.0;
    final ink = _ink(object, null, 'ink');
    canvas.save();
    _place(canvas, object.transform);
    _box(
      canvas,
      const Rect.fromLTWH(0, 0, square, square),
      theme.color(style.fill ?? 'accent'),
      ink,
      1,
    );
    final status = object.sourceStatus;
    final label = object.text.isNotEmpty
        ? object.text
        : (status != null && status.label.isNotEmpty
              ? status.label
              : object.name);
    _words(
      canvas,
      label,
      Offset(square + 7, (square - size * 1.3) / 2),
      _text(object, ink, size, weight: 500),
    );
    canvas.restore();
  }

  // ---- A connector -------------------------------------------------------

  /// A curve from one placed anchor to another, an arrowhead at the end and
  /// the label above the midpoint, where it never crosses a node's words.
  void _connector(Canvas canvas, BoardRelationship relationship) {
    final from = Offset(relationship.fromPoint.$1, relationship.fromPoint.$2);
    final to = Offset(relationship.toPoint.$1, relationship.toPoint.$2);
    final style = relationship.style;
    final stroke = theme.color(style.stroke ?? 'ink') ?? const Color(0xFF25272C);
    final width = style.strokeWidth ?? 2;
    final midX = (from.dx + to.dx) / 2;
    final midY = (from.dy + to.dy) / 2;
    final lift = math.min(40.0, (to.dx - from.dx).abs() / 8);
    final control = Offset(midX, midY - lift);
    final path = Path()
      ..moveTo(from.dx, from.dy)
      ..quadraticBezierTo(control.dx, control.dy, to.dx, to.dy);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..color = stroke
      ..strokeWidth = width;
    final dash = style.dashPattern;
    canvas.drawPath(
      dash.isEmpty ? path : _dashed(path, dash),
      paint,
    );
    _arrowhead(canvas, stroke, width, control, to);
    if (relationship.label.isEmpty) return;
    const size = 13.0;
    final painter = TextPainter(
      text: TextSpan(
        text: relationship.label,
        style: TextStyle(
          color: stroke,
          fontSize: size,
          height: 1.3,
          fontFamily: fontFamily,
          fontFamilyFallback: fontFallback,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final at = Offset(midX - painter.width / 2, midY - 6 - painter.height);
    final paper = theme.color('paper');
    if (paper != null) {
      canvas.drawRect(
        Rect.fromLTWH(
          at.dx - 2,
          at.dy - 2,
          painter.width + 4,
          painter.height + 4,
        ),
        Paint()..color = paper.withValues(alpha: 0.88),
      );
    }
    painter.paint(canvas, at);
    painter.dispose();
  }

  /// The arrowhead: two strokes at the curve's tangent where it arrives.
  void _arrowhead(
    Canvas canvas,
    Color color,
    double width,
    Offset from,
    Offset to,
  ) {
    final direction = to - from;
    final length = direction.distance;
    if (length < 0.001) return;
    final unit = direction / length;
    final normal = Offset(-unit.dy, unit.dx);
    final back = to - unit * (8.0 + width);
    final path = Path()
      ..moveTo(to.dx, to.dy)
      ..lineTo(back.dx + normal.dx * 3.5, back.dy + normal.dy * 3.5)
      ..moveTo(to.dx, to.dy)
      ..lineTo(back.dx - normal.dx * 3.5, back.dy - normal.dy * 3.5);
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..color = color
        ..strokeWidth = width
        ..strokeJoin = StrokeJoin.miter,
    );
  }

  Path _dashed(Path source, List<double> pattern) {
    final dashed = Path();
    var index = 0;
    var draw = true;
    for (final metric in source.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final step = pattern[index % pattern.length];
        final end = math.min(distance + step, metric.length);
        if (draw) dashed.addPath(metric.extractPath(distance, end), Offset.zero);
        distance = end;
        draw = !draw;
        index++;
      }
    }
    return dashed;
  }

  // ---- The selection -----------------------------------------------------

  /// The selection outline: the placed box, four points outside it, in the
  /// theme's accent with a dark hairline over it so it reads on any fill.
  void _outline(Canvas canvas, BoardObject object) {
    final (x, y, w, h) = object.box;
    final rect = Rect.fromLTWH(x - 4, y - 4, w + 8, h + 8);
    canvas.drawRect(
      rect,
      Paint()
        ..style = PaintingStyle.stroke
        ..color = theme.color('accent') ?? const Color(0xFFC5FF54)
        ..strokeWidth = 2,
    );
    canvas.drawRect(
      rect,
      Paint()
        ..style = PaintingStyle.stroke
        ..color = const Color(0xFF25272C).withValues(alpha: 0.5)
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(BoardCanvasPainter old) =>
      old.document != document ||
      old.theme != theme ||
      old.scale != scale ||
      old.offset != offset ||
      old.pictures != pictures ||
      old.picturesRevision != picturesRevision ||
      old.fontFamily != fontFamily ||
      old.outline != outline ||
      old.selection.length != selection.length ||
      !old.selection.every(selection.contains);
}
