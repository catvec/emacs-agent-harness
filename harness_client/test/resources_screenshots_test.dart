// Pictures of the Resources surface, with mock metadata only.
//
//   HARNESS_SHOTS=/some/directory flutter test test/resources_screenshots_test.dart
//
// writes a PNG for each case there.  Without HARNESS_SHOTS the cases still
// draw, check that nothing overflows, and write nothing.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/models/workspace.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/resources_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:harness_client/src/ui/adaptive/platform_style.dart';
import 'package:harness_client/src/ui/screens/resources_screen.dart';
import 'package:harness_client/src/ui/theme/harness_theme.dart';

import 'support/real_fonts.dart';

const _workspace = WorkspaceSummary(id: 'w1', name: 'Home');

Future<(GlobalKey, ResourcesController)> _show(
  WidgetTester tester, {
  required double width,
  required double height,
}) async {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 24);
  tester.view.padding = tester.view.viewPadding;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPadding);
  addTearDown(tester.view.resetViewPadding);

  final boundary = GlobalKey();
  final settings = SettingsController();
  final app = AppController(settings: settings);
  final controller = ResourcesController.preview();
  await tester.pumpWidget(
    RepaintBoundary(
      key: boundary,
      child: HarnessStyle(
        style: HarnessPlatformStyle.material,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: HarnessTheme.material(Brightness.light),
          home: MediaQuery(
            data: MediaQueryData(size: Size(width, height)),
            child: ResourcesScreen(
              app: app,
              workspace: _workspace,
              controller: controller,
            ),
          ),
        ),
      ),
    ),
  );
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
  return (boundary, controller);
}

Future<void> _write(WidgetTester tester, GlobalKey boundary, String path) async {
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

  testWidgets('resources on a phone', (tester) async {
    final (boundary, controller) = await _show(tester, width: 390, height: 844);
    expect(find.text('Browser'), findsOneWidget);
    expect(find.text('Preview · no changes'), findsOneWidget);
    expect(controller.canManage, isFalse);
    expect(tester.takeException(), isNull);
    if (shots != null) {
      await _write(tester, boundary, '$shots/resources-phone.png');
    }
  });

  testWidgets('a site on a phone', (tester) async {
    final (boundary, _) = await _show(tester, width: 390, height: 844);
    await tester.tap(find.text('stoneco.example').first);
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Site data deletion'), findsOneWidget);
    expect(tester.takeException(), isNull);
    if (shots != null) {
      await _write(tester, boundary, '$shots/resources-phone-site.png');
    }
  });

  testWidgets('the wallet on a desktop', (tester) async {
    final (boundary, _) = await _show(tester, width: 1440, height: 900);
    await tester.tap(find.text('Wallet'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Visa •••• 4242'), findsWidgets);
    expect(find.text('Advisory · no broker'), findsWidgets);
    expect(tester.takeException(), isNull);
    if (shots != null) {
      await _write(tester, boundary, '$shots/resources-wallet-desktop.png');
    }
  });

  testWidgets('credentials on a desktop', (tester) async {
    final (boundary, _) = await _show(tester, width: 1440, height: 900);
    await tester.tap(find.text('Credentials').last);
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Secrets module'), findsOneWidget);
    expect(find.text('deploy-key'), findsOneWidget);
    expect(tester.takeException(), isNull);
    if (shots != null) {
      await _write(tester, boundary, '$shots/resources-credentials-desktop.png');
    }
  });

  testWidgets('access and audit on a desktop', (tester) async {
    final (boundary, _) = await _show(tester, width: 1440, height: 900);
    await tester.tap(find.text('Access'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Audit'), findsOneWidget);
    expect(tester.takeException(), isNull);
    if (shots != null) {
      await _write(tester, boundary, '$shots/resources-access-desktop.png');
    }
  });
}
