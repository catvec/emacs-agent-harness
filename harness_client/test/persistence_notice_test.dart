import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/app.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';
// The store `setMockInitialValues` puts in place; the tests give the app one
// of their own that does not work.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'support/broken_preference_stores.dart';
import 'support/fake_harness.dart';

/// A device that cannot keep what it learns of its harness has to say so.
/// Otherwise "Remember" is on, the person types the address and the secret in
/// again each time the app opens, and nothing says why.  That is what a release
/// build of the Android app did while its preference plugin did not work.

const _problem = Key('persistence-problem');

Future<(SettingsController, AppController)> _launch({
  SharedPreferencesStorePlatform? store,
}) async {
  if (store == null) {
    SharedPreferences.setMockInitialValues({});
  } else {
    SharedPreferencesStorePlatform.instance = store;
    SharedPreferences.resetStatic();
    // `getInstance` is left waiting for ever after an Error.
    addTearDown(SharedPreferences.resetStatic);
  }
  final settings = SettingsController();
  await settings.load();
  final harness = FakeHarness();
  final app = AppController(settings: settings, connector: harness.connector);
  return (settings, app);
}

Future<void> _open(
  WidgetTester tester,
  SettingsController settings,
  AppController app,
) async {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(HarnessApp(settings: settings, appController: app));
  await _settle(tester, 4);
}

Future<void> _settle(WidgetTester tester, [int rounds = 12]) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

Future<void> _connect(WidgetTester tester) async {
  await tester.enterText(
    find.descendant(
      of: find.byKey(const Key('connect-address')),
      matching: find.byType(TextField),
    ),
    'ws://memory/acp',
  );
  await tester.pump();
  // The form scrolls: with a notice above it the button may be below the fold.
  await tester.ensureVisible(find.byKey(const Key('connect-button')));
  await tester.pump();
  await tester.tap(find.byKey(const Key('connect-button')));
  await _settle(tester);
}

/// Open Settings and bring the "Remember" row into view: the page is a list
/// that builds its rows as they are scrolled to.
Future<Finder> _rememberRow(WidgetTester tester) async {
  await tester.tap(find.text('Settings'));
  await _settle(tester, 6);
  final row = find.byKey(const Key('settings-remember'));
  await tester.scrollUntilVisible(
    row,
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pump();
  return row;
}

void main() {
  testWidgets('the connection form says so when the settings store is dead', (
    tester,
  ) async {
    final (settings, app) = await _launch(store: StrippedStore());
    await _open(tester, settings, app);
    expect(find.text('Your agents,\nwithin reach.'), findsOneWidget);
    expect(find.byKey(_problem), findsOneWidget);
    expect(
      find.text('This device cannot remember the harness'),
      findsOneWidget,
    );
    // Why, and what it means for the person.
    expect(
      find.textContaining(
        'did not open: NoSuchMethodError',
        findRichText: true,
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining('asked for again each time the app opens'),
      findsOneWidget,
    );
    // Above the form, which is still there and still works.
    expect(find.byKey(const Key('connect-address')), findsOneWidget);
    expect(
      tester.getBottomLeft(find.byKey(_problem)).dy,
      lessThan(tester.getTopLeft(find.byKey(const Key('connect-address'))).dy),
    );
  });

  testWidgets('the app still connects without a store, and keeps saying so', (
    tester,
  ) async {
    final (settings, app) = await _launch(store: StrippedStore());
    await _open(tester, settings, app);
    await _connect(tester);
    expect(find.text('Design the merge queue'), findsOneWidget);
    expect(find.byKey(_problem), findsNothing, reason: 'the form is gone');

    // In Settings, where "Remember" is, it is not promised: it says why not.
    final row = await _rememberRow(tester);
    expect(
      find.descendant(
        of: row,
        matching: find.textContaining('did not open: NoSuchMethodError'),
      ),
      findsOneWidget,
    );
    expect(
      find.text('Stay signed in: keep the address and session here.'),
      findsNothing,
    );
  });

  testWidgets('a store that works is not mentioned', (tester) async {
    final (settings, app) = await _launch();
    await _open(tester, settings, app);
    expect(find.byKey(_problem), findsNothing);
    expect(find.text('This device cannot remember the harness'), findsNothing);

    await _connect(tester);
    final row = await _rememberRow(tester);
    expect(
      find.descendant(
        of: row,
        matching: find.text(
          'Stay signed in: keep the address and session here.',
        ),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a write the store refuses shows up as it happens', (
    tester,
  ) async {
    final store = RefusingStore();
    final (settings, app) = await _launch(store: store);
    await _open(tester, settings, app);
    expect(find.byKey(_problem), findsNothing, reason: 'nothing written yet');

    // The person signs in; the address and secret are to be kept, and are not.
    await settings.rememberConnectionDetails('ws://memory/acp', 'hs1_device');
    await tester.pump();
    expect(find.byKey(_problem), findsOneWidget);
    expect(
      find.textContaining('refused to save "address"', findRichText: true),
      findsOneWidget,
    );

    // The store comes round: the notice goes.
    store.refuse = false;
    await settings.rememberConnectionDetails('ws://memory/acp', 'hs1_device');
    await tester.pump();
    expect(find.byKey(_problem), findsNothing);
  });
}
