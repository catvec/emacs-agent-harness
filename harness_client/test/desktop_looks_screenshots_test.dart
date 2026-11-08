// Pictures of the desktop looks: the same pages under Windows' Fluent, Linux's
// Adwaita, Apple's Cupertino and Android's Material 3, at the size of a
// desktop window and at the size of a narrow one, light and dark, and the
// Settings row that chooses them.
//
//   HARNESS_SHOTS=/some/directory flutter test test/desktop_looks_screenshots_test.dart
//
// writes a PNG for each case there.  Without HARNESS_SHOTS the cases still
// draw, check that nothing overflows, and write nothing.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/app.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:harness_client/src/ui/screens/settings_screen.dart';
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
  required PreviewPlatform platform,
  required Size size,
  bool dark = false,
  GlobalKey? boundary,
}) async {
  final rig = await _rig();
  await rig.settings.setPreviewPlatform(platform);
  if (dark) await rig.settings.setThemeMode(ThemeMode.dark);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    RepaintBoundary(
      key: boundary,
      child: HarnessApp(
        settings: rig.settings,
        appController: rig.app,
        themeBuilder: phoneFonts,
      ),
    ),
  );
  await tester.pump();
  await _settle(tester);
  return rig;
}

Future<void> _shot(WidgetTester tester, GlobalKey frame, String name) async {
  final shots = Platform.environment['HARNESS_SHOTS'];
  if (shots == null || shots.isEmpty) return;
  await tester.runAsync(() async {
    final boundary =
        frame.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1.5);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('$shots/$name.png');
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(data!.buffer.asUint8List());
    image.dispose();
  });
}

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  await loadRealFonts();

  const desktop = Size(1280, 900);
  const narrow = Size(420, 800);

  const looks = {
    'desktop-windows-sessions': (
      PreviewPlatform.windows,
      desktop,
      'Sessions',
      false,
    ),
    'desktop-windows-dark': (
      PreviewPlatform.windows,
      desktop,
      'Sessions',
      true,
    ),
    'desktop-linux-sessions': (
      PreviewPlatform.linux,
      desktop,
      'Sessions',
      false,
    ),
    'desktop-linux-dark': (PreviewPlatform.linux, desktop, 'Sessions', true),
    'desktop-macos-sessions': (
      PreviewPlatform.cupertino,
      desktop,
      'Sessions',
      false,
    ),
    'desktop-android-sessions': (
      PreviewPlatform.material,
      desktop,
      'Sessions',
      false,
    ),
    'desktop-windows-narrow': (
      PreviewPlatform.windows,
      narrow,
      'Sessions',
      false,
    ),
    'desktop-linux-narrow': (PreviewPlatform.linux, narrow, 'Sessions', false),
  };

  for (final MapEntry(key: name, value: (platform, size, page, dark))
      in looks.entries) {
    testWidgets('draws $name', (tester) async {
      final boundary = GlobalKey();
      await _pump(
        tester,
        platform: platform,
        size: size,
        dark: dark,
        boundary: boundary,
      );

      // The page is the same under every look.
      expect(find.text(page), findsWidgets);
      // A wide window has the navigation pane; a narrow one, the bottom bar.
      expect(
        find.byKey(const Key('sidebar-item-sessions')),
        size.width >= 920 ? findsOneWidget : findsNothing,
      );
      expect(
        find.byType(NavigationBar),
        size.width >= 920 ? findsNothing : findsOneWidget,
      );

      await _shot(tester, boundary, name);
    });
  }

  Future<void> settingsShot(
    WidgetTester tester,
    String name,
    PreviewPlatform platform,
  ) async {
    final rig = await _rig();
    await rig.settings.setPreviewPlatform(platform);
    tester.view.physicalSize = desktop;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final boundary = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: HarnessApp(
          settings: rig.settings,
          appController: rig.app,
          themeBuilder: phoneFonts,
        ),
      ),
    );
    await tester.pump();
    await _settle(tester);
    await tester.tap(find.byKey(const Key('sidebar-item-settings')));
    await _settle(tester);
    expect(find.text('Look'), findsOneWidget);
    expect(find.byKey(const Key('look-active')), findsOneWidget);
    await _shot(tester, boundary, name);
  }

  testWidgets('draws desktop-windows-settings', (tester) async {
    await settingsShot(
      tester,
      'desktop-windows-settings',
      PreviewPlatform.windows,
    );
  });

  testWidgets('draws desktop-linux-settings', (tester) async {
    await settingsShot(tester, 'desktop-linux-settings', PreviewPlatform.linux);
  });

  testWidgets('draws desktop-apple-settings', (tester) async {
    await settingsShot(
      tester,
      'desktop-apple-settings',
      PreviewPlatform.cupertino,
    );
  });

  testWidgets('draws desktop-look-menu', (tester) async {
    final rig = await _rig();
    await rig.settings.setPreviewPlatform(PreviewPlatform.windows);
    tester.view.physicalSize = desktop;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final boundary = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: HarnessApp(
          settings: rig.settings,
          appController: rig.app,
          themeBuilder: phoneFonts,
        ),
      ),
    );
    await tester.pump();
    await _settle(tester);
    await tester.tap(find.byKey(const Key('sidebar-item-settings')));
    await _settle(tester);
    final scrollable = find
        .descendant(
          of: find.byType(SettingsScreen),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.byKey(const Key('look-select')),
      200,
      scrollable: scrollable,
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('look-select')));
    await _settle(tester);
    for (final label in const [
      'System',
      'Android',
      'Apple',
      'Windows',
      'Linux',
    ]) {
      expect(find.widgetWithText(ListTile, label), findsOneWidget);
    }
    await _shot(tester, boundary, 'desktop-look-menu');
  });
}
