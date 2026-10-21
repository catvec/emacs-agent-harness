import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';

Future<(SettingsController, AppController, FakeHarness)> _connected({
  required String token,
  String? rotateTo,
  bool reducedBeforeAuth = false,
}) async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsController();
  await settings.load();
  final harness = FakeHarness(
    token: token,
    rotateTo: rotateTo,
    reducedBeforeAuth: reducedBeforeAuth,
  );
  final app = AppController(settings: settings, connector: harness.connector);
  await app.connect('ws://memory/acp', token: token);
  return (settings, app, harness);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('a session secret the harness replaces', () {
    test('the client says it can keep a new one', () async {
      final (_, app, harness) = await _connected(token: 'hs1_old');
      expect(app.phase, ConnectionPhase.connected);
      expect(harness.sessionRefreshAsked, isTrue);
    });

    test('the secret stays when the harness has no other', () async {
      final (settings, app, _) = await _connected(token: 'hs1_old');
      expect(app.phase, ConnectionPhase.connected);
      await Future<void>.delayed(Duration.zero);
      expect(settings.token, 'hs1_old');
    });

    test('the new secret is kept in place of the old one', () async {
      final (settings, app, _) = await _connected(
        token: 'hs1_old',
        rotateTo: 'hs1_new',
      );
      expect(app.phase, ConnectionPhase.connected);
      await Future<void>.delayed(Duration.zero);
      expect(settings.token, 'hs1_new');
      expect(settings.address, 'ws://memory/acp');
    });

    test('over plain TCP it arrives with the full capabilities', () async {
      final (settings, app, _) = await _connected(
        token: 'hs1_old',
        rotateTo: 'hs1_new',
        reducedBeforeAuth: true,
      );
      expect(app.phase, ConnectionPhase.connected);
      await Future<void>.delayed(Duration.zero);
      expect(settings.token, 'hs1_new');
      expect(app.capability?.isHarness, isTrue);
    });

    test('it is kept even when the rest of the connection fails', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsController();
      await settings.load();
      final harness = FakeHarness(token: 'hs1_old', rotateTo: 'hs1_new');
      harness.failSessionList = true;
      final app = AppController(
        settings: settings,
        connector: harness.connector,
      );
      await app.connect('ws://memory/acp', token: 'hs1_old');
      await Future<void>.delayed(Duration.zero);
      expect(app.phase, isNot(ConnectionPhase.connected));
      expect(settings.token, 'hs1_new');
    });
  });
}
