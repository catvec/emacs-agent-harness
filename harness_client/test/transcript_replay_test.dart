// The app reads a conversation from a harness that keeps the transcript's
// nodes as nodes: one update per node, where the standard replay would send
// the text again as a chunk of its own.  The updates that arrive while the
// replay goes out are held for after it, so a note written meanwhile is
// neither lost nor put below messages newer than it.
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/models/transcript.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';
import 'support/harness_wire.dart';

WireConversation _conversation() => WireConversation()
  ..user('Refactor the parser')
  ..say('Reading the code.')
  ..call('c1', 'read_file')
  ..result('c1')
  ..hint('non-interactive on')
  ..say('Done.');

const _expected = [
  'Refactor the parser',
  'Reading the code.',
  '[tool read_file]',
  'non-interactive on',
  'Done.',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<(AppController, FakeHarness)> connected() async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsController();
    await settings.load();
    final harness = FakeHarness();
    final app = AppController(settings: settings, connector: harness.connector);
    addTearDown(app.dispose);
    await app.connect('ws://memory/acp', token: '');
    return (app, harness);
  }

  Future<void> until(bool Function() done, {String? what}) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!done()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('Timed out waiting for ${what ?? 'the app'}.');
      }
      await Future<void>.delayed(const Duration(milliseconds: 4));
    }
  }

  void open(FakeHarness harness, WireConversation conversation) {
    harness.sessions['order'] = {
      ...harness.sessions['s1']!,
      'id': 'order',
      'name': 'Refactor the parser',
    };
    harness.nodes['order'] = [...conversation.nodes];
  }

  test('asks a harness with nodes for the nodes alone, in one request', () async {
    final (app, harness) = await connected();
    final conversation = _conversation();
    open(harness, conversation);
    final before = harness.requests.length;
    final controller = app.openSession('order');
    await until(() => !controller.loading, what: 'the conversation');
    expect(shown(controller.transcript.displayItems), _expected);
    final sent = [
      for (final (method, _) in harness.requests.skip(before)) method,
    ];
    expect(sent.where((method) => method == 'session/load'), hasLength(1));
    expect(harness.calls('session/load').single['_harness'], {
      'replay': 'nodes',
    });
    // The nodes came with the replay: no second read of them, no second
    // record of the session.
    expect(sent, isNot(contains('session/nodes')));
    expect(sent, isNot(contains('session/get')));
    // A home screen reads what it draws.
    expect(harness.calls('_harness/session/list').first['filter'], {
      'lean': true,
    });
  });

  test('reads a harness that replays the standard updates too', () async {
    // A harness that ignores the request: the node's chunk and the node
    // itself come for every node, and the conversation still reads right.
    final (app, harness) = await connected();
    harness.nodeReplay = false;
    final conversation = _conversation();
    open(harness, conversation);
    final controller = app.openSession('order');
    await until(() => !controller.loading, what: 'the conversation');
    expect(shown(controller.transcript.displayItems), _expected);
  });

  test('keeps a note written while the conversation loads', () async {
    final (app, harness) = await connected();
    final conversation = _conversation();
    open(harness, conversation);
    var written = false;
    harness.whileReplaying = (sid, sent) {
      if (sid != 'order' || sent != 2 || written) return;
      written = true;
      // Where the note belongs: right after the message it followed.
      final note = conversation.hint('while loading');
      note['parent'] = 'n2';
      harness.stream('order', note);
    };
    final controller = app.openSession('order');
    await until(() => !controller.loading, what: 'the conversation');
    expect(written, isTrue);
    expect(shown(controller.transcript.displayItems), [
      'Refactor the parser',
      'Reading the code.',
      'while loading',
      '[tool read_file]',
      'non-interactive on',
      'Done.',
    ]);
  });

  test('works out the displayed order once until the transcript changes', () {
    final conversation = _conversation();
    final transcript = TranscriptState();
    for (final node in conversation.nodes) {
      for (final update in WireConversation.updates(node, live: false)) {
        transcript.apply(update);
      }
    }
    final first = transcript.displayItems;
    expect(shown(first), _expected);
    expect(identical(transcript.displayItems, first), isTrue);
    transcript.apply(
      WireConversation.updates(conversation.hint('after'), live: false).last,
    );
    final second = transcript.displayItems;
    expect(identical(second, first), isFalse);
    expect(shown(second), [..._expected, 'after']);
    // A transcript read again is a new list, not the old order.
    transcript.reset();
    expect(identical(transcript.displayItems, second), isFalse);
    expect(transcript.displayItems, isEmpty);
  });
}
