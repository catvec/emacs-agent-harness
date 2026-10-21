import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/acp/acp_client.dart';
import 'package:harness_client/src/acp/connection_target.dart';
import 'package:harness_client/src/acp/transport_factory.dart';
import 'package:harness_client/src/acp/websocket_transport.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Pings every [interval], and closes the connection when the peer does not
/// answer within the same time: what the app does, quicker.
WebSocketOpener _pinging(Duration interval) =>
    (uri, protocols) => IOWebSocketChannel.connect(
      uri,
      protocols: protocols,
      pingInterval: interval,
    );

/// A peer that completes the WebSocket handshake and then says nothing at
/// all, pings included: a harness behind a network that died.  [requests]
/// gets the handshake requests it saw, [sockets] the connections it took.
Future<ServerSocket> _silentPeer(
  List<String> requests, [
  List<Socket>? sockets,
]) async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() => server.close());
  server.listen((socket) {
    sockets?.add(socket);
    final seen = StringBuffer();
    var upgraded = false;
    socket.listen(
      (bytes) {
        if (upgraded) return;
        seen.write(latin1.decode(bytes));
        final text = seen.toString();
        if (!text.contains('\r\n\r\n')) return;
        upgraded = true;
        requests.add(text);
        final key = RegExp(
          r'Sec-WebSocket-Key: (.+)\r\n',
          caseSensitive: false,
        ).firstMatch(text)!.group(1)!.trim();
        socket.add(
          latin1.encode(
            'HTTP/1.1 101 Switching Protocols\r\n'
            'Upgrade: websocket\r\n'
            'Connection: Upgrade\r\n'
            'Sec-WebSocket-Accept: ${WebSocketChannel.signKey(key)}\r\n'
            'Sec-WebSocket-Protocol: acp.v1\r\n\r\n',
          ),
        );
      },
      onError: (_) {},
      onDone: socket.destroy,
    );
  });
  return server;
}

/// An echo server on `dart:io`'s own WebSocket, which answers pings.
Future<HttpServer> _echoPeer(List<WebSocket> sockets) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() => server.close(force: true));
  server.listen((request) async {
    final socket = await WebSocketTransformer.upgrade(
      request,
      protocolSelector: (offered) => 'acp.v1',
    );
    sockets.add(socket);
    socket.listen(socket.add, onError: (_) {});
  });
  return server;
}

Uri _uri(int port) => Uri.parse('ws://127.0.0.1:$port/acp');

void main() {
  group('a WebSocket that pings', () {
    test('finds out that its peer stopped answering', () async {
      final requests = <String>[];
      final server = await _silentPeer(requests);
      final transport = await WebSocketAcpTransport.connect(
        _uri(server.port),
        token: 'hs1_secret',
        opener: _pinging(const Duration(milliseconds: 80)),
      );
      final client = AcpClient(transport);
      addTearDown(client.close);
      // A request nobody answers: it fails when the connection does, not
      // five minutes later.
      final pending = client.request('initialize');
      final failing = expectLater(
        pending,
        throwsA(
          isA<AcpException>().having((e) => e.isTransport, 'transport', isTrue),
        ),
      );
      await client.closed.timeout(const Duration(seconds: 5));
      await failing;
      expect(transport.isOpen, isFalse);
      expect(client.closeReason, contains('stopped answering'));
      // It offered the protocol and the secret, as the harness expects.
      expect(requests, hasLength(1));
      expect(
        requests.single.toLowerCase(),
        contains('sec-websocket-protocol: acp.v1, bearer.hs1_secret'),
      );
    });

    test('keeps an idle connection open against a peer that answers', () async {
      final sockets = <WebSocket>[];
      final server = await _echoPeer(sockets);
      final transport = await WebSocketAcpTransport.connect(
        _uri(server.port),
        opener: _pinging(const Duration(milliseconds: 60)),
      );
      addTearDown(transport.close);
      // Idle for many ping intervals: nothing is said either way.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(transport.isOpen, isTrue);
      expect(transport.closeReason, isNull);
      final echoed = transport.messages.first;
      transport.send('{"hello":"again"}');
      expect(
        await echoed.timeout(const Duration(seconds: 2)),
        '{"hello":"again"}',
      );
    });

    test('says what the peer said when it closes the connection', () async {
      final sockets = <WebSocket>[];
      final server = await _echoPeer(sockets);
      final transport = await WebSocketAcpTransport.connect(
        _uri(server.port),
        opener: _pinging(const Duration(seconds: 5)),
      );
      final client = AcpClient(transport);
      addTearDown(client.close);
      await _until(() => sockets.isNotEmpty);
      await sockets.single.close(4000, 'restarting');
      await client.closed.timeout(const Duration(seconds: 5));
      expect(
        client.closeReason,
        'The harness closed the connection (code 4000: restarting).',
      );
    });

    test('says so when the peer simply goes away', () async {
      final taken = <Socket>[];
      final server = await _silentPeer(<String>[], taken);
      final transport = await WebSocketAcpTransport.connect(
        _uri(server.port),
        opener: _pinging(const Duration(seconds: 5)),
      );
      final client = AcpClient(transport);
      addTearDown(client.close);
      await _until(() => taken.isNotEmpty);
      // No closing handshake: the socket is gone.
      taken.single.destroy();
      await client.closed.timeout(const Duration(seconds: 5));
      expect(client.closeReason, 'The connection dropped.');
    });

    test(
      'closing it oneself gives no reason, and still ends the client',
      () async {
        final sockets = <WebSocket>[];
        final server = await _echoPeer(sockets);
        final transport = await WebSocketAcpTransport.connect(
          _uri(server.port),
          opener: _pinging(const Duration(seconds: 5)),
        );
        final client = AcpClient(transport);
        await client.close();
        await client.closed.timeout(const Duration(seconds: 5));
        expect(client.isClosed, isTrue);
        expect(client.closeReason, isNull);
        expect(transport.closeReason, isNull);
      },
    );
  });

  group('the platform transport', () {
    test('offers the protocol and the secret, and reaches a harness', () async {
      final offered = <String?>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        offered.add(request.headers.value('sec-websocket-protocol'));
        final socket = await WebSocketTransformer.upgrade(
          request,
          protocolSelector: (offered) => 'acp.v1',
        );
        socket.listen(socket.add, onError: (_) {});
      });
      final transport = await openAcpTransport(
        ConnectionTarget.parse('ws://127.0.0.1:${server.port}/acp'),
        'hs1_device',
      );
      addTearDown(transport.close);
      final echoed = transport.messages.first;
      transport.send('{"ok":true}');
      expect(await echoed.timeout(const Duration(seconds: 2)), '{"ok":true}');
      expect(offered, ['acp.v1, bearer.hs1_device']);
    });
  });
}

Future<void> _until(bool Function() done) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) fail('Timed out.');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
