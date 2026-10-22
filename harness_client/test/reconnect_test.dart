import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/acp/acp_client.dart';
import 'package:harness_client/src/acp/connection_target.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/drafts.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';

class _Rig {
  _Rig(this.settings, this.harness, this.app);
  final SettingsController settings;
  final FakeHarness harness;
  final AppController app;
}

/// An app connected to a fake harness that can drop the connection, refuse
/// the next ones, or go silent.  Waits between attempts are a few
/// milliseconds, so a test need not wait for the real ones.
Future<_Rig> _rig({
  bool signIn = false,
  Set<String>? knownSecrets,
  String? issueSecret,
  String token = '',
  List<Duration> delays = const [Duration(milliseconds: 5)],
  Duration handshakeTimeout = const Duration(seconds: 2),
}) async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsController();
  await settings.load();
  final harness = FakeHarness(
    signIn: signIn,
    knownSecrets: knownSecrets,
    issueSecret: issueSecret,
  );
  final app = AppController(
    settings: settings,
    connector: harness.connector,
    reconnectDelays: delays,
    handshakeTimeout: handshakeTimeout,
    probeTimeout: const Duration(milliseconds: 150),
  );
  addTearDown(app.dispose);
  await app.connect('ws://memory/acp', token: token);
  return _Rig(settings, harness, app);
}

/// Let what runs on its own run: wait, in short steps, until [done].
Future<void> _until(bool Function() done, {String? what}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for ${what ?? 'the app'}.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 4));
  }
}

