/// The RFB protocol, as a VNC viewer needs it: the handshake, the pixel
/// format this client asks for, framebuffer updates, and the two events that
/// drive a computer (a pointer and a key).
///
/// It is plain Dart with no Flutter in it, so that the protocol is tested
/// over a transport that is a test's own, and so that it outlives the screen
/// it is drawn on: a workspace branch's own viewer replaces the drawing, not
/// this client.
///
/// Only what a demo needs is here.  Authentication is None, the pixel format
/// is 32 bits per pixel, depth 24, true colour, big-endian, with red, green
/// and blue at shifts 16, 8 and 0; the encodings are Raw, CopyRect and
/// DesktopSize.  A server that offers no None, or sends an encoding this
/// client does not know, ends the connection with an error rather than
/// showing a wrong picture.
library;

import 'dart:async';
import 'dart:typed_data';

/// Where the bytes of an RFB connection come from and go to: a WebSocket in
/// the app, a test's own script in a test.
abstract class RfbTransport {
  /// What the server sends, as binary frames.
  Stream<Uint8List> get bytes;

  /// Send a client message.
  void send(List<int> data);

  /// Close the connection.
  Future<void> close();
}

/// One whole framebuffer, 8 bits per channel in the order red, green, blue,
/// alpha.
class RfbFrame {
  const RfbFrame({
    required this.width,
    required this.height,
    required this.rgba,
  });

  final int width;
  final int height;
  final Uint8List rgba;
}

/// A client of one RFB server, over one [RfbTransport].
///
/// [connect] does the handshake, asks for the framebuffer and starts reading
/// updates; [frames] carries a picture after every update; [pointer] and
/// [key] drive the computer; [close] lets it all go.
class RfbClient {
  RfbClient(this.transport);

  final RfbTransport transport;
  final _frames = StreamController<RfbFrame>.broadcast();
  final _pending = <int>[];
  Completer<void>? _waiter;
  StreamSubscription<Uint8List>? _subscription;

  int _width = 0;
  int _height = 0;
  Uint8List _pixels = Uint8List(0);

  /// The version the server named in its greeting (`RFB 003.008`), once the
  /// handshake has read it.
  String? serverVersion;

  bool _connected = false;
  bool _closed = false;
  int _minor = 8;

  /// A picture after every framebuffer update, whole.
  Stream<RfbFrame> get frames => _frames.stream;

  bool get isClosed => _closed;
  int get width => _width;
  int get height => _height;

  /// Do the handshake and start reading.  Once.
  Future<void> connect() async {
    if (_connected) return;
    _connected = true;
    _subscription = transport.bytes.listen(
      _onBytes,
      onError: _onError,
      onDone: _onDone,
    );
    try {
      await _handshake();
    } catch (error, stack) {
      _fail(error, stack);
      rethrow;
    }
    // What is on the screen now, and then a request after every update.
    _requestUpdate(incremental: false);
    unawaited(_readMessages());
  }

  Future<void> _handshake() async {
    final greeting = await _read(12);
    serverVersion = String.fromCharCodes(greeting.sublist(0, 12)).trim();
    final match = RegExp(r'^RFB (\d{3})\.(\d{3})').firstMatch(serverVersion!);
    if (match == null) {
      throw StateError('Not an RFB server: $serverVersion');
    }
    final major = int.parse(match[1]!);
    final minor = int.parse(match[2]!);
    if (major != 3) {
      throw StateError('Unsupported RFB version: $serverVersion');
    }
    _minor = minor >= 8 ? 8 : (minor >= 7 ? 7 : 3);

    if (_minor == 3) {
      // 3.3 names the security type in one word, and has no SecurityResult.
      _sendText('RFB 003.003\n');
      final security = await _readU32();
      if (security != 1) {
        throw StateError('RFB authentication is not supported ($security)');
      }
    } else {
      _sendText('RFB 003.00$_minor\n');
      final count = (await _read(1))[0];
      final offered = await _read(count);
      if (!offered.contains(1)) {
        throw StateError('RFB authentication is not supported');
      }
      transport.send([1]);
      if (_minor == 8) {
        final result = await _readU32();
        if (result != 0) {
          throw StateError('RFB security failed ($result)');
        }
      }
    }

    // Shared: another client on the same server does not end this one.
    transport.send([1]);

    _width = await _readU16();
    _height = await _readU16();
    // The server's own pixel format is read and left alone: SetPixelFormat
    // asks for the one this client reads.
    await _read(16);
    final nameLength = await _readU32();
    if (nameLength > 0) await _read(nameLength);

    _pixels = _blank(_width, _height);
    _setPixelFormat();
    _setEncodings();
  }

