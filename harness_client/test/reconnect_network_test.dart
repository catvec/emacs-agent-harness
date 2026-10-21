import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/acp/websocket_transport.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/io.dart';

import 'support/fake_harness.dart';

/// A network between the app and the harness that can fail the way a real
/// one does: every connection cut at once, with no closing handshake, as a
/// radio does when a phone changes network; new connections refused while
/// it is down; or all traffic swallowed while the sockets stay open, as on
/// a network that died without a word.
class _Network {
  _Network._(this._server, this._target);

  final ServerSocket _server;
  final int _target;
  final _sockets = <Socket>[];
  bool refuse = false;
  bool swallow = false;
  int accepted = 0;

  static Future<_Network> start(int target) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final network = _Network._(server, target);
    server.listen(network._accept);
    return network;
  }

  int get port => _server.port;

  Future<void> _accept(Socket client) async {
    if (refuse) {
      client.destroy();
      return;
    }
    accepted++;
    final upstream = await Socket.connect(
      InternetAddress.loopbackIPv4,
      _target,
    );
    _sockets
      ..add(client)
      ..add(upstream);
    void pipe(Socket from, Socket to) {
      from.listen(
        (data) {
          if (!swallow) to.add(data);
        },
        onDone: to.destroy,
        onError: (_) => to.destroy(),
      );
    }

    pipe(client, upstream);
    pipe(upstream, client);
  }

  /// Every connection dies at once.
  void cut() {
    for (final socket in _sockets) {
      socket.destroy();
    }
    _sockets.clear();
  }

  Future<void> close() async {
    cut();
    await _server.close();
  }
}

/// The harness's ACP over a real WebSocket, as `tool/mock_harness_server.dart`
/// serves it: one scripted [FakeHarness] answers whoever is connected.
Future<(HttpServer, FakeHarness)> _harness() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final harness = FakeHarness();
  server.listen((request) async {
    final socket = await WebSocketTransformer.upgrade(
      request,
      protocolSelector: (protocols) => 'acp.v1',
    );
    harness.writer = socket.add;
    socket.listen(
      (data) {
        if (data is String) harness.handleMessage(data);
      },
      onDone: () => socket.close(),
      onError: (_) => socket.close(),
    );
  });
  return (server, harness);
}

Future<void> _until(bool Function() done, {String? what}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for ${what ?? 'the app'}.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Future<(AppController, _Network, FakeHarness)> _setUp({
  AcpConnector? connector,
}) async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsController();
  await settings.load();
  final (server, harness) = await _harness();
  addTearDown(() => server.close(force: true));
  final network = await _Network.start(server.port);
  addTearDown(network.close);
  final app = AppController(
    settings: settings,
    connector: connector,
    reconnectDelays: const [Duration(milliseconds: 30)],
    handshakeTimeout: const Duration(seconds: 3),
  );
  addTearDown(app.dispose);
  await app.connect('ws://127.0.0.1:${network.port}/acp');
  return (app, network, harness);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('on a real network', () {
    test(
      'a cut connection is got back, and what was shown is read again',
      () async {
        // The app as it ships: its own transport, its own connector.
        final (app, network, harness) = await _setUp();
        expect(app.phase, ConnectionPhase.connected);
        expect(network.accepted, 1);
        final controller = app.openSession('s1');
        await _until(() => !controller.loading, what: 'the conversation');
        app.drafts.setText('session:s1', 'a message being written');

        // The network goes: no closing handshake, and nothing gets through for
        // a while.
        network.refuse = true;
        harness.nodes['s1']!.add({
          'id': 'n99',
          'kind': 'assistant',
          'content': 'Something said while the phone was away.',
          'ts': DateTime.now().millisecondsSinceEpoch / 1000,
        });
        network.cut();
        await _until(() => app.isReconnecting, what: 'the app to notice');
        expect(app.lostReason, 'The connection dropped.');
        await _until(() => app.reconnectAttempt >= 3, what: 'attempts');
        expect(app.reconnectError, isNotNull);
        expect(app.sessions, hasLength(4), reason: 'the lists stay up');

        // It is back.
        network.refuse = false;
        await _until(() => app.isConnected, what: 'the connection');
        expect(network.accepted, 2);
        await _until(
          () => controller.transcript.items.any(
            (item) => item.text.contains('while the phone was away'),
          ),
          what: 'the conversation, read again',
        );
        expect(identical(app.sessionController('s1'), controller), isTrue);
        expect(app.drafts.text('session:s1'), 'a message being written');
        expect(controller.canSend, isTrue);
      },
    );

    test(
      'a connection that died without a word is found by its pings',
      () async {
        // Pings a fifth of a second apart, as the app's are 25 seconds apart.
        final (app, network, _) = await _setUp(
          connector: (target, token) => WebSocketAcpTransport.connect(
            target.webSocketUri!,
            token: token,
            opener: (uri, protocols) => IOWebSocketChannel.connect(
              uri,
              protocols: protocols,
              pingInterval: const Duration(milliseconds: 200),
            ),
          ),
        );
        expect(app.phase, ConnectionPhase.connected);

        // Nothing is closed, nothing arrives.
        network.swallow = true;
        await _until(() => app.isReconnecting, what: 'the app to notice');
        expect(app.lostReason, contains('stopped answering'));

        // The network is back.  The flows that were swallowed are reset, as
        // they are when a network comes back (the attempt that began while it
        // was down is stuck in its handshake); a new connection works.
        network.swallow = false;
        network.cut();
        await _until(() => app.isConnected, what: 'the connection');
        expect(network.accepted, greaterThanOrEqualTo(2));
        expect(app.sessions, hasLength(4));
      },
    );

    test('an idle connection stays up while it is pinged', () async {
      final (app, network, _) = await _setUp(
        connector: (target, token) => WebSocketAcpTransport.connect(
          target.webSocketUri!,
          token: token,
          opener: (uri, protocols) => IOWebSocketChannel.connect(
            uri,
            protocols: protocols,
            pingInterval: const Duration(milliseconds: 80),
          ),
        ),
      );
      // Many ping intervals with nothing to say: still one connection, still
      // connected, and still able to ask for something.
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(app.phase, ConnectionPhase.connected);
      expect(network.accepted, 1);
      await app.refreshSessions();
      expect(app.sessions, hasLength(4));
    });
  });
}
