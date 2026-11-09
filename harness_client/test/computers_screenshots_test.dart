// Pictures of the Computers surface, with mock data only.
//
//   HARNESS_SHOTS=/some/directory flutter test test/computers_screenshots_test.dart
//
// writes a PNG for each case there.  Without HARNESS_SHOTS the cases still
// draw, check that nothing overflows, and write nothing.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/models/computer.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/computers_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:harness_client/src/ui/adaptive/platform_style.dart';
import 'package:harness_client/src/ui/screens/computer_screen.dart';
import 'package:harness_client/src/ui/screens/computers_screen.dart';
import 'package:harness_client/src/ui/theme/harness_theme.dart';

import 'support/fake_rfb.dart';
import 'support/real_fonts.dart';

Future<(GlobalKey, ComputersController)> _show(
  WidgetTester tester, {
  required double width,
  required double height,
  ComputersController? controller,
  double textScale = 1,
}) async {
  tester.view.physicalSize = Size(width * 2, height * 2);
  tester.view.devicePixelRatio = 2;
  tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 24);
  tester.view.padding = tester.view.viewPadding;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPadding);
  addTearDown(tester.view.resetViewPadding);

  final boundary = GlobalKey();
  final settings = SettingsController();
  final app = AppController(settings: settings);
  final shown = controller ?? ComputersController.preview();
  await tester.pumpWidget(
    RepaintBoundary(
      key: boundary,
      child: HarnessStyle(
        style: HarnessPlatformStyle.material,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: HarnessTheme.material(Brightness.light),
          home: MediaQuery(
            data: MediaQueryData(
              size: Size(width, height),
              textScaler: TextScaler.linear(textScale),
            ),
            child: ComputersScreen(app: app, controller: shown),
          ),
        ),
      ),
    ),
  );
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 90));
  }
  return (boundary, shown);
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

  testWidgets('computers on a phone', (tester) async {
    final (boundary, controller) = await _show(
      tester,
      width: 390,
      height: 844,
    );
    expect(find.text('Machines'), findsWidgets);
    expect(find.text('marcuse'), findsWidgets);
    expect(find.text('Connected'), findsWidgets);
    expect(find.text('View'), findsWidgets);
    expect(find.text('Control'), findsWidgets);
    expect(find.text('Revocation'), findsWidgets);
    expect(find.text('Grant'), findsOneWidget);
    expect(find.text('Preference'), findsWidgets);
    expect(controller.canManage, isFalse);
    expect(tester.takeException(), isNull);
    if (shots != null) {
      await _write(tester, boundary, '$shots/computers-phone.png');
    }
  });

  testWidgets('computers on a desktop', (tester) async {
    final (boundary, _) = await _show(
      tester,
      width: 1440,
      height: 900,
    );
    expect(find.text('Computer use'), findsOneWidget);
    expect(find.text('Screens, pointer, keyboard, sandbox'), findsOneWidget);
    expect(find.text('harness'), findsWidgets);
    expect(tester.takeException(), isNull);
    if (shots != null) {
      await _write(tester, boundary, '$shots/computers-desktop.png');
    }
  });

  testWidgets('a computer screen', (tester) async {
    final controller = ComputersController.preview();
    final boundary = GlobalKey();
    tester.view.physicalSize = const Size(780, 1688);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final settings = SettingsController();
    final app = AppController(settings: settings);
    final computer = controller.computers.first;
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: HarnessStyle(
          style: HarnessPlatformStyle.material,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: HarnessTheme.material(Brightness.light),
            home: MediaQuery(
              data: const MediaQueryData(size: Size(390, 844)),
              child: ComputerScreen(
                app: app,
                computer: computer,
                controller: controller,
                vncTransportFactory: (_) =>
                    FakeRfbTransport(width: 640, height: 400),
              ),
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 90));
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 120)),
    );
    await tester.pump();
    expect(find.text('View only'), findsOneWidget);
    expect(find.text('marcuse'), findsWidgets);
    expect(tester.takeException(), isNull);
    if (shots != null) {
      await _write(tester, boundary, '$shots/computer-screen.png');
    }
  });

  testWidgets('this client', (tester) async {
    final (boundary, _) = await _show(tester, width: 390, height: 844);
    for (var i = 0;
        i < 12 && find.text('THIS CLIENT').evaluate().isEmpty;
        i++) {
      await tester.drag(find.byType(ListView), const Offset(0, -400));
      await tester.pump();
    }
    expect(find.text('THIS CLIENT'), findsOneWidget);
    expect(find.text('This phone'), findsOneWidget);
    expect(find.text('Not registered'), findsOneWidget);
    expect(find.text('Registration'), findsOneWidget);
    expect(find.text('File import'), findsOneWidget);
    expect(find.text('Capture only · no pointer or keyboard control'), findsOneWidget);
    expect(tester.takeException(), isNull);
    if (shots != null) {
      await _write(tester, boundary, '$shots/computers-phone-client.png');
    }
  });

  testWidgets('no computers', (tester) async {
    final controller = ComputersController.preview();
    controller.computers = const <Computer>[];
    controller.resources = const <ComputerResource>[];
    controller.access = const ComputerAccess(session: 's1');
    final (boundary, _) = await _show(
      tester,
      width: 390,
      height: 844,
      controller: controller,
    );
    expect(find.text('No computers'), findsOneWidget);
    expect(find.text('No resources'), findsOneWidget);
    expect(find.text('No session'), findsNothing);
    expect(tester.takeException(), isNull);
    if (shots != null) {
      await _write(tester, boundary, '$shots/computers-empty.png');
    }
  });

  testWidgets('a computer at a large text size', (tester) async {
    final (boundary, _) = await _show(
      tester,
      width: 390,
      height: 844,
      textScale: 1.5,
    );
    expect(find.text('Computers'), findsOneWidget);
    expect(tester.takeException(), isNull);
    if (shots != null) {
      await _write(tester, boundary, '$shots/computers-phone-large.png');
    }
  });
}