  /// 32 bits per pixel, depth 24, big-endian, true colour, r/g/b at
  /// 16/8/0 with a maximum of 255 each.
  void _setPixelFormat() {
    transport.send([
      0, 0, 0, 0, // SetPixelFormat, padding
      32, 24, 1, 1, // bits per pixel, depth, big-endian, true colour
      0, 255, 0, 255, 0, 255, // red, green and blue maxima
      16, 8, 0, // their shifts
      0, 0, 0, // padding
    ]);
  }

  /// Raw first, then CopyRect, then DesktopSize (a resize).
  void _setEncodings() {
    transport.send([
      2, 0, 0, 3, // SetEncodings, one padding byte, three encodings
      0, 0, 0, 0, // Raw
      0, 0, 0, 1, // CopyRect
      0xff, 0xff, 0xff, 0x21, // -223, DesktopSize
    ]);
  }

  void _requestUpdate({bool incremental = true}) {
    if (_closed) return;
    transport.send([
      3,
      incremental ? 1 : 0,
      0, 0, // x
      0, 0, // y
      (_width >> 8) & 0xff, _width & 0xff,
      (_height >> 8) & 0xff, _height & 0xff,
    ]);
  }

  Future<void> _readMessages() async {
    try {
      while (!_closed) {
        final type = (await _read(1))[0];
        switch (type) {
          case 0: // FramebufferUpdate
            await _readFramebufferUpdate();
          case 1: // SetColourMapEntries: nothing uses it with true colour.
            await _read(3);
            final count = await _readU16();
            await _read(count * 6);
          case 2: // Bell
            break;
          case 3: // ServerCutText: read the text and drop it.
            await _read(3);
            final length = await _readU32();
            if (length > 0) await _read(length);
          default:
            throw StateError('Unknown RFB message $type');
        }
      }
    } catch (error, stack) {
      _fail(error, stack);
    }
  }

  Future<void> _readFramebufferUpdate() async {
    await _read(1); // padding
    final count = await _readU16();
    for (var i = 0; i < count; i++) {
      final x = await _readU16();
      final y = await _readU16();
      final w = await _readU16();
      final h = await _readU16();
      final encoding = await _readI32();
      switch (encoding) {
        case 0: // Raw
          await _readRaw(x, y, w, h);
        case 1: // CopyRect
          final fromX = await _readU16();
          final fromY = await _readU16();
          _copyRect(x, y, w, h, fromX, fromY);
        case -223: // DesktopSize
          _resize(w, h);
        default:
          throw StateError('Unsupported RFB encoding $encoding');
      }
    }
    _emit();
    _requestUpdate();
  }

  Future<void> _readRaw(int x, int y, int w, int h) async {
    final raw = await _read(w * h * 4);
    for (var row = 0; row < h; row++) {
      final destY = y + row;
      if (destY < 0 || destY >= _height) continue;
      for (var col = 0; col < w; col++) {
        final destX = x + col;
        if (destX < 0 || destX >= _width) continue;
        final source = (row * w + col) * 4;
        final dest = (destY * _width + destX) * 4;
        // Big-endian 32-bit: the three low bytes are red, green and blue.
        _pixels[dest] = raw[source + 1];
        _pixels[dest + 1] = raw[source + 2];
        _pixels[dest + 2] = raw[source + 3];
        _pixels[dest + 3] = 255;
      }
    }
  }

  void _copyRect(int x, int y, int w, int h, int fromX, int fromY) {
    final copy = Uint8List(w * h * 4);
    for (var row = 0; row < h; row++) {
      final sourceY = fromY + row;
      if (sourceY < 0 || sourceY >= _height) continue;
      for (var col = 0; col < w; col++) {
        final sourceX = fromX + col;
        if (sourceX < 0 || sourceX >= _width) continue;
        final source = (sourceY * _width + sourceX) * 4;
        final dest = (row * w + col) * 4;
        copy[dest] = _pixels[source];
        copy[dest + 1] = _pixels[source + 1];
        copy[dest + 2] = _pixels[source + 2];
        copy[dest + 3] = _pixels[source + 3];
      }
    }
    for (var row = 0; row < h; row++) {
      final destY = y + row;
      if (destY < 0 || destY >= _height) continue;
      for (var col = 0; col < w; col++) {
        final destX = x + col;
        if (destX < 0 || destX >= _width) continue;
        final dest = (destY * _width + destX) * 4;
        final source = (row * w + col) * 4;
        _pixels[dest] = copy[source];
        _pixels[dest + 1] = copy[source + 1];
        _pixels[dest + 2] = copy[source + 2];
        _pixels[dest + 3] = copy[source + 3];
      }
    }
  }

