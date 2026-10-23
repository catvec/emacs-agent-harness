// A question the agent asks (`ask_user`) can be answered on a phone, whatever
// the phone and whatever the question: that is the only way the agent goes
// on.  These tests drive the app on phones of several sizes, with the
// keyboard down and up, and assert where things are (rects), because "it
// renders" would not catch a card whose answer field is under the keyboard,
// or whose question is cut to three lines.  The test font draws every
// letter as a wide square, which makes it a harsh judge of room.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/app.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:harness_client/src/ui/widgets/interaction_card.dart';
import 'package:harness_client/src/ui/widgets/message_composer.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';

class _Rig {
  _Rig(this.settings, this.harness, this.app);
  final SettingsController settings;
  final FakeHarness harness;
  final AppController app;
}

Future<_Rig> _rig() async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsController();
  await settings.load();
  final harness = FakeHarness();
  final app = AppController(settings: settings, connector: harness.connector);
  await app.connect('ws://memory/acp');
  return _Rig(settings, harness, app);
}

Future<void> _settle(WidgetTester tester, [int rounds = 10]) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

/// A phone: its size in points and how many pixels a point is.
class _Phone {
  const _Phone(this.name, this.width, this.height, this.ratio);
  final String name;
  final double width;
  final double height;
  final double ratio;

  @override
  String toString() => '$name ${width.round()}x${height.round()}';
}

const _small = _Phone('a small phone', 360, 640, 2.0);
const _tall = _Phone('a tall phone', 360, 800, 3.0);
const _pixel = _Phone('a Pixel', 412, 915, 2.625);
const _iphone = _Phone('an iPhone', 390, 844, 3.0);

/// What the keyboard of a phone takes, in points.
double _keyboardOf(_Phone phone) => phone.height < 700 ? 260 : 300;

/// [rig]'s app on [phone], with the first conversation of the list open.
Future<void> _open(WidgetTester tester, _Rig rig, _Phone phone) async {
  tester.view.physicalSize = Size(
    phone.width * phone.ratio,
    phone.height * phone.ratio,
  );
  tester.view.devicePixelRatio = phone.ratio;
  // The status bar and the navigation bar of the phone.
  tester.view.viewPadding = FakeViewPadding(
    top: 24 * phone.ratio,
    bottom: 24 * phone.ratio,
  );
  tester.view.padding = tester.view.viewPadding;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPadding);
  addTearDown(tester.view.resetViewPadding);
  addTearDown(tester.view.resetViewInsets);
  await tester.pumpWidget(
    HarnessApp(settings: rig.settings, appController: rig.app),
  );
  await tester.pump();
  await _settle(tester);
  await tester.tap(find.text('Design the merge queue'));
  await _settle(tester, 8);
}

/// The keyboard comes up, [points] high, or goes.
Future<void> _keyboard(WidgetTester tester, _Phone phone, double points) async {
  tester.view.viewInsets = FakeViewPadding(bottom: points * phone.ratio);
  tester.view.padding = FakeViewPadding(
    top: 24 * phone.ratio,
    bottom: points > 0 ? 0 : 24 * phone.ratio,
  );
  await tester.pump();
  await _settle(tester, 4);
}

/// The part of the screen that is not under the keyboard.
Rect _visible(_Phone phone, double keyboard) =>
    Rect.fromLTWH(0, 0, phone.width, phone.height - keyboard);

const _longQuestion =
    'The settings page has grown to **eleven sections**: General, Accounts, '
    'Notifications, Privacy, Appearance, Language, Storage, Backups, '
    'Integrations, Labs and About.\n\n'
    'Where should they go?\n\n'
    '- a sidebar on the left, as on a tablet;\n'
    '- tabs along the top, which scroll;\n'
    '- one long list of sections, as now.\n\n'
    'Whichever you pick I will also need to know whether the order matters, '
    'and whether the sections that are rarely opened (`Labs`, `About`) '
    'should be folded away. THE-LAST-WORDS-OF-IT';

const _diagrams = [
  {
    'type': 'ascii',
    'text': '┌──────┬───────────┐\n│ nav  │ content   │\n│      │           │\n└──────┴───────────┘',
  },
  {
    'type': 'ascii',
    'text': '┌───────────────────┐\n│ a | b | c | d | e │\n│ content           │\n└───────────────────┘',
  },
  {
    'type': 'ascii',
    'text': '┌───────────────────┐\n│ one long list     │\n│                   │\n└───────────────────┘',
  },
];

const _layouts = ['A sidebar on the left', 'Tabs along the top', 'One long list'];

Finder get _card => find.byType(InteractionCard);

/// The field the answer is typed in: the one text field of the card.
Finder get _field =>
    find.descendant(of: _card, matching: find.byType(TextField));
