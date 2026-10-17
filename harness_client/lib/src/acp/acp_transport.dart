import 'dart:async';

/// A bidirectional stream of ACP JSON-RPC messages.
///
/// ACP is one JSON object per line over a byte stream; over WebSocket each
/// text frame is one object.  Transports hand [AcpClient] whole strings and
/// take whole strings back.
abstract class AcpTransport {
  /// Whole JSON texts, in order, as they arrive.
  Stream<String> get messages;

  /// Resolves when the connection is gone (cleanly or not).
  Future<void> get done;

  bool get isOpen;

  String get description;

  void send(String message);

  Future<void> close([String? reason]);
}
