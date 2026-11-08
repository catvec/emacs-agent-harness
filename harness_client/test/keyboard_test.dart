// The Emacs keys of the Flutter client: what sends a message when the person
// asked for C-c C-c, the keys that edit a text field as Emacs does, and the
// C-c commands for the chat's own functions.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/app.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:harness_client/src/ui/adaptive/adaptive_widgets.dart';
import 'package:harness_client/src/ui/adaptive/platform_style.dart';
import 'package:harness_client/src/ui/app_scope.dart';
import 'package:harness_client/src/ui/emacs_keys.dart';
import 'package:harness_client/src/ui/harness_keys.dart';
import 'package:harness_client/src/ui/screens/quick_search_screen.dart';
import 'package:harness_client/src/ui/screens/settings_screen.dart';
import 'package:harness_client/src/ui/theme/harness_theme.dart';
import 'package:harness_client/src/ui/widgets/message_composer.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';

/// A test on the keyboard of a desktop, where the Control and Alt keys are.
/// The platform override is put back before the test returns: the test
/// binding checks it before the tear-downs run.
void _desktopTest(
  String description,
  Future<void> Function(WidgetTester tester) body,
) {
  testWidgets(description, (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      await body(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

void _window(WidgetTester tester, {Size size = const Size(900, 800)}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<SettingsController> _settings({
  SendKey sendKey = SendKey.enter,
  bool emacsEditing = false,
  bool harnessKeys = false,
}) async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsController();
  await settings.load();
  await settings.setSendKey(sendKey);
  await settings.setEmacsEditing(emacsEditing);
  await settings.setHarnessKeys(harnessKeys);
  return settings;
}

/// What a key does with Control and/or Alt held, as a person's hands do it.
Future<void> _key(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool control = false,
  bool alt = false,
  bool shift = false,
}) async {
  if (control) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  if (alt) await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
  if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(key);
  if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  if (alt) await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
  if (control) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
}

/// The harness's prefix: C-c, then the key with Control.
Future<void> _chord(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
}

const _field = Key('composer-field');

Future<void> _pumpComposer(
  WidgetTester tester,
  SettingsController settings, {
  required void Function(String text) onSend,
  bool canAttach = false,
}) async {
  _window(tester);
  final app = AppController(settings: settings);
  addTearDown(app.dispose);
  await tester.pumpWidget(
    HarnessStyle(
      style: HarnessPlatformStyle.material,
      child: HarnessScope(
        app: app,
        settings: settings,
        child: MaterialApp(
          theme: HarnessTheme.material(Brightness.dark),
          home: Scaffold(
            body: Column(
              children: [
                const Expanded(child: SizedBox.shrink()),
                MessageComposer(
                  onSend: (text, _) {
                    onSend(text);
                    return true;
                  },
                  onStop: () {},
                  running: false,
                  cancelling: false,
                  canAttach: canAttach,
                  autofocus: true,
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _pumpField(
  WidgetTester tester,
  TextEditingController controller, {
  bool emacsKeys = true,
}) async {
  _window(tester);
  await tester.pumpWidget(
    HarnessStyle(
      style: HarnessPlatformStyle.material,
      child: MaterialApp(
        theme: HarnessTheme.material(Brightness.dark),
        home: Scaffold(
          body: HarnessTextField(
            controller: controller,
            emacsKeys: emacsKeys,
            maxLines: 6,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.showKeyboard(find.byType(EditableText));
  await tester.pump();
}

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
  await settings.setHarnessKeys(true);
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

Future<void> _pumpApp(WidgetTester tester, _Rig rig) async {
  _window(tester, size: const Size(800, 900));
  await tester.pumpWidget(
    HarnessApp(settings: rig.settings, appController: rig.app),
  );
  await tester.pump();
  await _settle(tester);
}

Future<void> _openSession(WidgetTester tester) async {
  await tester.tap(find.text('Design the merge queue'));
  await _settle(tester);
}

void main() {
  setUp(KillRing.shared.clear);

  group('sending a message', () {
    _desktopTest('Enter sends, and the box says so', (tester) async {
      final sent = <String>[];
      await _pumpComposer(tester, await _settings(), onSend: sent.add);
      expect(find.text('Message · Enter to send'), findsOneWidget);
      expect(
        find.text('Enter to send · Shift + Enter for a new line'),
        findsOneWidget,
      );

      await tester.showKeyboard(find.byKey(_field));
      await tester.enterText(find.byKey(_field), 'From the keyboard');
      await tester.pump();
      await _key(tester, LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(sent, ['From the keyboard']);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
    });

    _desktopTest('C-c C-c sends and Enter writes a new line, when chosen', (
      tester,
    ) async {
      final sent = <String>[];
      await _pumpComposer(
        tester,
        await _settings(sendKey: SendKey.ctrlCctrlC),
        onSend: sent.add,
      );
      expect(find.text('Message · C-c C-c to send'), findsOneWidget);
      expect(
        find.text('C-c C-c to send · Enter for a new line'),
        findsOneWidget,
      );

      await tester.showKeyboard(find.byKey(_field));
      await tester.enterText(find.byKey(_field), 'Sent with Emacs');
      await tester.pump();
      await _key(tester, LogicalKeyboardKey.enter);
      await tester.pump();
      expect(sent, isEmpty, reason: 'Enter is a new line now');

      await _chord(tester, LogicalKeyboardKey.keyC);
      await tester.pumpAndSettle();
      expect(sent, ['Sent with Emacs']);
    });

    _desktopTest(
      'with harness keys off, the box leaves C-c C-c for the field',
      (tester) async {
        final sent = <String>[];
        await _pumpComposer(
          tester,
          await _settings(sendKey: SendKey.enter, harnessKeys: false),
          onSend: sent.add,
        );
        await tester.showKeyboard(find.byKey(_field));
        await tester.enterText(find.byKey(_field), 'Not sent this way');
        await tester.pump();
        await _chord(tester, LogicalKeyboardKey.keyC);
        await tester.pumpAndSettle();
        expect(sent, isEmpty);
      },
    );
  });

  group('Emacs editing', () {
    _desktopTest('moves by character, word and line', (tester) async {
      final controller = TextEditingController(text: 'one two\nthree');
      addTearDown(controller.dispose);
      await _pumpField(tester, controller);

      controller.selection = const TextSelection.collapsed(offset: 8);
      controller.value = controller.value.copyWith(
        selection: const TextSelection.collapsed(offset: 8),
      );
      await tester.pump();
      await _key(tester, LogicalKeyboardKey.keyE, control: true);
      expect(controller.selection.isCollapsed, isTrue);
      expect(controller.selection.extentOffset, 13);

      await _key(tester, LogicalKeyboardKey.keyA, control: true);
      expect(controller.selection.extentOffset, 8);

      await _key(tester, LogicalKeyboardKey.keyF, alt: true);
      expect(controller.selection.extentOffset, 13);
      await _key(tester, LogicalKeyboardKey.keyB, alt: true);
      expect(controller.selection.extentOffset, 8);

      await _key(tester, LogicalKeyboardKey.keyP, control: true);
      expect(controller.selection.extentOffset, 0);
      await _key(tester, LogicalKeyboardKey.keyN, control: true);
      expect(controller.selection.extentOffset, 8);
    });

    _desktopTest('kills a line and yanks it back', (tester) async {
      final controller = TextEditingController(text: 'one two\nthree');
      addTearDown(controller.dispose);
      await _pumpField(tester, controller);
      controller.value = controller.value.copyWith(
        selection: const TextSelection.collapsed(offset: 0),
      );
      await tester.pump();

      await _key(tester, LogicalKeyboardKey.keyK, control: true);
      expect(controller.text, '\nthree');
      expect(KillRing.shared.last, 'one two');

      await _key(tester, LogicalKeyboardKey.keyY, control: true);
      expect(controller.text, 'one two\nthree');
      expect(controller.selection.extentOffset, 7);
    });

    _desktopTest('a mark makes movement select, and C-w kills the region', (
      tester,
    ) async {
      final controller = TextEditingController(text: 'one two three');
      addTearDown(controller.dispose);
      await _pumpField(tester, controller);
      controller.value = controller.value.copyWith(
        selection: const TextSelection.collapsed(offset: 0),
      );
      await tester.pump();

      await _key(tester, LogicalKeyboardKey.space, control: true);
      await _key(tester, LogicalKeyboardKey.keyF, control: true);
      await _key(tester, LogicalKeyboardKey.keyF, control: true);
      expect(controller.selection.baseOffset, 0);
      expect(controller.selection.extentOffset, 2);

      await _key(tester, LogicalKeyboardKey.keyW, control: true);
      expect(controller.text, 'e two three');
      expect(KillRing.shared.last, 'on');
    });

    _desktopTest('does nothing when the setting is off', (tester) async {
      final controller = TextEditingController(text: 'one two');
      addTearDown(controller.dispose);
      await _pumpField(tester, controller, emacsKeys: false);
      controller.value = controller.value.copyWith(
        selection: const TextSelection.collapsed(offset: 0),
      );
      await tester.pump();

      await _key(tester, LogicalKeyboardKey.keyK, control: true);
      expect(controller.text, 'one two');
      expect(KillRing.shared.last, isNull);
    });
  });

  group('the C-c layer', () {
    Future<int> calls(WidgetTester tester, {required bool enabled}) async {
      _window(tester);
      var calls = 0;
      final focus = FocusNode();
      addTearDown(focus.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HarnessKeyLayer(
              enabled: enabled,
              commands: {
                LogicalKeyboardKey.keyK: () => calls++,
                LogicalKeyboardKey.keyS: () => calls++,
              },
              child: TextField(focusNode: focus),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      focus.requestFocus();
      await tester.pump();
      await _chord(tester, LogicalKeyboardKey.keyK);
      return calls;
    }

    _desktopTest('runs the command after C-c', (tester) async {
      expect(await calls(tester, enabled: true), 1);
    });

    _desktopTest('leaves the keys alone when switched off', (tester) async {
      expect(await calls(tester, enabled: false), 0);
    });
  });

  group('in a conversation', () {
    _desktopTest('C-c C-c sends what was typed', (tester) async {
      final rig = await _rig();
      await _pumpApp(tester, rig);
      await _openSession(tester);
      final field = find.byKey(_field);
      expect(field, findsOneWidget);
      await tester.enterText(field, 'Sent by the keys');
      await tester.pump();
      await _chord(tester, LogicalKeyboardKey.keyC);
      await _settle(tester, 14);
      expect(rig.harness.prompts, contains('Sent by the keys'));
    });

    _desktopTest('C-c C-s opens the quick search', (tester) async {
      final rig = await _rig();
      await _pumpApp(tester, rig);
      await _openSession(tester);
      await tester.showKeyboard(find.byKey(_field));
      await _chord(tester, LogicalKeyboardKey.keyS);
      await _settle(tester, 6);
      expect(find.byType(QuickSearchScreen), findsOneWidget);
    });

    _desktopTest('C-c C-w copies the last reply', (tester) async {
      final rig = await _rig();
      await _pumpApp(tester, rig);
      await _openSession(tester);
      await tester.showKeyboard(find.byKey(_field));
      await _chord(tester, LogicalKeyboardKey.keyW);
      await tester.pump();
      expect(find.text('Last reply copied'), findsOneWidget);
    });
  });

  group('the settings page', () {
    testWidgets('offers the keys, and keeps what is chosen', (tester) async {
      final settings = await _settings();
      _window(tester, size: const Size(900, 1200));
      final app = AppController(settings: settings);
      addTearDown(app.dispose);
      await tester.pumpWidget(
        HarnessStyle(
          style: HarnessPlatformStyle.material,
          child: HarnessScope(
            app: app,
            settings: settings,
            child: MaterialApp(
              theme: HarnessTheme.material(Brightness.dark),
              home: SettingsScreen(app: app),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final list = find
          .descendant(
            of: find.byType(SettingsScreen),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(find.text('KEYS'), 300, scrollable: list);
      expect(find.text('KEYS'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Harness keys'),
        300,
        scrollable: list,
      );
      expect(find.text('Send with'), findsOneWidget);
      expect(find.text('Enter, or C-c C-c as in Emacs.'), findsOneWidget);
      expect(find.text('Enter'), findsOneWidget);
      expect(find.text('C-c C-c'), findsOneWidget);
      expect(find.text('Emacs editing'), findsOneWidget);
      expect(
        find.text('C-a, C-e, C-k, C-y, M-f and M-b in text fields.'),
        findsOneWidget,
      );
      expect(find.text('Harness keys'), findsOneWidget);
      expect(
        find.text(
          'C-c commands: send, stop, attach, search, copy reply, bottom.',
        ),
        findsOneWidget,
      );

      await tester.tap(find.text('C-c C-c'));
      await tester.pumpAndSettle();
      expect(settings.sendKey, SendKey.ctrlCctrlC);

      final emacs = find.byKey(const Key('settings-emacs-editing'));
      await tester.ensureVisible(emacs);
      await tester.tap(emacs);
      await tester.pumpAndSettle();
      expect(settings.emacsEditing, isTrue);

      final harness = find.byKey(const Key('settings-harness-keys'));
      await tester.ensureVisible(harness);
      await tester.tap(harness);
      await tester.pumpAndSettle();
      expect(settings.harnessKeys, isTrue);
    });

    testWidgets('the Keys section fits a phone at large text', (tester) async {
      final settings = await _settings();
      final app = AppController(settings: settings);
      addTearDown(app.dispose);
      _window(tester, size: const Size(390, 844));
      await tester.pumpWidget(
        HarnessStyle(
          style: HarnessPlatformStyle.material,
          child: HarnessScope(
            app: app,
            settings: settings,
            child: MaterialApp(
              theme: HarnessTheme.material(Brightness.dark),
              home: MediaQuery(
                data: const MediaQueryData(
                  size: Size(390, 844),
                  textScaler: TextScaler.linear(1.5),
                ),
                child: SettingsScreen(app: app),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final list = find
          .descendant(
            of: find.byType(SettingsScreen),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        find.text('Harness keys'),
        300,
        scrollable: list,
      );
      await tester.pumpAndSettle();
      expect(find.text('Harness keys'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
