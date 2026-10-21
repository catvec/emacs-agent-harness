import 'dart:async';
import 'dart:convert';

import 'acp_message.dart';
import 'acp_transport.dart';

/// An error returned by the peer, or a transport failure.
class AcpException implements Exception {
  const AcpException(this.code, this.message, [this.data]);

  /// JSON-RPC error code (or -32003 for a closed transport).
  final int code;
  final String message;
  final Object? data;

  bool get isAuthRequired => code == -32000;
  bool get isMethodNotFound => code == -32601;
  bool get isInvalidParams => code == -32602;
  bool get isTransport => code == -32003;

  @override
  String toString() => 'ACP error $code: $message';
}

class AcpNotification {
  const AcpNotification(this.method, this.params);
  final String method;
  final JsonMap params;
}

/// A handler for a request that comes *from* the agent, such as
/// `session/request_permission` and `_harness/ask_user`.
typedef AcpRequestHandler = Future<Object?> Function(
  String method,
  JsonMap params,
);

/// ACP's JSON-RPC 2.0 peer: one message per line (or WebSocket frame).
///
/// Nothing here knows about sessions or harness features; it only pairs
/// requests with answers, surfaces notifications, and answers the agent's
/// requests.  That keeps the protocol testable on its own.
class AcpClient {
  AcpClient(
    this.transport, {
    Duration? requestTimeout = const Duration(minutes: 5),
    this.logger,
  }) : _requestTimeout = requestTimeout {
    _subscription = transport.messages.listen(
      _receive,
      onError: _transportFailed,
      onDone: _transportClosed,
    );
    unawaited(transport.done.whenComplete(_transportClosed));
  }

  final AcpTransport transport;
  final void Function(String message)? logger;
  final Duration? _requestTimeout;

  final _notifications = StreamController<AcpNotification>.broadcast();
  final Map<String, Completer<Object?>> _pending =
      <String, Completer<Object?>>{};
  final _closed = Completer<void>();
  StreamSubscription<String>? _subscription;
  AcpRequestHandler? requestHandler;
  int _nextId = 1;
  bool _isClosed = false;

  Stream<AcpNotification> get notifications => _notifications.stream;
  Future<void> get closed => _closed.future;
  bool get isClosed => _isClosed;
  String get description => transport.description;

  void _log(String message) => logger?.call(message);

  /// Call `initialize` and return the agent's capabilities object.
  ///
  /// `_harness.sessionRefresh` says this client keeps the session secret it
  /// is given when a harness replaces it: the new one comes back in the
  /// answer as `_harness.session.token`.
  ///
  /// `_harness.sessionRefresh` is also what asks a harness to hand over the
  /// session secret of a sign-in, in the answer to `authenticate`, so that
  /// the next connection needs no sign-in.  [clientTitle] is what the person
  /// asked to approve this device sees it called.
  Future<JsonMap> initialize({
    Map<String, Object?> clientCapabilities = const {
      'fs': {'readTextFile': false, 'writeTextFile': false},
      'terminal': false,
      '_harness': {'sessionRefresh': true},
    },
    String clientName = 'Harness',
    String clientTitle = '',
    String clientVersion = '1.0.0',
  }) async {
    final result = await request('initialize', <String, Object?>{
      'protocolVersion': 1,
      'clientCapabilities': clientCapabilities,
      'clientInfo': {
        'name': clientName,
        if (clientTitle.isNotEmpty) 'title': clientTitle,
        'version': clientVersion,
      },
    });
    return asMap(result);
  }

  /// Sign in with [methodId], one of the `authMethods` `initialize` listed:
  /// ACP's way for an agent to sign its user in itself.  The answer comes
  /// when the agent did, which can take as long as the person it asks
  /// does.  [token] is the credential of the method named `token`.
  Future<JsonMap> authenticate({required String methodId, String? token}) async {
    final result = await request('authenticate', <String, Object?>{
      'methodId': methodId,
      if (token != null) 'token': token,
    });
    return asMap(result);
  }

