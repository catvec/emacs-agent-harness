// A transcript reads in the order the harness recorded it, whatever order its
// updates come in.
//
// A system note ("non-interactive on", a note of the tool slots changing) is
// a node of the conversation like a message: the harness records it where it
// happens, between the messages around it, and says which node it follows.
// The updates do not always come in that order.  A conversation is read by
// `session/load`, a run of updates, and what the harness records while the
// run is on its way -- a mode switched on, say -- came in the middle of it
// from a harness that was busy writing a long one to a slow phone, and
// before it from one that announced the note as the app asked for the run.
// An app that stands things where they came shows the note among messages
// older than itself, which is "system messages are not where they happened".
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/models/transcript.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';
import 'support/harness_wire.dart';

/// A conversation in which non-interactive mode is switched on while it goes
/// on, and off again while a call runs.
WireConversation _conversation() => WireConversation()
  ..user('Refactor the parser')
  ..say('Reading the code.')
  ..call('c1', 'read_file')
  ..result('c1')
  ..hint('non-interactive on')
  ..say('Now the tests.')
  ..call('c2', 'grep')
  ..hint('non-interactive off')
  ..result('c2')
  ..say('Done.');

/// What a person reads of it, top to bottom: a call and its result are one.
const _expected = [
  'Refactor the parser',
  'Reading the code.',
  '[tool read_file]',
  'non-interactive on',
  'Now the tests.',
  '[tool grep]',
  'non-interactive off',
  'Done.',
];

