// Pictures of going back into a harness: the connection banner over the
// screens when the connection was lost, and the card a device that
// remembers its harness shows while it goes back in, each naming the
// stage it is in and how long it has been going.
//
//   HARNESS_SHOTS=/some/directory flutter test test/resume_screenshots_test.dart
//
// writes a PNG for each case.  Without HARNESS_SHOTS the cases still run
// (they draw, and check that the stage is shown and the age ticks), and
// write nothing.  The harness is the fake one: the pictures show what
// the app draws of what a harness answers, not a real network.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/app.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';
import 'support/phone_fonts.dart';
import 'support/real_fonts.dart';

const _address = 'ws://memory/acp';
const _token = 'hs1_device';
const _width = 360.0;
const _height = 800.0;

/// The frame as a picture, and written to [path] when HARNESS_SHOTS
/// names a directory.
Future<void> _shoot(WidgetTester tester, GlobalKey frame, String name) async {
  final image = await tester.runAsync(() async {
    final boundary =
        frame.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    return boundary.toImage(pixelRatio: 2.0);
  });
  final directory = Platform.environment['HARNESS_SHOTS'];
  if (directory == null || directory.isEmpty) return;
  await tester.runAsync(() async {
    final data = await image!.toByteData(format: ui.ImageByteFormat.png);
    final file = File('$directory/$name.png');
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(data!.buffer.asUint8List());
  });
}

Future<GlobalKey> _open(WidgetTester tester, AppController app,
    SettingsController settings) async {
  tester.view.physicalSize = const Size(_width * 2, _height * 2);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final frame = GlobalKey();
  await tester.pumpWidget(
    RepaintBoundary(
      key: frame,
      child: HarnessApp(settings: settings, appController: app,
          themeBuilder: phoneFonts),
    ),
  );
  await tester.pump();
  return frame;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadRealFonts);

  testWidgets('the banner: the stage and its age over the screens',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsController();
    await settings.load();
    final harness = FakeHarness();
    final app = AppController(
      settings: settings,
      connector: harness.connector,
      reconnectDelays: const [Duration(seconds: 30)],
    );
    await app.connect(_address, token: _token);
    final frame = await _open(tester, app, settings);
    harness.refuseConnects = 1000000;
    await harness.dropConnection('The connection dropped.');
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('Connection lost. Reconnecting…'), findsOneWidget);
    expect(find.text('Waiting to retry · 3s'), findsOneWidget);
    await _shoot(tester, frame, 'android-resume-banner');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 31));
  });

  testWidgets('the resume card: the stage and its age on the way in',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'address': _address,
      'token': _token,
    });
    final settings = SettingsController();
    await settings.load();
    final harness = FakeHarness(signIn: true, knownSecrets: {_token})
      ..connectDelay = const Duration(seconds: 30);
    final app = AppController(
      settings: settings,
      connector: harness.connector,
      reconnectDelays: const [Duration(seconds: 30)],
    );
    final frame = await _open(tester, app, settings);
    await tester.pump(const Duration(seconds: 4));
    expect(find.byKey(const Key('resume-card')), findsOneWidget);
    expect(find.text('Connecting · 4s'), findsOneWidget);
    await _shoot(tester, frame, 'android-resume-card');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 31));
  });
}
