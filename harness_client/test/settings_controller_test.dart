import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';
// The store the plugin puts under `setMockInitialValues`, which the tests
// below give a mind of its own.  It comes with `shared_preferences`.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

/// A preference store that takes its time over some writes, and over reading,
/// as a phone's does when it is busy.
class _SlowStore extends InMemorySharedPreferencesStore {
  _SlowStore() : super.empty();

  /// A write of this value (not its key) lands this much later.
  final Map<Object, Duration> lateWrites = {};

  /// Reading waits for this, when it is set.
  Completer<void>? readGate;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    final late = lateWrites[value];
    if (late != null) await Future<void>.delayed(late);
    return super.setValue(valueType, key, value);
  }

  @override
  Future<Map<String, Object>> getAll() async {
    await readGate?.future;
    return super.getAll();
  }
}

/// What the device has on disk, read from the store itself.
Future<Map<String, Object>> _onDisk(SharedPreferencesStorePlatform store) =>
    store.getAll();

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

  group('what a device remembers of its harness', () {
    test(
      'is kept with the flag that brings the app back in by itself',
      () async {
        SharedPreferences.setMockInitialValues({});
        final settings = SettingsController();
        await settings.load();
        expect(
          settings.canResume,
          isFalse,
          reason: 'nothing is remembered yet',
        );
        await settings.rememberConnectionDetails(
          'ws://host:4276/acp',
          'hs1_device',
        );
        expect(settings.canResume, isTrue);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('address'), 'ws://host:4276/acp');
        expect(prefs.getString('token'), 'hs1_device');
        expect(prefs.getBool('reconnectOnLaunch'), isTrue);
      },
    );

    test('is read again by the next run of the app', () async {
      SharedPreferences.setMockInitialValues({
        'address': 'ws://host:4276/acp',
        'token': 'hs1_device',
      });
      final settings = SettingsController();
      await settings.load();
      // An install from before the flag existed gets the new behaviour.
      expect(settings.reconnectOnLaunch, isTrue);
      expect(settings.canResume, isTrue);
    });

    test('is not used until the settings were read', () async {
      SharedPreferences.setMockInitialValues({
        'address': 'ws://host:4276/acp',
        'token': 'hs1_device',
      });
      final settings = SettingsController();
      expect(settings.canResume, isFalse);
      await settings.load();
      expect(settings.canResume, isTrue);
    });

    test('is not used when the person turned remembering off', () async {
      SharedPreferences.setMockInitialValues({
        'address': 'ws://host:4276/acp',
        'token': 'hs1_device',
        'rememberConnection': false,
      });
      final settings = SettingsController();
      await settings.load();
      expect(settings.address, 'ws://host:4276/acp', reason: 'still offered');
      expect(settings.canResume, isFalse);
    });

    test('is not used without an address', () async {
      SharedPreferences.setMockInitialValues({'token': 'hs1_device'});
      final settings = SettingsController();
      await settings.load();
      expect(settings.canResume, isFalse);
    });

    test(
      'leaving on purpose is remembered, and a new connection ends it',
      () async {
        SharedPreferences.setMockInitialValues({
          'address': 'ws://host:4276/acp',
          'token': 'hs1_device',
        });
        var settings = SettingsController();
        await settings.load();
        await settings.setReconnectOnLaunch(false);
        expect(settings.canResume, isFalse);
        expect(settings.address, 'ws://host:4276/acp', reason: 'one tap away');

        // The next run of the app.
        SharedPreferences.setMockInitialValues({
          for (final entry in (await _onDiskNow()).entries)
            entry.key: entry.value,
        });
        settings = SettingsController();
        await settings.load();
        expect(settings.reconnectOnLaunch, isFalse);
        expect(settings.canResume, isFalse);
        expect(settings.address, 'ws://host:4276/acp');
        expect(settings.token, 'hs1_device');

        await settings.rememberConnectionDetails(
          'ws://host:4276/acp',
          'hs1_device',
        );
        expect(settings.canResume, isTrue);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getBool('reconnectOnLaunch'), isTrue);
      },
    );

    test('is forgotten with the address and the secret', () async {
      SharedPreferences.setMockInitialValues({
        'address': 'ws://host:4276/acp',
        'token': 'hs1_device',
        'reconnectOnLaunch': false,
      });
      final settings = SettingsController();
      await settings.load();
      await settings.clearConnection();
      expect(settings.canResume, isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('address'), isNull);
      expect(prefs.getString('token'), isNull);
      expect(prefs.getBool('reconnectOnLaunch'), isNull);
    });

    test('turning remembering on keeps the connection the app has', () async {
      SharedPreferences.setMockInitialValues({'rememberConnection': false});
      final settings = SettingsController();
      await settings.load();
      await settings.rememberConnectionDetails(
        'ws://host:4276/acp',
        'hs1_device',
      );
      var prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('token'), isNull, reason: 'the person said no');
      await settings.setRememberConnection(true);
      prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('address'), 'ws://host:4276/acp');
      expect(prefs.getString('token'), 'hs1_device');
      expect(settings.canResume, isTrue);
    });

    test('turning remembering off forgets it', () async {
      SharedPreferences.setMockInitialValues({
        'address': 'ws://host:4276/acp',
        'token': 'hs1_device',
      });
      final settings = SettingsController();
      await settings.load();
      await settings.setRememberConnection(false);
      expect(settings.canResume, isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('token'), isNull);
    });
  });

  group('writing what a device remembers', () {
    test('ends with the last secret, whichever write lands last', () async {
      final store = _SlowStore();
      SharedPreferencesStorePlatform.instance = store;
      SharedPreferences.resetStatic();
      final settings = SettingsController();
      await settings.load();

      // The write of the old secret is slow; the harness replaced the secret
      // meanwhile, and the new one is written while the old one is still on
      // its way.  The old secret must not be what the device is left with: the
      // harness stops honouring it, and the next launch would have to sign in.
      store.lateWrites['hs1_old'] = const Duration(milliseconds: 60);
      final first = settings.rememberConnectionDetails('ws://h/acp', 'hs1_old');
      await Future<void>.delayed(const Duration(milliseconds: 15));
      final second = settings.rememberConnectionDetails(
        'ws://h/acp',
        'hs1_new',
      );
      await Future.wait([first, second]);

      expect((await _onDisk(store))['flutter.token'], 'hs1_new');
      expect(settings.token, 'hs1_new');
    });

    test(
      'a connection made while the store is still being read is kept',
      () async {
        final store = _SlowStore()..readGate = Completer<void>();
        SharedPreferencesStorePlatform.instance = store;
        SharedPreferences.resetStatic();
        final settings = SettingsController();
        final loading = settings.load();
        // The person connected by hand before the stored values arrived.
        final saved = settings.rememberConnectionDetails(
          'ws://h/acp',
          'hs1_fresh',
        );
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(settings.loaded, isFalse);
        store.readGate!.complete();
        await loading;
        await saved;

        // What was stored before does not replace it, and it reaches the disk.
        expect(settings.address, 'ws://h/acp');
        expect(settings.token, 'hs1_fresh');
        expect((await _onDisk(store))['flutter.token'], 'hs1_fresh');
        expect((await _onDisk(store))['flutter.address'], 'ws://h/acp');
      },
    );
  });
}

/// The preferences as the platform holds them now, for a next run of the app.
Future<Map<String, Object>> _onDiskNow() async {
  final prefs = await SharedPreferences.getInstance();
  return {for (final key in prefs.getKeys()) key: prefs.get(key)!};
}
