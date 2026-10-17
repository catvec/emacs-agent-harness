import 'acp_transport.dart';
import 'transport_factory.dart';

/// Where an ACP client should connect and how.
class ConnectionTarget {
  const ConnectionTarget({
    required this.raw,
    this.webSocketUri,
    this.tcpHost,
    this.tcpPort,
    required this.isTcp,
  });

  final String raw;
  final Uri? webSocketUri;
  final String? tcpHost;
  final int? tcpPort;
  final bool isTcp;

  /// The label shown beside a connection.
  String get label {
    if (isTcp) return '$tcpHost:$tcpPort · TCP';
    final uri = webSocketUri!;
    return '${uri.host}:${uri.port} · WebSocket';
  }

  /// Parse what a person types into a connection target.
  ///
  /// Accepted forms:
  ///   * `ws://host:4276/acp`, `wss://…` — WebSocket (phone/remote)
  ///   * `tcp://host:1234` — ACP's line framing (desktop/local)
  ///   * `host:port` — TCP on desktop; WebSocket at `/acp` on the web,
  ///     where a browser cannot open a raw socket.
  ///   * `http(s)://host:port/pair?code=…` — the pairing link the harness
  ///     shows.  The caller is told where the ACP address is.
  static ConnectionTarget parse(String input, {bool web = false}) {
    var text = input.trim();
    if (text.isEmpty) throw const FormatException('Enter a server address.');
    if (!text.contains('://')) {
      if (text.startsWith('//')) text = '//$text';
      final looksLikePairing = text.contains('/pair');
      if (looksLikePairing) {
        throw const FormatException(
          'That is a pairing link. Open it on this device first, then use '
          'the ws:// address it shows (ws://HOST:4276/acp).',
        );
      }
      if (web) {
        final uri = Uri.parse('ws://$text');
        final path = uri.path.isEmpty || uri.path == '/' ? '/acp' : uri.path;
        return ConnectionTarget(
          raw: input,
          webSocketUri: uri.replace(path: path),
          isTcp: false,
        );
      }
      final uri = Uri.parse('tcp://$text');
      if (uri.host.isEmpty || !uri.hasPort) {
        throw const FormatException(
          'Use HOST:PORT, for example 127.0.0.1:4276.',
        );
      }
      return ConnectionTarget(
        raw: input,
        tcpHost: uri.host,
        tcpPort: uri.port,
        isTcp: true,
      );
    }
    final uri = Uri.tryParse(text);
    if (uri == null) {
      throw const FormatException('That address does not parse.');
    }
    switch (uri.scheme) {
      case 'ws':
      case 'wss':
        final path = uri.path.isEmpty || uri.path == '/' ? '/acp' : uri.path;
        return ConnectionTarget(
          raw: input,
          webSocketUri: uri.replace(path: path),
          isTcp: false,
        );
      case 'tcp':
        if (web) {
          throw const FormatException(
            'A browser cannot open a raw TCP socket. Use ws://HOST:PORT/acp.',
          );
        }
        if (uri.host.isEmpty || !uri.hasPort) {
          throw const FormatException('Use tcp://HOST:PORT.');
        }
        return ConnectionTarget(
          raw: input,
          tcpHost: uri.host,
          tcpPort: uri.port,
          isTcp: true,
        );
      case 'http':
      case 'https':
        throw const FormatException(
          'That is the harness web page, not ACP. Open it, pair this device, '
          'then connect to ws://HOST:4276/acp.',
        );
      default:
        throw FormatException('Unsupported scheme "${uri.scheme}".');
    }
  }

  /// The WebSocket address, with the token in the query when there is one.
  /// The harness accepts the token there as well as in the subprotocol,
  /// which is the only way a browser can offer it.
  Uri? uriWithToken(String token) {
    final uri = webSocketUri;
    if (uri == null || token.isEmpty) return uri;
    final params = Map<String, String>.from(uri.queryParametersAll)
      ..putIfAbsent('token', () => token);
    return uri.replace(queryParameters: params);
  }

  /// Connect, picking the right transport for this platform.
  Future<AcpTransport> connect({String token = ''}) =>
      openAcpTransport(this, token);
}