/// The phases the app goes through from now on, one for each change of
/// phase, starting with the one it is in; [sessionsKept] collects how many
/// sessions it showed at each notification.  What the app goes on doing in
/// the background once it has connected (the plan quota arriving, say)
/// notifies it with the phase as it stands, and is no change.
List<ConnectionPhase> _recordPhases(AppController app, List<int> sessionsKept) {
  final phases = <ConnectionPhase>[app.phase];
  app.addListener(() {
    if (phases.last != app.phase) phases.add(app.phase);
    sessionsKept.add(app.sessions.length);
  });
  return phases;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('a connection that is lost', () {
    test('is got back by itself, and the app keeps what it showed', () async {
      final rig = await _rig();
      final app = rig.app;
      expect(rig.harness.connects, 1);
      expect(app.sessions, hasLength(4));
      final sessionsKept = <int>[];
      final phases = _recordPhases(app, sessionsKept);

      // The harness refuses the first two attempts, as a harness that is
      // restarting does.
      rig.harness.refuseConnects = 2;
      await rig.harness.dropConnection('The connection dropped.');
      await _until(
        () => app.phase == ConnectionPhase.reconnecting,
        what: 'the app to notice',
      );
      expect(app.lostReason, 'The connection dropped.');
      expect(app.isReconnecting, isTrue);
      expect(app.hasSession, isTrue);
      await _until(() => app.reconnectAttempt >= 2, what: 'a second attempt');
      expect(app.reconnectError, contains('refused'));

      await _until(() => app.isConnected, what: 'the connection');
      expect(rig.harness.connects, 2);
      // It started over, with the client, and told the harness who it is.
      expect(
        rig.harness.requestsByClient.where((m) => m == 'initialize'),
        hasLength(2),
      );
      expect(app.lostReason, isNull);
      expect(app.reconnectAttempt, 0);
      expect(app.reconnectError, isNull);
      // Out of touch, never out of the session: the screens were not torn
      // down, nothing went through the connection screen, and the lists
      // were there the whole time.
      expect(phases, [
        ConnectionPhase.connected,
        ConnectionPhase.reconnecting,
        ConnectionPhase.connected,
      ]);
      expect(sessionsKept, everyElement(4));
      expect(app.sessions, hasLength(4));
    });

    test(
      'has the open conversation read again, from the same controller',
      () async {
        final rig = await _rig();
        final app = rig.app;
        final controller = app.openSession('s1');
        await _until(() => !controller.loading, what: 'the transcript');
        bool shows(String text) =>
            controller.transcript.items.any((item) => item.text.contains(text));
        expect(shows('Give me the tour'), isTrue);
        expect(shows('Back again'), isFalse);

        // The harness went on while the connection was out.
        rig.harness.nodes['s1']!.add({
          'id': 'n99',
          'kind': 'assistant',
          'content': 'Back again, with news from while you were away.',
          'ts': DateTime.now().millisecondsSinceEpoch / 1000,
        });
        await rig.harness.dropConnection();
        await _until(
          () => app.isConnected && rig.harness.connects == 2,
          what: 'the connection',
        );
        await _until(() => shows('Back again'), what: 'the transcript again');
        expect(identical(app.sessionController('s1'), controller), isTrue);
        expect(controller.error, isNull);
        // And the controller talks over the new connection: the api it holds
        // was moved to it, not replaced.
        expect(controller.canSend, isTrue);
        expect(controller.api.client.isClosed, isFalse);
      },
    );

    test(
      'does not answer what the agent asked on the lost connection',
      () async {
        final rig = await _rig();
        final app = rig.app;
        final controller = app.openSession('s1');
        await _until(() => !controller.loading, what: 'the transcript');
        unawaited(controller.send('Run the tests with permission'));
        await _until(
          () => controller.currentInteraction != null,
          what: 'the permission request',
        );
        await rig.harness.dropConnection();
        await _until(
          () => app.isConnected && rig.harness.connects == 2,
          what: 'the connection',
        );
        // Giving the request up must not send a refusal nobody gave: the
        // connection it would go out on was closed first.
        expect(rig.harness.permissionAnswers, isEmpty);
        expect(controller.currentInteraction, isNull);
        // The turn is the harness's, and goes on there (it waits for an
        // answer): reading the session again says so.
        expect(controller.error, isNull);
      },
    );

    test(
      'is not got back when the harness no longer accepts the device',
      () async {
        final rig = await _rig(
          signIn: true,
          knownSecrets: {'hs1_device'},
          token: 'hs1_device',
          issueSecret: 'hs1_again',
        );
        final app = rig.app;
        expect(app.phase, ConnectionPhase.connected);
        app.drafts.setText(DraftStore.composerKey('s1'), 'half written');
        app.drafts.task.prompt = 'Write the migration notes';

        // The session was ended in Emacs while the phone was away.
        rig.harness.knownSecrets.clear();
        await rig.harness.dropConnection();
        await _until(
          () => app.phase == ConnectionPhase.needsAuth,
          what: 'the harness to turn the device away',
        );
        expect(app.error, contains('Sign in again'));
        expect(app.hasSession, isFalse);
        expect(app.sessions, isEmpty);
        // The person may sign in again from the screen it falls back to.
        expect(app.signInMethods.map((m) => m.id), ['emacs-approval']);
        // What was typed did not go with the screens.
        expect(app.drafts.text(DraftStore.composerKey('s1')), 'half written');
        expect(app.drafts.task.prompt, 'Write the migration notes');

        final signing = app.signIn(app.signInMethods.first);
        await _until(
          () => rig.harness.waitingForApproval,
          what: 'the approval to be asked for',
        );
        rig.harness.approve();
        await signing;
        expect(app.phase, ConnectionPhase.connected);
        expect(app.drafts.text(DraftStore.composerKey('s1')), 'half written');
      },
    );

    test('stops trying when the person disconnects', () async {
      final rig = await _rig();
      final app = rig.app;
      rig.harness.refuseConnects = 1000000;
      await rig.harness.dropConnection();
      await _until(() => app.reconnectAttempt >= 2, what: 'the attempts');
      await app.disconnect();
      expect(app.phase, ConnectionPhase.disconnected);
      final left = rig.harness.refuseConnects;
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(rig.harness.refuseConnects, left, reason: 'no more attempts');
      expect(app.phase, ConnectionPhase.disconnected);
      expect(app.lostReason, isNull);
    });

    test('tries again at once when asked to', () async {
      // The next attempt would be an hour away.
      final rig = await _rig(delays: const [Duration(hours: 1)]);
      final app = rig.app;
      rig.harness.refuseConnects = 1;
      await rig.harness.dropConnection();
      await _until(() => app.waitingToRetry, what: 'the wait between attempts');
      expect(app.isConnected, isFalse);
      app.retryNow();
      await _until(() => app.isConnected, what: 'the connection');
      expect(rig.harness.connects, 2);
    });

    test('backs off between attempts, and keeps trying', () async {
      final rig = await _rig(
        delays: const [Duration(milliseconds: 5), Duration(milliseconds: 20)],
      );
      final app = rig.app;
      rig.harness.refuseConnects = 5;
      final stamps = <DateTime>[];
      var seen = 0;
      app.addListener(() {
        if (app.reconnectAttempt > seen) {
          seen = app.reconnectAttempt;
          stamps.add(DateTime.now());
        }
      });
      await rig.harness.dropConnection();
      await _until(
        () => rig.harness.connects == 2 && app.isConnected,
        what: 'the connection',
      );
      // Five refused attempts, then the sixth: it never gave up.
      expect(seen, 6);
      // The last wait is the one that repeats: later attempts are 20 ms
      // apart, the first ones sooner.
      final gaps = [
        for (var i = 1; i < stamps.length; i++)
          stamps[i].difference(stamps[i - 1]).inMilliseconds,
      ];
      expect(gaps.last, greaterThanOrEqualTo(15));
    });

    test(
      'gives up on an attempt the harness does not answer, and tries again',
      () async {
        final rig = await _rig(
          handshakeTimeout: const Duration(milliseconds: 60),
        );
        final app = rig.app;
        final errors = <String>[];
        app.addListener(() {
          final error = app.reconnectError;
          if (error != null && (errors.isEmpty || errors.last != error)) {
            errors.add(error);
          }
        });
        // A harness that takes the connection and then says nothing, once.
        rig.harness.silentConnects = 1;
        await rig.harness.dropConnection();
        await _until(
          () => rig.harness.connects == 3 && app.isConnected,
          what: 'the connection',
        );
        expect(errors, hasLength(1));
        expect(errors.single, contains('No answer to initialize'));
      },
    );
  });

  group('a phone that is put away', () {
    test('does not try to connect again until it is back', () async {
      final rig = await _rig();
      final app = rig.app;
      // The app goes to the background; the network goes with it.
      app.setForeground(false);
      rig.harness.refuseConnects = 1;
      await rig.harness.dropConnection();
      await _until(() => app.isReconnecting, what: 'the app to notice');
      await Future<void>.delayed(const Duration(milliseconds: 80));
      // No attempt was made while it was away.
      expect(app.reconnectAttempt, 0);
      expect(rig.harness.refuseConnects, 1);
      expect(rig.harness.connects, 1);

      // Back on screen: it connects again at once.
      await app.resumed();
      await _until(
        () => app.isConnected && rig.harness.connects == 2,
        what: 'the connection',
      );
      expect(app.sessions, hasLength(4));
    });

    test('is not kept from disconnecting', () async {
      final rig = await _rig();
      final app = rig.app;
      app.setForeground(false);
      await rig.harness.dropConnection();
      await _until(() => app.isReconnecting, what: 'the app to notice');
      await app.disconnect();
      expect(app.phase, ConnectionPhase.disconnected);
      // Nothing is left waiting for the app to return.
      app.setForeground(true);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(rig.harness.connects, 1);
      expect(app.phase, ConnectionPhase.disconnected);
    });
  });

  group('a connection that looks open', () {
    test('is found dead by a probe, and replaced', () async {
      final rig = await _rig();
      final app = rig.app;
      // The network died without a word: nothing arrives, nothing is closed.
      rig.harness.silent = true;
      await app.checkConnection();
      await _until(
        () => app.isConnected && rig.harness.connects == 2,
        what: 'a new connection',
      );
      expect(app.sessions, hasLength(4));
    });

    test('is left alone when it answers', () async {
      final rig = await _rig();
      await rig.app.checkConnection();
      await rig.app.resumed();
      expect(rig.harness.connects, 1);
      expect(rig.app.phase, ConnectionPhase.connected);
    });

    test('is replaced at once when it was closed meanwhile', () async {
      final rig = await _rig();
      final app = rig.app;
      // The socket closed while the app was away, and nobody was told.
      await app.client!.close();
      await _until(
        () => app.isConnected && rig.harness.connects == 2,
        what: 'a new connection',
      );
    });

    test('a probe says whether the peer answers', () async {
      final harness = FakeHarness();
      final transport = await harness.open(
        ConnectionTarget.parse('ws://x/acp'),
        '',
      );
      final client = AcpClient(transport);
      addTearDown(client.close);
      await client.initialize();
      // "Method not found" is an answer: the peer is there.
      expect(await client.probe(), isTrue);
      harness.silent = true;
      expect(
        await client.probe(timeout: const Duration(milliseconds: 50)),
        isFalse,
      );
      await client.close();
      expect(await client.probe(), isFalse);
    });

    test('says why it ended, when it was the other end that did', () async {
      final harness = FakeHarness();
      final transport = await harness.open(
        ConnectionTarget.parse('ws://x/acp'),
        '',
      );
      final client = AcpClient(transport);
      await client.initialize();
      expect(client.closeReason, isNull);
      await harness.dropConnection('The harness stopped answering.');
      await client.closed;
      expect(client.closeReason, 'The harness stopped answering.');

      // Ending it oneself is not a reason to tell anybody.
      final other = AcpClient(
        await FakeHarness().open(ConnectionTarget.parse('ws://x/acp'), ''),
      );
      await other.initialize();
      await other.close();
      expect(other.closeReason, isNull);
    });
  });

  group('asking meanwhile', () {
    test('a request made while the connection is out waits for it', () async {
      final rig = await _rig(delays: const [Duration(milliseconds: 40)]);
      final app = rig.app;
      rig.harness.refuseConnects = 1;
      await rig.harness.dropConnection();
      await _until(() => app.isReconnecting, what: 'the app to notice');
      // Asked in the gap: it goes out over the new connection, a moment
      // late, instead of failing on the dead one.
      final page = await app.api!.listSessions();
      expect(page.sessions, isNotEmpty);
      expect(app.isConnected, isTrue);
      expect(rig.harness.connects, 2);
    });

    test(
      'a request fails once the wait is over and nothing came back',
      () async {
        final rig = await _rig(delays: const [Duration(hours: 1)]);
        final app = rig.app;
        app.api!.reconnectGrace = const Duration(milliseconds: 30);
        rig.harness.refuseConnects = 1000000;
        await rig.harness.dropConnection();
        await _until(() => app.waitingToRetry, what: 'the wait');
        await expectLater(
          app.api!.listSessions(),
          throwsA(
            isA<AcpException>().having(
              (e) => e.isTransport,
              'transport',
              isTrue,
            ),
          ),
        );
      },
    );

    test(
      'a message is not taken while there is no connection to send it',
      () async {
        final rig = await _rig(delays: const [Duration(hours: 1)]);
        final app = rig.app;
        final controller = app.openSession('s1');
        await _until(() => !controller.loading, what: 'the transcript');
        rig.harness.refuseConnects = 1000000;
        await rig.harness.dropConnection();
        await _until(() => app.waitingToRetry, what: 'the wait');
        expect(controller.canSend, isFalse);
        final before = controller.transcript.items.length;
        await controller.send('Is anybody there?');
        // Nothing was echoed that never left, and it says so.
        expect(controller.transcript.items.length, before);
        expect(controller.error, contains('not sent'));
      },
    );
  });

  group('a message on its way when the connection goes', () {
    test('that the harness never got comes back to the composer', () async {
      final rig = await _rig();
      final app = rig.app;
      final controller = app.openSession('s1');
      await _until(() => !controller.loading, what: 'the transcript');
      bool shown(String text) =>
          controller.transcript.items.any((item) => item.text == text);

      // The network died without a word: the message goes into the void.
      rig.harness.silent = true;
      final sending = controller.send('Is this thing on?');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(shown('Is this thing on?'), isTrue, reason: 'echoed locally');
      expect(controller.promptInFlight, isTrue);

      // The app finds the connection dead, and replaces it.
      await app.checkConnection();
      await sending;
      // It was never echoed, so the harness never had it: it is not lost.
      expect(shown('Is this thing on?'), isFalse);
      expect(
        app.drafts.text(DraftStore.composerKey('s1')),
        'Is this thing on?',
      );
      expect(controller.error, contains('before this was sent'));
      expect(controller.promptInFlight, isFalse);
      await _until(
        () => app.isConnected && rig.harness.connects == 2,
        what: 'the connection',
      );
      expect(rig.harness.prompts, isEmpty);
    });

    test('that was typed meanwhile is not overwritten by it', () async {
      final rig = await _rig();
      final app = rig.app;
      final controller = app.openSession('s1');
      await _until(() => !controller.loading, what: 'the transcript');
      rig.harness.silent = true;
      final sending = controller.send('First thing');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      // The person goes on typing the next one.
      app.drafts.setText(DraftStore.composerKey('s1'), 'Second thing');
      await app.checkConnection();
      await sending;
      expect(
        app.drafts.text(DraftStore.composerKey('s1')),
        'First thing\n\nSecond thing',
      );
    });

    test(
      'that the harness has is not put back, and its turn goes on',
      () async {
        final rig = await _rig();
        final app = rig.app;
        final controller = app.openSession('s1');
        await _until(() => !controller.loading, what: 'the transcript');
        unawaited(controller.send('Run the tests with permission'));
        // The harness took it (it echoes at once) and asks for a permission.
        await _until(
          () => controller.currentInteraction != null,
          what: 'the permission request',
        );
        await rig.harness.dropConnection();
        await _until(
          () => app.isConnected && rig.harness.connects == 2,
          what: 'the connection',
        );
        expect(app.drafts.text(DraftStore.composerKey('s1')), isEmpty);
        expect(rig.harness.prompts, ['Run the tests with permission']);
        // Read again, it is in the conversation once.
        await _until(
          () => controller.transcript.items
              .where((item) => item.text == 'Run the tests with permission')
              .isNotEmpty,
          what: 'the conversation, read again',
        );
        expect(
          controller.transcript.items
              .where((item) => item.text == 'Run the tests with permission')
              .length,
          1,
        );
        expect(controller.error, isNull);
      },
    );
  });

  group('reconnecting from Settings', () {
    test('is in place: the session is never left', () async {
      final rig = await _rig();
      final app = rig.app;
      final sessionsKept = <int>[];
      final phases = _recordPhases(app, sessionsKept);
      app.drafts.setText('session:s1', 'not sent yet');
      await app.reconnect();
      await _until(
        () => app.isConnected && rig.harness.connects == 2,
        what: 'the new connection',
      );
      expect(phases, [
        ConnectionPhase.connected,
        ConnectionPhase.reconnecting,
        ConnectionPhase.connected,
      ]);
      expect(phases, isNot(contains(ConnectionPhase.disconnected)));
      expect(phases, isNot(contains(ConnectionPhase.connecting)));
      expect(sessionsKept, everyElement(4));
      expect(app.drafts.text('session:s1'), 'not sent yet');
    });

    test(
      'with no connection at all, connects from what the device holds',
      () async {
        final rig = await _rig(
          signIn: true,
          knownSecrets: {'hs1_device'},
          token: 'hs1_device',
        );
        final app = rig.app;
        await app.disconnect();
        expect(app.phase, ConnectionPhase.disconnected);
        // Disconnecting forgot the address; the settings still have it.
        await rig.settings.rememberConnectionDetails(
          'ws://memory/acp',
          'hs1_device',
        );
        await app.reconnect();
        expect(app.phase, ConnectionPhase.connected);
        expect(rig.harness.signInAttempts, isEmpty);
      },
    );
  });

  group('what was typed', () {
    test('outlives a disconnect and the next connection', () async {
      final rig = await _rig();
      final app = rig.app;
      app.drafts.setText(DraftStore.composerKey('s1'), 'half a thought');
      app.drafts
        ..task.prompt = 'Fix the thing'
        ..task.priority = 'high'
        ..task.mainTree = true;
      await app.disconnect();
      await app.connect('ws://memory/acp');
      expect(app.drafts.text(DraftStore.composerKey('s1')), 'half a thought');
      expect(app.drafts.task.prompt, 'Fix the thing');
      expect(app.drafts.task.priority, 'high');
      expect(app.drafts.task.mainTree, isTrue);
    });

    test('is forgotten when it is emptied or cleared', () {
      final drafts = DraftStore();
      drafts.setText('a', 'text');
      expect(drafts.text('a'), 'text');
      drafts.setText('a', '');
      expect(drafts.text('a'), '');
      drafts.setText('b', 'more');
      drafts.clear('b');
      expect(drafts.text('b'), '');
      drafts.task
        ..prompt = 'p'
        ..refine = true;
      expect(drafts.task.isEmpty, isFalse);
      drafts.task.clear();
      expect(drafts.task.isEmpty, isTrue);
      expect(drafts.task.refine, isFalse);
    });
  });
}
