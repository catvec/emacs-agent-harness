// Pictures of the memory page, with sample notes only.
//
//   HARNESS_SHOTS=/some/directory flutter test test/memory_screenshots_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/models/workspace.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/memory_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:harness_client/src/ui/adaptive/platform_style.dart';
import 'package:harness_client/src/ui/screens/memory_screen.dart';
import 'package:harness_client/src/ui/theme/harness_theme.dart';

import 'support/real_fonts.dart';

const _workspace = WorkspaceSummary(id: 'w1', name: 'Home');

Future<GlobalKey> _show(WidgetTester tester, double width, double height) async {
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
  final controller = MemoryController.preview();
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
            child: MemoryScreen(
              app: app,
              workspace: _workspace,
              controller: controller,
            ),
          ),
        ),
      ),
    ),
  );
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
  return boundary;
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

  testWidgets('memory on a phone', (tester) async {
    final boundary = await _show(tester, 390, 844);
    expect(find.text('Memory'), findsWidgets);
    expect(find.text('# Kitchen renovation'), findsWidgets);
    expect(tester.takeException(), isNull);
    if (shots != null) await _write(tester, boundary, '$shots/memory-phone.png');
  });

  testWidgets('memory on a desktop', (tester) async {
    final boundary = await _show(tester, 1440, 900);
    expect(find.text('Search memory'), findsOneWidget);
    expect(tester.takeException(), isNull);
    if (shots != null) await _write(tester, boundary, '$shots/memory-desktop.png');
  });
}
