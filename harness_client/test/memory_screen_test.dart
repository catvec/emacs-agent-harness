import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/models/workspace.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/memory_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:harness_client/src/state/app_controller.dart' show AppController;
import 'package:harness_client/src/ui/adaptive/platform_style.dart';
import 'package:harness_client/src/ui/screens/memory_screen.dart';
import 'package:harness_client/src/ui/theme/harness_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';

const _workspace = WorkspaceSummary(id: 'w1', name: 'Home');

Future<(AppController, FakeHarness, MemoryController)> _rig() async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsController();
  await settings.load();
  final harness = FakeHarness(workspace: true);
  final app = AppController(
    settings: settings,
    connector: harness.connector,
    reconnectDelays: const [Duration(milliseconds: 5)],
  );
  addTearDown(app.dispose);
  await app.connect('ws://memory/acp');
  final controller = MemoryController(app.harness, workspaceId: 'w1');
  addTearDown(controller.dispose);
  await controller.load();
  return (app, harness, controller);
}

Future<void> _pump(
  WidgetTester tester,
  AppController app,
  MemoryController controller, {
  Size size = const Size(390, 844),
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    HarnessStyle(
      style: HarnessPlatformStyle.material,
      child: MaterialApp(
        theme: HarnessTheme.material(Brightness.light),
        home: MediaQuery(
          data: MediaQueryData(size: size, textScaler: TextScaler.linear(textScale)),
          child: MemoryScreen(app: app, workspace: _workspace, controller: controller),
        ),
      ),
    ),
  );
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  test('the memory loads notes and searches them', () async {
    final (_, harness, controller) = await _rig();
    expect(controller.status!.notes, 12);
    expect(controller.notes.length, 2);
    expect(controller.notes.first.thread, 'Kitchen renovation');
    await controller.search('recall');
    expect(harness.memorySearches, ['recall']);
    expect(controller.notes.single.snippet, contains('<<recall>>'));
    await controller.clearSearch();
    expect(controller.query, isEmpty);
    expect(controller.notes.length, 2);
  });

  testWidgets('memory says what it holds on a phone', (tester) async {
    final (app, _, controller) = await _rig();
    await _pump(tester, app, controller);
    expect(find.text('Memory'), findsWidgets);
    expect(find.textContaining('12 notes'), findsWidgets);
    expect(find.text('Search memory'), findsOneWidget);
    expect(find.text('# Kitchen renovation'), findsOneWidget);
    expect(find.text('Let us go with quartz for the countertop.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a recall highlights the match', (tester) async {
    final (app, _, controller) = await _rig();
    await _pump(tester, app, controller);
    await tester.enterText(find.byKey(const ValueKey('memory-search')), 'recall');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(controller.notes.length, 1);
    expect(find.text('Recall · 1'), findsOneWidget);
    expect(find.textContaining('No matches'), findsNothing);
    await tester.enterText(find.byKey(const ValueKey('memory-search')), 'zebra');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(find.text('No matches'), findsOneWidget);
  });

  testWidgets('memory holds at desktop widths and larger text', (tester) async {
    final (app, _, controller) = await _rig();
    for (final size in const [Size(390, 844), Size(1440, 900)]) {
      for (final scale in const [1.0, 1.5, 2.0]) {
        await _pump(tester, app, controller, size: size, textScale: scale);
        expect(tester.takeException(), isNull, reason: '$size at $scale');
        expect(find.text('Memory'), findsWidgets);
      }
    }
  });
}
