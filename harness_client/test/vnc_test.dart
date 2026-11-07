// The VNC side of a demo screen: the RFB client is real code, driven over a
// transport a test scripts byte by byte (no socket, no server, no network),
// and the endpoint a harness's loopback URL is rewritten to.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/vnc/rfb.dart';
import 'package:harness_client/src/vnc/websocket_transport.dart';

/// An RFB connection whose bytes the test writes and whose client messages
/// the test reads.
class _ScriptedTransport implements RfbTransport {
  final _bytes = StreamController<Uint8List>.broadcast();
  final List<List<int>> sent = [];
  bool closed = false;

  @override
  Stream<Uint8List> get bytes => _bytes.stream;

  @override
  void send(List<int> data) => sent.add(List<int>.of(data));

  @override
  Future<void> close() async {
    closed = true;
    if (!_bytes.isClosed) await _bytes.close();
  }

  void add(List<int> data) {
    if (!_bytes.isClosed) _bytes.add(Uint8List.fromList(data));
  }

  void text(String text) => add(text.codeUnits);
}

/// The pixel format a server answers with in its ServerInit: 32 bits per
/// pixel, depth 24, true colour.
const _serverPixelFormat = [
  32, 24, 0, 1, // bits per pixel, depth, big-endian, true colour
  0, 255, 0, 255, 0, 255, // maxima
  16, 8, 0, // shifts
  0, 0, 0, // padding
];

List<int> _serverInit(int width, int height, {String name = ''}) => [
  (width >> 8) & 0xff,
  width & 0xff,
  (height >> 8) & 0xff,
  height & 0xff,
  ..._serverPixelFormat,
  0,
  0,
  0,
  name.length,
  ...name.codeUnits,
];

List<int> _rect(
  int x,
  int y,
  int width,
  int height,
  int encoding, [
  List<int> payload = const [],
]) => [
  (x >> 8) & 0xff,
  x & 0xff,
  (y >> 8) & 0xff,
  y & 0xff,
  (width >> 8) & 0xff,
  width & 0xff,
  (height >> 8) & 0xff,
  height & 0xff,
  (encoding >> 24) & 0xff,
  (encoding >> 16) & 0xff,
  (encoding >> 8) & 0xff,
  encoding & 0xff,
  ...payload,
];

/// A framebuffer update of [rectangles].
List<int> _update(int rectangles, List<int> body) => [
  0, 0, // FramebufferUpdate, padding
  (rectangles >> 8) & 0xff, rectangles & 0xff,
  ...body,
];

/// A red pixel and a green one, as the server sends them with the format the
/// client asked for: big-endian, the three low bytes red, green and blue.
const _redGreen = [0, 255, 0, 0, 0, 0, 255, 0];

