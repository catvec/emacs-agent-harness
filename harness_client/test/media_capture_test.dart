import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/media/media_capture.dart';

import 'support/media_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'camera starts, a frame is bounded and a second source stops the first',
    () async {
      final platform = FakeMediaCapturePlatform();
      platform.png = await syntheticPng(width: 1200, height: 800);
      final capture = MediaCaptureSession(platform: platform);

      await capture.start(CaptureSource.camera);
      expect(capture.status.state, CaptureState.live);
      expect(capture.status.source, CaptureSource.camera);
      expect(platform.started, [CaptureSource.camera]);

      final frame = await capture.captureFrame();
      expect(frame, isNotNull);
      expect(frame!.source, CaptureSource.camera);
      expect(frame.width, lessThanOrEqualTo(640));
      expect(frame.height, lessThanOrEqualTo(360));
      expect(frame.byteLength, lessThanOrEqualTo(184320));
      expect(capture.status.framesCaptured, 1);

      await capture.start(CaptureSource.screen);
      expect(platform.started, [CaptureSource.camera, CaptureSource.screen]);
      expect(platform.stopped, 1);
      expect(capture.status.source, CaptureSource.screen);

      await capture.stop();
      expect(capture.status.state, CaptureState.off);
      expect(platform.stopped, 2);
    },
  );

  test('a preview is smaller and is not counted as a sent frame', () async {
    final platform = FakeMediaCapturePlatform();
    platform.png = await syntheticPng(width: 1200, height: 800);
    final capture = MediaCaptureSession(platform: platform);
    await capture.start(CaptureSource.screen);

    final preview = await capture.captureFrame(preview: true);
    expect(preview, isNotNull);
    expect(preview!.width, lessThanOrEqualTo(320));
    expect(preview.height, lessThanOrEqualTo(180));
    expect(capture.status.framesCaptured, 0);
  });

  test('permission denial is a state, not a live capture', () async {
    final platform = FakeMediaCapturePlatform(
      failStart: const MediaCaptureException(
        CaptureState.denied,
        'permission denied',
      ),
    );
    final capture = MediaCaptureSession(platform: platform);
    await expectLater(
      capture.start(CaptureSource.camera),
      throwsA(isA<MediaCaptureException>()),
    );
    expect(capture.status.state, CaptureState.denied);
    expect(capture.status.detail, contains('denied'));
    expect(capture.videoTrack, isNull);
  });

  test('pause disables the track and resume re-enables it', () async {
    final platform = FakeMediaCapturePlatform();
    final capture = MediaCaptureSession(platform: platform);
    await capture.start(CaptureSource.camera);
    await capture.pause();
    expect(capture.status.state, CaptureState.paused);
    expect(platform.paused, 1);
    await capture.resume();
    expect(capture.status.state, CaptureState.live);
    expect(platform.resumed, 1);
  });

  test(
    'backgrounding stops capture and says suspended, and never resumes',
    () async {
      final platform = FakeMediaCapturePlatform();
      final capture = MediaCaptureSession(platform: platform);
      await capture.start(CaptureSource.screen);
      await capture.handleLifecycle(AppLifecycleState.paused);
      expect(capture.status.state, CaptureState.suspended);
      expect(capture.status.detail, 'app-backgrounded');
      expect(platform.stopped, 1);
      await capture.handleLifecycle(AppLifecycleState.resumed);
      expect(capture.status.state, CaptureState.suspended);
      expect(platform.started, [CaptureSource.screen]);
    },
  );

  test('the OS taking a permission back is a revoked state', () async {
    final platform = FakeMediaCapturePlatform();
    final capture = MediaCaptureSession(platform: platform);
    await capture.start(CaptureSource.camera);
    await capture.markRevoked('projection-stopped');
    expect(capture.status.state, CaptureState.revoked);
    expect(capture.status.detail, 'projection-stopped');
    expect(capture.status.transmitting, isFalse);
  });

  test(
    'a microphone clip is refused while voice owns the microphone',
    () async {
      final platform = FakeMediaCapturePlatform();
      final capture = MediaCaptureSession(platform: platform);
      capture.microphoneInUse = true;
      await expectLater(
        capture.captureAudioClip(),
        throwsA(isA<MediaCaptureException>()),
      );
      expect(platform.clips, 0);
      final caps = await capture.capabilities();
      expect(caps[CaptureSource.microphone]!.available, isFalse);
      expect(caps[CaptureSource.microphone]!.reason, 'microphone-in-use');
    },
  );

  test(
    'a bounded audio clip is returned when the microphone is free',
    () async {
      final platform = FakeMediaCapturePlatform();
      final capture = MediaCaptureSession(platform: platform);
      final clip = await capture.captureAudioClip(
        max: const Duration(milliseconds: 10),
      );
      expect(clip, isNotNull);
      expect(clip!.mimeType, 'audio/wav');
      expect(platform.clips, 1);
      expect(capture.status.state, CaptureState.off);
    },
  );

  test('the platform bounds are what the session asks for', () async {
    final platform = FakeMediaCapturePlatform();
    final capture = MediaCaptureSession(
      platform: platform,
      bounds: const CaptureBounds(width: 320, height: 180, fps: 5),
    );
    await capture.start(CaptureSource.camera);
    expect(platform.started, [CaptureSource.camera]);
    final frame = await capture.captureFrame();
    expect(frame!.width, lessThanOrEqualTo(320));
    expect(frame.height, lessThanOrEqualTo(180));
  });

  test('a source the platform lacks changes nothing', () async {
    final platform = FakeMediaCapturePlatform(
      capabilities: const {
        CaptureSource.camera: CaptureCapability(available: true),
        CaptureSource.screen: CaptureCapability.unavailable('no-screen'),
        CaptureSource.microphone: CaptureCapability(available: true),
      },
    );
    final capture = MediaCaptureSession(platform: platform);
    await expectLater(
      capture.start(CaptureSource.screen),
      throwsA(isA<MediaCaptureException>()),
    );
    expect(platform.started, isEmpty);
    expect(capture.status.state, CaptureState.unavailable);
  });
}
