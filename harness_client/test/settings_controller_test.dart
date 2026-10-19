import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Keep this first: once setMockInitialValues has run, the test platform has
  // a working in-memory store and the missing-plugin path is no longer
  // reachable in this isolate.
  test('load falls back when the preference store is unavailable', () async {
    final settings = SettingsController();
    await settings.load();
    expect(settings.loaded, isTrue);
    expect(settings.persistenceAvailable, isFalse);
    expect(settings.loadError, isNotNull);
    expect(settings.themeMode, ThemeMode.system);
    expect(settings.previewPlatform, PreviewPlatform.system);
    expect(settings.showThinking, isTrue);
    expect(settings.rememberConnection, isTrue);
    expect(settings.address, isEmpty);
    expect(settings.token, isEmpty);

    // Setters still update memory and do not throw when there is no store.
    await settings.setThemeMode(ThemeMode.dark);
    await settings.rememberConnectionDetails('ws://host:4276/acp', 'token');
    expect(settings.themeMode, ThemeMode.dark);
    expect(settings.address, 'ws://host:4276/acp');
  });

  test('valid stored values are read', () async {
    SharedPreferences.setMockInitialValues({
      'themeMode': 'light',
      'previewPlatform': 'cupertino',
      'showThinking': false,
      'rememberConnection': false,
      'address': 'ws://192.168.1.20:4276/acp',
      'token': 's3cret',
    });
    final settings = SettingsController();
    await settings.load();
    expect(settings.loadError, isNull);
    expect(settings.persistenceAvailable, isTrue);
    expect(settings.themeMode, ThemeMode.light);
    expect(settings.previewPlatform, PreviewPlatform.cupertino);
    expect(settings.showThinking, isFalse);
    expect(settings.rememberConnection, isFalse);
    expect(settings.address, 'ws://192.168.1.20:4276/acp');
    expect(settings.token, 's3cret');
  });

  test('corrupt stored values keep the defaults', () async {
    SharedPreferences.setMockInitialValues({
      'themeMode': 7,
      'showThinking': 'not a bool',
    });
    final settings = SettingsController();
    await settings.load();
    expect(settings.loaded, isTrue);
    expect(settings.loadError, isNotNull);
    expect(settings.themeMode, ThemeMode.system);
    expect(settings.showThinking, isTrue);
  });

  test('clearConnection forgets the address and token', () async {
    SharedPreferences.setMockInitialValues({
      'address': 'ws://host:4276/acp',
      'token': 's3cret',
    });
    final settings = SettingsController();
    await settings.load();
    await settings.clearConnection();
    expect(settings.address, isEmpty);
    expect(settings.token, isEmpty);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('address'), isNull);
    expect(prefs.getString('token'), isNull);
  });
}
