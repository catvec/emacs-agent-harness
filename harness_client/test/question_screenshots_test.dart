// Pictures of the question card on phones, drawn with the fonts of a phone.
//
//   HARNESS_SHOTS=/some/directory flutter test test/question_screenshots_test.dart
//
// writes a PNG for each case there.  Without HARNESS_SHOTS the cases still
// run (they draw, and check that the card is whole on the picture's screen),
// and write nothing.  The keyboard is drawn as a grey block: the test has no
// keyboard, only the room one takes.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/app.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:harness_client/src/ui/widgets/interaction_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';
import 'support/real_fonts.dart';

const _question =
    'The settings page has grown to **eleven sections**: General, Accounts, '
    'Notifications, Privacy, Appearance, Language, Storage, Backups, '
    'Integrations, Labs and About.\n\n'
    'Where should they go?  Whichever you pick I will also need to know '
    'whether the order matters, and whether the sections that are rarely '
    'opened (`Labs`, `About`) should be folded away.';

const _options = [
  'A sidebar on the left, as on a tablet',
  'Tabs along the top, which scroll',
  'One long list of sections, as now',
];

const _diagrams = [
  {
    'type': 'ascii',
    'text':
        '┌────────┬─────────────────┐\n'
        '│ General│ Notifications   │\n'
        '│ Privacy│  [x] Sound      │\n'
        '│ About  │  [ ] Vibrate    │\n'
        '└────────┴─────────────────┘',
  },
  {
    'type': 'ascii',
    'text':
        '┌──────────────────────────┐\n'
        '│ General | Privacy | About│\n'
        '│ Notifications            │\n'
        '└──────────────────────────┘',
  },
  {
    'type': 'ascii',
    'text':
        '┌──────────────────────────┐\n'
        '│ General                  │\n'
        '│ Notifications            │\n'
        '│ Privacy ...              │\n'
        '└──────────────────────────┘',
  },
];

const _foldQuestion = 'Which sections should the settings page fold away?';

const _foldable = ['Labs', 'About', 'Backups', 'Integrations', 'Language'];

class _Case {
  const _Case(
    this.file,
    this.width,
    this.height, {
    this.keyboard = 0,
    this.question = 'Which layout should the settings page use?',
    this.options = const <String>[],
    this.diagrams,
    this.type,
    this.apple = false,
    this.multiple = false,
    this.tick = const <String>[],
  });
  final String file;
  final double width;
  final double height;
  final double keyboard;
  final String question;
  final List<String> options;
  final List<Object?>? diagrams;

  /// Several of the options may be ticked (`allow_multiple`), and the ones
  /// named in [tick] are tapped, in turn: one named twice is ticked and
  /// taken back, and is where the diagram is looked at.
  final bool multiple;
  final List<String> tick;

  /// The options that are ticked once [tick] is done.
  Set<String> get ticked => {
    for (final option in tick.toSet())
      if (tick.where((other) => other == option).length.isOdd) option,
  };

  /// What is typed in the field of the card, if anything.
  final String? type;

  /// Drawn in the style of an iPhone, not of an Android phone.
  final bool apple;
}