  void _resize(int w, int h) {
    if (w <= 0 || h <= 0) return;
    final next = _blank(w, h);
    final rows = h < _height ? h : _height;
    final columns = w < _width ? w : _width;
    for (var row = 0; row < rows; row++) {
      final source = row * _width * 4;
      final dest = row * w * 4;
      next.setRange(dest, dest + columns * 4, _pixels, source);
    }
    _width = w;
    _height = h;
    _pixels = next;
  }

  static Uint8List _blank(int width, int height) {
    final pixels = Uint8List(width * height * 4);
    for (var i = 3; i < pixels.length; i += 4) {
      pixels[i] = 255;
    }
    return pixels;
  }

  void _emit() {
    if (_frames.isClosed) return;
    _frames.add(
      RfbFrame(
        width: _width,
        height: _height,
        rgba: Uint8List.fromList(_pixels),
      ),
    );
  }

  /// Move the pointer to ([x], [y]) with [mask] held (1 left, 2 middle,
  /// 4 right, and 0 for a release).
  void pointer(int x, int y, int mask) {
    if (_closed) return;
    final atX = x.clamp(0, _width > 0 ? _width - 1 : 0);
    final atY = y.clamp(0, _height > 0 ? _height - 1 : 0);
    transport.send([
      5,
      mask & 0xff,
      (atX >> 8) & 0xff,
      atX & 0xff,
      (atY >> 8) & 0xff,
      atY & 0xff,
    ]);
  }

  /// A key, down or up, in X11 keysym terms.
  void key(int keysym, {required bool down}) {
    if (_closed) return;
    transport.send([
      4,
      down ? 1 : 0,
      0,
      0,
      (keysym >> 24) & 0xff,
      (keysym >> 16) & 0xff,
      (keysym >> 8) & 0xff,
      keysym & 0xff,
    ]);
  }

  /// Let the connection go: no more updates, no more events.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final waiter = _waiter;
    _waiter = null;
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete();
    }
    await _subscription?.cancel();
    _subscription = null;
    await transport.close();
    if (!_frames.isClosed) await _frames.close();
  }

  void _onBytes(Uint8List bytes) {
    _pending.addAll(bytes);
    final waiter = _waiter;
    _waiter = null;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
  }

  void _onError(Object error, StackTrace stack) => _fail(error, stack);

  void _onDone() {
    final waiter = _waiter;
    _waiter = null;
    if (waiter != null && !waiter.isCompleted) {
      waiter.completeError(StateError('The screen connection closed'));
    }
  }

  void _fail(Object error, StackTrace stack) {
    if (_closed) return;
    _closed = true;
    final waiter = _waiter;
    _waiter = null;
    if (waiter != null && !waiter.isCompleted) {
      waiter.completeError(error, stack);
    }
    if (!_frames.isClosed) _frames.addError(error, stack);
    unawaited(_subscription?.cancel());
    _subscription = null;
  }

  void _sendText(String text) => transport.send(text.codeUnits);

  Future<Uint8List> _read(int count) async {
    if (count <= 0) return Uint8List(0);
    while (_pending.length < count) {
      if (_closed) throw StateError('The screen connection closed');
      final waiter = _waiter ??= Completer<void>();
      await waiter.future;
    }
    final out = Uint8List.fromList(_pending.sublist(0, count));
    _pending.removeRange(0, count);
    return out;
  }

  Future<int> _readU16() async {
    final bytes = await _read(2);
    return (bytes[0] << 8) | bytes[1];
  }

  Future<int> _readU32() async {
    final bytes = await _read(4);
    return (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];
  }

  Future<int> _readI32() async {
    final value = await _readU32();
    return value & 0x80000000 == 0 ? value : value - 0x100000000;
  }
}
