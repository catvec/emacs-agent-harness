import 'dart:async';

import 'acp_transport.dart';
import 'connection_target.dart';
import 'websocket_transport.dart';

/// Browsers have WebSocket and nothing else; TCP is refused with a clear
/// message by [ConnectionTarget.parse].
Future<AcpTransport> openAcpTransport(
  ConnectionTarget target,
  String token,
) async {
  if (target.isTcp) {
    throw const FormatException(
      'A browser cannot open a raw TCP socket. Use ws://HOST:PORT/acp.',
    );
  }
  return WebSocketAcpTransport.connect(target.webSocketUri!, token: token);
}
