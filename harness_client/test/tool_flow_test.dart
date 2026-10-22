// The calls of a task's session, read through the whole client: the harness's
// replay over ACP and its nodes with the keys the harness writes (`call-id`,
// `is-error`, a result's `meta`), into the page the person reads.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/app.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';
import 'support/tool_showcase.dart';

Future<void> _settle(WidgetTester tester, [int rounds = 12]) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

Future<void> _openSession(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsController();
  await settings.load();
  final harness = FakeHarness()..seedToolShowcase();
  final app = AppController(settings: settings, connector: harness.connector);
  await app.connect('ws://memory/acp');
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(HarnessApp(settings: settings, appController: app));
  await tester.pump();
  await _settle(tester);
  await tester.tap(find.text(toolShowcaseName));
  await _settle(tester, 30);
}

void main() {
  testWidgets('a task\'s session opens on the call that handed its work in', (
    tester,
  ) async {
    await _openSession(tester);
    // The latest of what the agent did is what is on the screen.
    expect(find.textContaining('Hand in the finished work'), findsOneWidget);
    expect(find.text('Hand-in'), findsOneWidget);
  });

  testWidgets('the call that handed the work in opens to its report', (
    tester,
  ) async {
    await _openSession(tester);
    await tester.tap(find.textContaining('Hand in the finished work'));
    await _settle(tester, 6);
    expect(find.text('PROBLEM'), findsOneWidget);
    expect(find.text('SUMMARY'), findsOneWidget);
    expect(find.text('What was wrong'), findsOneWidget);
    expect(
      find.textContaining('Tool call results are hard to read'),
      findsWidgets,
    );
    // Not the call as it was sent.
    expect(find.textContaining('"evidence"'), findsNothing);
    expect(find.textContaining(r'\n'), findsNothing);
  });

  testWidgets('a refused call and a failed one are not the same', (
    tester,
  ) async {
    await _openSession(tester);
    // The two calls before the last message are both in the screen's reach.
    final list = find.byKey(const ValueKey('transcript-list'));
    await tester.dragUntilVisible(
      find.text('Denied'),
      list,
      const Offset(0, 120),
      maxIteration: 40,
    );
    expect(find.text('Denied'), findsOneWidget);
    expect(find.text('Failed'), findsOneWidget);
    expect(find.textContaining('lies outside the directories'), findsOneWidget);
    expect(
      find.textContaining("error • Undefined name 'theme'"),
      findsOneWidget,
    );
  });
}
