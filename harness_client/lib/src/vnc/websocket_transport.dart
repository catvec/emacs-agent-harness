/// The WebSocket side of a VNC connection: the RFB bytes of a workspace
/// computer as binary WebSocket frames, and where that endpoint really is.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'rfb.dart';

/// [RfbTransport] over a WebSocket, as a browser's VNC server speaks it:
/// every binary frame is a piece of the RFB stream.
class WebSocketTransport implements RfbTransport {
  WebSocketTransport(this._channel) {
    _subscription = _channel.stream.listen(
      _onData,
      onError: _onError,
      onDone: _onDone,
    );
  }

  /// Open the WebSocket at [url] (`ws://` or `wss://`).
  ///
  /// [token] is the harness's session secret when the endpoint is its
  /// authenticated VNC tunnel; it travels in the `bearer.` subprotocol, the
  /// one place a browser can put a credential, and never in the URL.  The
  /// box's own bridge on this machine needs none and takes any subprotocol.
  factory WebSocketTransport.connect(String url, {String token = ''}) {
    final protocols = <String>['vnc.v1'];
    final secret = token.trim();
    if (secret.isNotEmpty) protocols.add('bearer.$secret');
    return WebSocketTransport(
      WebSocketChannel.connect(Uri.parse(url), protocols: protocols),
    );
  }

  final WebSocketChannel _channel;
  final _bytes = StreamController<Uint8List>.broadcast();
  StreamSubscription<Object?>? _subscription;
  bool _closed = false;

  @override
  Stream<Uint8List> get bytes => _bytes.stream;

  @override
  void send(List<int> data) {
    if (_closed) return;
    _channel.sink.add(data);
  }

  void _onData(Object? data) {
    if (_bytes.isClosed) return;
    if (data is Uint8List) {
      _bytes.add(data);
    } else if (data is List<int>) {
      _bytes.add(Uint8List.fromList(data));
    }
  }

  void _onError(Object error, StackTrace stack) {
    if (!_bytes.isClosed) _bytes.addError(error, stack);
  }

  void _onDone() {
    unawaited(close());
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _subscription?.cancel();
    _subscription = null;
    await _channel.sink.close();
    if (!_bytes.isClosed) await _bytes.close();
  }
}

/// Where a VNC endpoint is, for the device that watches it.
abstract final class VncEndpoint {
  /// The screen endpoint [socket] names, with a loopback host and port
  /// rewritten to the harness the app is signed in to ([harnessAddress]): the
  /// demo runs on the harness's machine, and `127.0.0.1` there is not
  /// `127.0.0.1` here.
  ///
  /// [socket] is the `socket` of a demo's `vnc`, the WebSocket an RFB client
  /// speaks to; the `url` beside it is the box's noVNC page, which this app
  /// never opens as the screen and this function does not read: an
  /// `http(s)` URL is not a socket, and resolves to null.
  ///
  /// The path and query are kept, and so is the transport: `wss` stays
  /// `wss`; a `ws` endpoint goes to `wss` when the harness is reached over
  /// TLS (`https` or `wss`).  Anything that is not a loopback endpoint, or a
  /// harness that does not parse, is left as it came.
  ///
  /// A box on this machine publishes `/websockify?token=…&workspace=ID` on
  /// its own loopback web port.  That port is not reachable from another
  /// machine, so when the host and port are rewritten the path becomes the
  /// harness's authenticated `/workspace/vnc?workspace=ID`: the same RFB
  /// bytes, through the session the app is signed in to.  The box's page
  /// token is not needed there and is not sent.
  static String? resolve(String socket, String? harnessAddress) {
    final vnc = Uri.tryParse(socket.trim());
    if (vnc == null || !vnc.hasScheme || vnc.host.isEmpty) return null;
    if (vnc.scheme != 'ws' && vnc.scheme != 'wss') return null;
    if (!_isLoopback(vnc.host)) return socket;
    final harness = _harness(harnessAddress);
    if (harness == null || harness.host.isEmpty) return socket;
    final workspace = vnc.queryParameters['workspace'];
    final tunnel =
        vnc.path == '/websockify' && workspace != null && workspace.isNotEmpty;
    final secureHarness = harness.scheme == 'https' || harness.scheme == 'wss';
    final scheme = vnc.scheme == 'wss' || secureHarness ? 'wss' : 'ws';
    final port = harness.hasPort && !_isDefaultPort(scheme, harness.port)
        ? harness.port
        : null;
    final resolved = Uri(
      scheme: scheme,
      userInfo: vnc.userInfo.isEmpty ? null : vnc.userInfo,
      host: harness.host,
      port: port,
      path: tunnel ? '/workspace/vnc' : vnc.path,
      query: tunnel
          ? 'workspace=${Uri.encodeQueryComponent(workspace)}'
          : (vnc.hasQuery ? vnc.query : null),
      fragment: vnc.hasFragment ? vnc.fragment : null,
    );
    return resolved.toString();
  }

  static bool _isLoopback(String host) {
    final name = host.toLowerCase();
    return name == 'localhost' ||
        name == '::1' ||
        name == '0.0.0.0' ||
        name.startsWith('127.');
  }

  static bool _isDefaultPort(String scheme, int port) =>
      ((scheme == 'wss' || scheme == 'https') && port == 443) ||
      ((scheme == 'ws' || scheme == 'http') && port == 80);

  static Uri? _harness(String? address) {
    final text = address?.trim();
    if (text == null || text.isEmpty) return null;
    // `box:9999` parses as a URI whose scheme is `box`; an address with no
    // `//` is a host and port, not a scheme.
    var uri = Uri.tryParse(text.contains('://') ? text : 'ws://$text');
    if (uri == null) return null;
    return switch (uri.scheme) {
      'ws' || 'wss' || 'http' || 'https' => uri,
      _ => null,
    };
  }
}
