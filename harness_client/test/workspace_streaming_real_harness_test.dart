// Workspace streaming against the real harness: the Emacs one, with its
// demo provider standing in for the model, over ACP as the app talks to it.
//
//   tool/with_real_harness.sh flutter test \
//       test/workspace_streaming_real_harness_test.dart
//
// It is skipped without HARNESS_REAL_ADDRESS.  The fake-harness test says
// what the client does with the events it is sent; this is the harness
// sending them: the workspace episode's chunks and final node, the
// timeline read that replays it, and the words on the controller.
import 'dart:async';
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

  Future<void> eventually(bool Function() done, [int seconds = 60]) async {
    final deadline = DateTime.now().add(Duration(seconds: seconds));
    while (!done()) {
      if (DateTime.now().isAfter(deadline)) fail('timed out');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
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
  });

  tearDownAll(() async {
    if (skip != false) return;
    app.dispose();
  });

  test('a real workspace reply streams in pieces and replays whole', () async {
    if (skip != false) return;
    final root = Platform.environment['HARNESS_REAL_CWD'];
    expect(root, isNotNull);
    final created = await app.api!.extension('workspace/create', {
      'name': 'Streaming probe',
      'root': root,
    });
    final id = asString(created['id']);
    expect(id, isNotNull);
    final workspace = app.workspace!;
    await workspace.load(id: id, showSpinner: false);
    expect(workspace.current?.id, id);

    // The demo provider's `stream` reply is paced in many text chunks
    // across two model calls.
    final seen = <String, List<String>>{};
    void record() {
      for (final entry in workspace.entries) {
        if (!entry.isAgent || entry.node.isEmpty || entry.text.isEmpty) {
          continue;
        }
        final texts = seen.putIfAbsent(entry.node, () => <String>[]);
        if (texts.isEmpty || texts.last != entry.text) texts.add(entry.text);
      }
    }

    workspace.addListener(record);
    unawaited(workspace.send('stream the reply'));
    await eventually(
      () =>
          !workspace.sending &&
          workspace.entries.any(
            (entry) =>
                entry.isAgent && entry.text.contains('second model call'),
          ),
    );
    workspace.removeListener(record);

    final answers = workspace.entries
        .where(
          (entry) =>
              entry.isAgent && entry.node.isNotEmpty && entry.text.isNotEmpty,
        )
        .toList();
    expect(answers, isNotEmpty);
    final last = answers.last;
    expect(last.text, contains('second model call'));
    expect(last.text.split(RegExp(r'\s+')).length, greaterThan(20));
    expect(last.streaming, isFalse);
    // The words grow a piece at a time, each reading a prefix of the next.
    final growth = seen[last.node] ?? const <String>[];
    expect(growth.length, greaterThan(2));
    for (var i = 1; i < growth.length; i++) {
      expect(
        growth[i].startsWith(growth[i - 1]),
        isTrue,
        reason: 'snapshot $i is not a growth of the one before it',
      );
      expect(growth[i].length, greaterThan(growth[i - 1].length));
    }
    expect(growth.last, last.text);

    // Reading the workspace again is the replay: the same complete text,
    // one entry per node, never the first chunk nor the text twice.
    final nodes = answers.map((entry) => entry.node).toSet();
    await workspace.reload();
    final replayed = workspace.entries
        .where(
          (entry) =>
              entry.isAgent && entry.node.isNotEmpty && entry.text.isNotEmpty,
        )
        .toList();
    expect(replayed.map((entry) => entry.node).toSet(), nodes);
    expect(
      replayed.where((entry) => entry.node == last.node).single.text,
      last.text,
    );
    expect(
      workspace.entries.where((entry) => entry.node == last.node),
      hasLength(1),
    );
    expect(last.text.contains('${last.text}${last.text}'), isFalse);
  });
}
