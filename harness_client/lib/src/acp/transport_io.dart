import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'acp_transport.dart';
import 'connection_target.dart';
import 'websocket_transport.dart';

/// `dart:io` can ping: a WebSocket that does keeps a connection open through
/// a mobile network, a VPN or a NAT that forgets a quiet one, and closes it
/// when the peer stops answering, so a connection that died without a word is
/// found out in under a minute instead of when the next request times out.
WebSocketChannel _openWithPings(Uri uri, List<String> protocols) =>
    IOWebSocketChannel.connect(
      uri,
      protocols: protocols,
      pingInterval: webSocketPingInterval,
    );

/// How long opening the socket may take, where nothing else bounds it.
const Duration connectTimeout = Duration(seconds: 10);

Future<AcpTransport> openAcpTransport(
  ConnectionTarget target,
  String token,
) async {
  if (!target.isTcp) {
    return WebSocketAcpTransport.connect(
      target.webSocketUri!,
      token: token,
      timeout: connectTimeout,
      opener: _openWithPings,
    );
  }
  // A connect that goes nowhere (a phone between cells, a VPN reconnecting)
  // can hang far longer than the platform's own patience; give up in time
  // for the next attempt to be made.
  final socket = await Socket.connect(
    target.tcpHost!,
    target.tcpPort!,
    timeout: connectTimeout,
  );
  return TcpAcpTransport._(socket);
}

/// ACP's own line framing over a TCP socket, as `harness-acp` serves on
/// loopback and `harness-acp-remote` also serves on its port.
class TcpAcpTransport implements AcpTransport {
  TcpAcpTransport._(this._socket) {
    _socket.setOption(SocketOption.tcpNoDelay, true);
    _sub = _socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          _onLine,
          onError: _onError,
          onDone: _onDone,
          cancelOnError: false,
        );
  }

  final Socket _socket;
  final _messages = StreamController<String>.broadcast();
  final _done = Completer<void>();
  late final StreamSubscription<String> _sub;
  bool _open = true;
  bool _closedHere = false;
  String? _closeReason;

  void _onLine(String line) {
    if (line.trim().isNotEmpty) _messages.add(line);
  }

  void _onError(Object error, StackTrace stack) {
    if (_open && !_closedHere) _closeReason = 'The connection failed: $error';
    if (!_messages.isClosed) _messages.addError(error, stack);
    _finish();
  }

  void _onDone() {
    if (_open && !_closedHere) {
      _closeReason = 'The harness closed the connection.';
    }
    _finish();
  }

  void _finish() {
    _open = false;
    if (!_done.isCompleted) _done.complete();
    if (!_messages.isClosed) _messages.close();
  }

  @override
  Stream<String> get messages => _messages.stream;

  @override
  Future<void> get done => _done.future;

  @override
  bool get isOpen => _open;

  @override
  String get description =>
      'tcp://${_socket.remoteAddress.host}:${_socket.remotePort}';

  @override
  String? get closeReason => _closeReason;

  @override
  void send(String message) {
    if (!_open) throw StateError('TCP connection is closed');
    _socket.add(utf8.encode(message));
    _socket.add(const <int>[10]);
  }

  @override
  Future<void> close([String? reason]) async {
    if (!_open) return;
    _open = false;
    _closedHere = true;
    await _sub.cancel();
    try {
      await _socket.flush();
    } catch (_) {
      // The peer may already be gone.
    }
    await _socket.close();
    _finish();
  }
}
