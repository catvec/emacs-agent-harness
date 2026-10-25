import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';
// The store the plugin puts under `setMockInitialValues`, which the tests
// below give a mind of its own.  It comes with `shared_preferences`.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'support/broken_preference_stores.dart';

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

    expect(settings.newTaskChoices, const NewTaskChoices());

    // Setters still update memory and do not throw when there is no store.
    await settings.setThemeMode(ThemeMode.dark);
    await settings.rememberConnectionDetails('ws://host:4276/acp', 'token');
    await settings.setNewTaskChoices(
      const NewTaskChoices(priority: 'high', mainTree: true),
    );
    expect(settings.themeMode, ThemeMode.dark);
    expect(settings.address, 'ws://host:4276/acp');
    expect(
      settings.newTaskChoices,
      const NewTaskChoices(priority: 'high', mainTree: true),
      reason: 'kept for this run of the app',
    );
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

  test('a corrupt value does not make the device forget its harness', () async {
    // The theme and the thinking switch are damaged; the address and the
    // secret are fine, and used to be skipped: they were read after them, in
    // the same try.
    SharedPreferences.setMockInitialValues({
      'themeMode': 7,
      'showThinking': 'not a bool',
      'reconnectOnLaunch': 'yes',
      'address': 'ws://192.168.1.20:4276/acp',
      'token': 'hs1_device',
    });
    final settings = SettingsController();
    await settings.load();
    expect(settings.loadError, isNotNull);
    expect(settings.address, 'ws://192.168.1.20:4276/acp');
    expect(settings.token, 'hs1_device');
    expect(settings.reconnectOnLaunch, isTrue, reason: 'its default');
    expect(settings.canResume, isTrue);
    expect(
      settings.persistenceProblem,
      isNull,
      reason: 'the store works; only some values in it are damaged',
    );
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

  group('how the new-task sheet was left', () {
    // The priority and the three switches of the sheet are the device's: the
    // sheet starts from them, and the next run of the app does too.
    const set = NewTaskChoices(
      priority: 'high',
      refine: true,
      plan: false,
      mainTree: true,
    );

    test('starts as a task is by default', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsController();
      expect(settings.newTaskChoices, const NewTaskChoices());
      await settings.load();
      expect(settings.newTaskChoices.priority, 'medium');
      expect(settings.newTaskChoices.refine, isFalse);
      expect(settings.newTaskChoices.plan, isFalse);
      expect(settings.newTaskChoices.mainTree, isFalse);
      expect(settings.loadError, isNull);
    });

    test('is kept on the device, and read again by the next run', () async {
      SharedPreferences.setMockInitialValues({});
      var settings = SettingsController();
      await settings.load();
      await settings.setNewTaskChoices(set);
      expect(settings.newTaskChoices, set);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('newTaskPriority'), 'high');
      expect(prefs.getBool('newTaskRefine'), isTrue);
      expect(prefs.getBool('newTaskPlan'), isFalse);
      expect(prefs.getBool('newTaskMainTree'), isTrue);

      // The next run of the app.
      SharedPreferences.setMockInitialValues(await _onDiskNow());
      settings = SettingsController();
      await settings.load();
      expect(settings.newTaskChoices, set);
      expect(settings.loadError, isNull);
    });

    test('is changed one choice at a time, and the last stays', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsController();
      await settings.load();
      await settings.setNewTaskChoices(set);
      await settings.setNewTaskChoices(
        settings.newTaskChoices.copyWith(priority: 'low', mainTree: false),
      );
      expect(
        settings.newTaskChoices,
        const NewTaskChoices(priority: 'low', refine: true),
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('newTaskPriority'), 'low');
      expect(prefs.getBool('newTaskRefine'), isTrue);
      expect(prefs.getBool('newTaskMainTree'), isFalse);
    });

    test('is left alone by the person signing out', () async {
      SharedPreferences.setMockInitialValues({
        'address': 'ws://host:4276/acp',
        'token': 'hs1_device',
      });
      final settings = SettingsController();
      await settings.load();
      await settings.setNewTaskChoices(set);
      await settings.clearConnection();
      await settings.setRememberConnection(false);
      expect(settings.newTaskChoices, set);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('token'), isNull);
      expect(prefs.getString('newTaskPriority'), 'high');
      expect(prefs.getBool('newTaskMainTree'), isTrue);
    });

    test('keeps a damaged value to its default, and the rest', () async {
      SharedPreferences.setMockInitialValues({
        'newTaskPriority': 'low',
        'newTaskRefine': 'yes', // Not a bool.
        'newTaskPlan': true,
        'newTaskMainTree': true,
      });
      final settings = SettingsController();
      await settings.load();
      expect(settings.loadError, isNotNull);
      expect(
        settings.newTaskChoices,
        const NewTaskChoices(priority: 'low', plan: true, mainTree: true),
      );
    });

    test('takes no priority a task does not have', () async {
      SharedPreferences.setMockInitialValues({
        'newTaskPriority': 'urgent',
        'newTaskPlan': true,
      });
      final settings = SettingsController();
      await settings.load();
      expect(settings.newTaskChoices.priority, 'medium');
      expect(settings.newTaskChoices.plan, isTrue);
      expect(settings.loadError, isNull, reason: 'the store is not damaged');
    });

    test('made while the store is still being read is kept', () async {
      final store = _SlowStore()..readGate = Completer<void>();
      await store.setValue('String', 'flutter.newTaskPriority', 'low');
      await store.setValue('Bool', 'flutter.newTaskMainTree', true);
      SharedPreferencesStorePlatform.instance = store;
      SharedPreferences.resetStatic();
      final settings = SettingsController();
      final loading = settings.load();
      // The sheet was opened and set before what was kept arrived.
      final saved = settings.setNewTaskChoices(set);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(settings.loaded, isFalse);
      store.readGate!.complete();
      await loading;
      await saved;

      expect(settings.newTaskChoices, set);
      final disk = await _onDisk(store);
      expect(disk['flutter.newTaskPriority'], 'high');
      expect(disk['flutter.newTaskRefine'], isTrue);
      expect(disk['flutter.newTaskMainTree'], isTrue);
    });

    test('ends with the last choice, whichever write lands last', () async {
      final store = _SlowStore();
      SharedPreferencesStorePlatform.instance = store;
      SharedPreferences.resetStatic();
      final settings = SettingsController();
      await settings.load();

      // The write of the first priority is slow, and the second is made
      // while it is on its way: the device must not be left with the first.
      store.lateWrites['high'] = const Duration(milliseconds: 60);
      final first = settings.setNewTaskChoices(
        const NewTaskChoices(priority: 'high'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 15));
      final second = settings.setNewTaskChoices(
        const NewTaskChoices(priority: 'low'),
      );
      await Future.wait([first, second]);

      expect((await _onDisk(store))['flutter.newTaskPriority'], 'low');
      expect(settings.newTaskChoices.priority, 'low');
    });

    test('a write the store refuses is said, and the choice kept', () async {
      final store = RefusingStore()
        ..refuse = false
        ..refuseKeys.add('flutter.newTaskPlan');
      SharedPreferencesStorePlatform.instance = store;
      SharedPreferences.resetStatic();
      final settings = SettingsController();
      await settings.load();
      await settings.setNewTaskChoices(set.copyWith(plan: true));
      expect(
        settings.persistenceProblem,
        'The settings store refused to save "newTaskPlan".',
      );
      expect(settings.newTaskChoices.plan, isTrue, reason: 'for this run');
      // The rest of them were written all the same.
      expect((await _onDisk(store))['flutter.newTaskPriority'], 'high');
    });
  });

  group('when the device cannot keep what it learns', () {
    // The app goes on without a store that does not work, but it then forgets
    // the harness's address and the device's secret each time it closes, and
    // "Remember" being on changes nothing.  A phone ran a release build in
    // which that was so for days, and nothing said why: the person only found
    // they had to type it all in again.  It is said now.

    test('a store that dies as the stripped Android plugin did is said', () async {
      SharedPreferencesStorePlatform.instance = StrippedStore();
      SharedPreferences.resetStatic();
      // `getInstance` is left waiting for ever after an Error: do not leave it
      // so for the tests that follow.
      addTearDown(SharedPreferences.resetStatic);
      final settings = SettingsController();
      expect(settings.persistenceProblem, isNull, reason: 'not known yet');
      await settings.load();

      // The app starts all the same, with nothing remembered ...
      expect(settings.loaded, isTrue);
      expect(settings.persistenceAvailable, isFalse);
      expect(settings.canResume, isFalse);
      // ... and says why, in a line: what failed, not a page of it.
      final problem = settings.persistenceProblem;
      expect(
        problem,
        startsWith('The settings store of this device did not open'),
      );
      expect(problem, contains('NoSuchMethodError'));
      expect(problem, isNot(contains('\n')));

      // What the person does meanwhile still works for this run of the app,
      // and still does not reach the disk: the problem stays.
      await settings.rememberConnectionDetails('ws://h/acp', 'hs1_device');
      expect(settings.address, 'ws://h/acp');
      expect(settings.persistenceProblem, isNotNull);
    });

    test('a store that works says nothing', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsController();
      expect(settings.persistenceProblem, isNull);
      await settings.load();
      expect(settings.persistenceProblem, isNull);
      await settings.rememberConnectionDetails('ws://h/acp', 'hs1_device');
      await settings.setThemeMode(ThemeMode.dark);
      await settings.setRememberConnection(true);
      await settings.clearConnection();
      expect(settings.persistenceProblem, isNull);
    });

    test(
      'a write the store refuses is said, and one that works ends it',
      () async {
        final store = RefusingStore();
        SharedPreferencesStorePlatform.instance = store;
        SharedPreferences.resetStatic();
        final settings = SettingsController();
        await settings.load();
        expect(settings.persistenceAvailable, isTrue);
        expect(settings.persistenceProblem, isNull);

        var heard = 0;
        settings.addListener(() => heard++);
        await settings.rememberConnectionDetails('ws://h/acp', 'hs1_device');
        // The first write that did not take is the one it names: later ones
        // that fail too do not move it, and ones that work do not end it.
        expect(
          settings.persistenceProblem,
          'The settings store refused to save "address".',
        );
        expect(heard, greaterThan(0), reason: 'the screens are told');

        store.refuse = false;
        await settings.rememberConnectionDetails('ws://h/acp', 'hs1_device');
        expect(settings.persistenceProblem, isNull);
        expect((await _onDisk(store))['flutter.token'], 'hs1_device');
      },
    );

    test('a write that works does not hide one that did not', () async {
      final store = RefusingStore()
        ..refuse = false
        ..refuseKeys.add('flutter.address');
      SharedPreferencesStorePlatform.instance = store;
      SharedPreferences.resetStatic();
      final settings = SettingsController();
      await settings.load();
      // The address is refused; the secret and the flag after it are taken.
      await settings.rememberConnectionDetails('ws://h/acp', 'hs1_device');
      expect(
        settings.persistenceProblem,
        'The settings store refused to save "address".',
      );
      expect((await _onDisk(store))['flutter.token'], 'hs1_device');
      // Written well, in the end, it is no longer a problem.
      store.refuseKeys.clear();
      await settings.rememberConnectionDetails('ws://h/acp', 'hs1_device');
      expect(settings.persistenceProblem, isNull);
    });

    test('a write that raises is said, in a line', () async {
      final store = RefusingStore()
        ..refuse = false
        ..fail = true;
      SharedPreferencesStorePlatform.instance = store;
      SharedPreferences.resetStatic();
      final settings = SettingsController();
      await settings.load();
      await settings.setShowThinking(false);
      final problem = settings.persistenceProblem;
      expect(problem, contains('could not save "showThinking"'));
      expect(problem, contains('disk full'));
      expect(settings.showThinking, isFalse, reason: 'kept for this run');
    });
  });
}

/// The preferences as the platform holds them now, for a next run of the app.
Future<Map<String, Object>> _onDiskNow() async {
  final prefs = await SharedPreferences.getInstance();
  return {for (final key in prefs.getKeys()) key: prefs.get(key)!};
}
