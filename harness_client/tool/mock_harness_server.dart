// A scripted ACP-over-WebSocket server for trying the client and for the
// end-to-end screenshot run.  It is not the real harness: it speaks the same
// protocol with deterministic data, so every view can be exercised offline.
//
//   dart run tool/mock_harness_server.dart [--port 4277] [--standard]
//
// The client connects to ws://127.0.0.1:PORT/acp.

import 'dart:io';

import '../test/support/fake_harness.dart';

Future<void> main(List<String> arguments) async {
  var port = 4277;
  var enhanced = true;
  for (var index = 0; index < arguments.length; index++) {
    final argument = arguments[index];
    if (argument == '--port' && index + 1 < arguments.length) {
      port = int.parse(arguments[++index]);
    } else if (argument == '--standard') {
      enhanced = false;
    } else if (argument == '--help' || argument == '-h') {
      stdout.writeln(
        'usage: dart run tool/mock_harness_server.dart '
        '[--port 4277] [--standard]',
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
    final harness = FakeHarness(enhanced: enhanced);
    harness.writer = socket.add;
    socket.listen(
      (data) {
        if (data is String) harness.handleMessage(data);
      },
      onDone: () => socket.close(),
      onError: (_) => socket.close(),
    );
    stdout.writeln('client connected');
  }
}
