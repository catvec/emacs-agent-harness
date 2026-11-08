// Pictures of the keys: the Settings › Keys section and the message box
// with C-c C-c to send.
//
//   HARNESS_SHOTS=/some/directory flutter test test/keyboard_screenshots_test.dart
//
// writes a PNG for each case there.  Without HARNESS_SHOTS the cases still
// draw, check that nothing overflows, and write nothing.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:harness_client/src/ui/adaptive/platform_style.dart';
import 'package:harness_client/src/ui/app_scope.dart';
import 'package:harness_client/src/ui/screens/settings_screen.dart';
import 'package:harness_client/src/ui/theme/harness_theme.dart';
import 'package:harness_client/src/ui/widgets/message_composer.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/real_fonts.dart';

Future<SettingsController> _settings() async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsController();
  await settings.load();
  return settings;
}

void _window(WidgetTester tester, {required Size size}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 24);
  tester.view.padding = tester.view.viewPadding;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPadding);
  addTearDown(tester.view.resetViewPadding);
}

Future<GlobalKey> _pump(
  WidgetTester tester,
  AppController app,
  Widget page, {
  required Size size,
  Brightness brightness = Brightness.light,
}) async {
  _window(tester, size: size);
  final settings = app.settings;
  final boundary = GlobalKey();
  await tester.pumpWidget(
    RepaintBoundary(
      key: boundary,
      child: HarnessStyle(
        style: HarnessPlatformStyle.material,
        child: HarnessScope(
          app: app,
          settings: settings,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: HarnessTheme.material(brightness),
            home: page,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return boundary;
}

Future<void> _write(
  WidgetTester tester,
  GlobalKey boundary,
  String path,
) async {
  await tester.runAsync(() async {
    final object =
        boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await object.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File(path);
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  final shots = Platform.environment['HARNESS_SHOTS'];
  setUpAll(() async {
    await loadRealFonts();
  });

  testWidgets('Settings › Keys', (tester) async {
    final settings = await _settings();
    final app = AppController(settings: settings);
    addTearDown(app.dispose);
    final boundary = await _pump(
      tester,
      app,
      SettingsScreen(app: app),
      size: const Size(900, 1200),
    );
    final list = find
        .descendant(
          of: find.byType(SettingsScreen),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(find.text('KEYS'), 300, scrollable: list);
    await tester.pumpAndSettle();
    expect(find.text('Send with'), findsOneWidget);
    expect(find.text('C-c C-c'), findsOneWidget);
    expect(tester.takeException(), isNull);
    if (shots != null) {
      await _write(tester, boundary, '$shots/keys-settings.png');
    }
  });

  testWidgets('the message box with C-c C-c to send', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      final settings = await _settings();
      await settings.setSendKey(SendKey.ctrlCctrlC);
      final app = AppController(settings: settings);
      addTearDown(app.dispose);
      final boundary = await _pump(
        tester,
        app,
        Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: MessageComposer(
              onSend: (_, _) => true,
              onStop: () {},
              running: false,
              cancelling: false,
              canAttach: true,
            ),
          ),
        ),
        size: const Size(900, 400),
        brightness: Brightness.dark,
      );
      expect(find.text('Message · C-c C-c to send'), findsOneWidget);
      expect(
        find.text('C-c C-c to send · Enter for a new line'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      if (shots != null) {
        await _write(tester, boundary, '$shots/keys-composer.png');
      }
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
