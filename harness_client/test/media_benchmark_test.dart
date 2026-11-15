// What one frame costs on this machine, in real timestamps.
//
//   flutter test test/media_benchmark_test.dart
//
// The bytes are a synthetic photograph-like PNG, not a camera or a person's
// screen.  The work measured is the app's own: decode the platform's frame,
// downscale it inside the published bounds, encode it again, and build the
// JSON message a data channel or an ACP prompt would carry.  It is a local
// measurement, not a network or provider latency.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/media/media_capture.dart';
import 'package:harness_client/src/services/voice_webrtc.dart';

import 'support/media_fakes.dart';

/// A PNG whose pixels are noise, so its size is like a photograph's rather
/// than a flat test rectangle's.  Drawn here; no camera or screen is read.
Future<Uint8List> _noisePng(int width, int height) async {
  final pixels = Uint8List(width * height * 4);
  var seed = 123456789;
  for (var i = 0; i < pixels.length; i += 4) {
    seed = (1103515245 * seed + 12345) & 0x7fffffff;
    pixels[i] = seed & 0xff;
    pixels[i + 1] = (seed >> 8) & 0xff;
    pixels[i + 2] = (seed >> 16) & 0xff;
    pixels[i + 3] = 255;
  }
  final image = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    pixels,
    width,
    height,
    ui.PixelFormat.rgba8888,
    image.complete,
  );
  final decoded = await image.future;
  final data = await decoded.toByteData(format: ui.ImageByteFormat.png);
  decoded.dispose();
  if (data == null) throw StateError('noise PNG failed');
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

int _percentile(List<int> sorted, double fraction) =>
    sorted[(sorted.length * fraction).ceil() - 1];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'one bounded frame costs what it costs, in measured milliseconds',
    () async {
      final platform = FakeMediaCapturePlatform();
      platform.png = await _noisePng(1280, 720);
      final capture = MediaCaptureSession(platform: platform);
      addTearDown(capture.dispose);
      await capture.start(CaptureSource.camera);

      final elapsed = <int>[];
      var outputBytes = 0;
      var wireBytes = 0;
      for (var i = 0; i < 3; i++) {
        final watch = Stopwatch()..start();
        final frame = await capture.captureFrame();
        final message = harnessFrameMessage(frame!, i);
        watch.stop();
        expect(frame.width, lessThanOrEqualTo(640));
        expect(frame.height, lessThanOrEqualTo(360));
        expect(frame.byteLength, lessThanOrEqualTo(184320));
        elapsed.add(watch.elapsedMilliseconds);
        outputBytes = frame.byteLength;
        wireBytes = jsonEncode(message).length;
        // ignore: avoid_print
        print(
          'MEDIA-BENCH frame=$i app_ms=${watch.elapsedMilliseconds} '
          'png_bytes=$outputBytes json_bytes=$wireBytes '
          'size=${frame.width}x${frame.height}',
        );
      }
      final sorted = [...elapsed]..sort();
      // ignore: avoid_print
      print(
        'MEDIA-BENCH summary frames=${elapsed.length} '
        'p50_ms=${_percentile(sorted, 0.5)} '
        'p95_ms=${_percentile(sorted, 1.0)} '
        'max_png_bytes=$outputBytes max_json_bytes=$wireBytes',
      );
      // A cap on a runaway, not a target: the local work is expected to be a
      // few hundred milliseconds and must never hold a call for seconds.
      expect(_percentile(sorted, 1.0), lessThan(5000));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'a flat screen frame keeps the full 640x360 within the same bound',
    () async {
      final platform = FakeMediaCapturePlatform();
      platform.png = await syntheticPng(width: 1280, height: 720);
      final capture = MediaCaptureSession(platform: platform);
      addTearDown(capture.dispose);
      await capture.start(CaptureSource.screen);
      final watch = Stopwatch()..start();
      final frame = await capture.captureFrame();
      watch.stop();
      expect(frame, isNotNull);
      expect(frame!.width, 640);
      expect(frame.height, 360);
      expect(frame.byteLength, lessThanOrEqualTo(184320));
      // ignore: avoid_print
      print(
        'MEDIA-BENCH screen app_ms=${watch.elapsedMilliseconds} '
        'png_bytes=${frame.byteLength} size=${frame.width}x${frame.height}',
      );
      expect(watch.elapsedMilliseconds, lessThan(5000));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
