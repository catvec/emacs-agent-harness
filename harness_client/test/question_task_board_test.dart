// A task whose agent asks a question waits on the task board with an
// "Answer" button.  The question is not on the board: it is in the
// conversation of the task, so that is where the button has to take the
// person (it used to open the task's detail, which has nowhere to answer).
//
// Drawn with the fonts of a phone: the board's header holds a spend chip,
// which the test font, with its wide letters, squeezes out of its row.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/app.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:harness_client/src/ui/widgets/interaction_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';
import 'support/real_fonts.dart';

Future<void> _settle(WidgetTester tester, [int rounds = 10]) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  await loadRealFonts();

  Future<FakeHarness> open(
    WidgetTester tester, {
    void Function(FakeHarness harness)? arrange,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsController();
    await settings.load();
    final harness = FakeHarness();
    arrange?.call(harness);
    final app = AppController(settings: settings, connector: harness.connector);
    await app.connect('ws://memory/acp');
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(HarnessApp(settings: settings, appController: app));
    await tester.pump();
    await _settle(tester, 8);
    await tester.tap(find.text('Tasks'));
    await _settle(tester, 6);
    return harness;
  }

  testWidgets('"Answer" opens the conversation of the task that asks', (
    tester,
  ) async {
    // The agent of "Answer the permission" asked a question instead: the
    // harness holds it on the session of the task.
    final harness = await open(
      tester,
      arrange: (harness) {
        harness.sessions['s2']!['pending'] = <Map<String, Object?>>[];
        harness.leavePendingQuestion(
          's2',
          question: 'Which branch should the title fix land on?',
          options: const ['main', 'A branch of its own'],
        );
      },
    );
    expect(find.text('Answer the permission'), findsOneWidget);
    await tester.ensureVisible(find.text('Answer'));
    await tester.tap(find.text('Answer'));
    await _settle(tester, 10);

    // The conversation of the task is open, with what it asks to answer.
    expect(find.text('Fix duplicate task titles'), findsWidgets);
    expect(find.byType(InteractionCard), findsOneWidget);
    expect(
      find.text('Which branch should the title fix land on?'),
      findsOneWidget,
    );
    await tester.tap(find.text('A branch of its own'));
    await _settle(tester, 3);
    await tester.ensureVisible(find.text('Send answer'));
    await tester.tap(find.text('Send answer'));
    await _settle(tester, 8);
    expect(harness.questionAnswers.last['answer'], 'A branch of its own');
    expect(find.byType(InteractionCard), findsNothing);
  });

  testWidgets('the detail of the task leads to the conversation too', (
    tester,
  ) async {
    final harness = await open(
      tester,
      arrange: (harness) {
        harness.sessions['s2']!['pending'] = <Map<String, Object?>>[];
        harness.leavePendingQuestion(
          's2',
          question: 'Which branch should the title fix land on?',
          options: const ['main', 'A branch of its own'],
        );
      },
    );
    await tester.tap(find.text('Answer the permission'));
    await _settle(tester, 8);
    // A task that waits for an answer says where it is answered.
    expect(find.text('Answer in the task’s session'), findsOneWidget);
    await tester.ensureVisible(find.text('Answer in the task’s session'));
    await tester.tap(find.text('Answer in the task’s session'));
    await _settle(tester, 10);
    expect(find.byType(InteractionCard), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('question-answer-field')),
      'On main',
    );
    await tester.pump();
    await tester.tap(find.byTooltip('Send typed answer'));
    await _settle(tester, 8);
    expect(harness.questionAnswers.last['answer'], 'On main');
  });
}