void _apply(TranscriptState transcript, Iterable<Wire> updates) {
  for (final update in updates) {
    transcript.apply(update);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('a system note between the messages around it', () {
    test('stands there while the conversation goes on', () {
      final conversation = _conversation();
      final transcript = TranscriptState();
      for (final node in conversation.nodes) {
        _apply(transcript, WireConversation.updates(node, live: true));
      }
      expect(shown(transcript.displayItems), _expected);
    });

    test('stands there when the conversation is read again', () {
      final transcript = TranscriptState();
      _apply(transcript, _conversation().replay());
      expect(shown(transcript.displayItems), _expected);
    });

    test('stands there when it came while a call was still running', () {
      // The note is recorded between a call and its result: the result joins
      // the call above it, and the note stands under both.
      final conversation = WireConversation()
        ..user('Run it')
        ..call('c1', 'bash')
        ..hint('non-interactive on')
        ..result('c1')
        ..say('It passed.');
      const expected = [
        'Run it',
        '[tool bash]',
        'non-interactive on',
        'It passed.',
      ];
      final live = TranscriptState();
      for (final node in conversation.nodes) {
        _apply(live, WireConversation.updates(node, live: true));
      }
      expect(shown(live.displayItems), expected);
      final reread = TranscriptState();
      _apply(reread, conversation.replay());
      expect(shown(reread.displayItems), expected);
    });

    test(
      'leaves a call and its result one card when the result came first',
      () {
        // The newest node of a conversation, a call's result, reaches an app
        // that has asked for the conversation before the call does, which
        // comes with the replay.
        final conversation = WireConversation()
          ..user('Go')
          ..call('c1', 'bash')
          ..result('c1', 'all passed');
        final transcript = TranscriptState();
        _apply(
          transcript,
          WireConversation.updates(conversation.nodes[2], live: true),
        );
        _apply(transcript, conversation.replay());
        expect(shown(transcript.displayItems), ['Go', '[tool bash]']);
        expect(transcript.items.where((item) => item.isTool), hasLength(1));
        expect(transcript.displayItems.last.tool!.output, 'all passed');
        expect(transcript.displayItems.last.tool!.isRunning, isFalse);
      },
    );

    test('stays where it is when the harness adds to it', () {
      // A note of something that happens again and again is written once and
      // added to (the tool slots following the machine's load).
      final conversation = WireConversation()
        ..user('Go')
        ..hint('Slots changed due to system load (1 change)')
        ..say('Working on it.');
      final transcript = TranscriptState();
      _apply(transcript, conversation.replay());
      final note = conversation.nodes[1];
      // The whole node again, and the shorter word of it that names no
      // parent.
      transcript.apply({
        'sessionUpdate': '_harness/node',
        'node': {
          ...note,
          'content': 'Slots changed due to system load (2 changes)',
        },
      });
      transcript.apply({
        'sessionUpdate': '_harness/node',
        'node': {
          'id': note['id'],
          'kind': 'hint',
          'content': 'Slots changed due to system load (3 changes)',
        },
      });
      expect(shown(transcript.displayItems), [
        'Go',
        'Slots changed due to system load (3 changes)',
        'Working on it.',
      ]);
    });
  });

  group('a note recorded while a conversation is being read', () {
    test('stands after all of it, wherever in the run it came', () {
      final conversation = _conversation();
      // What the harness replays: the nodes as they are when it begins.
      final replay = conversation.replay();
      // Then it records a note, which is announced as it is.
      final note = conversation.hint('non-interactive on again');
      final announced = WireConversation.updates(note, live: true);
      for (var at = 0; at <= replay.length; at++) {
        final transcript = TranscriptState();
        _apply(transcript, [...replay.take(at), ...announced]);
        // While the rest of the replay comes, the note stands last: the
        // first node of the conversation is here once its two updates are.
        for (var i = at; i < replay.length; i++) {
          transcript.apply(replay[i]);
          if (i >= 1) {
            expect(
              shown(transcript.displayItems).last,
              'non-interactive on again',
              reason:
                  'the note came after $at of the ${replay.length} updates '
                  'of the replay, and ${i + 1} are here',
            );
          }
        }
        expect(
          shown(transcript.displayItems),
          [..._expected, 'non-interactive on again'],
          reason:
              'the note came after $at of the ${replay.length} updates of '
              'the replay',
        );
      }
    });

    test('would stand among older messages if it stood where it came', () {
      // What the order the updates came in shows, which is why the app does
      // not take it as it is.
      final conversation = _conversation();
      final replay = conversation.replay();
      final note = conversation.hint('non-interactive on again');
      final transcript = TranscriptState();
      _apply(transcript, [
        ...replay.take(6),
        ...WireConversation.updates(note, live: true),
        ...replay.skip(6),
      ]);
      final asItCame = shown(transcript.items);
      expect(
        asItCame.indexOf('non-interactive on again'),
        lessThan(asItCame.indexOf('Done.')),
      );
      expect(shown(transcript.displayItems).last, 'non-interactive on again');
    });

    test('and one that came before the replay began, stands after it', () {
      // Announced to an app that had asked for the conversation and not yet
      // had a line of it: the newest nodes of the conversation come first,
      // then all of it.
      final conversation = _conversation();
      final replay = conversation.replay();
      for (var recent = 1; recent <= conversation.nodes.length; recent++) {
        final transcript = TranscriptState();
        for (final node in conversation.nodes.skip(
          conversation.nodes.length - recent,
        )) {
          _apply(transcript, WireConversation.updates(node, live: true));
        }
        // The conversation begins at the top as soon as its first node is
        // here, and what came before it waits at the end.
        _apply(transcript, replay.take(2));
        expect(
          shown(transcript.displayItems).first,
          'Refactor the parser',
          reason: 'the last $recent nodes came before the replay',
        );
        _apply(transcript, replay.skip(2));
        expect(
          shown(transcript.displayItems),
          _expected,
          reason: 'the last $recent nodes came before the replay',
        );
      }
    });

    test('stands between its messages when the app was away from it', () {
      // The first messages came while the app was connected; the note and
      // the messages after it were recorded while its connection was lost;
      // the newest node reached it when it was back, and then it read the
      // conversation again.  What it missed came after the newest node.
      final conversation = _conversation();
      final transcript = TranscriptState();
      void announce(Iterable<Wire> nodes) {
        for (final node in nodes) {
          _apply(transcript, WireConversation.updates(node, live: true));
        }
      }

      announce(conversation.nodes.take(4));
      announce(conversation.nodes.skip(9));
      // As the updates came, what was missed is below the newest message.
      expect(shown(transcript.items), [
        'Refactor the parser',
        'Reading the code.',
        '[tool read_file]',
        'Done.',
      ]);
      _apply(transcript, conversation.replay());
      final shownNow = shown(transcript.displayItems);
      expect(shownNow, _expected);
      // The note stands where it was recorded: after the call before it and
      // before the message after it.
      expect(
        shownNow.indexOf('non-interactive on'),
        shownNow.indexOf('[tool read_file]') + 1,
      );
      expect(
        shownNow.indexOf('Now the tests.'),
        shownNow.indexOf('non-interactive on') + 1,
      );
      // As it came, it stood below the newest message.
      final asItCame = shown(transcript.items);
      expect(
        asItCame.indexOf('non-interactive on'),
        greaterThan(asItCame.indexOf('Done.')),
        reason: 'as it came, the note is below the newest message',
      );
    });

    test('several, in the order they were recorded', () {
      final conversation = _conversation();
      final replay = conversation.replay();
      final first = conversation.hint('first note');
      final reply = conversation.say('a reply');
      final second = conversation.hint('second note');
      final announced = [
        for (final node in [first, reply, second])
          ...WireConversation.updates(node, live: true),
      ];
      for (final at in [0, 3, 9, replay.length]) {
        final transcript = TranscriptState();
        _apply(transcript, [
          ...replay.take(at),
          ...announced,
          ...replay.skip(at),
        ]);
        expect(shown(transcript.displayItems), [
          ..._expected,
          'first note',
          'a reply',
          'second note',
        ], reason: 'they came after $at updates of the replay');
      }
    });

    test('is not moved by reading the conversation again', () {
      final conversation = _conversation();
      final transcript = TranscriptState();
      // The first six nodes came live; then the connection was lost, and
      // the harness recorded the rest.
      for (final node in conversation.nodes.take(6)) {
        _apply(transcript, WireConversation.updates(node, live: true));
      }
      final replay = conversation.replay();
      _apply(transcript, replay);
      expect(shown(transcript.displayItems), _expected);
      // And again: nothing is shown twice or moved.
      _apply(transcript, replay);
      expect(shown(transcript.displayItems), _expected);
      expect(transcript.items, hasLength(_expected.length));
    });
  });

  group('what is not told in order stays as it came', () {
    test('nodes that name no parent are read as they were sent', () {
      // A harness that does not say what each node follows, or an agent that
      // is no harness: the order the updates come in is all there is.
      final conversation = _conversation();
      final transcript = TranscriptState();
      final nodes = [
        for (final node in conversation.nodes) {...node}..remove('parent'),
      ];
      // The note first, as a transcript that was sent so would show it.
      nodes.insert(0, nodes.removeAt(4));
      for (final node in nodes) {
        _apply(transcript, WireConversation.updates(node, live: false));
      }
      expect(shown(transcript.displayItems).first, 'non-interactive on');
      expect(shown(transcript.displayItems), shown(transcript.items));
    });

    test(
      'a node whose parent is not in the transcript stays where it came',
      () {
        // A transcript read from the middle (a window of its nodes) names a
        // parent it does not hold.
        final conversation = _conversation();
        final transcript = TranscriptState();
        for (final node in conversation.nodes.skip(4)) {
          _apply(transcript, WireConversation.updates(node, live: false));
        }
        expect(shown(transcript.displayItems), _expected.skip(3).toList());
      },
    );

    test('a second branch stands after the first, as it came', () {
      // The head of a session moved back and the conversation went on from
      // there: two nodes follow the same one.
      final conversation = WireConversation()
        ..user('Go')
        ..say('first answer');
      conversation.say('second answer', {
        'parent': conversation.nodes[0]['id'],
      });
      conversation.say('and on', {'parent': conversation.last});
      final transcript = TranscriptState();
      _apply(transcript, conversation.replay());
      expect(shown(transcript.displayItems), [
        'Go',
        'first answer',
        'second answer',
        'and on',
      ]);
    });

    test(
      'nodes that follow each other in a loop all stay in the transcript',
      () {
        final transcript = TranscriptState();
        for (final (id, parent) in [('a', 'b'), ('b', 'a'), ('c', 'a')]) {
          _apply(
            transcript,
            WireConversation.updates({
              'id': id,
              'kind': 'hint',
              'content': 'note $id',
              'parent': parent,
            }, live: true),
          );
        }
        expect(shown(transcript.displayItems), ['note a', 'note b', 'note c']);
      },
    );
  });

  group('a message the turn has not taken yet', () {
    test('stays last, and stands after what it was recorded after', () {
      final conversation = WireConversation()
        ..user('Go')
        ..say('Looking.');
      final transcript = TranscriptState();
      _apply(transcript, conversation.replay());
      // Held for the turn's next step: it is no node yet.
      transcript.syncPending([
        (id: 'held-1', text: 'also check b', sender: 'Harness · tasks'),
      ]);
      expect(shown(transcript.displayItems), [
        'Go',
        'Looking.',
        'Harness · tasks: also check b',
      ]);
      // The agent goes on, and a note is recorded: the message waits below.
      final note = conversation.hint('non-interactive on');
      final more = conversation.say('Checking a.');
      for (final node in [note, more]) {
        _apply(transcript, WireConversation.updates(node, live: true));
      }
      expect(shown(transcript.displayItems), [
        'Go',
        'Looking.',
        'non-interactive on',
        'Checking a.',
        'Harness · tasks: also check b',
      ]);
      expect(transcript.displayItems.last.pending, isTrue);
      // The turn takes it: recorded where the model reads it.
      final taken = conversation.user('also check b', {
        'id': 'held-1',
        'meta': {
          'steering': true,
          'from': {'kind': 'system', 'source': 'tasks'},
        },
      });
      _apply(transcript, WireConversation.updates(taken, live: true));
      transcript.syncPending([]);
      final last = conversation.say('b is fine.');
      _apply(transcript, WireConversation.updates(last, live: true));
      expect(shown(transcript.displayItems), [
        'Go',
        'Looking.',
        'non-interactive on',
        'Checking a.',
        'Harness · tasks: also check b',
        'b is fine.',
      ]);
      expect(transcript.items.any((item) => item.pending), isFalse);
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

    // `strict` is a harness that answers as the real one does when the app
    // asks it for the nodes with `limit` (that it knows no such parameter):
    // the app then has the replay of `session/load` and nothing else, which
    // is how it reads a conversation from a real harness.
    for (final strict in [true, false]) {
      test('puts a note the harness wrote while it loaded a conversation after '
          'it${strict ? '' : ' (the nodes read as well)'}', () async {
        final (app, harness) = await connected();
        harness.strictNodeParams = strict;
        final conversation = _conversation();
        harness.sessions['order'] = {
          ...harness.sessions['s1']!,
          'id': 'order',
          'name': 'Refactor the parser',
        };
        harness.nodes['order'] = [...conversation.nodes];
        var written = false;
        harness.whileReplaying = (sid, sent) {
          // The harness records a note as the fourth node goes out: it
          // reaches the app in the middle of the replay.
          if (sid != 'order' || sent != 4 || written) return;
          written = true;
          harness.stream(
            'order',
            conversation.hint('non-interactive on again'),
          );
        };
        final controller = app.openSession('order');
        await until(() => !controller.loading, what: 'the conversation');
        expect(written, isTrue);
        expect(shown(controller.transcript.displayItems), [
          ..._expected,
          'non-interactive on again',
        ]);
        // As it came it stood among older messages.
        if (strict) {
          final asItCame = shown(controller.transcript.items);
          expect(
            asItCame.indexOf('non-interactive on again'),
            lessThan(asItCame.indexOf('Done.')),
          );
        }
        // And a note recorded after the conversation is loaded stands
        // last, where it is announced.
        harness.stream('order', conversation.hint('non-interactive off'));
        await until(
          () =>
              shown(controller.transcript.displayItems).last ==
              'non-interactive off',
          what: 'the next note',
        );
        expect(shown(controller.transcript.displayItems), [
          ..._expected,
          'non-interactive on again',
          'non-interactive off',
        ]);
      });
    }

    test('puts what was recorded while the app was away between the messages '
        'around it', () async {
      final (app, harness) = await connected();
      // As the real harness answers a request for the nodes with `limit`:
      // the app has the replay of `session/load`, and nothing else.
      harness.strictNodeParams = true;
      final conversation = _conversation();
      harness.sessions['order'] = {
        ...harness.sessions['s1']!,
        'id': 'order',
        'name': 'Refactor the parser',
      };
      harness.nodes['order'] = conversation.nodes.take(4).toList();
      final controller = app.openSession('order');
      await until(() => !controller.loading, what: 'the conversation');
      expect(shown(controller.transcript.displayItems), _expected.take(3));
      // The connection is out while the harness records the next five
      // nodes, a mode switched on and off among them.  Nothing is announced.
      harness.nodes['order']!.addAll(conversation.nodes.skip(4).take(5));
      // The connection is back, and the newest node is announced to the
      // app before it has read the conversation again.
      harness.stream('order', conversation.nodes[9]);
      await until(
        () => shown(controller.transcript.items).contains('Done.'),
        what: 'the newest node',
      );
      // The app reads the conversation again, as it does once it is back.
      await controller.open(force: true);
      expect(shown(controller.transcript.displayItems), _expected);
      // As the updates came, what it missed stood below the newest message.
      final asItCame = shown(controller.transcript.items);
      expect(
        asItCame.indexOf('non-interactive on'),
        greaterThan(asItCame.indexOf('Done.')),
      );
    });
  });
}
