import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/media/media_capture.dart';
import 'package:harness_client/src/models/session_media.dart';
import 'package:harness_client/src/ui/widgets/voice_media_bar.dart';
import 'package:harness_client/src/voice/voice_controller.dart';
import 'package:harness_client/src/voice/voice_settings.dart';

import 'support/media_fakes.dart';
import 'support/voice_fakes.dart';

SessionMediaCapabilities _media({bool? vision = true}) =>
    SessionMediaCapabilities(
      session: 'session-1',
      images: true,
      vision: vision,
      model: 'demo:model',
    );

VoiceController _controller({
  required FakeSession session,
  required FakeBackend backend,
  required MediaCaptureSession capture,
}) => VoiceController(
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

Widget _host(VoiceController controller) => MaterialApp(
  home: Scaffold(
    body: Center(child: VoiceMediaBar(controller: controller)),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the bar names the sources and says when nothing is shared', (
    tester,
  ) async {
    final session = FakeSession()..media = _media();
    final backend = FakeBackend();
    final platform = FakeMediaCapturePlatform();
    final capture = MediaCaptureSession(platform: platform);
    final controller = _controller(
      session: session,
      backend: backend,
      capture: capture,
    );
    addTearDown(controller.dispose);
    await controller.start();
    await controller.prepareMedia();
    await tester.pumpWidget(_host(controller));

    expect(find.text('Camera'), findsOneWidget);
    expect(find.text('Screen'), findsOneWidget);
    expect(find.text('Frame to chat'), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('media-status'))).data,
      'Camera and screen off',
    );
    expect(
      find.byTooltip('Frame to chat · no live camera or screen'),
      findsOneWidget,
    );
    final status = tester.getSemantics(
      find.byKey(const Key('media-status-node')),
    );
    expect(status.label, 'Camera and screen off');
    expect(status.hasFlag(SemanticsFlag.isLiveRegion), isTrue);
    controller.dispose();
    await tester.pump();
  });

  testWidgets(
    'a live camera says ready, offers Stop camera and stops in one tap',
    (tester) async {
      final session = FakeSession()..media = _media();
      final backend = FakeBackend();
      final platform = FakeMediaCapturePlatform();
      platform.png = await tester.runAsync(syntheticPng);
      final capture = MediaCaptureSession(platform: platform);
      final controller = _controller(
        session: session,
        backend: backend,
        capture: capture,
      );
      addTearDown(controller.dispose);
      await controller.start();
      await controller.prepareMedia();
      await controller.startMedia(CaptureSource.camera);
      await tester.pumpWidget(_host(controller));

      expect(find.text('Stop camera'), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('media-status'))).data,
        'Camera preview',
      );
      expect(find.byTooltip('Frame to chat'), findsOneWidget);
      expect(find.byTooltip('Camera'), findsOneWidget);
      controller.dispose();
      await tester.pump();
    },
  );

  testWidgets('a provider without vision is not offered a frame', (
    tester,
  ) async {
    final session = FakeSession()..media = _media(vision: false);
    final backend = FakeBackend();
    final platform = FakeMediaCapturePlatform();
    final capture = MediaCaptureSession(platform: platform);
    final controller = _controller(
      session: session,
      backend: backend,
      capture: capture,
    );
    addTearDown(controller.dispose);
    await controller.start();
    await controller.prepareMedia();
    await controller.startMedia(CaptureSource.camera);
    await tester.pumpWidget(_host(controller));

    expect(
      tester.widget<Text>(find.byKey(const Key('media-problem'))).data,
      'No video · voice model',
    );
    final frame = tester.widget<OutlinedButton>(
      find.descendant(
        of: find.byKey(const Key('media-frame-to-chat')),
        matching: find.byType(OutlinedButton),
      ),
    );
    expect(frame.onPressed, isNull);
    controller.dispose();
    await tester.pump();
  });

  testWidgets('an iOS-style screen limitation is a noun, not a false control', (
    tester,
  ) async {
    final session = FakeSession()..media = _media();
    final backend = FakeBackend();
    final platform = FakeMediaCapturePlatform(
      capabilities: const {
        CaptureSource.camera: CaptureCapability(
          available: true,
          foregroundOnly: true,
        ),
        CaptureSource.screen: CaptureCapability.unavailable(
          'ios-screen-share-needs-broadcast-extension',
        ),
        CaptureSource.microphone: CaptureCapability(available: true),
      },
    );
    final capture = MediaCaptureSession(platform: platform);
    final controller = _controller(
      session: session,
      backend: backend,
      capture: capture,
    );
    addTearDown(controller.dispose);
    await controller.start();
    await controller.prepareMedia();
    await tester.pumpWidget(_host(controller));

    expect(
      find.byTooltip('Screen · needs a broadcast extension'),
      findsOneWidget,
    );
    expect(find.byTooltip('Camera · foreground only'), findsOneWidget);
    controller.dispose();
    await tester.pump();
  });

  testWidgets('a preview is drawn from a captured frame, and only in memory', (
    tester,
  ) async {
    final session = FakeSession()..media = _media();
    final backend = FakeBackend();
    final platform = FakeMediaCapturePlatform();
    platform.png = await tester.runAsync(syntheticPng);
    final capture = MediaCaptureSession(platform: platform);
    final controller = _controller(
      session: session,
      backend: backend,
      capture: capture,
    );
    addTearDown(controller.dispose);
    await controller.start();
    await controller.prepareMedia();
    await controller.startMedia(CaptureSource.camera);
    final preview = await tester.runAsync(
      () => syntheticPng(width: 64, height: 36),
    );
    controller.mediaPreview = MediaPreview(preview!, DateTime.now());
    await tester.pumpWidget(_host(controller));

    expect(find.byKey(const Key('media-preview')), findsOneWidget);
    controller.dispose();
    await tester.pump();
  });

  testWidgets('every capture state is a noun this bar says', (tester) async {
    final session = FakeSession()..media = _media();
    final backend = FakeBackend();
    final capture = MediaCaptureSession(platform: FakeMediaCapturePlatform());
    final controller = _controller(
      session: session,
      backend: backend,
      capture: capture,
    );
    addTearDown(controller.dispose);
    const expected = {
      CaptureState.off: 'Camera off',
      CaptureState.starting: 'Camera starting',
      CaptureState.live: 'Camera preview',
      CaptureState.paused: 'Camera paused',
      CaptureState.denied: 'Camera permission denied',
      CaptureState.revoked: 'Camera permission revoked',
      CaptureState.unavailable: 'Camera unavailable',
      CaptureState.foregroundOnly: 'Camera foreground only',
      CaptureState.suspended: 'Camera suspended',
      CaptureState.error: 'Camera failed',
    };
    for (final entry in expected.entries) {
      controller.mediaStatus = CaptureStatus(
        source: CaptureSource.camera,
        state: entry.key,
      );
      await tester.pumpWidget(_host(controller));
      expect(
        tester.widget<Text>(find.byKey(const Key('media-status'))).data,
        entry.value,
        reason: entry.key.name,
      );
    }
    controller.mediaStatus = const CaptureStatus();
    await tester.pumpWidget(_host(controller));
    expect(
      tester.widget<Text>(find.byKey(const Key('media-status'))).data,
      'Camera and screen off',
    );
  });

  testWidgets('a capability reason and a missing answer are tooltips', (
    tester,
  ) async {
    final session = FakeSession()..media = _media();
    final backend = FakeBackend();
    final capture = MediaCaptureSession(platform: FakeMediaCapturePlatform());
    final controller = _controller(
      session: session,
      backend: backend,
      capture: capture,
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(_host(controller));
    expect(find.byTooltip('Camera · checking'), findsOneWidget);
    expect(find.byTooltip('Screen · checking'), findsOneWidget);

    controller.mediaCapabilities = const {
      CaptureSource.camera: CaptureCapability.unavailable('microphone-in-use'),
      CaptureSource.screen: CaptureCapability.unavailable('no-screen'),
    };
    await tester.pumpWidget(_host(controller));
    expect(find.byTooltip('Camera · microphone in use'), findsOneWidget);
    expect(find.byTooltip('Screen · unavailable'), findsOneWidget);
  });

  testWidgets('a denied camera, a frame limit and unknown vision each say so', (
    tester,
  ) async {
    final session = FakeSession()..media = _media(vision: false);
    final backend = FakeBackend();
    final platform = FakeMediaCapturePlatform(
      failStart: const MediaCaptureException(
        CaptureState.denied,
        'permission denied',
      ),
    );
    final capture = MediaCaptureSession(platform: platform);
    final controller = _controller(
      session: session,
      backend: backend,
      capture: capture,
    );
    addTearDown(controller.dispose);
    await controller.start();
    await controller.prepareMedia();
    await controller.startMedia(CaptureSource.camera);
    await tester.pumpWidget(_host(controller));
    expect(
      tester.widget<Text>(find.byKey(const Key('media-status'))).data,
      'Camera permission denied',
    );
    expect(find.byKey(const Key('media-problem')), findsNothing);
    expect(
      find.byTooltip('Frame to chat · no live camera or screen'),
      findsOneWidget,
    );

    controller.mediaStatus = const CaptureStatus(
      source: CaptureSource.camera,
      state: CaptureState.live,
    );
    await tester.pumpWidget(_host(controller));
    expect(
      find.byTooltip('Frame to chat · model without vision'),
      findsOneWidget,
    );

    controller.frameProblem = 'Frame limit · 1 minute';
    await tester.pumpWidget(_host(controller));
    expect(
      tester.widget<Text>(find.byKey(const Key('media-frame-problem'))).data,
      'Frame limit · 1 minute',
    );

    session.media = _media(vision: null);
    await controller.prepareMedia();
    controller.mediaStatus = const CaptureStatus(
      source: CaptureSource.camera,
      state: CaptureState.live,
    );
    await tester.pumpWidget(_host(controller));
    expect(find.text('Vision unconfirmed'), findsOneWidget);
    expect(
      find.byTooltip('Frame to chat · vision unconfirmed'),
      findsOneWidget,
    );

    controller.sessionMedia = null;
    await tester.pumpWidget(_host(controller));
    expect(find.text('Vision unconfirmed'), findsNothing);
    expect(find.byTooltip('Frame to chat · harness not ready'), findsOneWidget);
  });
}
