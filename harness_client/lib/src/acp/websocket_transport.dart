import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'acp_transport.dart';

/// Opens the channel of a WebSocket connection to [uri], offering
/// [protocols].  A platform that can do more than the default (`dart:io`
/// can ping) passes its own to [WebSocketAcpTransport.connect].
typedef WebSocketOpener = WebSocketChannel Function(
  Uri uri,
  List<String> protocols,
);

/// How often a connection that can ping does, to keep it open through
/// whatever is between the device and the harness (a mobile network, a VPN,
/// a NAT forget a connection that is silent for a minute or so) and to find
/// out that it died: the peer must answer a ping within the same time, or
/// the connection is closed (`dart:io` closes it with "going away").  That
/// is also how long the harness may be busy before it is given up on, so it
/// is not much shorter than that.
const Duration webSocketPingInterval = Duration(seconds: 25);

WebSocketChannel _openDefault(Uri uri, List<String> protocols) =>
    WebSocketChannel.connect(uri, protocols: protocols);

/// WebSocket transport, shared by mobile, desktop and web builds.
///
/// It offers `acp.v1` (the protocol's subprotocol) and, when there is a
/// session secret, `bearer.SECRET`, which the harness's remote listener
/// accepts on every upgrade.  A subprotocol is the one place a browser can
/// put a credential (it cannot set headers), and it keeps the secret out of
/// the URL, which proxies log.  The harness answers with `acp.v1` and never
/// echoes the secret.  A listener that refuses the secret answers the
/// upgrade with HTTP 401.
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
    WebSocketOpener? opener,
  }) async {
    final protocols = <String>['acp.v1'];
    if (token.isNotEmpty) protocols.add('bearer.$token');
    final channel = (opener ?? _openDefault)(uri, protocols);
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
  bool _closedHere = false;
  Object? _failure;
  String? _closeReason;

  void _onData(dynamic data) {
    if (data is String) {
      if (data.trim().isNotEmpty) _messages.add(data);
    } else if (data is List<int>) {
      _messages.add(utf8.decode(data, allowMalformed: true));
    }
  }

  void _onError(Object error, StackTrace stack) {
    _failure ??= error;
    if (!_messages.isClosed) _messages.addError(error, stack);
    _finish();
  }

  void _onDone() => _finish();

  void _finish() {
    if (_open && !_closedHere) {
      _closeReason = _describeEnd(
        _failure,
        _channel.closeCode,
        _channel.closeReason,
      );
    }
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
  String? get closeReason => _closeReason;

  @override
  void send(String message) {
    if (!_open) throw StateError('WebSocket is closed');
    _channel.sink.add(message);
  }

  @override
  Future<void> close([String? reason]) async {
    if (!_open) return;
    _open = false;
    _closedHere = true;
    await _channel.sink.close(1000, reason);
    await _sub?.cancel();
    _finish();
  }
}

/// What a person is told about the end of a WebSocket: the [failure] its
/// socket failed with, else the close [code] and [reason] its peer gave.
String _describeEnd(Object? failure, int? code, String? reason) {
  if (failure != null) {
    final text = '$failure'.replaceFirst(RegExp(r'^Exception: '), '');
    return 'The connection failed: $text';
  }
  final why = reason == null || reason.isEmpty ? '' : ': $reason';
  return switch (code) {
    1000 => 'The harness closed the connection.',
    // `dart:io` closes a connection whose peer did not answer a ping with
    // "going away", and says nothing more.
    1001 => 'The harness stopped answering, or went away$why.',
    null || 1005 || 1006 => 'The connection dropped.',
    // A connection cut in the middle of a message: `dart:io` calls that a
    // protocol error, and the peer said nothing.
    1002 when why.isEmpty => 'The connection dropped.',
    _ => 'The harness closed the connection (code $code$why).',
  };
}
