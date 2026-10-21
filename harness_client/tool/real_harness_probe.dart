// Connect to a real emacs-agent-harness over ACP and exercise a scripted turn.
//
//   dart run tool/real_harness_probe.dart ADDRESS [TOKEN] [CWD]
//
// ADDRESS is HOST:PORT or tcp://HOST:PORT (ACP's line framing), a ws://
// address, or the connection link of a device that was given a token (a
// ws:// address with ?token=SESSION-SECRET).  TOKEN is a session secret (or,
// on a loopback ACP server, its acp-token).
//
// A harness that lists sign-in methods in `initialize` is signed in to the way
// an app does it: ACP's `authenticate`.  The method is "emacs-approval" unless
// the environment names another (SIGN_IN_METHOD=oidc), and the person at the
// harness's Emacs approves the device there: the probe prints the code to
// compare and waits.
//
// It prints what the harness advertises, creates a demo-provider session in
// CWD, prompts it with "tour", and reports the standard and harness-specific
// updates that arrive.  Use it to check a new harness version without the UI.

import 'dart:async';
import 'dart:io';

import 'package:harness_client/src/acp/acp_client.dart';
import 'package:harness_client/src/acp/acp_message.dart';
import 'package:harness_client/src/acp/capabilities.dart';
import 'package:harness_client/src/acp/connection_target.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.isEmpty) {
    stderr.writeln(
      'usage: dart run tool/real_harness_probe.dart ADDRESS [TOKEN] [CWD]',
    );
    exit(64);
  }
  final address = arguments[0];
  var token = arguments.length > 1 ? arguments[1] : '';
  final cwd = arguments.length > 2 ? arguments[2] : Directory.current.path;
  final target = ConnectionTarget.parse(
    address.contains('://') ? address : 'tcp://$address',
  );
  if (token.isEmpty && target.token != null) token = target.token!;
  final transport = await target.connect(token: token);
  final client = AcpClient(
    transport,
    logger: (message) {
      if (Platform.environment['VERBOSE'] == '1') stderr.writeln(message);
    },
  );
  final updates = <String>[];
  final subscription = client.notifications.listen((notification) {
    if (notification.method == 'session/update') {
      updates.add(
        asStringOr(asMap(notification.params['update'])['sessionUpdate'], ''),
      );
    }
  });
  try {
    var initialized = await client.initialize(clientTitle: 'Harness probe');
    var caps = HarnessCapabilities.fromInitialize(initialized);
    if (caps.authMethods.isNotEmpty) {
      // The harness lists how this device signs in: over plain TCP with the
      // secret it was given, any other way by a method it chooses.
      final wanted = Platform.environment['SIGN_IN_METHOD'] ?? 'emacs-approval';
      final method = caps.authMethods.firstWhere(
        (m) => token.isNotEmpty && target.isTcp ? m.isToken : m.id == wanted,
        orElse: () => caps.authMethods.first,
      );
      if (method.isToken) {
        await client.authenticate(methodId: 'token', token: token);
        stdout.writeln('signed in with the session secret');
      } else {
        stdout.writeln('${method.name}: ${method.description}');
        if (method.url != null) stdout.writeln('open ${method.url}');
        final answer = await client.authenticate(methodId: method.id);
        final session = asMap(asMap(asMap(answer['_meta'])['harness'])['session']);
        stdout.writeln(
          'signed in with "${method.name}"'
          '${session.isNotEmpty ? '; handed a session secret to keep' : ''}',
        );
      }
      // A listener that has not signed a device in answers `initialize` with
      // little; ask again once let in.
      initialized = await client.initialize(clientTitle: 'Harness probe');
      caps = HarnessCapabilities.fromInitialize(initialized);
    }
    stdout.writeln('agent: ${caps.agentName} ${caps.agentVersion}');
    stdout.writeln(
      'protocol: ${caps.protocolVersion} · harness: ${caps.isHarness} · '
      'extensions: ${caps.extensionCount}',
    );
    stdout.writeln(
      'features: ${caps.features.where((f) => f.enabled).map((f) => f.name).join(', ')}',
    );
    final listed = asMap(await client.request('session/list', {'cwd': cwd}));
    final sessions = asMapList(listed['sessions']);
    stdout.writeln('sessions in $cwd: ${sessions.length}');
    if (caps.sessionList && sessions.isEmpty) {
      stdout.writeln(
        '(the cwd filter is offered; this directory simply has none yet)',
      );
    }
    final created = asMap(
      await client.request('session/new', {
        'cwd': cwd,
        'mcpServers': const <Object?>[],
        if (caps.isHarness)
          '_harness': {'model': 'demo:scripted', 'name': 'ACP probe'},
      }),
    );
    final sid = asString(created['sessionId']);
    if (sid == null) {
      throw StateError('session/new returned no sessionId: $created');
    }
    stdout.writeln('created session $sid');
    final result = asMap(
      await client.request('session/prompt', {
        'sessionId': sid,
        'prompt': [
          {'type': 'text', 'text': 'tour'},
        ],
      }, Duration.zero),
    );
    stdout.writeln('prompt stopped: ${result['stopReason']}');
    final counts = <String, int>{};
    for (final kind in updates) {
      counts[kind] = (counts[kind] ?? 0) + 1;
    }
    stdout.writeln('updates: $counts');
    final required = ['user_message_chunk', 'agent_message_chunk'];
    for (final kind in required) {
      if (!updates.contains(kind)) {
        throw StateError('missing $kind in the turn');
      }
    }
    if (caps.isHarness && !updates.contains('_harness/session')) {
      throw StateError('the harness did not announce its session record');
    }
    // The node stream is what powers the rich transcript.
    if (caps.richNodes) {
      final nodes = asMapList(
        await client.request('_harness/session/nodes', {'id': sid}),
      );
      stdout.writeln(
        'nodes: ${nodes.length} '
        '(${nodes.map((node) => node['kind']).join(', ')})',
      );
      if (nodes.isEmpty) {
        throw StateError('rich nodes were advertised but none returned');
      }
    }
    stdout.writeln('OK');
  } finally {
    await subscription.cancel();
    await client.close();
  }
}
