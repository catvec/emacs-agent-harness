import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/acp/acp_transport.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';

const _address = 'ws://memory/acp';

class _Rig {
  _Rig(this.settings, this.harness, this.app);
  final SettingsController settings;
  final FakeHarness harness;
  final AppController app;
}

/// A device that signed in before and is opened again: [stored] is what its
/// preferences hold, and the app is a new one, as after a launch.  The waits
/// between attempts are a few milliseconds, so a test need not wait for the
/// real ones.
Future<_Rig> _launch({
  Map<String, Object> stored = const {
    'address': _address,
    'token': 'hs1_device',
  },
  Set<String> knownSecrets = const {'hs1_device'},
  bool signIn = true,
  String? token,
  bool reducedBeforeAuth = false,
  String? rotateTo,
  String? issueSecret = 'hs1_issued',
  List<Duration> delays = const [Duration(milliseconds: 5)],
  Duration handshakeTimeout = const Duration(seconds: 2),
}) async {
  SharedPreferences.setMockInitialValues(stored);
  final settings = SettingsController();
  await settings.load();
  final harness = FakeHarness(
    signIn: signIn,
    knownSecrets: signIn ? knownSecrets : null,
    issueSecret: issueSecret,
    rotateTo: rotateTo,
    token: token,
    reducedBeforeAuth: reducedBeforeAuth,
  );
  final app = AppController(
    settings: settings,
    connector: harness.connector,
    reconnectDelays: delays,
    handshakeTimeout: handshakeTimeout,
    probeTimeout: const Duration(milliseconds: 150),
  );
  addTearDown(app.dispose);
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('a device that signed in before', () {
    test('goes straight back in, and nothing is asked of the person', () async {
      final rig = await _launch();
      final app = rig.app;
      await app.resume();
      expect(app.phase, ConnectionPhase.connected);
      expect(app.resuming, isFalse);
      expect(app.sessions, isNotEmpty);
      // It brought its secret as it connected: no sign-in was started, and
      // the harness listed no way to sign in because none was needed.
      expect(rig.harness.connects, 1);
      expect(rig.harness.signInAttempts, isEmpty);
      expect(app.signInMethods, isEmpty);
      expect(app.error, isNull);
      expect(app.address, _address);
    });

    test('is let in with the very secret the harness gave it', () async {
      // The device signed in by an approval in Emacs, and was handed a secret.
      final rig = await _launch(
        stored: const {},
        knownSecrets: const {},
        issueSecret: 'hs1_issued',
      );
      final first = rig.app;
      await first.connect(_address);
      expect(first.phase, ConnectionPhase.needsAuth);
      final signing = first.signIn(first.signInMethods.first);
      await _until(() => rig.harness.waitingForApproval, what: 'the approval');
      rig.harness.approve();
      await signing;
      expect(first.phase, ConnectionPhase.connected);
      expect(rig.harness.signInAttempts, ['emacs-approval']);
      await pumpEventQueue();

      // The app is closed, and opened again: a new app on the same
      // preferences, with a harness that knows the secret it handed out.
      final next = await _relaunch(rig, knownSecrets: {'hs1_issued'});
      expect(next.settings.token, 'hs1_issued');
      await next.app.resume();
      expect(next.app.phase, ConnectionPhase.connected);
      expect(next.harness.connects, 1);
      expect(next.harness.signInAttempts, isEmpty, reason: 'signed in once');
    });

    test('keeps the secret the harness replaces on the way in', () async {
      final rig = await _launch(rotateTo: 'hs1_replacement');
      await rig.app.resume();
      expect(rig.app.phase, ConnectionPhase.connected);
      await pumpEventQueue();
      expect(rig.settings.token, 'hs1_replacement');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('token'), 'hs1_replacement');
      expect(prefs.getString('address'), _address);
    });

    test('also goes back into a harness that needs no secret', () async {
      final rig = await _launch(stored: {'address': _address}, signIn: false);
      await rig.app.resume();
      expect(rig.app.phase, ConnectionPhase.connected);
      expect(rig.harness.connects, 1);
    });

    test(
      'presents the secret over plain TCP, where it cannot ride the connection',
      () async {
        final rig = await _launch(
          stored: {'address': 'tcp://memory:4276', 'token': 'hs1_device'},
          signIn: false,
          token: 'hs1_device',
          reducedBeforeAuth: true,
        );
        await rig.app.resume();
        expect(rig.app.phase, ConnectionPhase.connected);
        expect(rig.app.capability!.isHarness, isTrue);
      },
    );

    test('is not shown the connection form on the way', () async {
      final rig = await _launch();
      final app = rig.app;
      // The form is what the screen shows when the app is not in a session
      // and is not going back into one.
      bool formShown() => !app.hasSession && !app.resuming;
      final shown = <bool>[];
      app.addListener(() => shown.add(formShown()));
      final going = app.resume();
      // As soon as it starts, before anything is answered.
      expect(formShown(), isFalse);
      await going;
      expect(app.phase, ConnectionPhase.connected);
      expect(shown, isNotEmpty);
      expect(shown, everyElement(isFalse));
    });

    test('goes back in once per run of the app', () async {
      final rig = await _launch();
      await rig.app.resume();
      expect(rig.harness.connects, 1);
      await rig.app.resume();
      await rig.app.disconnect();
      await rig.app.resume();
      expect(rig.harness.connects, 1);
      expect(rig.app.phase, ConnectionPhase.disconnected);
    });
  });

  group('only the harness can ask again', () {
    test('a secret it does not know leads to the sign-in, once', () async {
      final rig = await _launch(
        stored: {'address': _address, 'token': 'hs1_revoked'},
      );
      final app = rig.app;
      await app.resume();
      expect(app.phase, ConnectionPhase.needsAuth);
      expect(app.resuming, isFalse);
      expect(app.error, contains('Sign in again'));
      expect(app.signInMethods.map((m) => m.id), ['emacs-approval']);

      // It does not go on offering a secret that was turned down.
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(rig.harness.connects, 1);
      expect(app.phase, ConnectionPhase.needsAuth);

      // The device is not made to forget it, though: a harness that said no
      // for now (it is in a mode that refuses everything) may take it later.
      expect(rig.settings.token, 'hs1_revoked');

      // And the person signs in the way the harness offers.
      final signing = app.signIn(app.signInMethods.first);
      await _until(() => rig.harness.waitingForApproval, what: 'the approval');
      rig.harness.approve();
      await signing;
      expect(app.phase, ConnectionPhase.connected);
      await pumpEventQueue();
      expect(rig.settings.token, 'hs1_issued');
    });

    test('a device that holds no secret is asked to sign in', () async {
      final rig = await _launch(stored: {'address': _address});
      await rig.app.resume();
      expect(rig.app.phase, ConnectionPhase.needsAuth);
      expect(rig.app.resuming, isFalse);
      expect(rig.app.error, isNull, reason: 'nothing was turned down');
      expect(rig.app.signInMethods, isNotEmpty);
    });
  });

  group('a harness that cannot be reached', () {
    test('is tried again until it answers, with nobody asked', () async {
      final rig = await _launch();
      final app = rig.app;
      rig.harness.refuseConnects = 3;
      final seen = <String?>[];
      app.addListener(() {
        if (app.resumeError != null &&
            (seen.isEmpty || seen.last != app.resumeError)) {
          seen.add(app.resumeError);
        }
      });
      final going = app.resume();
      expect(app.resuming, isTrue);
      await _until(() => seen.isNotEmpty, what: 'the first failure');
      expect(app.resuming, isTrue, reason: 'still going back in');
      expect(app.phase, isNot(ConnectionPhase.needsAuth));
      expect(seen.single, contains('refused'));

      await going;
      expect(app.phase, ConnectionPhase.connected);
      expect(rig.harness.connects, 1, reason: 'the refused ones did not count');
      expect(rig.harness.signInAttempts, isEmpty);
      expect(app.resumeError, isNull);
      expect(app.resuming, isFalse);
      // It was the remembered secret that finally got it in.
      await pumpEventQueue();
      expect(rig.settings.token, 'hs1_device');
    });

    test('is tried at once when the person asks', () async {
      final rig = await _launch(delays: const [Duration(minutes: 10)]);
      final app = rig.app;
      rig.harness.refuseConnects = 1;
      final going = app.resume();
      await _until(() => app.waitingToRetry, what: 'the wait');
      expect(app.phase, ConnectionPhase.failed);
      app.retryNow();
      await going;
      expect(app.phase, ConnectionPhase.connected);
    });

    test('is not asked while the app is out of sight', () async {
      final rig = await _launch();
      final app = rig.app;
      rig.harness.refuseConnects = 1;
      final going = app.resume();
      // A phone put away: the first try failed, and the next waits.
      app.setForeground(false);
      await _until(() => app.resumeError != null, what: 'the first failure');
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(app.phase, ConnectionPhase.failed);
      expect(rig.harness.connects, 0);
      expect(app.resuming, isTrue);

      // Picked up again.
      await app.resumed();
      await going;
      expect(app.phase, ConnectionPhase.connected);
      expect(rig.harness.connects, 1);
    });

    test(
      'that takes the connection and never answers is given up on',
      () async {
        final rig = await _launch(
          handshakeTimeout: const Duration(milliseconds: 120),
        );
        final app = rig.app;
        rig.harness.silentConnects = 1;
        await app.resume();
        expect(app.phase, ConnectionPhase.connected);
        expect(rig.harness.connects, 2);
        expect(app.sessions, isNotEmpty);
      },
    );

    test('is said in words, not as the exception the network raised', () async {
      final rig = await _launch();
      final app = rig.app;
      var said = '';
      app.addListener(() => said = app.resumeError ?? said);
      rig.harness.refuseConnects = 1;
      await app.resume();
      expect(said, 'The harness refused the connection: is it running?');
    });
  });

  group('when the app does not go back in by itself', () {
    test('there is nothing remembered', () async {
      final rig = await _launch(stored: const {});
      await rig.app.resume();
      expect(rig.app.phase, ConnectionPhase.disconnected);
      expect(rig.app.resuming, isFalse);
      expect(rig.harness.connects, 0);
    });

    test('the person turned remembering off', () async {
      final rig = await _launch(
        stored: {
          'address': _address,
          'token': 'hs1_device',
          'rememberConnection': false,
        },
      );
      await rig.app.resume();
      expect(rig.app.phase, ConnectionPhase.disconnected);
      expect(rig.harness.connects, 0);
    });

    test('what is remembered is no address', () async {
      final rig = await _launch(
        stored: {'address': 'ftp://memory/acp', 'token': 'hs1_device'},
      );
      await rig.app.resume();
      expect(rig.app.phase, ConnectionPhase.disconnected);
      expect(rig.app.resuming, isFalse);
      expect(rig.harness.connects, 0);
    });

    test('the person left the harness on purpose', () async {
      final rig = await _launch();
      await rig.app.resume();
      expect(rig.app.phase, ConnectionPhase.connected);
      await rig.app.disconnect();
      await pumpEventQueue();

      // The next launch finds the address and the secret, and waits.
      final next = await _relaunch(rig);
      expect(next.settings.address, _address);
      expect(next.settings.token, 'hs1_device');
      await next.app.resume();
      expect(next.app.phase, ConnectionPhase.disconnected);
      expect(next.harness.connects, 0);

      // One tap on Connect, and it is as before: the launch after goes in.
      await next.app.connect(next.settings.address, token: next.settings.token);
      expect(next.app.phase, ConnectionPhase.connected);
      await pumpEventQueue();
      final last = await _relaunch(next);
      await last.app.resume();
      expect(last.app.phase, ConnectionPhase.connected);
    });

    test('the person signed out', () async {
      final rig = await _launch();
      await rig.app.resume();
      await rig.app.signOut();
      await pumpEventQueue();
      expect(rig.settings.address, isEmpty);
      expect(rig.settings.token, isEmpty);
      final next = await _relaunch(rig);
      await next.app.resume();
      expect(next.app.phase, ConnectionPhase.disconnected);
      expect(next.harness.connects, 0);
    });
  });

  group('the person takes over', () {
    test(
      'and asks for another address while the harness is out of reach',
      () async {
        final rig = await _launch(delays: const [Duration(minutes: 10)]);
        final app = rig.app;
        rig.harness.refuseConnects = 1000000;
        final going = app.resume();
        await _until(() => app.waitingToRetry, what: 'the wait');
        expect(app.resuming, isTrue);

        await app.cancelResume();
        await going;
        expect(app.resuming, isFalse);
        expect(app.phase, ConnectionPhase.disconnected);
        expect(app.resumeError, isNull);
        // What was remembered is still there, for the form to show.
        expect(rig.settings.address, _address);
        expect(rig.settings.token, 'hs1_device');

        // It stays that way: no more attempts are made.
        rig.harness.refuseConnects = 0;
        await Future<void>.delayed(const Duration(milliseconds: 60));
        expect(rig.harness.connects, 0);
        expect(app.phase, ConnectionPhase.disconnected);

        // And another address works as ever.
        await app.connect(_address, token: 'hs1_device');
        expect(app.phase, ConnectionPhase.connected);
      },
    );

    test('and connects by hand while the app is still trying', () async {
      final rig = await _launch(delays: const [Duration(milliseconds: 30)]);
      final app = rig.app;
      rig.harness.refuseConnects = 2;
      final going = app.resume();
      await _until(() => app.resumeError != null, what: 'the first failure');
      // The harness is back, and the person did not wait to be let in.
      rig.harness.refuseConnects = 0;
      await app.connect(_address, token: 'hs1_device');
      await going;
      expect(app.phase, ConnectionPhase.connected);
      expect(app.resuming, isFalse);
      expect(app.error, isNull);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(app.phase, ConnectionPhase.connected, reason: 'it stayed in');
      expect(rig.harness.connects, 1, reason: 'one connection, not two');
    });

    test('and disconnects while the app is still trying', () async {
      final rig = await _launch(delays: const [Duration(milliseconds: 10)]);
      final app = rig.app;
      rig.harness.refuseConnects = 1000000;
      final going = app.resume();
      await _until(() => app.resumeError != null, what: 'the first failure');
      await app.disconnect();
      await going;
      expect(app.resuming, isFalse);
      expect(app.phase, ConnectionPhase.disconnected);
      rig.harness.refuseConnects = 0;
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(rig.harness.connects, 0);
    });
  });

  group('an attempt that something else took over from', () {
    test(
      'that was closed under its own feet does not undo the new one',
      () async {
        final rig = await _launch(stored: const {});
        final app = rig.app;
        // The first connection is taken and never answered.
        rig.harness.silentConnects = 1;
        final first = app.connect(_address, token: 'hs1_device');
        await pumpEventQueue();
        expect(app.phase, ConnectionPhase.connecting);
        // The person tries again; the first one is closed under its own feet,
        // and fails.  That must not be the last word.
        final second = app.connect(_address, token: 'hs1_device');
        await Future.wait([first, second]);
        expect(app.phase, ConnectionPhase.connected);
        expect(app.error, isNull);
        expect(app.sessions, isNotEmpty);
      },
    );

    test('that fails long after does not end the connection that replaced it', () async {
      final rig = await _launch(stored: const {});
      // The first attempt is at an address that does not answer: it hangs
      // until the network gives up on it, a quarter of a minute later.
      final hanging = Completer<AcpTransport>();
      var calls = 0;
      final app = AppController(
        settings: rig.settings,
        connector: (target, token) {
          calls++;
          return calls == 1
              ? hanging.future
              : rig.harness.connector(target, token);
        },
      );
      addTearDown(app.dispose);
      final first = app.connect('ws://dead/acp', token: 'hs1_device');
      await pumpEventQueue();
      // Meanwhile the person gave another address, and it worked.
      await app.connect(_address, token: 'hs1_device');
      expect(app.phase, ConnectionPhase.connected);
      final client = app.client;

      // Now the first gives up.  That is none of the new connection's business.
      hanging.completeError(Exception('Connection timed out'));
      await first;
      await pumpEventQueue();
      expect(app.phase, ConnectionPhase.connected);
      expect(app.error, isNull);
      expect(identical(app.client, client), isTrue);
      expect(client!.isClosed, isFalse);
      expect(app.sessions, isNotEmpty);
    });

    test(
      'that is the first try of the app does not outlast "use another address"',
      () async {
        final rig = await _launch();
        final hanging = Completer<AcpTransport>();
        var calls = 0;
        final app = AppController(
          settings: rig.settings,
          connector: (target, token) {
            calls++;
            return calls == 1
                ? hanging.future
                : rig.harness.connector(target, token);
          },
          handshakeTimeout: const Duration(seconds: 2),
        );
        addTearDown(app.dispose);
        final going = app.resume();
        await pumpEventQueue();
        expect(app.resuming, isTrue);
        expect(app.phase, ConnectionPhase.connecting);

        // The person does not wait for it: the form is theirs at once.
        await app.cancelResume();
        expect(app.resuming, isFalse);
        expect(app.phase, ConnectionPhase.disconnected);
        await app.connect(_address, token: 'hs1_device');
        expect(app.phase, ConnectionPhase.connected);
        final client = app.client;

        // The address that never answered finally says so, and the attempt
        // that waited for it ends without a word.
        hanging.completeError(Exception('Connection timed out'));
        await going;
        await pumpEventQueue();
        expect(app.phase, ConnectionPhase.connected);
        expect(identical(app.client, client), isTrue);
        expect(app.resuming, isFalse);
        expect(app.sessions, isNotEmpty);
        expect(calls, 2, reason: 'it did not try the dead address again');
      },
    );
  });
}

/// The next launch of the app: new controllers on the preferences the last
/// one left, and a harness that knows [knownSecrets], so its counts start at
/// zero.
Future<_Rig> _relaunch(
  _Rig last, {
  Set<String> knownSecrets = const {'hs1_device'},
}) async {
  final prefs = await SharedPreferences.getInstance();
  SharedPreferences.setMockInitialValues({
    for (final key in prefs.getKeys()) key: prefs.get(key)!,
  });
  final settings = SettingsController();
  await settings.load();
  final harness = FakeHarness(signIn: true, knownSecrets: knownSecrets);
  final app = AppController(
    settings: settings,
    connector: harness.connector,
    reconnectDelays: const [Duration(milliseconds: 5)],
  );
  addTearDown(app.dispose);
  return _Rig(settings, harness, app);
}
