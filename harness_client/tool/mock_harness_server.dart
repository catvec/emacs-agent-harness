// A scripted ACP-over-WebSocket server for trying the client and for the
// end-to-end screenshot run.  It is not the real harness: it speaks the same
// protocol with deterministic data, so every view can be exercised offline.
//
//   dart run tool/mock_harness_server.dart [--port 4277] [--standard]
//                                          [--token hs1_SECRET]
//                                          [--approve-after 3] [--tools]
//
// The client connects to ws://127.0.0.1:PORT/acp.  With --token the server
// behaves like the real harness's listener for other devices: an upgrade that
// presents that session secret (`bearer.SECRET` subprotocol, `Authorization:
// Bearer` or `?token=`) is signed in; any other is let in to sign in, and may
// only `initialize` and `authenticate`.  `initialize` lists "Approve in
// Emacs", and its `authenticate` is approved --approve-after seconds later
// (the person at the harness's Emacs, here), with the code on the console;
// the answer hands a client that keeps secrets that secret.  With --tools
// there is one more session, "Tidy the tool cards": a task's session that
// has done some work, with its tool calls of every kind, a failed one, a
// refused one and the `hand_in` call that handed the work in.

import 'dart:async';
import 'dart:io';

import '../test/support/fake_harness.dart';

Future<void> main(List<String> arguments) async {
  var port = 4277;
  var enhanced = true;
  var approveAfter = 3;
  var tools = false;
  String? token;
  for (var index = 0; index < arguments.length; index++) {
    final argument = arguments[index];
    if (argument == '--port' && index + 1 < arguments.length) {
      port = int.parse(arguments[++index]);
    } else if (argument == '--token' && index + 1 < arguments.length) {
      token = arguments[++index];
    } else if (argument == '--approve-after' && index + 1 < arguments.length) {
      approveAfter = int.parse(arguments[++index]);
    } else if (argument == '--standard') {
      enhanced = false;
    } else if (argument == '--tools') {
      tools = true;
    } else if (argument == '--help' || argument == '-h') {
      stdout.writeln(
        'usage: dart run tool/mock_harness_server.dart '
        '[--port 4277] [--standard] [--token hs1_SECRET] [--approve-after 3] '
        '[--tools]',
      );
      return;
    }
  }
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
  stdout.writeln(
    'mock harness (${enhanced ? 'harness extensions' : 'standard ACP'}) '
    'listening on ws://127.0.0.1:$port/acp',
  );
  await for (final request in server) {
    if (!WebSocketTransformer.isUpgradeRequest(request)) {
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.text
        ..write('Harness preview ACP is at ws://127.0.0.1:$port/acp\n');
      await request.response.close();
      continue;
    }
    final presented = token != null && _presents(request, token);
    final socket = await WebSocketTransformer.upgrade(
      request,
      protocolSelector: (protocols) {
        if (protocols.contains('acp.v1')) return 'acp.v1';
        for (final protocol in protocols) {
          if (!protocol.startsWith('bearer.')) return protocol;
        }
        return null;
      },
    );
    final harness = FakeHarness(
      enhanced: enhanced,
      signIn: token != null,
      issueSecret: token,
      knownSecrets: token == null ? null : {token},
    );
    if (tools) harness.seedToolShowcase();
    harness.authenticated = token == null || presented;
    harness.writer = socket.add;
    socket.listen(
      (data) {
        if (data is! String) return;
        harness.handleMessage(data);
        if (harness.waitingForApproval) {
          stdout.writeln(
            'a device asks to be approved: code ${harness.signInCode}; '
            'approving in $approveAfter s',
          );
          Timer(Duration(seconds: approveAfter), harness.approve);
        }
      },
      onDone: () => socket.close(),
      onError: (_) => socket.close(),
    );
    stdout.writeln('client connected${presented ? ' with its secret' : ''}');
  }
}

/// Whether [request] carries the session secret in any of the three places
/// the real harness reads it.
bool _presents(HttpRequest request, String token) {
  final protocols = request.headers['sec-websocket-protocol'] ?? const [];
  for (final line in protocols) {
    for (final protocol in line.split(',')) {
      if (protocol.trim() == 'bearer.$token') return true;
    }
  }
  if (request.headers.value('authorization') == 'Bearer $token') return true;
  return request.uri.queryParameters['token'] == token;
}
