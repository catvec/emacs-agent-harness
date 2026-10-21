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
    this.token,
  });

  final String raw;
  final Uri? webSocketUri;
  final String? tcpHost;
  final int? tcpPort;
  final bool isTcp;

  /// A session secret that came with the address (`?token=` in a pasted
  /// connection link), already removed from [webSocketUri].
  final String? token;

  /// The label shown beside a connection.
  String get label {
    if (isTcp) return '$tcpHost:$tcpPort · TCP';
    final uri = webSocketUri!;
    return '${uri.host}:${uri.port} · WebSocket';
  }

  /// Parse what a person types into a connection target.
  ///
  /// Accepted forms:
  ///   * `ws://host:4276/acp`, `wss://…` — WebSocket (phone/remote).  A
  ///     `?token=` in it, as the address of a device that is given a token
  ///     has, is taken out into [token].  `http://` and `https://` name the
  ///     same server: the public URL of a harness behind a TLS proxy.
  ///   * `tcp://host:1234` — ACP's line framing (desktop/local)
  ///   * `host:port` — TCP on desktop; WebSocket at `/acp` on the web,
  ///     where a browser cannot open a raw socket.
  static ConnectionTarget parse(String input, {bool web = false}) {
    var text = input.trim();
    if (text.isEmpty) throw const FormatException('Enter a server address.');
    if (!text.contains('://')) {
      if (text.startsWith('//')) text = text.substring(2);
      if (web) {
        final uri = Uri.parse('ws://$text');
        return _webSocket(input, uri);
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
        return _webSocket(input, uri);
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
        // A harness behind a TLS proxy is told by its URL; ACP is at /acp.
        return _webSocket(
          input,
          uri.replace(scheme: uri.scheme == 'https' ? 'wss' : 'ws'),
        );
      default:
        throw FormatException('Unsupported scheme "${uri.scheme}".');
    }
  }

  static ConnectionTarget _webSocket(String raw, Uri uri) {
    final path = uri.path.isEmpty || uri.path == '/' ? '/acp' : uri.path;
    final params = Map<String, List<String>>.from(uri.queryParametersAll);
    final tokens = params.remove('token');
    final token = tokens == null || tokens.isEmpty || tokens.first.isEmpty
        ? null
        : tokens.first;
    final clean = Uri(
      scheme: uri.scheme,
      userInfo: uri.userInfo,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: path,
      queryParameters: params.isEmpty ? null : params,
    );
    return ConnectionTarget(
      raw: raw,
      webSocketUri: clean,
      isTcp: false,
      token: token,
    );
  }

  /// Connect, picking the right transport for this platform.  [token] is
  /// the session secret, sent in the `bearer.` WebSocket subprotocol: the
  /// one place a browser can put it.
  Future<AcpTransport> connect({String token = ''}) =>
      openAcpTransport(this, token);
}
