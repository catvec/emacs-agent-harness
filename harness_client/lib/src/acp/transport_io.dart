import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'acp_transport.dart';
import 'connection_target.dart';
import 'websocket_transport.dart';

Future<AcpTransport> openAcpTransport(
  ConnectionTarget target,
  String token,
) async {
  if (!target.isTcp) {
    return WebSocketAcpTransport.connect(
      target.uriWithToken(token)!,
      token: token,
    );
  }
  final socket = await Socket.connect(target.tcpHost!, target.tcpPort!);
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

  void _onLine(String line) {
    if (line.trim().isNotEmpty) _messages.add(line);
  }

  void _onError(Object error, StackTrace stack) {
    if (!_messages.isClosed) _messages.addError(error, stack);
    _finish();
  }

  void _onDone() => _finish();

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
  void send(String message) {
    if (!_open) throw StateError('TCP connection is closed');
    _socket.add(utf8.encode(message));
    _socket.add(const <int>[10]);
  }

  @override
  Future<void> close([String? reason]) async {
    if (!_open) return;
    _open = false;
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
