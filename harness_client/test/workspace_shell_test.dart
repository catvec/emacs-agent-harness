import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/app.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';

Future<AppController> _rig() async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsController();
  await settings.load();
  final harness = FakeHarness(workspace: true);
  final app = AppController(settings: settings, connector: harness.connector);
  await app.connect('ws://memory/acp');
  return app;
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 160));
  }
}

void main() {
  testWidgets('the workspace tab opens on a phone', (tester) async {
    final app = await _rig();
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      HarnessApp(settings: app.settings, appController: app),
    );
    await _settle(tester);
    expect(find.text('Workspace'), findsWidgets);
    await tester.tap(find.text('Workspace').last);
    await _settle(tester);
    expect(find.text('Home'), findsWidgets);
    expect(find.text('The tile is matte.'), findsOneWidget);
  });

  testWidgets('the workspace tab opens on a desktop', (tester) async {
    final app = await _rig();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      HarnessApp(settings: app.settings, appController: app),
    );
    await _settle(tester);
    await tester.tap(find.text('Workspace').last);
    await _settle(tester);
    expect(find.text('Threads'), findsOneWidget);
    expect(find.text('Computer'), findsOneWidget);
    expect(find.text('Concepts'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
