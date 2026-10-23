
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/models/transcript.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';

/// A message sent while the agent works is no node of the transcript until the
/// turn takes it: it reads in the order the model got things.  Until then the
/// harness holds it and says so (`session/steering-changed`).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  void userChunk(TranscriptState transcript, String id, String text) {
    transcript.apply({
      'sessionUpdate': 'user_message_chunk',
      'content': {'type': 'text', 'text': text},
      '_harness': {'nodeId': id},
    });
  }

  void agentChunk(TranscriptState transcript, String id, String text) {
    transcript.apply({
      'sessionUpdate': 'agent_message_chunk',
      'content': {'type': 'text', 'text': text},
      '_harness': {'nodeId': id},
    });
  }

  List<String> texts(List<TranscriptItem> items) => [
    for (final item in items) item.text,
  ];

  group('a message the harness holds for the running turn', () {
    test('is the one the person sent, waiting last', () {
      final transcript = TranscriptState();
      userChunk(transcript, 'u1', 'go');
      // Sent while the agent works: shown at once.
      transcript.addLocalUser('also check the docs');
      expect(transcript.items.last.localEcho, isTrue);
      // The harness has it, and holds it for the turn's next step.
      transcript.syncPending([
        (id: 'n-2', text: 'also check the docs', sender: null),
      ]);
      final held = transcript.items.last;
      expect(held.localEcho, isFalse, reason: 'the harness has it');
      expect(held.pending, isTrue);
      expect(held.nodeId, 'n-2');
      // The agent goes on, and the message stays below what it does.
      agentChunk(transcript, 'a1', 'Working on it.');
      expect(texts(transcript.displayItems), [
        'go',
        'Working on it.',
        'also check the docs',
      ]);
      expect(transcript.displayItems.last.pending, isTrue);
      expect(transcript.items.length, 3);
    });

    test('stands where the model read it once the turn takes it', () {
      final transcript = TranscriptState();
      userChunk(transcript, 'u1', 'go');
      transcript.addLocalUser('also check the docs');
      transcript.syncPending([
        (id: 'n-2', text: 'also check the docs', sender: null),
      ]);
      agentChunk(transcript, 'a1', 'Working on it.');
      // The turn takes it, after that work: the harness echoes it, and the
      // list it holds is empty.
      userChunk(transcript, 'n-2', 'also check the docs');
      transcript.syncPending([]);
      agentChunk(transcript, 'a2', 'Checking the docs.');
      expect(texts(transcript.displayItems), [
        'go',
        'Working on it.',
        'also check the docs',
        'Checking the docs.',
      ]);
      expect(transcript.items.any((item) => item.pending), isFalse);
      expect(transcript.items.where((item) => item.isUser), hasLength(2));
      expect(transcript.items[2].nodeId, 'n-2');
    });

    test('is the same whichever update tells of the node first', () {
      final transcript = TranscriptState();
      userChunk(transcript, 'u1', 'go');
      transcript.syncPending([(id: 'n-2', text: 'and this', sender: null)]);
      agentChunk(transcript, 'a1', 'Working on it.');
      transcript.applyNode({
        'id': 'n-2',
        'kind': 'user',
        'content': 'and this',
        'meta': {'steering': true},
      });
      expect(texts(transcript.displayItems), [
        'go',
        'Working on it.',
        'and this',
      ]);
      expect(transcript.items.any((item) => item.pending), isFalse);
    });

    test('goes when it is taken back', () {
      final transcript = TranscriptState();
      userChunk(transcript, 'u1', 'go');
      transcript.syncPending([(id: 'n-2', text: 'never mind', sender: null)]);
      expect(transcript.items.last.pending, isTrue);
      transcript.syncPending([]);
      expect(texts(transcript.items), ['go']);
    });

    test('that another client sent is shown too, and names its sender', () {
      final transcript = TranscriptState();
      userChunk(transcript, 'u1', 'go');
      transcript.syncPending([
        (id: 'n-3', text: 'rebase please', sender: 'Harness'),
        (id: 'n-4', text: 'and run the tests', sender: null),
      ]);
      expect(texts(transcript.displayItems), [
        'go',
        'rebase please',
        'and run the tests',
      ]);
      expect(transcript.displayItems[1].sender, 'Harness');
      expect(transcript.displayItems[2].sender, 'You');
      // Said again, nothing is shown twice.
      transcript.syncPending([
        (id: 'n-3', text: 'rebase please', sender: 'Harness'),
        (id: 'n-4', text: 'and run the tests', sender: null),
      ]);
      expect(transcript.items, hasLength(3));
    });
  });

  group('the app', () {
    Future<(AppController, FakeHarness)> connected() async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsController();
      await settings.load();
      final harness = FakeHarness();
      final app = AppController(
        settings: settings,
        connector: harness.connector,
      );
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

    test('shows a message the harness holds last, until the turn reads it', () async {
      final (app, harness) = await connected();
      final controller = app.openSession('s1');
      await until(() => !controller.loading, what: 'the transcript');
      // A message sent from elsewhere while the agent works.
      harness.announce('session/steering-changed', [
        's1',
        [
          {'id': 'n-77', 'text': 'also check b', 'ts': 1.0},
        ],
      ]);
      await until(
        () => controller.transcript.items.any((item) => item.pending),
        what: 'the held message',
      );
      expect(controller.transcript.displayItems.last.text, 'also check b');
      // The agent goes on.
      harness.stream('s1', {
        'id': 'a-90',
        'kind': 'assistant',
        'content': 'Looking at b.',
      });
      await until(
        () => controller.transcript.items.any(
          (item) => item.text == 'Looking at b.',
        ),
        what: 'the agent going on',
      );
      expect(controller.transcript.displayItems.last.text, 'also check b');
      expect(controller.transcript.displayItems.last.pending, isTrue);
      // The turn takes it: the harness records it where the model reads it.
      harness.stream('s1', {
        'id': 'n-77',
        'kind': 'user',
        'content': 'also check b',
        'meta': {'steering': true},
      });
      harness.announce('session/steering-changed', ['s1', <Object?>[]]);
      harness.stream('s1', {
        'id': 'a-91',
        'kind': 'assistant',
        'content': 'b is fine.',
      });
      await until(
        () => controller.transcript.items.any((item) => item.text == 'b is fine.'),
        what: 'the reply',
      );
      final shown = controller.transcript.displayItems;
      final at = shown.indexWhere((item) => item.text == 'also check b');
      expect(shown[at - 1].text, 'Looking at b.');
      expect(shown[at + 1].text, 'b is fine.');
      expect(controller.transcript.items.any((item) => item.pending), isFalse);
    });
  });
}
