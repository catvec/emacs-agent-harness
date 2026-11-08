// The desktop looks as a person meets them: a Windows window drawn as
// Fluent, a Linux one as Adwaita, and the Settings row that names them.  The
// page is the same under every look; the palette, the type and the shape of
// the controls are the desktop's own.
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/app.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:harness_client/src/ui/adaptive/platform_style.dart';
import 'package:harness_client/src/ui/screens/settings_screen.dart';
import 'package:harness_client/src/ui/theme/harness_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';
import 'support/phone_fonts.dart';
import 'support/real_fonts.dart';

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

Future<void> _settle(WidgetTester tester, [int rounds = 12]) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

Future<_Rig> _pump(
  WidgetTester tester, {
  PreviewPlatform platform = PreviewPlatform.system,
  Size size = const Size(1280, 900),
}) async {
  final rig = await _rig();
  await rig.settings.setPreviewPlatform(platform);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    HarnessApp(
      settings: rig.settings,
      appController: rig.app,
      themeBuilder: phoneFonts,
    ),
  );
  await tester.pump();
  await _settle(tester);
  return rig;
}

Future<void> _openSettings(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('sidebar-item-settings')));
  await _settle(tester);
}

/// A choice of the open Look menu: Material draws it as a sheet of rows,
/// Cupertino as an action sheet.
Finder _menuItem(String label) => find.descendant(
  of: find.byWidgetPredicate(
    (widget) => widget is ListTile || widget is CupertinoActionSheet,
  ),
  matching: find.text(label),
);

Future<void> _showLookMenu(WidgetTester tester) async {
  final select = find.byKey(const Key('look-select'));
  final scrollable = find
      .descendant(
        of: find.byType(SettingsScreen),
        matching: find.byType(Scrollable),
      )
      .first;
  await tester.scrollUntilVisible(select, 200, scrollable: scrollable);
  await tester.pump();
  await tester.tap(select);
  await _settle(tester);
}

String _activeLook(WidgetTester tester) {
  final text = tester.widget<Text>(find.byKey(const Key('look-active')));
  return text.data!;
}

