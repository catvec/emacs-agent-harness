import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';

const _main = '/Users/noah/Code/emacs-agent-harness/';

/// A session of kind `internal`: the record of a model call the harness made
/// on its own (the permission judge, a recap), not a conversation.
Map<String, Object?> _internal(String id) => {
  'id': id,
  'name': 'Permission judge',
  'kind': 'internal',
  'project': _main,
  'cwd': _main,
  'model': 'claude:claude-haiku-5-5',
  'status': 'idle',
  'updated': DateTime.now().millisecondsSinceEpoch / 1000,
};

Future<(AppController, FakeHarness)> _connected({
  void Function(FakeHarness harness)? arrange,
}) async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsController();
  await settings.load();
  final harness = FakeHarness();
  arrange?.call(harness);
  final app = AppController(settings: settings, connector: harness.connector);
  addTearDown(app.dispose);
  await app.connect('ws://memory/acp');
  return (app, harness);
}

int _listings(FakeHarness harness) =>
    harness.requests.where((r) => r.$1 == '_harness/session/list').length;

/// Long enough for the refresh an event schedules (it waits a moment for
/// more events to come) to have been made, if it is going to be.
Future<void> _afterEvents() =>
    Future<void>.delayed(const Duration(milliseconds: 800));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('what the harness says of its sessions', () {
    test('has the sessions read again when a conversation changes', () async {
      final (app, harness) = await _connected();
      final before = _listings(harness);
      harness.announce('session/status', ['s1', 'running']);
      await _afterEvents();
      expect(_listings(harness), before + 1);
      expect(app.sessions, hasLength(4));
    });

    test('has them read again for a session nothing is known of', () async {
      final (_, harness) = await _connected();
      final before = _listings(harness);
      // Only what is certain is skipped: this may be a conversation that
      // began a moment ago.
      harness.announce('session/status', ['n1', 'running']);
      await _afterEvents();
      expect(_listings(harness), before + 1);
    });

    test('does not, for the record of a model call the harness made', () async {
      final (app, harness) = await _connected();
      final before = _listings(harness);
      // The harness records each call it makes on its own as a session that
      // comes and goes: made, run, finished and, once it has kept enough of
      // them, deleted.  That is a few events a minute, all day long.
      harness.announce('session/created', ['j1', _internal('j1')]);
      harness.announce('session/status', ['j1', 'running']);
      harness.announce('session/status', ['j1', 'idle']);
      harness.announce('session/deleted', ['j1', _internal('j1')]);
      await _afterEvents();
      expect(_listings(harness), before);
      expect(app.sessions.map((session) => session.id), isNot(contains('j1')));
      expect(app.sessions, hasLength(4));
    });

    test('knows the record of a call the list told of by its id', () async {
      final (app, harness) = await _connected(
        arrange: (harness) => harness.sessions['j2'] = _internal('j2'),
      );
      expect(app.sessions.map((session) => session.id), isNot(contains('j2')));
      final before = _listings(harness);
      // `session/status` tells the id and the status, no more.
      harness.announce('session/status', ['j2', 'running']);
      harness.announce('session/status', ['j2', 'idle']);
      await _afterEvents();
      expect(_listings(harness), before);
    });

    test('forgets a record that was deleted', () async {
      final (_, harness) = await _connected();
      harness.announce('session/created', ['j3', _internal('j3')]);
      harness.announce('session/deleted', ['j3', _internal('j3')]);
      await _afterEvents();
      final before = _listings(harness);
      // A session that is made with that id after it is no internal one,
      // and is not taken for it.
      harness.announce('session/status', ['j3', 'running']);
      await _afterEvents();
      expect(_listings(harness), before + 1);
    });
  });
}