  Future<Object?> request(
    String method, [
    Map<String, Object?>? params,
    Duration? timeout,
  ]) async {
    if (_isClosed) {
      throw const AcpException(-32003, 'The connection is closed.');
    }
    final id = _nextId++;
    final key = '$id';
    final completer = Completer<Object?>();
    _pending[key] = completer;
    final message = <String, Object?>{
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      if (params != null) 'params': params,
    };
    try {
      transport.send(jsonEncode(message));
      _log('→ $method (#$id)');
    } catch (error) {
      _pending.remove(key);
      throw AcpException(-32003, 'Could not send $method: $error');
    }
    // A null timeout uses the client default; Duration.zero means wait
    // forever, which is what a long model turn wants.
    final wait = timeout == Duration.zero ? null : (timeout ?? _requestTimeout);
    if (wait == null) return completer.future;
    return completer.future.timeout(
      wait,
      onTimeout: () {
        _pending.remove(key);
        throw AcpException(
          -32003,
          'No answer to $method after ${wait.inSeconds}s.',
        );
      },
    );
  }

  Future<void> notify(String method, [Map<String, Object?>? params]) async {
    if (_isClosed) return;
    transport.send(
      jsonEncode(<String, Object?>{
        'jsonrpc': '2.0',
        'method': method,
        if (params != null) 'params': params,
      }),
    );
    _log('→ $method (notification)');
  }

  /// Send back the result of an agent request.  Public so a test (or a
  /// custom interaction UI) can answer requests it took out of band.
  void respond(Object? id, Object? result) {
    if (_isClosed) return;
    transport.send(
      jsonEncode(<String, Object?>{
        'jsonrpc': '2.0',
        'id': id,
        'result': result ?? const <String, Object?>{},
      }),
    );
  }

  void respondError(Object? id, int code, String message, [Object? data]) {
    if (_isClosed) return;
    transport.send(
      jsonEncode(<String, Object?>{
        'jsonrpc': '2.0',
        'id': id,
        'error': {
          'code': code,
          'message': message,
          if (data != null) 'data': data,
        },
      }),
    );
  }

  void _receive(String text) {
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } catch (error) {
      _log('Ignoring unparseable message: $error');
      return;
    }
    if (decoded is! Map) {
      _log('Ignoring a non-object message.');
      return;
    }
    final message = asMap(decoded);
    final id = message['id'];
    final method = asString(message['method']);
    if (method != null) {
      if (id == null) {
        final params = asMap(message['params']);
        _log('← $method (notification)');
        _notifications.add(AcpNotification(method, params));
      } else {
        _log('← $method (request #$id)');
        unawaited(_answerRequest(id, method, asMap(message['params'])));
      }
      return;
    }
    if (id != null) {
      final completer = _pending.remove('$id');
      if (completer == null) {
        _log('Answer to unknown request #$id');
        return;
      }
      final error = message['error'];
      if (error is Map) {
        final errorMap = asMap(error);
        completer.completeError(
          AcpException(
            asInt(errorMap['code']) ?? -32603,
            asStringOr(errorMap['message'], 'The agent returned an error.'),
            errorMap['data'],
          ),
        );
      } else {
        completer.complete(message['result']);
      }
    }
  }

  Future<void> _answerRequest(Object? id, String method, JsonMap params) async {
    final handler = requestHandler;
    if (handler == null) {
      respondError(id, -32601, 'Method not found: $method');
      return;
    }
    try {
      final result = await handler(method, params);
      respond(id, result);
    } on AcpException catch (error) {
      respondError(id, error.code, error.message, error.data);
    } catch (error) {
      respondError(id, -32603, '$error');
    }
  }

  void _transportFailed(Object error, StackTrace stack) {
    _log('Transport error: $error');
    _failPending(-32003, 'The connection failed: $error');
    _close();
  }

  void _transportClosed() {
    _failPending(-32003, 'The connection was closed.');
    _close();
  }

  void _failPending(int code, String message) {
    final pending = List<Completer<Object?>>.of(_pending.values);
    _pending.clear();
    for (final completer in pending) {
      if (!completer.isCompleted) {
        completer.completeError(AcpException(code, message));
      }
    }
  }

  void _close() {
    if (_isClosed) return;
    _isClosed = true;
    if (!_notifications.isClosed) _notifications.close();
    if (!_closed.isCompleted) _closed.complete();
  }

  Future<void> close() async {
    if (_isClosed) return;
    _isClosed = true;
    _failPending(-32003, 'The connection was closed.');
    await _subscription?.cancel();
    await transport.close();
    _close();
  }
}