const _cases = [
  // The card, as it has been: a short question, options, a diagram.
  _Case(
    'question-options',
    360,
    800,
    options: _options,
    diagrams: _diagrams,
  ),
  // A long question, with its Markdown, read to its end by scrolling.
  _Case(
    'question-long',
    360,
    800,
    question: _question,
    options: _options,
    diagrams: _diagrams,
  ),
  // A question with no options, answered by typing: the keyboard is up.
  _Case(
    'question-typing-keyboard',
    360,
    800,
    keyboard: 300,
    question: _question,
    type: 'In tabs, and fold Labs and About away',
  ),
  // The same, on a small phone, where it used to be out of reach.
  _Case(
    'question-small-phone-keyboard',
    360,
    640,
    keyboard: 260,
    question: _question,
    options: _options,
    diagrams: _diagrams,
  ),
  // The same two, in the style of an iPhone.
  _Case(
    'question-long-ios',
    390,
    844,
    question: _question,
    options: _options,
    diagrams: _diagrams,
    apple: true,
  ),
  _Case(
    'question-typing-keyboard-ios',
    390,
    844,
    keyboard: 300,
    question: _question,
    type: 'In tabs, and fold Labs and About away',
    apple: true,
  ),
  // A question of several choices: check boxes, two ticked, and the button
  // that says how many it sends.
  _Case(
    'question-multiple',
    360,
    800,
    question: _foldQuestion,
    options: _foldable,
    multiple: true,
    tick: ['Labs', 'Backups'],
  ),
  // With diagrams, which show the option tapped last, ticked or not: here
  // one that was ticked and taken back, outlined, the other one ticked.
  _Case(
    'question-multiple-diagrams',
    360,
    800,
    question: 'Which layouts should the settings page offer?',
    options: _options,
    diagrams: _diagrams,
    multiple: true,
    tick: [
      'A sidebar on the left, as on a tablet',
      'Tabs along the top, which scroll',
      'Tabs along the top, which scroll',
    ],
  ),
  // The same on a small phone, with the keyboard up and a note typed after
  // the ticks.
  _Case(
    'question-multiple-diagrams-keyboard',
    360,
    640,
    keyboard: 260,
    question: 'Which layouts should the settings page offer?',
    options: _options,
    diagrams: _diagrams,
    multiple: true,
    tick: [
      'A sidebar on the left, as on a tablet',
      'Tabs along the top, which scroll',
    ],
    type: 'the sidebar only on tablets',
  ),
  // The same, in the style of an iPhone.
  _Case(
    'question-multiple-ios',
    390,
    844,
    question: _foldQuestion,
    options: _foldable,
    multiple: true,
    tick: ['About', 'Integrations', 'Language'],
    apple: true,
  ),
];

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  final shots = Platform.environment['HARNESS_SHOTS'];
  final real = await loadRealFonts();

  for (final shot in _cases) {
    testWidgets('draws ${shot.file}', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsController();
      await settings.load();
      if (shot.apple) {
        await settings.setPreviewPlatform(PreviewPlatform.cupertino);
      }
      final harness = FakeHarness();
      final app = AppController(
        settings: settings,
        connector: harness.connector,
      );
      await app.connect('ws://memory/acp');

      const ratio = 2.0;
      tester.view.physicalSize = Size(shot.width * ratio, shot.height * ratio);
      tester.view.devicePixelRatio = ratio;
      tester.view.viewPadding = const FakeViewPadding(
        top: 24 * ratio,
        bottom: 24 * ratio,
      );
      tester.view.padding = tester.view.viewPadding;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);
      addTearDown(tester.view.resetViewInsets);

      final boundary = GlobalKey();
      final keyboardUp = ValueNotifier<bool>(false);
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: Stack(
            textDirection: TextDirection.ltr,
            children: [
              Positioned.fill(
                child: HarnessApp(settings: settings, appController: app),
              ),
              if (shot.keyboard > 0)
                ValueListenableBuilder<bool>(
                  valueListenable: keyboardUp,
                  builder: (context, up, _) => up
                      ? Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          height: shot.keyboard,
                          child: const ColoredBox(
                            color: Color(0xFFD3D6DB),
                            child: Center(
                              child: Text(
                                'soft keyboard',
                                textDirection: TextDirection.ltr,
                                style: TextStyle(
                                  color: Color(0xFF5F6368),
                                  fontSize: 14,
                                  decoration: TextDecoration.none,
                                ),
                              ),
                            ),
                          ),
                        )
                      : const Positioned(
                          left: 0,
                          top: 0,
                          width: 0,
                          height: 0,
                          child: SizedBox.shrink(),
                        ),
                ),
            ],
          ),
        ),
      );
      await tester.pump();
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 120));
      }
      await tester.tap(find.text('Design the merge queue'));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 120));
        // The tabs of the home screen are all there under the page that
        // opens, each with a navigation bar of the same hero tag, which
        // Cupertino pages complain of in a debug build: not what is drawn.
        if (shot.apple) tester.takeException();
      }
      harness.askUser(
        's1',
        question: shot.question,
        options: shot.options,
        diagrams: shot.diagrams,
        allowMultiple: shot.multiple,
      );
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 120));
      }
      for (final option in shot.tick) {
        await tester.tap(find.text(option));
        // The row takes its colours on over a moment, and the ripple of the
        // tap fades: both are let go by.
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
      }
      if (shot.keyboard > 0) {
        keyboardUp.value = true;
        tester.view.viewInsets = FakeViewPadding(
          bottom: shot.keyboard * ratio,
        );
        tester.view.padding = const FakeViewPadding(top: 24 * ratio);
        await tester.pump();
        for (var i = 0; i < 4; i++) {
          await tester.pump(const Duration(milliseconds: 120));
        }
      }
      if (shot.type != null) {
        await tester.enterText(
          find.byKey(const Key('question-answer-field')),
          shot.type!,
        );
        // The card grows with a line more, which takes a moment.
        await tester.pump();
        for (var i = 0; i < 4; i++) {
          await tester.pump(const Duration(milliseconds: 120));
        }
      }

      // What was ticked is ticked, and the button says how many.
      if (shot.multiple) {
        expect(
          find.byIcon(Icons.check_box_rounded),
          findsNWidgets(shot.ticked.length),
        );
        if (shot.ticked.isNotEmpty) {
          expect(
            find.text('Send answer (${shot.ticked.length})'),
            findsOneWidget,
          );
        }
      }

      // The whole card is on the screen, above the keyboard.
      final card = tester.getRect(find.byType(InteractionCard));
      expect(card.top, greaterThanOrEqualTo(0));
      expect(card.bottom, lessThanOrEqualTo(shot.height - shot.keyboard + 0.01));

      if (shots != null) {
        await tester.runAsync(() async {
          final render =
              boundary.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await render.toImage(pixelRatio: 1.5);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File('$shots/${shot.file}${real ? '' : '-ahem'}.png');
          file.parent.createSync(recursive: true);
          file.writeAsBytesSync(data!.buffer.asUint8List());
        });
      }
    });
  }
}
