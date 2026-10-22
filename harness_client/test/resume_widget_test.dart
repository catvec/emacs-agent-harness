import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/app.dart';
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

/// The app as it is opened on a device that signed in before: its preferences
/// hold [stored], and the harness knows the secrets in [knownSecrets].
/// [loaded] is whether the preferences were read before the first frame, as
/// `main` does.
Future<_Rig> _launch({
  Map<String, Object> stored = const {
    'address': _address,
    'token': 'hs1_device',
  },
  Set<String> knownSecrets = const {'hs1_device'},
  bool loaded = true,
  List<Duration> delays = const [Duration(milliseconds: 5)],
}) async {
  SharedPreferences.setMockInitialValues(stored);
  final settings = SettingsController();
  if (loaded) await settings.load();
  final harness = FakeHarness(signIn: true, knownSecrets: knownSecrets);
  final app = AppController(
    settings: settings,
    connector: harness.connector,
    reconnectDelays: delays,
    handshakeTimeout: const Duration(seconds: 2),
  );
  return _Rig(settings, harness, app);
}

Future<void> _open(WidgetTester tester, _Rig rig) async {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    HarnessApp(settings: rig.settings, appController: rig.app),
  );
}

Future<void> _settle(WidgetTester tester, [int rounds = 12]) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

Finder get _form => find.byKey(const Key('connect-address'));
Finder get _resumeCard => find.byKey(const Key('resume-card'));

String _fieldText(WidgetTester tester, String key) => tester
    .widget<TextField>(
      find.descendant(
        of: find.byKey(Key(key)),
        matching: find.byType(TextField),
      ),
    )
    .controller!
    .text;

void main() {
  testWidgets(
    'a device that signed in opens on its sessions, with nothing to tap',
    (tester) async {
      final rig = await _launch();
      await _open(tester, rig);
      await _settle(tester);
      expect(find.text('Design the merge queue'), findsOneWidget);
      // The form for an address and a secret never came up, nor a sign-in.
      expect(find.textContaining('within reach'), findsNothing);
      expect(_form, findsNothing);
      expect(find.text('Sign in to this harness'), findsNothing);
      expect(rig.harness.signInAttempts, isEmpty);
      expect(rig.harness.connects, 1);
    },
  );

  testWidgets('the first frame is not the form, when the settings are read', (
    tester,
  ) async {
    final rig = await _launch();
    await _open(tester, rig);
    // Before anything was answered: the app is already going back in.
    expect(_resumeCard, findsOneWidget);
    expect(find.text('Welcome\nback.'), findsOneWidget);
    expect(_form, findsNothing);
    expect(find.text('Connect'), findsNothing);
    await _settle(tester);
    expect(find.text('Design the merge queue'), findsOneWidget);
  });

  testWidgets(
    'settings that are read after the first frame lead there as well',
    (tester) async {
      final rig = await _launch(loaded: false);
      await _open(tester, rig);
      await _settle(tester);
      expect(find.text('Design the merge queue'), findsOneWidget);
      expect(rig.harness.connects, 1);
      expect(rig.harness.signInAttempts, isEmpty);
    },
  );

  testWidgets('a device that remembers nothing sees the form', (tester) async {
    final rig = await _launch(stored: const {});
    await _open(tester, rig);
    await _settle(tester, 4);
    expect(find.textContaining('within reach'), findsOneWidget);
    expect(_form, findsOneWidget);
    expect(_resumeCard, findsNothing);
    expect(rig.harness.connects, 0);
  });

  testWidgets(
    'a harness that cannot be reached is waited for, and the person can help it',
    (tester) async {
      final rig = await _launch(delays: const [Duration(minutes: 10)]);
      rig.harness.refuseConnects = 1;
      await _open(tester, rig);
      await _settle(tester, 4);
      // It says where it goes and why it has not got there; it is not a form.
      expect(_resumeCard, findsOneWidget);
      expect(find.text('Reconnecting…'), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('resume-address'))).data,
        'memory',
      );
      expect(
        find.text('The harness refused the connection: is it running?'),
        findsOneWidget,
      );
      expect(_form, findsNothing);
      expect(find.byKey(const Key('resume-retry')), findsOneWidget);
      expect(find.byKey(const Key('resume-change')), findsOneWidget);

      // The harness is back; the person does not want to wait for the timer.
      await tester.tap(find.byKey(const Key('resume-retry')));
      await _settle(tester);
      expect(find.text('Design the merge queue'), findsOneWidget);
      expect(_resumeCard, findsNothing);
    },
  );

  testWidgets(
    '"Use another address" shows the form with what is remembered in it',
    (tester) async {
      final rig = await _launch(delays: const [Duration(minutes: 10)]);
      rig.harness.refuseConnects = 1000000;
      await _open(tester, rig);
      await _settle(tester, 4);
      expect(_resumeCard, findsOneWidget);

      await tester.tap(find.byKey(const Key('resume-change')));
      await _settle(tester, 4);
      expect(_resumeCard, findsNothing);
      expect(find.textContaining('within reach'), findsOneWidget);
      expect(_fieldText(tester, 'connect-address'), _address);
      expect(_fieldText(tester, 'connect-token'), 'hs1_device');
      expect(rig.app.phase, ConnectionPhase.disconnected);

      // Nothing goes on trying behind the form.
      rig.harness.refuseConnects = 0;
      await _settle(tester, 6);
      expect(rig.harness.connects, 0);
      expect(_form, findsOneWidget);
    },
  );

  testWidgets(
    'a harness that turns the device away is the only thing that asks',
    (tester) async {
      final rig = await _launch(
        stored: {'address': _address, 'token': 'hs1_revoked'},
      );
      await _open(tester, rig);
      await _settle(tester);
      expect(_resumeCard, findsNothing);
      expect(find.text('Sign in to this harness'), findsOneWidget);
      expect(find.byKey(const Key('signin-emacs-approval')), findsOneWidget);
      expect(
        find.textContaining('did not accept this device', findRichText: true),
        findsOneWidget,
      );
      // It asked once, and the form still has what the device held.
      expect(rig.harness.connects, 1);
      expect(_fieldText(tester, 'connect-address'), _address);
    },
  );

  testWidgets('leaving on purpose is not undone by opening the app again', (
    tester,
  ) async {
    final rig = await _launch();
    await _open(tester, rig);
    await _settle(tester);
    expect(find.text('Design the merge queue'), findsOneWidget);
    await rig.app.disconnect();
    await _settle(tester, 4);
    // The form, with what the device holds, and a tap away.
    expect(_form, findsOneWidget);
    expect(_fieldText(tester, 'connect-address'), _address);
    expect(rig.settings.canResume, isFalse);
    expect(rig.settings.address, _address);
  });
}
