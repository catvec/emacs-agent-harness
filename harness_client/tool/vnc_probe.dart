// Connect to a workspace computer's screen the way the app does, through the
// harness's authenticated WebSocket tunnel, and report what came back.
//
//   dart run tool/vnc_probe.dart ADDRESS TOKEN SOCKET [--input]
//
// ADDRESS is the harness the device signed in to (`ws://HOST:PORT/acp`,
// `https://HOST`, or a bare `HOST:PORT`); TOKEN is its session secret; SOCKET
// is the `socket` of `workspace/box/vnc` as the harness answered it (a
// loopback `ws://127.0.0.1:PORT/websockify?...&workspace=ID`).  The probe
// resolves that loopback socket onto the harness with `VncEndpoint`, as the
// app does, opens it with `WebSocketTransport`, offers the secret in the
// `bearer.` subprotocol and does the RFB handshake with the app's `RfbClient`.
// It then:
//
//   * waits for a framebuffer and prints its size and a pixel digest;
//   * with `--input`, moves the pointer to 100,100 and types
//     `echo VNC-PROBE-OK` followed by Return;
//   * closes, opens a second connection and waits for another framebuffer,
//     which is the reconnect a phone makes after a network change.
//
// A phone would do the same with a widget in front of it; no widget is
// involved here, so a failure is the transport's and the protocol's.
//
// It prints `resolved=`, `frame=`, `input=`, `reconnect=` and
// `VNC PROBE OK`, and exits non-zero on any failure.  A timeout is a failure.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:harness_client/src/vnc/rfb.dart';
import 'package:harness_client/src/vnc/websocket_transport.dart';

const _timeout = Duration(seconds: 30);

Future<void> main(List<String> arguments) async {
  if (arguments.length < 3) {
    stderr.writeln(
      'usage: dart run tool/vnc_probe.dart ADDRESS TOKEN SOCKET [--input]',
    );
    exit(64);
  }
  final address = arguments[0];
  final token = arguments[1];
  final socket = arguments[2];
  final input = arguments.contains('--input');

  try {
    final resolved = VncEndpoint.resolve(socket, address);
    if (resolved == null) {
      throw StateError('the box socket is not a WebSocket: $socket');
    }
    if (!resolved.contains('/workspace/vnc?workspace=')) {
      throw StateError(
        'the socket did not resolve to the harness tunnel: $resolved',
      );
    }
    if (resolved.contains('token=')) {
      throw StateError(
        'the box page token leaked into the tunnel URL: $resolved',
      );
    }
    stdout.writeln('resolved=$resolved');

    final first = await _connect(resolved, token);
    stdout.writeln(
      'frame=${first.width}x${first.height} '
      'digest=${_digest(first.rgba)}',
    );
    final framePath = Platform.environment['VNC_PROBE_FRAME'];
    if (framePath != null && framePath.isNotEmpty) {
      _writePpm(framePath, first.width, first.height, first.rgba);
      stdout.writeln('ppm=$framePath');
    }

    if (input) {
      final client = first.client;
      client.pointer(100, 100, 0);
      for (final code in 'echo VNC-PROBE-OK'.codeUnits) {
        client.key(code, down: true);
        client.key(code, down: false);
      }
      client.key(0xff0d, down: true); // Return
      client.key(0xff0d, down: false);
      await Future<void>.delayed(const Duration(milliseconds: 800));
      stdout.writeln('input=pointer 100,100; keys "echo VNC-PROBE-OK" Return');
      await client.close();
    } else {
      await first.client.close();
    }

    final again = await _connect(resolved, token);
    stdout.writeln(
      'reconnect=${again.width}x${again.height} '
      'digest=${_digest(again.rgba)}',
    );
    await again.client.close();
    stdout.writeln('VNC PROBE OK');
  } catch (error, stack) {
    stderr.writeln('VNC PROBE FAILED: $error');
    if (Platform.environment['VNC_PROBE_TRACE'] == '1') {
      stderr.writeln(stack);
    }
    exit(1);
  }
}

class _Connected {
  _Connected(this.client, this.width, this.height, this.rgba);

  final RfbClient client;
  final int width;
  final int height;
  final List<int> rgba;
}

Future<_Connected> _connect(String resolved, String token) async {
  final client = RfbClient(WebSocketTransport.connect(resolved, token: token));
  // Listen before the handshake: the first frame is a broadcast event.
  final frame = client.frames.first;
  try {
    await client.connect().timeout(_timeout);
    final picture = await frame.timeout(_timeout);
    return _Connected(client, picture.width, picture.height, picture.rgba);
  } catch (error) {
    await client.close();
    rethrow;
  }
}

/// Write the frame as a binary PPM (P6), so what the RFB client received can
/// be looked at and is not only a digest: a picture of the stream itself.
void _writePpm(String path, int width, int height, List<int> rgba) {
  final out = BytesBuilder(copy: false);
  out.add(ascii.encode('P6\n$width $height\n255\n'));
  for (var i = 0; i + 3 < rgba.length; i += 4) {
    out.add([rgba[i], rgba[i + 1], rgba[i + 2]]);
  }
  File(path).writeAsBytesSync(out.takeBytes());
}

/// A small stable digest of the picture, to say the framebuffer is not blank
/// and changes between connections without printing a megabyte of pixels.
String _digest(List<int> rgba) {
  var hash = 0x811c9dc5;
  var ink = 0;
  for (var i = 0; i < rgba.length; i++) {
    final byte = rgba[i];
    hash = ((hash ^ byte) * 0x01000193) & 0xffffffff;
    if (i % 4 != 3 && byte != 0) ink++;
  }
  return '${hash.toRadixString(16).padLeft(8, '0')} ink=$ink';
}