Color _primary(WidgetTester tester) =>
    Theme.of(tester.element(find.byType(SettingsScreen))).colorScheme.primary;

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  await loadRealFonts();

  group('drawing a desktop', () {
    const looks = {
      PreviewPlatform.windows: (
        HarnessPlatformStyle.windows,
        Color(0xFF0067C0),
      ),
      PreviewPlatform.linux: (HarnessPlatformStyle.linux, Color(0xFF3584E4)),
      PreviewPlatform.cupertino: (
        HarnessPlatformStyle.cupertino,
        HarnessColors.oxide,
      ),
      PreviewPlatform.material: (
        HarnessPlatformStyle.material,
        HarnessColors.oxide,
      ),
    };

    for (final MapEntry(key: preview, value: (look, primary))
        in looks.entries) {
      testWidgets('${preview.name}: the same page under its look', (
        tester,
      ) async {
        await _pump(tester, platform: preview);
        final context = tester.element(
          find.byKey(const Key('sidebar-item-sessions')),
        );
        expect(HarnessStyle.lookOf(context), look);
        expect(Theme.of(context).colorScheme.primary, primary);
        expect(find.text('Sessions'), findsWidgets);
        expect(
          find.byKey(const Key('sidebar-item-sessions')),
          findsOneWidget,
          reason: 'a desktop window has the navigation pane',
        );
        expect(find.byType(NavigationBar), findsNothing);
      });
    }

    for (final preview in const [
      PreviewPlatform.windows,
      PreviewPlatform.linux,
    ]) {
      testWidgets('${preview.name}: a narrow window keeps the bottom bar', (
        tester,
      ) async {
        await _pump(tester, platform: preview, size: const Size(420, 800));
        final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
        expect(bar, isNotNull);
        expect(find.byKey(const Key('sidebar-item-sessions')), findsNothing);
        final height = Theme.of(tester.element(find.byType(NavigationBar)))
            .navigationBarTheme
            .height;
        expect(
          height,
          preview == PreviewPlatform.windows ? 64 : 72,
          reason: 'the bar is as tall as the desktop draws its own',
        );
      });
    }

    testWidgets('each desktop sizes its sidebar rows as its system does', (
      tester,
    ) async {
      await _pump(tester, platform: PreviewPlatform.windows);
      final text = tester.widget<Text>(
        find.descendant(
          of: find.byKey(const Key('sidebar-item-sessions')),
          matching: find.text('Sessions'),
        ),
      );
      expect(text.style?.fontSize, 13);
      expect(text.style?.fontWeight, FontWeight.w600);
    });

    testWidgets('GNOME draws them larger, with its own weight', (tester) async {
      await _pump(tester, platform: PreviewPlatform.linux);
      final text = tester.widget<Text>(
        find.descendant(
          of: find.byKey(const Key('sidebar-item-sessions')),
          matching: find.text('Sessions'),
        ),
      );
      expect(text.style?.fontSize, 15);
      expect(text.style?.fontWeight, FontWeight.w700);
    });

    testWidgets('Windows marks the page in use with a bar at the start', (
      tester,
    ) async {
      await _pump(tester, platform: PreviewPlatform.windows);
      expect(find.byKey(const Key('sidebar-accent-bar')), findsOneWidget);
    });

    testWidgets('Linux marks it with a pill, not a bar', (tester) async {
      await _pump(tester, platform: PreviewPlatform.linux);
      expect(find.byKey(const Key('sidebar-accent-bar')), findsNothing);
    });
  });

  group('Settings › Look', () {
    testWidgets('names every look, and the one in use', (tester) async {
      final rig = await _pump(tester, platform: PreviewPlatform.windows);
      await _openSettings(tester);

      // The row: a noun, a noun phrase, and the look in use, nothing more.
      expect(find.text('Look'), findsOneWidget);
      expect(find.text("System, or a platform's controls"), findsOneWidget);
      expect(_activeLook(tester), 'Fluent');
      // A desktop names a group of settings in sentence case, as its own
      // settings app does, not in the brand's tracked upper case.
      expect(find.text('Connection'), findsOneWidget);
      expect(find.text('CONNECTION'), findsNothing);
      expect(find.text('Appearance'), findsOneWidget);
      expect(find.text('APPEARANCE'), findsNothing);
      expect(
        find.text('Cupertino navigation, sheets and typography are active.'),
        findsNothing,
      );

      await _showLookMenu(tester);
      for (final label in const [
        'System',
        'Android',
        'Apple',
        'Windows',
        'Linux',
      ]) {
        expect(
          _menuItem(label),
          findsOneWidget,
          reason: 'the menu names $label',
        );
      }

      await tester.tap(_menuItem('Linux'));
      await _settle(tester);
      expect(rig.settings.previewPlatform, PreviewPlatform.linux);
      expect(_activeLook(tester), 'Adwaita');
      expect(_primary(tester), const Color(0xFF3584E4));
      expect(find.text('APPEARANCE'), findsNothing);
      expect(find.text('Appearance'), findsOneWidget);

      await _showLookMenu(tester);
      await tester.tap(_menuItem('Windows'));
      await _settle(tester);
      expect(_activeLook(tester), 'Fluent');
      expect(_primary(tester), const Color(0xFF0067C0));

      await _showLookMenu(tester);
      await tester.tap(_menuItem('Apple'));
      await _settle(tester);
      expect(_activeLook(tester), 'Cupertino');

      await _showLookMenu(tester);
      await tester.tap(_menuItem('Android'));
      await _settle(tester);
      expect(_activeLook(tester), 'Material 3');

      // System is the platform this build runs on: Android in the tests.
      await _showLookMenu(tester);
      await tester.tap(_menuItem('System'));
      await _settle(tester);
      expect(rig.settings.previewPlatform, PreviewPlatform.system);
      expect(_activeLook(tester), 'Material 3');
      expect(
        HarnessStyle.lookOf(tester.element(find.byType(SettingsScreen))),
        HarnessPlatformStyle.material,
      );
    });

    testWidgets('a narrow window reaches the same row', (tester) async {
      await _pump(
        tester,
        platform: PreviewPlatform.linux,
        size: const Size(420, 800),
      );
      await tester.tap(find.text('Settings'));
      await _settle(tester);
      await _showLookMenu(tester);
      for (final label in const [
        'System',
        'Android',
        'Apple',
        'Windows',
        'Linux',
      ]) {
        expect(_menuItem(label), findsOneWidget);
      }
      await tester.tap(_menuItem('Windows'));
      await _settle(tester);
      expect(_activeLook(tester), 'Fluent');
    });
  });
}
