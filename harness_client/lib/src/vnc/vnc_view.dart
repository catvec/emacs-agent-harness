/// The screen of a computer the harness runs: an RFB client's pictures,
/// letterboxed, with the pointer and the keyboard sent back while the person
/// has control.
///
/// The protocol is [RfbClient]'s, in `rfb.dart`, and knows nothing of this
/// widget or of the hand-in report it was opened from.  When the workspace
/// branch's own viewer lands (`VncTakeover` and the box surface), its
/// surface replaces this widget inside the demo screen; the client stays.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart' show PointerScrollEvent;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'rfb.dart';

class VncView extends StatefulWidget {
  const VncView({
    super.key,
    required this.transport,
    this.enabled = true,
    this.onLost,
  });

  /// Where the bytes come from.  A new connection is a new [VncView], with a
  /// transport of its own: the screen keeps the last picture and asks for
  /// another view when it has the connection back.
  final RfbTransport transport;

  /// Whether the pointer and the keyboard go to the computer.  The picture
  /// comes either way.
  final bool enabled;

  /// Called when the connection ends, whether the server closed it or the
  /// network did.
  final void Function(Object error)? onLost;

  @override
  State<VncView> createState() => _VncViewState();
}

class _VncViewState extends State<VncView> {
  late final RfbClient _client = RfbClient(widget.transport);
  StreamSubscription<RfbFrame>? _frames;
  ui.Image? _image;
  int _width = 0;
  int _height = 0;
  bool _down = false;

  @override
  void initState() {
    super.initState();
    _frames = _client.frames.listen(_onFrame, onError: _lost, onDone: _closed);
    unawaited(
      _client.connect().catchError((Object error) {
        _lost(error);
      }),
    );
  }

  @override
  void dispose() {
    unawaited(_frames?.cancel());
    _frames = null;
    unawaited(_client.close());
    _image?.dispose();
    _image = null;
    super.dispose();
  }

  void _onFrame(RfbFrame frame) {
    if (!mounted) return;
    _width = frame.width;
    _height = frame.height;
    ui.decodeImageFromPixels(
      frame.rgba,
      frame.width,
      frame.height,
      ui.PixelFormat.rgba8888,
      (image) {
        if (!mounted) {
          image.dispose();
          return;
        }
        setState(() {
          _image?.dispose();
          _image = image;
        });
      },
    );
  }

  void _lost(Object error) {
    if (mounted) widget.onLost?.call(error);
  }

  void _closed() => _lost(StateError('The screen connection closed'));

  /// Where the picture goes: as large as the space allows, the shape kept,
  /// in the middle.
  Rect _fit(Size size) {
    if (_width <= 0 || _height <= 0) return Rect.zero;
    final scale = math.min(size.width / _width, size.height / _height);
    final width = _width * scale;
    final height = _height * scale;
    return Rect.fromLTWH(
      (size.width - width) / 2,
      (size.height - height) / 2,
      width,
      height,
    );
  }

  /// The point of the picture under [local], or null when [local] is in the
  /// letterbox or there is no picture yet.
  Offset? _point(Offset local) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    final fit = _fit(box.size);
    if (fit.isEmpty || !fit.contains(local)) return null;
    final x = ((local.dx - fit.left) / fit.width * _width).floor();
    final y = ((local.dy - fit.top) / fit.height * _height).floor();
    return Offset(
      x.clamp(0, _width - 1).toDouble(),
      y.clamp(0, _height - 1).toDouble(),
    );
  }

  void _pointer(Offset local, int mask) {
    if (!widget.enabled) return;
    final point = _point(local);
    if (point == null) return;
    _client.pointer(point.dx.round(), point.dy.round(), mask);
  }

  void _wheel(PointerScrollEvent event) {
    if (!widget.enabled) return;
    final point = _point(event.localPosition);
    if (point == null) return;
    final button = event.scrollDelta.dy < 0 ? 4 : 5;
    _client.pointer(point.dx.round(), point.dy.round(), button);
    _client.pointer(point.dx.round(), point.dy.round(), 0);
  }

  /// The keysym of a key, as X11 names it: the control keys the protocol
  /// has its own codes for, and everything else as the character it writes.
  int? _keysym(KeyEvent event) {
    final key = event.logicalKey;
    final control = switch (key) {
      LogicalKeyboardKey.enter || LogicalKeyboardKey.numpadEnter => 0xff0d,
      LogicalKeyboardKey.backspace => 0xff08,
      LogicalKeyboardKey.tab => 0xff09,
      LogicalKeyboardKey.escape => 0xff1b,
      LogicalKeyboardKey.delete => 0xffff,
      LogicalKeyboardKey.arrowLeft => 0xff51,
      LogicalKeyboardKey.arrowUp => 0xff52,
      LogicalKeyboardKey.arrowRight => 0xff53,
      LogicalKeyboardKey.arrowDown => 0xff54,
      _ => null,
    };
    if (control != null) return control;
    final character = event.character;
    if (character == null || character.isEmpty) return null;
    final code = character.runes.first;
    if (code < 0x20) return null;
    return code <= 0xff ? code : 0x01000000 | code;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (!widget.enabled) return KeyEventResult.ignored;
    if (event is! KeyDownEvent && event is! KeyUpEvent) {
      return KeyEventResult.ignored;
    }
    final keysym = _keysym(event);
    if (keysym == null) return KeyEventResult.ignored;
    _client.key(keysym, down: event is KeyDownEvent);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: widget.enabled,
      onKeyEvent: _onKey,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (event) {
          _down = true;
          _pointer(event.localPosition, 1);
        },
        onPointerMove: (event) {
          if (_down) _pointer(event.localPosition, 1);
        },
        onPointerUp: (event) {
          _down = false;
          _pointer(event.localPosition, 0);
        },
        onPointerCancel: (event) {
          _down = false;
          _pointer(event.localPosition, 0);
        },
        onPointerSignal: (event) {
          if (event is PointerScrollEvent) _wheel(event);
        },
        child: CustomPaint(
          key: _image == null ? null : const Key('vnc-picture'),
          size: Size.infinite,
          painter: _ScreenPainter(
            image: _image,
            pictureWidth: _width,
            pictureHeight: _height,
          ),
        ),
      ),
    );
  }
}

/// The picture, letterboxed: never stretched, and nothing around it but the
/// surface the screen puts there.
class _ScreenPainter extends CustomPainter {
  const _ScreenPainter({
    required this.image,
    required this.pictureWidth,
    required this.pictureHeight,
  });

  final ui.Image? image;
  final int pictureWidth;
  final int pictureHeight;

  @override
  void paint(Canvas canvas, Size size) {
    final picture = image;
    if (picture == null || pictureWidth <= 0 || pictureHeight <= 0) return;
    final scale = math.min(
      size.width / pictureWidth,
      size.height / pictureHeight,
    );
    final width = pictureWidth * scale;
    final height = pictureHeight * scale;
    final destination = Rect.fromLTWH(
      (size.width - width) / 2,
      (size.height - height) / 2,
      width,
      height,
    );
    if (destination.isEmpty) return;
    canvas.drawImageRect(
      picture,
      Rect.fromLTWH(0, 0, picture.width.toDouble(), picture.height.toDouble()),
      destination,
      Paint()..filterQuality = FilterQuality.low,
    );
  }

  @override
  bool shouldRepaint(_ScreenPainter oldDelegate) =>
      oldDelegate.image != image ||
      oldDelegate.pictureWidth != pictureWidth ||
      oldDelegate.pictureHeight != pictureHeight;
}
