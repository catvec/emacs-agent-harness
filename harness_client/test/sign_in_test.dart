import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';

class _Rig {
  _Rig(this.settings, this.harness, this.app, this.opened);
  final SettingsController settings;
  final FakeHarness harness;
  final AppController app;
  final List<Uri> opened;
}

Future<_Rig> _rig({
  String? issueSecret = 'hs1_issued',
  Set<String>? knownSecrets,
  String? oidcUrl,
}) async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsController();
  await settings.load();
  final harness = FakeHarness(
    signIn: true,
    issueSecret: issueSecret,
    knownSecrets: knownSecrets,
    oidcUrl: oidcUrl,
  );
  final opened = <Uri>[];
  final app = AppController(
    settings: settings,
    connector: harness.connector,
    urlOpener: (url) async {
      opened.add(url);
      return true;
    },
  );
  return _Rig(settings, harness, app, opened);
}

/// Let what was started finish: the fake answers on the event loop.
Future<void> _later([int rounds = 5]) async {
  for (var i = 0; i < rounds; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('signing in from inside the client', () {
    test('a harness that listed methods needs a choice, not a typed secret', () async {
      final rig = await _rig();
      await rig.app.connect('ws://memory/acp');
      expect(rig.app.phase, ConnectionPhase.needsAuth);
      expect(rig.app.error, isNull);
      // The ways to choose from, and apart from them a secret that is typed.
      expect(rig.app.signInMethods.map((m) => m.id), ['emacs-approval']);
      final approval = rig.app.signInMethods.first;
      expect(approval.name, 'Approve in Emacs');
      expect(approval.isApproval, isTrue);
      // The code to compare is in the description the method came with.
      expect(approval.code, '4719');
      expect(rig.app.canUseToken, isTrue);
      // What the harness knows of the app: its name, to show who asks.
      expect(rig.harness.lastClientInfo['name'], 'Harness');
      expect(rig.harness.lastClientInfo['title'], startsWith('Harness on '));
      // Nothing but initialize went out: no session was asked for.
      expect(rig.harness.requestsByClient, ['initialize']);
    });

    test('an approval signs the device in and the secret it is handed is kept', () async {
      final rig = await _rig();
      await rig.app.connect('ws://memory/acp');
      final signing = rig.app.signIn(rig.app.signInMethods.first);
      await _later();
      // It waits for the person at Emacs, and says what for.
      expect(rig.harness.waitingForApproval, isTrue);
      expect(rig.app.phase, ConnectionPhase.authenticating);
      expect(rig.app.signingInWith?.isApproval, isTrue);
      rig.harness.approve();
      await signing;
      expect(rig.app.phase, ConnectionPhase.connected);
      expect(rig.app.signingInWith, isNull);
      expect(rig.app.sessions, isNotEmpty);
      // It asked again, for everything the harness does, once let in.
      expect(
        rig.harness.requestsByClient.where((m) => m == 'initialize').length,
        2,
      );
      expect(rig.app.capability!.isHarness, isTrue);
      await _later();
      expect(rig.settings.token, 'hs1_issued');
      expect(rig.settings.address, 'ws://memory/acp');
    });

    test('the next connection brings the secret and needs no sign-in', () async {
      final rig = await _rig(knownSecrets: {'hs1_issued'});
      await rig.app.connect('ws://memory/acp', token: 'hs1_issued');
      expect(rig.app.phase, ConnectionPhase.connected);
      expect(rig.harness.signInAttempts, isEmpty);
    });

    test('a secret the harness does not know leaves the choice to the user', () async {
      final rig = await _rig(knownSecrets: {'hs1_other'});
      await rig.app.connect('ws://memory/acp', token: 'hs1_revoked');
      expect(rig.app.phase, ConnectionPhase.needsAuth);
      expect(rig.app.error, contains('Sign in again'));
      final signing = rig.app.signIn(rig.app.signInMethods.first);
      await _later();
      rig.harness.approve();
      await signing;
      expect(rig.app.phase, ConnectionPhase.connected);
      await _later();
      // The one that was no good is replaced.
      expect(rig.settings.token, 'hs1_issued');
    });

    test('a refusal is shown and the user may try again', () async {
      final rig = await _rig();
      await rig.app.connect('ws://memory/acp');
      var signing = rig.app.signIn(rig.app.signInMethods.first);
      await _later();
      rig.harness.deny();
      await signing;
      expect(rig.app.phase, ConnectionPhase.needsAuth);
      expect(rig.app.error, contains('refused this device'));
      expect(rig.app.signingInWith, isNull);
      signing = rig.app.signIn(rig.app.signInMethods.first);
      await _later();
      rig.harness.approve();
      await signing;
      expect(rig.app.phase, ConnectionPhase.connected);
      expect(rig.app.error, isNull);
    });

    test('giving up closes the connection the harness waits on', () async {
      final rig = await _rig();
      await rig.app.connect('ws://memory/acp');
      unawaited(rig.app.signIn(rig.app.signInMethods.first));
      await _later();
      expect(rig.app.signingInWith, isNotNull);
      await rig.app.cancelSignIn();
      expect(rig.app.phase, ConnectionPhase.disconnected);
      expect(rig.app.signingInWith, isNull);
      expect(rig.settings.token, isEmpty);
    });

    test('a login at the provider is opened in the browser, by the app', () async {
      final rig = await _rig(oidcUrl: 'https://harness.example/login?c=4719');
      await rig.app.connect('ws://memory/acp');
      final oidc = rig.app.signInMethods.firstWhere((m) => m.isOidc);
      expect(oidc.url, 'https://harness.example/login?c=4719');
      expect(oidc.code, '4719');
      final signing = rig.app.signIn(oidc);
      await _later();
      // The user left the app only for the provider's page.
      expect(rig.opened.map((u) => u.toString()), [
        'https://harness.example/login?c=4719',
      ]);
      expect(rig.harness.signInAttempts, ['oidc']);
      rig.harness.approve();
      await signing;
      expect(rig.app.phase, ConnectionPhase.connected);
    });

    test('a secret typed in is another way in', () async {
      final rig = await _rig(knownSecrets: {'hs1_typed'});
      await rig.app.connect('ws://memory/acp');
      await rig.app.submitToken('hs1_wrong');
      expect(rig.app.phase, ConnectionPhase.needsAuth);
      await rig.app.submitToken('hs1_typed');
      expect(rig.app.phase, ConnectionPhase.connected);
      await _later();
      expect(rig.settings.token, 'hs1_typed');
    });

    test('a harness that hands over no secret still signs the connection in', () async {
      final rig = await _rig(issueSecret: null);
      await rig.app.connect('ws://memory/acp');
      final signing = rig.app.signIn(rig.app.signInMethods.first);
      await _later();
      rig.harness.approve();
      await signing;
      expect(rig.app.phase, ConnectionPhase.connected);
      await _later();
      expect(rig.settings.token, isEmpty);
    });
  });
}
