import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/media/media_capture.dart';
import 'package:harness_client/src/models/session_media.dart';
import 'package:harness_client/src/voice/voice_controller.dart';
import 'package:harness_client/src/voice/voice_settings.dart';

import 'support/media_fakes.dart';
import 'support/voice_fakes.dart';

SessionMediaCapabilities _sessionMedia({bool vision = true}) =>
    SessionMediaCapabilities(
      session: 'session-1',
      endpoint: 'session/prompt',
      images: true,
      vision: vision,
      model: 'demo:sees',
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

Future<MediaCaptureSession> _capture({CaptureBounds? bounds}) async {
  final platform = FakeMediaCapturePlatform();
  platform.png = await syntheticPng(width: 800, height: 600);
  return MediaCaptureSession(
    platform: platform,
    bounds:
        bounds ??
        const CaptureBounds(sampleInterval: Duration(milliseconds: 10)),
  );
}

/// Wait for a condition, rather than guessing how long a frame takes.
Future<void> _until(
  bool Function() done, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  final watch = Stopwatch()..start();
  while (!done() && watch.elapsed < timeout) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a video-track provider gets the live track and one-step stop detaches it',
    () async {
      final session = FakeSession()..media = _sessionMedia();
      final backend = FakeBackend()
        ..delivery = const MediaDelivery(tracks: true, frames: false);
      final capture = await _capture();
      final controller = _controller(
        session: session,
        backend: backend,
        capture: capture,
      );
      addTearDown(controller.dispose);

      await controller.start();
      await controller.prepareMedia();
      expect(controller.mediaDelivery.tracks, isTrue);

      await controller.startMedia(CaptureSource.camera);
      expect(controller.mediaStatus.state, CaptureState.live);
      expect(backend.attachedSource, CaptureSource.camera);
      expect(controller.mediaStateLabel, 'Camera live');

      await controller.stopMedia();
      expect(backend.detachCalls, greaterThanOrEqualTo(1));
      expect(controller.mediaStatus.state, CaptureState.off);
      controller.dispose();
    },
  );

  test(
    'a frame-only provider is sampled at the interval and never called live',
    () async {
      final session = FakeSession()..media = _sessionMedia();
      final backend = FakeBackend()
        ..delivery = const MediaDelivery(tracks: false, frames: true);
      final capture = await _capture();
      final controller = _controller(
        session: session,
        backend: backend,
        capture: capture,
      );
      addTearDown(controller.dispose);
      await controller.start();
      await controller.prepareMedia();

      await controller.startMedia(CaptureSource.camera);
      expect(controller.mediaStateLabel, 'Camera frames · 1/s');
      await _until(() => backend.framesSent.isNotEmpty);
      expect(backend.framesSent, isNotEmpty);
      expect(controller.mediaDelivery.tracks, isFalse);

      await controller.stopMedia();
      expect(backend.detachCalls, greaterThanOrEqualTo(0));
      controller.dispose();
    },
  );

  test(
    'a workspace-style provider takes one frame per press, not a loop',
    () async {
      final session = FakeSession()..media = _sessionMedia();
      final backend = FakeBackend();
      final capture = await _capture();
      final controller = _controller(
        session: session,
        backend: backend,
        capture: capture,
      );
      addTearDown(controller.dispose);
      await controller.start();
      await controller.prepareMedia();

      await controller.startMedia(CaptureSource.screen);
      expect(controller.mediaStateLabel, 'Screen preview');
      expect(controller.canFrameToChat, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(backend.framesSent, isEmpty);

      await controller.sendFrameToChat();
      expect(session.frames, hasLength(1));
      expect(session.frames.single.source, CaptureSource.screen);
      expect(controller.framesSent, 1);
      controller.dispose();
    },
  );

  test(
    'no video delivery and no vision says so and releases the camera',
    () async {
      final session = FakeSession()..media = _sessionMedia(vision: false);
      final backend = FakeBackend();
      final capture = await _capture();
      final controller = _controller(
        session: session,
        backend: backend,
        capture: capture,
      );
      addTearDown(controller.dispose);
      await controller.start();
      await controller.prepareMedia();

      await controller.startMedia(CaptureSource.camera);
      expect(controller.mediaStatus.state, CaptureState.off);
      expect(controller.mediaProblem, 'No video · voice model');
      controller.dispose();
    },
  );

  test('pause stops sampling and resume keeps the same source', () async {
    final session = FakeSession()..media = _sessionMedia();
    final backend = FakeBackend()
      ..delivery = const MediaDelivery(tracks: false, frames: true);
    final capture = await _capture();
    final controller = _controller(
      session: session,
      backend: backend,
      capture: capture,
    );
    addTearDown(controller.dispose);
    await controller.start();
    await controller.prepareMedia();
    await controller.startMedia(CaptureSource.camera);
    await _until(() => backend.framesSent.isNotEmpty);

    await controller.pause();
    expect(controller.mediaStatus.state, CaptureState.paused);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final afterPause = backend.framesSent.length;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(backend.framesSent.length, afterPause);

    await controller.resume();
    expect(controller.mediaStatus.state, CaptureState.live);
    await _until(() => backend.framesSent.length > afterPause);
    expect(backend.framesSent.length, greaterThan(afterPause));
    controller.dispose();
  });

  test('ending the call stops the camera and its preview', () async {
    final session = FakeSession()..media = _sessionMedia();
    final backend = FakeBackend();
    final capture = await _capture();
    final controller = _controller(
      session: session,
      backend: backend,
      capture: capture,
    );
    await controller.start();
    await controller.prepareMedia();
    await controller.startMedia(CaptureSource.camera);
    expect(controller.mediaStatus.state, CaptureState.live);

    await controller.stop();
    expect(controller.mediaStatus.state, CaptureState.off);
    expect(controller.mediaPreview, isNull);
    controller.dispose();
  });

  test('the one-step stop is named for the source that is live', () async {
    final session = FakeSession();
    final backend = FakeBackend();
    final capture = MediaCaptureSession(platform: FakeMediaCapturePlatform());
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
    addTearDown(controller.dispose);
    controller.mediaStatus = const CaptureStatus(
      source: CaptureSource.camera,
      state: CaptureState.live,
    );
    expect(controller.mediaStopLabel, 'Stop camera');
    controller.mediaStatus = const CaptureStatus(
      source: CaptureSource.screen,
      state: CaptureState.live,
    );
    expect(controller.mediaStopLabel, 'Stop screen share');
  });

  test(
    'a provider that refuses the track does not leave a live camera',
    () async {
      final session = FakeSession()..media = _sessionMedia();
      final backend = FakeBackend()
        ..delivery = const MediaDelivery(tracks: true)
        ..attachFails = true;
      final capture = await _capture();
      final controller = _controller(
        session: session,
        backend: backend,
        capture: capture,
      );
      addTearDown(controller.dispose);
      await controller.start();
      await controller.prepareMedia();
      await controller.startMedia(CaptureSource.camera);

      expect(controller.mediaStatus.state, CaptureState.off);
      expect(controller.mediaProblem, 'No video · track refused');
      expect(controller.mediaStateLabel, 'Camera off');
    },
  );
}
