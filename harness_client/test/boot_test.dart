import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/app.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:harness_client/src/ui/adaptive/adaptive_widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';

/// A settings controller whose platform store never answers, like a plugin
/// that is missing or blocked on a device.
class _HangingSettings extends SettingsController {
  final gate = Completer<void>();

  @override
  Future<void> load() => gate.future;
}

Future<void> _show(
  WidgetTester tester,
  SettingsController settings, {
  AppController? app,
}) async {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(HarnessApp(settings: settings, appController: app));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

Future<void> _settle(WidgetTester tester, [int rounds = 12]) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

Future<void> _enterAddress(WidgetTester tester, String address) async {
  await tester.enterText(
    find.descendant(
      of: find.byKey(const Key('connect-address')),
      matching: find.byType(TextField),
    ),
    address,
  );
  await tester.pump();
}

void main() {
  testWidgets('the connection screen does not wait for local settings', (
    tester,
  ) async {
    final settings = _HangingSettings();
    final harness = FakeHarness();
    final app = AppController(settings: settings, connector: harness.connector);
    await _show(tester, settings, app: app);
    // The first screen is where a person types the harness address, so it
    // must appear even while the preference store is unresponsive.
    expect(find.text('Your agents,\nwithin reach.'), findsOneWidget);
    expect(find.byKey(const Key('connect-address')), findsOneWidget);
    expect(find.textContaining('Opening the line'), findsNothing);

    // And the address can still be used to connect.
    await _enterAddress(tester, 'ws://memory/acp');
    await tester.tap(find.byKey(const Key('connect-button')));
    await _settle(tester);
    expect(find.text('Design the merge queue'), findsOneWidget);
    settings.gate.complete();
    await tester.pump();
  });

  testWidgets('remembered address and token arrive after the screen', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'address': 'ws://192.168.1.20:4276/acp',
      'token': 's3cret',
      'rememberConnection': false,
    });
    final settings = SettingsController();
    await _show(tester, settings);
    expect(find.text('Your agents,\nwithin reach.'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 50));
    expect(settings.loaded, isTrue);
    expect(
      tester
          .widget<TextField>(
            find.descendant(
              of: find.byKey(const Key('connect-address')),
              matching: find.byType(TextField),
            ),
          )
          .controller!
          .text,
      'ws://192.168.1.20:4276/acp',
    );
    expect(
      tester
          .widget<TextField>(
            find.descendant(
              of: find.byKey(const Key('connect-token')),
              matching: find.byType(TextField),
            ),
          )
          .controller!
          .text,
      's3cret',
    );
    final remember = tester.widget<HarnessSwitch>(find.byType(HarnessSwitch));
    expect(remember.value, isFalse);
  });
}