void main() {
  group('the RFB client', () {
    late _ScriptedTransport transport;
    late RfbClient client;

    setUp(() {
      transport = _ScriptedTransport();
      client = RfbClient(transport);
    });

    tearDown(() async {
      await client.close();
    });

    /// The handshake of RFB 3.8, and a [width] by [height] framebuffer with
    /// no name, read together with what the client sends.
    Future<void> handshake(int width, int height, {int version = 8}) async {
      final connected = client.connect();
      transport.text('RFB 003.00$version\n');
      if (version == 3) {
        transport.add([0, 0, 0, 1]); // security type: None
      } else {
        transport.add([1, 1]); // one security type: None
        if (version == 8) transport.add([0, 0, 0, 0]); // SecurityResult: ok
      }
      transport.add(_serverInit(width, height));
      await connected;
    }

    test(
      'negotiates RFB 3.8, asks for its pixel format and a framebuffer',
      () async {
        await handshake(2, 2);
        expect(client.serverVersion, 'RFB 003.008');
        expect(client.width, 2);
        expect(client.height, 2);

        final setPixelFormat = transport.sent.firstWhere(
          (message) => message.length == 20 && message[0] == 0,
        );
        expect(setPixelFormat, [
          0,
          0,
          0,
          0,
          32,
          24,
          1,
          1,
          0,
          255,
          0,
          255,
          0,
          255,
          16,
          8,
          0,
          0,
          0,
          0,
        ]);
        final setEncodings = transport.sent.firstWhere(
          (message) => message.isNotEmpty && message[0] == 2,
        );
        expect(setEncodings, [
          2,
          0,
          0,
          3,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          1,
          0xff,
          0xff,
          0xff,
          0x21,
        ]);
        expect(
          transport.sent.any(
            (message) => message.isNotEmpty && message[0] == 3,
          ),
          isTrue,
          reason: 'the first framebuffer update is asked for',
        );
      },
    );

    test('negotiates RFB 3.3, which names None in one word', () async {
      await handshake(1, 1, version: 3);
      expect(client.serverVersion, 'RFB 003.003');
      expect(transport.sent.first, 'RFB 003.003\n'.codeUnits);
    });

    test('reads Raw and CopyRect into one buffer', () async {
      await handshake(2, 2);
      final frames = <RfbFrame>[];
      client.frames.listen(frames.add);
      transport.add(
        _update(2, [
          ..._rect(0, 0, 2, 1, 0, _redGreen),
          ..._rect(0, 1, 2, 1, 1, [0, 0, 0, 0]), // copy from 0,0
        ]),
      );
      await _until(() => frames.isNotEmpty);
      final frame = frames.single;
      expect(frame.width, 2);
      expect(frame.height, 2);
      // Two rows of red, green: the copy put the first row below itself.
      expect(frame.rgba, [
        255,
        0,
        0,
        255,
        0,
        255,
        0,
        255,
        255,
        0,
        0,
        255,
        0,
        255,
        0,
        255,
      ]);
      // And the next update is asked for, incrementally.
      expect(transport.sent.last.sublist(0, 2), [3, 1]);
    });

    test('takes a DesktopSize as a new size, keeping what it had', () async {
      await handshake(2, 2);
      final frames = <RfbFrame>[];
      client.frames.listen(frames.add);
      transport.add(
        _update(1, _rect(0, 0, 2, 2, 0, [..._redGreen, ..._redGreen])),
      );
      await _until(() => frames.length == 1);
      transport.add(_update(1, _rect(0, 0, 4, 3, -223)));
      await _until(() => frames.length == 2);
      expect(frames.last.width, 4);
      expect(frames.last.height, 3);
      expect(frames.last.rgba.length, 4 * 3 * 4);
      // The old pixels are still there: the first two are red.
      expect(frames.last.rgba.sublist(0, 4), [255, 0, 0, 255]);
    });

    test('puts pointers and keys on the wire as the protocol says', () async {
      await handshake(640, 400);
      client.pointer(100, 200, 1);
      expect(transport.sent.last, [5, 1, 0, 100, 0, 200]);
      client.pointer(1, 2, 0);
      expect(transport.sent.last, [5, 0, 0, 1, 0, 2]);
      client.key(0xff0d, down: true);
      expect(transport.sent.last, [4, 1, 0, 0, 0, 0, 0xff, 0x0d]);
      client.key(0x61, down: false);
      expect(transport.sent.last, [4, 0, 0, 0, 0, 0, 0, 0x61]);
    });

    test(
      'refuses a server that offers only authentication it has not',
      () async {
        final connected = client.connect();
        transport.text('RFB 003.008\n');
        transport.add([1, 2]); // one security type, VNC authentication
        await expectLater(connected, throwsStateError);
      },
    );

    test(
      'refuses an encoding it does not know rather than draw it wrong',
      () async {
        await handshake(1, 1);
        final failures = <Object>[];
        client.frames.listen((_) {}, onError: failures.add);
        transport.add(
          _update(1, _rect(0, 0, 1, 1, 5)),
        ); // Hextile, not asked for
        await _until(() => failures.isNotEmpty);
        expect(failures.single, isA<StateError>());
      },
    );
  });

  group('where a VNC endpoint really is', () {
    test('a loopback socket goes to the harness the app is signed in to', () {
      expect(
        VncEndpoint.resolve(
          'ws://127.0.0.1:5901/websockify',
          'ws://harness.test:9999/acp',
        ),
        'ws://harness.test:9999/websockify',
      );
      expect(
        VncEndpoint.resolve(
          'ws://localhost:6080/websockify?autoconnect=1',
          'http://harness.test:7000/acp',
        ),
        'ws://harness.test:7000/websockify?autoconnect=1',
      );
    });

    test('a noVNC page is not a socket and resolves to none', () {
      // The `url` of a demo's `vnc` is a page a browser opens; only the
      // `socket` beside it is spoken to.
      expect(
        VncEndpoint.resolve(
          'http://127.0.0.1:6080/vnc.html?autoconnect=1',
          'ws://harness.test:9999/acp',
        ),
        isNull,
      );
      expect(
        VncEndpoint.resolve(
          'https://127.0.0.1:6080/vnc.html',
          'wss://harness.test:9999/acp',
        ),
        isNull,
      );
    });

    test('a workspace socket goes through the harness tunnel', () {
      // The box's own web port is loopback: a phone reaches the RFB bytes
      // through the harness it is signed in to, naming the workspace rather
      // than a port of this machine.  The box's page token stays behind.
      expect(
        VncEndpoint.resolve(
          'ws://127.0.0.1:6080/websockify?token=box-token&workspace=w-1',
          'ws://harness.test:9999/acp',
        ),
        'ws://harness.test:9999/workspace/vnc?workspace=w-1',
      );
      expect(
        VncEndpoint.resolve(
          'ws://127.0.0.1:6080/websockify?token=box-token&workspace=w-1',
          'https://harness.test/acp',
        ),
        'wss://harness.test/workspace/vnc?workspace=w-1',
      );
    });

    test('a socket behind a TLS harness is reached over TLS', () {
      expect(
        VncEndpoint.resolve(
          'ws://127.0.0.1:5901/websockify',
          'https://box.example/acp',
        ),
        'wss://box.example/websockify',
      );
      expect(
        VncEndpoint.resolve(
          'wss://[::1]:5901/websockify',
          'wss://box.example:443/acp',
        ),
        'wss://box.example/websockify',
      );
    });

    test('an address with no scheme is read as a harness', () {
      expect(
        VncEndpoint.resolve('ws://127.0.0.1:5901/x', 'harness.test:9999'),
        'ws://harness.test:9999/x',
      );
    });

    test('anything else is left as it came, or is no socket at all', () {
      const elsewhere = 'ws://192.168.1.5:5900/websockify';
      expect(
        VncEndpoint.resolve(elsewhere, 'ws://harness.test:9999/acp'),
        elsewhere,
      );
      expect(
        VncEndpoint.resolve('ws://127.0.0.1:5901/x', null),
        'ws://127.0.0.1:5901/x',
      );
      expect(VncEndpoint.resolve('not a url', 'ws://harness.test/acp'), isNull);
    });
  });
}

/// Wait, in real time, for [condition] to hold: the client reads its stream
/// as the test writes it.
Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('the condition did not hold');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}