Finder get _sendAnswer => find.text('Send answer');
Finder get _sendTyped => find.byTooltip('Send typed answer');

/// Whether the part of [finder] the screen shows is all of it.
void _expectInSight(
  WidgetTester tester,
  Finder finder,
  Rect visible,
  String what,
) {
  expect(finder, findsOneWidget, reason: what);
  final rect = tester.getRect(finder);
  const slack = 0.01;
  expect(
    rect.left >= visible.left - slack &&
        rect.top >= visible.top - slack &&
        rect.right <= visible.right + slack &&
        rect.bottom <= visible.bottom + slack,
    isTrue,
    reason: '$what is at $rect, outside what is shown: $visible',
  );
}

void main() {
  for (final phone in [_small, _tall, _pixel, _iphone]) {
    for (final typing in [false, true]) {
      final where =
          '${phone.name} (${phone.width.round()}x${phone.height.round()})'
          '${typing ? ' with the keyboard up' : ''}';
      final keyboard = typing ? _keyboardOf(phone) : 0.0;

      group('on $where', () {
        testWidgets('a question with options and diagrams is answered', (
          tester,
        ) async {
          final rig = await _rig();
          await _open(tester, rig, phone);
          final reply = rig.harness.askUser(
            's1',
            question: _longQuestion,
            options: _layouts,
            diagrams: _diagrams,
          );
          await _settle(tester, 8);
          if (typing) await _keyboard(tester, phone, keyboard);
          final visible = _visible(phone, keyboard);

          // The card is on the screen, the whole of it.
          _expectInSight(tester, _card, visible, 'the card');
          // Where the answer is typed is in sight, to be typed in.
          _expectInSight(tester, _field, visible, 'the field of the answer');
          // The button is in sight, or in the card, which scrolls: scroll
          // to it, and it is.
          await tester.ensureVisible(_sendAnswer);
          await tester.pump();
          _expectInSight(tester, _sendAnswer, visible, 'the Send answer button');
          // The card does not take what the keyboard and the header have.
          expect(
            tester.getRect(_card).top,
            greaterThanOrEqualTo(tester.getRect(find.byType(AppBar)).bottom),
            reason: 'the card is under the header',
          );

          // The second option, then the button.
          await tester.ensureVisible(find.text('Tabs along the top'));
          await tester.pump();
          await tester.tap(find.text('Tabs along the top'));
          await tester.pump();
          await tester.ensureVisible(_sendAnswer);
          await tester.pump();
          await tester.tap(_sendAnswer);
          await _settle(tester, 6);
          expect(await reply, {'answer': 'Tabs along the top'});
          expect(_card, findsNothing);
        });

        testWidgets('a question with no options is answered by typing', (
          tester,
        ) async {
          final rig = await _rig();
          await _open(tester, rig, phone);
          final reply = rig.harness.askUser('s1', question: _longQuestion);
          await _settle(tester, 8);
          // Typing is how it is answered: the keyboard comes up for it.
          if (typing) await _keyboard(tester, phone, keyboard);
          final visible = _visible(phone, keyboard);

          _expectInSight(tester, _card, visible, 'the card');
          _expectInSight(tester, _field, visible, 'the field of the answer');
          _expectInSight(tester, _sendTyped, visible, 'the button for it');
          expect(_sendAnswer, findsNothing, reason: 'there is no option');

          await tester.enterText(_field, 'In tabs, folded away');
          await tester.pump();
          await tester.tap(_sendTyped);
          await _settle(tester, 6);
          expect(await reply, {'answer': 'In tabs, folded away'});
        });
      });
    }
  }

  group('the question is read in full', () {
    testWidgets('a long one, with its Markdown, to its last words', (
      tester,
    ) async {
      final rig = await _rig();
      await _open(tester, rig, _small);
      rig.harness.askUser('s1', question: _longQuestion, options: _layouts);
      await _settle(tester, 8);
      final last = find.textContaining('THE-LAST-WORDS-OF-IT', findRichText: true);
      expect(last, findsOneWidget, reason: 'it was not cut to three lines');
      await tester.ensureVisible(last);
      await tester.pump();
      // In the card, which the question scrolls in: not past it.
      final card = tester.getRect(_card);
      final rect = tester.getRect(last);
      expect(rect.top, greaterThanOrEqualTo(card.top));
      expect(rect.bottom, lessThanOrEqualTo(card.bottom));
      // Its Markdown is drawn, not shown: no asterisks.
      expect(find.textContaining('**eleven', findRichText: true), findsNothing);
      expect(find.textContaining('eleven sections', findRichText: true), findsOneWidget);
    });

    testWidgets('a short one is the title of the card, and only there', (
      tester,
    ) async {
      final rig = await _rig();
      await _open(tester, rig, _pixel);
      rig.harness.askUser(
        's1',
        question: 'Which database should the store use?',
        options: ['sqlite', 'postgres'],
      );
      await _settle(tester, 8);
      expect(find.text('Which database should the store use?'), findsOneWidget);
      expect(
        find.textContaining('Which database', findRichText: true),
        findsOneWidget,
      );
    });
  });

  group('typing the answer', () {
    testWidgets('the keyboard sends it', (tester) async {
      final rig = await _rig();
      await _open(tester, rig, _pixel);
      final reply = rig.harness.askUser(
        's1',
        question: 'What should the new tab be called?',
      );
      await _settle(tester, 8);
      await _keyboard(tester, _pixel, 300);
      await tester.tap(_field);
      await tester.pump();
      // What the keyboard is asked for: a key that says "send".  (A field
      // for lines would get a key that adds one, which sends nothing.)
      final editable = tester.widget<EditableText>(
        find.descendant(of: _field, matching: find.byType(EditableText)),
      );
      expect(editable.textInputAction, TextInputAction.send);
      expect(editable.keyboardType, isNot(TextInputType.multiline));
      await tester.enterText(_field, 'Automation');
      await tester.pump();
      // The key of the keyboard that says "send".
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await _settle(tester, 6);
      expect(await reply, {'answer': 'Automation'});
      expect(_card, findsNothing);
    });

    testWidgets('and sends nothing when nothing was typed', (tester) async {
      final rig = await _rig();
      await _open(tester, rig, _pixel);
      rig.harness.askUser('s1', question: 'What should it be called?');
      await _settle(tester, 8);
      await tester.tap(_field);
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await _settle(tester, 4);
      await tester.enterText(_field, '   ');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await _settle(tester, 4);
      expect(_card, findsOneWidget, reason: 'still waits for an answer');
      expect(rig.harness.questionAnswers, isEmpty);
    });

    testWidgets('the keyboard stays up for the field of the card', (
      tester,
    ) async {
      // The card gives the answer field room as the keyboard comes up and
      // the card is made smaller: it is not made again, which would take
      // the focus the person types in, and the keyboard with it.
      final rig = await _rig();
      await _open(tester, rig, _small);
      rig.harness.askUser(
        's1',
        question: _longQuestion,
        options: _layouts,
        diagrams: _diagrams,
      );
      await _settle(tester, 8);
      await tester.tap(_field);
      await tester.pump();
      final focused = FocusManager.instance.primaryFocus;
      expect(focused, isNotNull);
      await _keyboard(tester, _small, 260);
      expect(FocusManager.instance.primaryFocus, same(focused));
      await tester.enterText(_field, 'tabs');
      await tester.pump();
      expect(find.text('tabs'), findsOneWidget);
    });
  });

  group('the composer', () {
    testWidgets('is out of the way of a question, and is back, with what '
        'was typed in it, once the question is answered', (tester) async {
      final rig = await _rig();
      await _open(tester, rig, _pixel);
      final composer = find.byKey(const Key('composer-field'));
      await tester.enterText(composer, 'And then the review');
      await tester.pump();
      expect(find.byType(MessageComposer), findsOneWidget);

      final reply = rig.harness.askUser(
        's1',
        question: 'Which one?',
        options: ['this', 'that'],
      );
      await _settle(tester, 8);
      expect(find.byType(MessageComposer), findsNothing);
      expect(composer, findsNothing);

      await tester.tap(find.text('that'));
      await tester.pump();
      await tester.tap(_sendAnswer);
      await _settle(tester, 6);
      expect(await reply, {'answer': 'that'});
      expect(find.byType(MessageComposer), findsOneWidget);
      expect(find.text('And then the review'), findsOneWidget);
    });

    testWidgets('puts away the keyboard it had up when a question comes', (
      tester,
    ) async {
      final rig = await _rig();
      await _open(tester, rig, _pixel);
      await tester.tap(find.byKey(const Key('composer-field')));
      await tester.pump();
      expect(FocusManager.instance.primaryFocus, isNotNull);
      rig.harness.askUser('s1', question: 'Which one?', options: ['a', 'b']);
      await _settle(tester, 8);
      final focus = FocusManager.instance.primaryFocus;
      expect(
        focus?.context?.findAncestorWidgetOfExactType<MessageComposer>(),
        isNull,
        reason: 'what is typed in is the card, not the composer out of sight',
      );
    });
  });

  group('a question that was not asked of this device', () {
    testWidgets('waiting when the conversation is opened, is shown and '
        'answered through the harness', (tester) async {
      final rig = await _rig();
      rig.harness.leavePendingQuestion(
        's1',
        question: 'Which layout should the settings page use?',
        options: ['Sidebar on the left', 'Tabs along the top'],
        requestId: 'q-waiting',
      );
      await _open(tester, rig, _pixel);
      expect(
        find.text('Which layout should the settings page use?'),
        findsOneWidget,
      );
      await tester.tap(find.text('Tabs along the top'));
      await tester.pump();
      await tester.tap(_sendAnswer);
      await _settle(tester, 8);
      expect(rig.harness.questionAnswers, [
        {'answer': 'Tabs along the top'},
      ]);
      expect(rig.harness.isPending('s1', 'q-waiting'), isFalse);
      expect(_card, findsNothing);
    });

    testWidgets('held while the conversation is open is shown, once the '
        'request it comes with has had time to arrive', (tester) async {
      final rig = await _rig();
      await _open(tester, rig, _pixel);
      expect(_card, findsNothing);
      // The harness holds a question it did not ask this device (the
      // request did not reach it) and says so.
      rig.harness.leavePendingQuestion(
        's1',
        question: 'Which database?',
        options: ['sqlite', 'postgres'],
        requestId: 'q-unheard',
        announce: true,
      );
      await _settle(tester, 4);
      expect(_card, findsNothing, reason: 'its request may still be coming');
      await tester.pump(const Duration(seconds: 2));
      await _settle(tester, 4);
      expect(find.text('Which database?'), findsOneWidget);
      expect(tester.widgetList(_card), hasLength(1));
      await tester.tap(find.text('postgres'));
      await tester.pump();
      await tester.tap(_sendAnswer);
      await _settle(tester, 6);
      expect(rig.harness.questionAnswers.single, {'answer': 'postgres'});
    });

    testWidgets('and the request that follows is not a second card', (
      tester,
    ) async {
      final rig = await _rig();
      await _open(tester, rig, _pixel);
      final reply = rig.harness.askUser(
        's1',
        question: 'Which database?',
        options: ['sqlite', 'postgres'],
        requestId: 'q-once',
      );
      await tester.pump(const Duration(seconds: 3));
      await _settle(tester, 6);
      expect(tester.widgetList(_card), hasLength(1));
      expect(find.text('Which database?'), findsOneWidget);
      // It is answered as what was asked of this device: with the reply.
      await tester.tap(find.text('sqlite'));
      await tester.pump();
      await tester.tap(_sendAnswer);
      await _settle(tester, 6);
      expect(await reply, {'answer': 'sqlite'});
      expect(rig.harness.questionAnswers, hasLength(1));
    });

    testWidgets('answered somewhere else goes from the screen', (tester) async {
      final rig = await _rig();
      await _open(tester, rig, _pixel);
      final reply = rig.harness.askUser(
        's1',
        question: 'Which database?',
        options: ['sqlite', 'postgres'],
        requestId: 'q-else',
      );
      await _settle(tester, 8);
      expect(_card, findsOneWidget);
      rig.harness.answerElsewhere('s1', 'q-else', 'sqlite');
      await _settle(tester, 6);
      expect(_card, findsNothing);
      expect(find.byType(MessageComposer), findsOneWidget);
      // The reply this device gives, to the question it was asked, is
      // nothing: the harness knows it was answered.
      expect(await reply, {'answer': ''});
      expect(rig.harness.questionAnswers, [
        {'answer': 'sqlite', 'from': 'elsewhere'},
      ]);
    });

    testWidgets('one the harness holds, answered somewhere else, goes too', (
      tester,
    ) async {
      final rig = await _rig();
      rig.harness.leavePendingQuestion(
        's1',
        question: 'Which database?',
        options: ['sqlite', 'postgres'],
        requestId: 'q-held',
      );
      await _open(tester, rig, _pixel);
      expect(_card, findsOneWidget);
      rig.harness.answerElsewhere('s1', 'q-held', 'sqlite');
      await _settle(tester, 6);
      expect(_card, findsNothing);
    });

    testWidgets('an answer the harness did not take is not lost: the question '
        'is shown again', (tester) async {
      final rig = await _rig();
      rig.harness.leavePendingQuestion(
        's1',
        question: 'Which database?',
        options: ['sqlite', 'postgres'],
        requestId: 'q-fail',
      );
      await _open(tester, rig, _pixel);
      rig.harness.failQuestionAnswers = true;
      await tester.tap(_sendAnswer);
      await _settle(tester, 8);
      expect(find.text('The harness could not take the answer'), findsOneWidget);
      expect(find.text('Which database?'), findsOneWidget);
      // And it can be answered again.
      rig.harness.failQuestionAnswers = false;
      await tester.tap(_sendAnswer);
      await _settle(tester, 8);
      expect(rig.harness.isPending('s1', 'q-fail'), isFalse);
    });
  });
}
