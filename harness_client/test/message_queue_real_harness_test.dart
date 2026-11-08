// The queue against a real harness: the Emacs one, with its demo provider
// standing in for the model, over ACP as the app talks to it.
//
//   tool/with_real_harness.sh flutter test test/message_queue_real_harness_test.dart
//
// It is skipped without HARNESS_REAL_ADDRESS (the harness's ACP server, TCP or
// a ws:// address; HARNESS_REAL_TOKEN is the secret of one that wants it, and
// HARNESS_REAL_CWD the directory the session works in).  The fake harness says
// what the harness is believed to answer; this is the harness answering: a
// message put in `session/queue` is the session's queue, the app sees it, and
// the turn that ends sends it as a turn of its own.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/acp/acp_message.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final address = Platform.environment['HARNESS_REAL_ADDRESS'];
  final token = Platform.environment['HARNESS_REAL_TOKEN'] ?? '';
  final skip = address == null || address.isEmpty
      ? 'HARNESS_REAL_ADDRESS names no running harness'
      : false;

  late AppController app;
  late String project;
  late String sessionId;

  Future<void> eventually(
    Future<bool> Function() done, [
    int seconds = 30,
  ]) async {
    final deadline = DateTime.now().add(Duration(seconds: seconds));
    while (!await done()) {
      if (DateTime.now().isAfter(deadline)) fail('timed out');
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  Future<bool> says(String text) async {
    final nodes = await app.api!.sessionNodes(sessionId);
    return nodes.any(
      (node) =>
          asString(node['kind']) == 'user' &&
          (asString(node['content']) ?? '').contains(text),
    );
  }

  setUpAll(() async {
    if (skip != false) return;
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsController();
    await settings.load();
    app = AppController(settings: settings);
    await app.connect(address!, token: token);
    expect(
      app.isConnected,
      isTrue,
      reason: '${app.phase.name}: ${app.error ?? app.resumeError}',
    );
    expect(app.api!.can('session/queue'), isTrue);
    expect(app.api!.can('agent/send-queue'), isTrue);
    expect(app.api!.can('session/queue-remove'), isTrue);
    project =
        Platform.environment['HARNESS_REAL_CWD'] ?? Directory.current.path;
    final created = asMap(
      await app.api!.client.request('session/new', {
        'cwd': project,
        'mcpServers': const <Object?>[],
        '_harness': {'name': 'Queue a message'},
      }),
    );
    sessionId = asString(created['sessionId'])!;
  });

  tearDownAll(() async {
    if (skip != false) return;
    await app.disconnect();
  });

  test(
    'a queued message is the session\'s, and the turn that ends sends it',
    () async {
      final controller = app.sessionController(sessionId);
      await controller.open();
      expect(controller.canQueue, isTrue);

      // Queue the second message while nothing runs: the harness answers the
      // item, its record of the session lists it, and the app shows it.
      await controller.queue('Second message, held for the next turn.');
      expect(controller.queued, hasLength(1));
      expect(
        controller.queued.single.text,
        'Second message, held for the next turn.',
      );
      final record = asMap(
        await app.api!.extensionRaw('session/get', {'id': sessionId}),
      );
      expect(asMapList(record['queue']), hasLength(1));

      // A turn of its own.  When it ends the harness sends the queue as the
      // next turn, and the message it held becomes a node of the conversation.
      await app.api!.prompt(sessionId, [
        {'type': 'text', 'text': 'First message, the turn that runs.'},
      ]);
      await eventually(() => says('Second message'));
      await eventually(() async => controller.queued.isEmpty);
    },
    skip: skip,
  );

  test('a queued message leaves the queue without a turn', () async {
    final controller = app.sessionController(sessionId);
    await controller.open();
    await controller.queue('Delete this one.');
    expect(controller.queued, hasLength(1));
    await controller.removeQueued(controller.queued.single.id);
    expect(controller.queued, isEmpty);
  }, skip: skip);
}
