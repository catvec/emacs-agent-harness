import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_webrtc/flutter_webrtc.dart' show MediaStreamTrack;
import 'package:harness_client/src/media/media_capture.dart';

/// A scripted capture platform: no device, no platform channel, real bytes.
class FakeMediaCapturePlatform implements MediaCapturePlatform {
  FakeMediaCapturePlatform({
    Map<CaptureSource, CaptureCapability>? capabilities,
    this.png,
    this.audio,
    this.failStart,
  }) : _capabilities =
           capabilities ??
           const {
             CaptureSource.microphone: CaptureCapability(available: true),
             CaptureSource.camera: CaptureCapability(available: true),
             CaptureSource.screen: CaptureCapability(available: true),
           };

  final Map<CaptureSource, CaptureCapability> _capabilities;
  Uint8List? png;
  CapturedAudio? audio;
  Object? failStart;

  final List<CaptureSource> started = <CaptureSource>[];
  int stopped = 0;
  int paused = 0;
  int resumed = 0;
  int captured = 0;
  int clips = 0;
  bool disposed = false;
  String? lastScreenReason;

  @override
  Future<Map<CaptureSource, CaptureCapability>> capabilities() async =>
      _capabilities;

  @override
  Future<MediaStreamTrack?> startVisual(
    CaptureSource source, {
    required int width,
    required int height,
    required int fps,
  }) async {
    if (failStart != null) throw failStart!;
    started.add(source);
    return null;
  }

  @override
  Future<void> setVisualPaused(bool paused) async {
    if (paused) {
      this.paused++;
    } else {
      resumed++;
    }
  }

  @override
  Future<void> stopVisual() async {
    stopped++;
  }

  @override
  Future<Uint8List> capturePng() async {
    captured++;
    return png ?? Uint8List.fromList(_transparentPng);
  }

  @override
  Future<CapturedAudio> recordAudioClip(Duration max) async {
    clips++;
    return audio ??
        CapturedAudio(
          wav: Uint8List.fromList(const [82, 73, 70, 70]),
          duration: const Duration(seconds: 1),
          capturedAt: DateTime.now(),
        );
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

/// A 1x1 transparent PNG, valid bytes for a codec that must decode one.
const _transparentPng = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, //
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, //
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, //
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, //
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, //
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, //
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, //
  0x42, 0x60, 0x82,
];

/// A synthetic frame of the requested size, encoded as PNG.  It is not a
/// picture of anyone's screen: the pixels are drawn here, so a test can put
/// real bytes through the real decoder and bounds without a device.
Future<Uint8List> syntheticPng({
  int width = 640,
  int height = 360,
  ui.Color color = const ui.Color(0xFF203040),
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..color = color,
  );
  canvas.drawRect(
    ui.Rect.fromLTWH(8, 8, width * 0.3, height * 0.2),
    ui.Paint()..color = const ui.Color(0xFFD65A36),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  if (data == null) throw StateError('synthetic PNG failed');
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}
