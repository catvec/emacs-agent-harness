import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'acp_transport.dart';

/// WebSocket transport, shared by mobile, desktop and web builds.
///
/// It offers `acp.v1` (the protocol's subprotocol) and, when there is a
/// token, `bearer.TOKEN`, which the harness's remote listener accepts.  The
/// token is also put in the query string: the web build cannot set headers,
/// and the harness reads either.
class WebSocketAcpTransport implements AcpTransport {
  WebSocketAcpTransport._(this._channel, this._uri) {
    _sub = _channel.stream.listen(
      _onData,
      onError: _onError,
      onDone: _onDone,
      cancelOnError: false,
    );
  }

  static Future<WebSocketAcpTransport> connect(
    Uri uri, {
    String token = '',
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final protocols = <String>['acp.v1'];
    if (token.isNotEmpty) protocols.add('bearer.$token');
    final channel = WebSocketChannel.connect(uri, protocols: protocols);
    try {
      await channel.ready.timeout(timeout);
    } on TimeoutException {
      await channel.sink.close();
      throw TimeoutException('WebSocket handshake timed out', timeout);
    }
    return WebSocketAcpTransport._(channel, uri);
  }

  final WebSocketChannel _channel;
  final Uri _uri;
  final _messages = StreamController<String>.broadcast();
  final _done = Completer<void>();
  StreamSubscription<dynamic>? _sub;
  bool _open = true;

  void _onData(dynamic data) {
    if (data is String) {
      if (data.trim().isNotEmpty) _messages.add(data);
    } else if (data is List<int>) {
      _messages.add(utf8.decode(data, allowMalformed: true));
    }
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
  String get description => _uri.toString();

  @override
  void send(String message) {
    if (!_open) throw StateError('WebSocket is closed');
    _channel.sink.add(message);
  }

  @override
  Future<void> close([String? reason]) async {
    if (!_open) return;
    _open = false;
    await _channel.sink.close(1000, reason);
    await _sub?.cancel();
    _finish();
  }
}
