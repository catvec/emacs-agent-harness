// Pictures of camera and phone-screen sharing in the voice screen.
//
//   HARNESS_SHOTS=/some/directory flutter test test/media_screenshots_test.dart
//
// Every state is a fixture: a scripted capture platform and a scripted
// backend, not a camera, a screen or a provider.  What is real is the widget,
// the controller's state machine and the frame bytes (drawn synthetically).
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/media/media_capture.dart';
import 'package:harness_client/src/models/session_media.dart';
import 'package:harness_client/src/ui/adaptive/platform_style.dart';
import 'package:harness_client/src/ui/screens/voice_screen.dart';
import 'package:harness_client/src/ui/theme/harness_theme.dart';
import 'package:harness_client/src/voice/voice_controller.dart';
import 'package:harness_client/src/voice/voice_settings.dart';

import 'support/media_fakes.dart';
import 'support/real_fonts.dart';
import 'support/voice_fakes.dart';

class _Rig {
  _Rig(this.controller, this.backend, this.capture);

  final VoiceController controller;
  final FakeBackend backend;
  final MediaCaptureSession capture;
}

Future<_Rig> _rig({
  MediaDelivery delivery = const MediaDelivery.none(),
  bool vision = true,
  Object? failStart,
  WidgetTester? tester,
}) async {
  final session = FakeSession()
    ..media = SessionMediaCapabilities(
      session: 'session-1',
      images: true,
      vision: vision,
      model: 'demo:sees',
    );
  final backend = FakeBackend()..delivery = delivery;
  final platform = FakeMediaCapturePlatform(failStart: failStart);
  platform.png = tester == null
      ? await syntheticPng(width: 800, height: 600)
      : (await tester.runAsync(() => syntheticPng(width: 800, height: 600)))!;
  final capture = MediaCaptureSession(platform: platform);
  final controller = VoiceController(
    settings: const VoiceSettings(
      provider: VoiceProvider.clip,
      clipDelivery: ClipDelivery.audioPrompt,
    ),
    bridge: session,
    harnessAddress: '',
    backendFactory: (_, _) => backend,
    onSettingsChanged: (_) async {},
    capture: capture,
  );
  await controller.start();
  await controller.prepareMedia();
  return _Rig(controller, backend, capture);
}

Widget _app(Widget child) => HarnessStyle(
  style: HarnessPlatformStyle.material,
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: HarnessTheme.material(Brightness.dark),
    home: child,
  ),
);

Future<void> _size(WidgetTester tester, double width, double height) async {
  const ratio = 2.0;
  tester.view.physicalSize = Size(width * ratio, height * ratio);
  tester.view.devicePixelRatio = ratio;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _write(
  WidgetTester tester,
  GlobalKey boundary,
  String path,
) async {
  await tester.runAsync(() async {
    final render =
        boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await render.toImage(pixelRatio: 1.5);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File(path);
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(data!.buffer.asUint8List());
  });
}

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  final shots = Platform.environment['HARNESS_SHOTS'];
  await loadRealFonts();

  testWidgets('phone: camera ready for one frame to the workspace', (
    tester,
  ) async {
    final rig = await _rig(tester: tester);
    await rig.controller.startMedia(CaptureSource.camera);
    final preview = await tester.runAsync(
      () => syntheticPng(width: 64, height: 36),
    );
    rig.controller.mediaPreview = MediaPreview(
      preview!,
      DateTime(2026, 11, 8, 12),
    );
    final boundary = GlobalKey();
    await _size(tester, 390, 844);
    await tester.pumpWidget(
      _app(
        RepaintBoundary(
          key: boundary,
          child: VoiceScreen(
            controller: rig.controller,
            attached: true,
            onEnd: () async {},
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));
    // A widget test decodes no image until real time runs: let the preview
    // arrive, so the picture shows the frame a person would see.
    final shown = rig.controller.mediaPreview!;
    final context = tester.element(find.byKey(const Key('voice-media-bar')));
    await tester.runAsync(() => precacheImage(MemoryImage(shown.png), context));
    await tester.pump();

    expect(find.text('Stop camera'), findsOneWidget);
    expect(find.text('Camera preview'), findsOneWidget);
    expect(find.text('Frame to chat'), findsOneWidget);
    expect(tester.takeException(), isNull);
    if (shots != null) {
      await _write(tester, boundary, '$shots/media/phone-camera-ready.png');
    }
    rig.controller.dispose();
  });

  testWidgets('phone: a live track and a screen share that is frames', (
    tester,
  ) async {
    final rig = await _rig(
      tester: tester,
      delivery: const MediaDelivery(tracks: true),
    );
    await rig.controller.startMedia(CaptureSource.camera);
    final boundary = GlobalKey();
    await tester.pumpWidget(
      _app(
        RepaintBoundary(
          key: boundary,
          child: VoiceScreen(controller: rig.controller, attached: true),
        ),
      ),
    );
    await _size(tester, 390, 844);
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Camera live'), findsOneWidget);
    expect(find.text('Stop camera'), findsOneWidget);
    if (shots != null) {
      await _write(tester, boundary, '$shots/media/phone-camera-live.png');
    }
    rig.controller.dispose();
  });

  testWidgets('desktop: screen frames at one per second', (tester) async {
    final rig = await _rig(
      tester: tester,
      delivery: const MediaDelivery(frames: true, maxFps: 1),
    );
    await rig.controller.startMedia(CaptureSource.screen);
    final boundary = GlobalKey();
    await _size(tester, 1280, 800);
    await tester.pumpWidget(
      _app(
        RepaintBoundary(
          key: boundary,
          child: VoiceScreen(controller: rig.controller, attached: true),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Screen frames · 1/s'), findsOneWidget);
    expect(find.text('Stop screen share'), findsOneWidget);
    if (shots != null) {
      await _write(tester, boundary, '$shots/media/desktop-screen-frames.png');
    }
    rig.controller.dispose();
  });

  testWidgets('phone: paused, and a model without vision', (tester) async {
    final paused = await _rig(tester: tester);
    await paused.controller.startMedia(CaptureSource.camera);
    await paused.controller.pause();
    final pausedBoundary = GlobalKey();
    await _size(tester, 390, 844);
    await tester.pumpWidget(
      _app(
        RepaintBoundary(
          key: pausedBoundary,
          child: VoiceScreen(controller: paused.controller, attached: true),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Camera paused'), findsOneWidget);
    if (shots != null) {
      await _write(
        tester,
        pausedBoundary,
        '$shots/media/phone-camera-paused.png',
      );
    }
    paused.controller.dispose();

    final unsupported = await _rig(tester: tester, vision: false);
    await unsupported.controller.startMedia(CaptureSource.camera);
    final unsupportedBoundary = GlobalKey();
    await tester.pumpWidget(
      _app(
        RepaintBoundary(
          key: unsupportedBoundary,
          child: VoiceScreen(
            controller: unsupported.controller,
            attached: true,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('No video · voice model'), findsOneWidget);
    if (shots != null) {
      await _write(
        tester,
        unsupportedBoundary,
        '$shots/media/phone-vision-unsupported.png',
      );
    }
    unsupported.controller.dispose();
  });
}
