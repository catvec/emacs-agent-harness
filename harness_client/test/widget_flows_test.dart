import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/app.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:harness_client/src/ui/screens/usage_screen.dart';
import 'package:harness_client/src/ui/widgets/message_composer.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';

class _Rig {
  _Rig(this.settings, this.harness, this.app);
  final SettingsController settings;
  final FakeHarness harness;
  final AppController app;
}

Future<_Rig> _rig({
  bool enhanced = true,
  String? token,
  bool connect = true,
  String connectionToken = '',
}) async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsController();
  await settings.load();
  final harness = FakeHarness(enhanced: enhanced, token: token);
  final app = AppController(settings: settings, connector: harness.connector);
  if (connect) {
    await app.connect('ws://memory/acp', token: connectionToken);
  }
  return _Rig(settings, harness, app);
}

Future<void> _pump(WidgetTester tester, _Rig rig, {int rounds = 8}) async {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    HarnessApp(settings: rig.settings, appController: rig.app),
  );
  await tester.pump();
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

Future<void> _settle(WidgetTester tester, [int rounds = 10]) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

void main() {
  testWidgets('connect flow discovers the harness and opens Sessions', (
    tester,
  ) async {
    final rig = await _rig(connect: false);
    await _pump(tester, rig);
    expect(find.textContaining('within reach'), findsOneWidget);
    await tester.enterText(find.byType(TextField).at(0), 'ws://memory/acp');
    await tester.tap(find.text('Connect'));
    await _settle(tester, 12);
    expect(find.text('Sessions'), findsWidgets);
    expect(find.text('Design the merge queue'), findsOneWidget);
  });

  testWidgets('auth flow unlocks with the shared token', (tester) async {
    final rig = await _rig(connect: false, token: 's3cret');
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      HarnessApp(settings: rig.settings, appController: rig.app),
    );
    await tester.pump();
    await tester.enterText(find.byType(TextField).at(0), 'ws://memory/acp');
    await tester.tap(find.text('Connect'));
    await _settle(tester, 8);
    expect(
      find.text('This harness is protecting the connection'),
      findsOneWidget,
    );
    await tester.enterText(find.byType(TextField).at(1), 's3cret');
    await tester.ensureVisible(find.text('Unlock with the token above'));
    await tester.tap(find.text('Unlock with the token above'));
    await _settle(tester, 12);
    expect(find.text('Design the merge queue'), findsOneWidget);
  });

  testWidgets('talk, stream, approve a permission, and answer a question', (
    tester,
  ) async {
    final rig = await _rig();
    await _pump(tester, rig);
    expect(find.text('Design the merge queue'), findsOneWidget);
    await tester.tap(find.text('Design the merge queue'));
    await _settle(tester, 6);
    expect(
      find.textContaining('The merge queue has three', findRichText: true),
      findsOneWidget,
    );
    expect(
      find.textContaining('Give me the tour', findRichText: true),
      findsOneWidget,
    );

    final composer = find.descendant(
      of: find.byType(MessageComposer),
      matching: find.byType(TextField),
    );
    expect(composer, findsOneWidget);
    await tester.enterText(composer, 'Run the tests with permission');
    await tester.pump();
    await tester.tap(find.byKey(const Key('composer-send')));
    await _settle(tester, 14);
    expect(find.text('PERMISSION'), findsOneWidget);
    expect(find.textContaining('Run the full test suite'), findsWidgets);
    await tester.tap(find.text('Allow'));
    await _settle(tester, 12);
    expect(rig.harness.permissionAnswers, isNotEmpty);
    final outcome = rig.harness.permissionAnswers.last['outcome'] as Map;
    expect(outcome['optionId'], 'allow-once');

    await tester.enterText(composer, 'Ask me a question');
    await tester.pump();
    await tester.tap(find.byKey(const Key('composer-send')));
    await _settle(tester, 16);
    expect(
      find.text('Which layout should the tablet session view use?'),
      findsOneWidget,
    );
    expect(find.text('Split: list and transcript'), findsOneWidget);
    await tester.tap(find.text('Split: list and transcript'));
    await _settle(tester, 3);
    await tester.ensureVisible(find.text('Send answer'));
    await tester.tap(find.text('Send answer'));
    await _settle(tester, 8);
    expect(rig.harness.questionAnswers, isNotEmpty);
    expect(
      rig.harness.questionAnswers.last['answer'],
      'Split: list and transcript',
    );
  });

  testWidgets('creates a session from the sheet', (tester) async {
    final rig = await _rig();
    await _pump(tester, rig);
    await tester.tap(find.byIcon(Icons.add_rounded));
    await _settle(tester, 4);
    expect(find.text('Start session'), findsOneWidget);
    await tester.tap(find.text('Start session'));
    await _settle(tester, 10);
    expect(find.text('The line is open'), findsOneWidget);
    expect(rig.harness.sessions.length, 5);
  });

  testWidgets('opens the new task sheet and submits through the API', (
    tester,
  ) async {
    final rig = await _rig();
    await _pump(tester, rig);
    await tester.tap(find.text('Tasks'));
    await _settle(tester, 5);
    await tester.tap(find.byIcon(Icons.add_rounded));
    await _settle(tester, 4);
    expect(find.text('Submit task'), findsOneWidget);
    final task = await rig.app.tasks!.submit(
      cwd: rig.app.selectedProject!,
      prompt: 'Write the migration notes',
      priority: 'medium',
    );
    expect(task, isNotNull);
    expect(rig.harness.tasks.length, 7);
  });

  testWidgets('task board opens a task and verifies it', (tester) async {
    final rig = await _rig();
    await _pump(tester, rig);
    await tester.tap(find.text('Tasks'));
    await _settle(tester, 6);
    expect(find.text('Answer the permission'), findsOneWidget);
    await tester.ensureVisible(find.text('Review'));
    await tester.tap(find.text('Review'));
    await _settle(tester, 4);
    expect(find.text('Review the emulator screenshots'), findsOneWidget);
    await tester.tap(find.text('Review the emulator screenshots'));
    await _settle(tester, 6);
    expect(find.text('Verify and merge'), findsOneWidget);
    await tester.tap(find.text('Verify and merge'));
    await _settle(tester, 8);
    expect(rig.harness.tasks['task-2']!['state'], 'done');
  });

  testWidgets('usage and server views expose the harness extensions', (
    tester,
  ) async {
    final rig = await _rig();
    await _pump(tester, rig);
    await tester.tap(find.text('Usage'));
    await _settle(tester, 6);
    expect(find.text('Spend'.toUpperCase()), findsOneWidget);
    expect(find.text(r'$1.24'), findsOneWidget);
    final usageList = find
        .descendant(
          of: find.byType(UsageScreen),
          matching: find.byType(ListView),
        )
        .first;
    await tester.drag(usageList, const Offset(0, -500));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('MODELS'), findsOneWidget);
    await tester.tap(find.text('Server'));
    await _settle(tester, 6);
    expect(find.text('emacs-agent-harness'), findsOneWidget);
    expect(find.text('Task board'), findsOneWidget);
  });

  testWidgets('plain ACP gets the chat and hides enhanced tabs', (
    tester,
  ) async {
    final rig = await _rig(enhanced: false);
    await _pump(tester, rig);
    final nav = tester.widget<NavigationBar>(find.byType(NavigationBar));
    expect(nav.destinations, hasLength(3));
    expect(find.text('Tasks'), findsNothing);
    expect(
      find.text(
        'Standard ACP agent · the task board and usage views are hidden.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Design the merge queue'));
    await _settle(tester, 6);
    await tester.enterText(
      find.descendant(
        of: find.byType(MessageComposer),
        matching: find.byType(TextField),
      ),
      'hello',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('composer-send')));
    await _settle(tester, 10);
    expect(
      find.textContaining('I’m on it', findRichText: true),
      findsOneWidget,
    );
  });

  testWidgets('apple platform style renders Cupertino navigation', (
    tester,
  ) async {
    final rig = await _rig();
    await rig.settings.setPreviewPlatform(PreviewPlatform.cupertino);
    await _pump(tester, rig);
    expect(find.byType(CupertinoTabBar), findsOneWidget);
    expect(find.byType(CupertinoNavigationBar), findsWidgets);
  });

  testWidgets('session search filters the list', (tester) async {
    final rig = await _rig();
    await _pump(tester, rig);
    await tester.enterText(find.byKey(const Key('session-search')), 'cache');
    await _settle(tester, 4);
    expect(find.text('Investigate cache misses'), findsOneWidget);
    expect(find.text('Design the merge queue'), findsNothing);
  });
}
