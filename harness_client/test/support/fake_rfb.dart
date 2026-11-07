// An RFB server in memory, for the demo screen's tests and pictures: the
// real `RfbClient` speaks to it, so what is drawn is a picture the client
// decoded, not a stand-in for one.  It answers the handshake of RFB 3.8,
// accepts None, and sends one synthetic framebuffer (a gradient with a grid
// of blocks) when the first update is asked for.
import 'dart:async';
import 'dart:typed_data';

import 'package:harness_client/src/vnc/rfb.dart';

class FakeRfbTransport implements RfbTransport {
  FakeRfbTransport({this.width = 640, this.height = 400}) {
    // A server greets a client as it connects, before it has heard anything.
    // The controller is not a broadcast one, so the greeting waits for the
    // client's listener and is not lost.
    _text('RFB 003.008\n');
  }

  final int width;
  final int height;
  final _bytes = StreamController<Uint8List>();

  /// Every client message, in order.
  final List<List<int>> sent = [];
  bool closed = false;
  bool sentFrame = false;
  int _stage = 0;

  @override
  Stream<Uint8List> get bytes => _bytes.stream;

  @override
  void send(List<int> data) {
    sent.add(List<int>.of(data));
    if (data.length >= 12 &&
        data[0] == 0x52 && // R
        data[1] == 0x46 && // F
        data[2] == 0x42) {
      // B
      _add([1, 1]); // one security type: None
      _stage = 1;
      return;
    }
    if (_stage == 1) {
      // The security choice, then the result that says it was accepted.
      _add([0, 0, 0, 0]);
      _stage = 2;
      return;
    }
    if (_stage == 2) {
      // ClientInit: the server's own picture and name follow.
      _add(_serverInit());
      _stage = 3;
      return;
    }
    if (data.isNotEmpty && data[0] == 3 && !sentFrame) {
      sentFrame = true;
      _add(_framebufferUpdate());
    }
  }

  /// The screen's connection goes away, as a socket that drops does.
  void drop([String reason = 'The screen connection dropped']) {
    if (!_bytes.isClosed) _bytes.addError(StateError(reason));
  }

  @override
  Future<void> close() async {
    closed = true;
    if (!_bytes.isClosed) await _bytes.close();
  }

  void _add(List<int> data) {
    if (!_bytes.isClosed) _bytes.add(Uint8List.fromList(data));
  }

  void _text(String text) => _add(text.codeUnits);

  List<int> _serverInit() => [
    (width >> 8) & 0xff, width & 0xff,
    (height >> 8) & 0xff, height & 0xff,
    32, 24, 0, 1, // bits per pixel, depth, big-endian, true colour
    0, 255, 0, 255, 0, 255, // maxima
    16, 8, 0, // shifts
    0, 0, 0, // padding
    0, 0, 0, 0, // no name
  ];

  List<int> _framebufferUpdate() {
    final pixels = <int>[];
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final red = width <= 1 ? 0 : x * 255 ~/ (width - 1);
        final green = height <= 1 ? 0 : y * 255 ~/ (height - 1);
        final blue = ((x ~/ 32) + (y ~/ 32)).isEven ? 0xcc : 0x44;
        pixels.addAll([0, red, green, blue]);
      }
    }
    return [
      0, 0, // FramebufferUpdate, padding
      0, 1, // one rectangle
      0, 0, // x
      0, 0, // y
      (width >> 8) & 0xff, width & 0xff,
      (height >> 8) & 0xff, height & 0xff,
      0, 0, 0, 0, // Raw
      ...pixels,
    ];
  }
}
