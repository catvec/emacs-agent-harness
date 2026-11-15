import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:path_provider/path_provider.dart';

import '../services/voice_audio_io.dart';
import '../voice/voice_audio.dart';
import 'media_capture.dart';

/// The Android foreground service that makes MediaProjection legal on
/// Android 14 and later.  The plugin asks for the projection consent; this
/// app-owned service is what Android requires to be running around it.
///
/// It is only a seam: a build without the native channel answers false, and
/// screen capture is then reported unavailable rather than crashing the
/// process with a SecurityException.
abstract class ScreenShareForegroundSeam {
  Future<bool> start();
  Future<void> stop();
}

class ScreenShareForeground implements ScreenShareForegroundSeam {
  const ScreenShareForeground();

  static const channel = MethodChannel('app.harness/screen_share');

  bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  Future<bool> start() async {
    if (!_isAndroid) return true;
    try {
      return await channel.invokeMethod<bool>('start') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<void> stop() async {
    if (!_isAndroid) return;
    try {
      await channel.invokeMethod<void>('stop');
    } on MissingPluginException {
      // No native bridge in this build.
    } on PlatformException {
      // The service is already gone.
    }
  }
}

/// The real capture adapter: flutter_webrtc's native camera and screen
/// capture, a full-size PNG per frame, and the existing microphone seam for
/// a bounded clip.
///
/// It loads no platform channel until a source is started, so a test that
/// injects a fake never reaches it.
/// The platform's own screen-capture request.  It shows the system's
/// projection consent dialog and does not return until the person
/// answers, so a test can put a fake here and see what the capture path
/// does around it.  The real one is flutter_webrtc's `getDisplayMedia`.
abstract class ScreenCaptureSource {
  Future<MediaStream> request(Map<String, Object?> constraints);
}

/// flutter_webrtc's own screen capture, which is what a build uses.
class WebRtcScreenCaptureSource implements ScreenCaptureSource {
  const WebRtcScreenCaptureSource();

  @override
  Future<MediaStream> request(Map<String, Object?> constraints) =>
      navigator.mediaDevices.getDisplayMedia(constraints);
}

class WebRtcMediaCapturePlatform implements MediaCapturePlatform {
  WebRtcMediaCapturePlatform({
    ScreenShareForegroundSeam? foreground,
    ScreenCaptureSource? screen,
  }) : _foreground = foreground ?? const ScreenShareForeground(),
       _screen = screen ?? const WebRtcScreenCaptureSource();

  final ScreenShareForegroundSeam _foreground;
  final ScreenCaptureSource _screen;

  MediaStream? _stream;
  MediaStreamTrack? _track;
  CaptureSource? _source;

  @override
  Future<Map<CaptureSource, CaptureCapability>> capabilities() async {
    if (kIsWeb) {
      // flutter_webrtc can open a browser camera or screen stream, but its
      // PNG capture is native only.  This build has no validated browser
      // frame path, so it says so instead of offering a control whose
      // `Frame to chat` and sampled frames could not work.
      return const {
        CaptureSource.microphone: CaptureCapability(available: true),
        CaptureSource.camera: CaptureCapability.unavailable(
          'web-frames-native-only',
        ),
        CaptureSource.screen: CaptureCapability.unavailable(
          'web-frames-native-only',
        ),
      };
    }
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => const {
        CaptureSource.microphone: CaptureCapability(available: true),
        CaptureSource.camera: CaptureCapability(
          available: true,
          foregroundOnly: true,
        ),
        CaptureSource.screen: CaptureCapability(
          available: true,
          foregroundOnly: true,
        ),
      },
      TargetPlatform.iOS => const {
        CaptureSource.microphone: CaptureCapability(available: true),
        CaptureSource.camera: CaptureCapability(
          available: true,
          foregroundOnly: true,
        ),
        CaptureSource.screen: CaptureCapability.unavailable(
          'ios-screen-share-needs-broadcast-extension',
        ),
      },
      TargetPlatform.macOS ||
      TargetPlatform.windows ||
      TargetPlatform.linux => const {
        CaptureSource.microphone: CaptureCapability(available: true),
        CaptureSource.camera: CaptureCapability(available: true),
        CaptureSource.screen: CaptureCapability(available: true),
      },
      TargetPlatform.fuchsia => const {
        CaptureSource.microphone: CaptureCapability.unavailable(
          'no-microphone-path',
        ),
        CaptureSource.camera: CaptureCapability.unavailable('no-camera-path'),
        CaptureSource.screen: CaptureCapability.unavailable(
          'no-screen-capture-path',
        ),
      },
    };
  }

  @override
  Future<MediaStreamTrack?> startVisual(
    CaptureSource source, {
    required int width,
    required int height,
    required int fps,
  }) async {
    await stopVisual();
    final constraints = <String, Object?>{
      'audio': false,
      'video': <String, Object?>{
        'width': width,
        'height': height,
        'frameRate': fps,
        if (source == CaptureSource.camera) 'facingMode': 'user',
      },
    };
    try {
      if (source == CaptureSource.screen) {
        if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
          throw const MediaCaptureException(
            CaptureState.unavailable,
            'ios-screen-share-needs-broadcast-extension',
          );
        }
        // The projection is asked for first, and the foreground
        // service only once the person has granted it.  Android 14+
        // refuses a `mediaProjection` foreground service before that
        // grant (`startForeground` throws `SecurityException: ...
        // requires ... [android:project_media]`), and the refusal used
        // to kill the app; a device showed exactly that.  The consent
        // dialog is what `getDisplayMedia` shows, and it does not return
        // until the person answers, so the service starts here.
        _stream = await _screen.request(constraints);
        final foreground = await _foreground.start();
        if (!foreground) {
          throw const MediaCaptureException(
            CaptureState.unavailable,
            'screen-share-foreground-service',
          );
        }
      } else {
        _stream = await navigator.mediaDevices.getUserMedia(constraints);
      }
      final tracks = _stream?.getVideoTracks() ?? const <MediaStreamTrack>[];
      if (tracks.isEmpty) {
        await stopVisual();
        throw const MediaCaptureException(
          CaptureState.unavailable,
          'no-video-track',
        );
      }
      _track = tracks.first;
      _source = source;
      _track!.enabled = true;
      return _track;
    } catch (error) {
      await _foreground.stop();
      if (error is MediaCaptureException) rethrow;
      throw _asCaptureException(error);
    }
  }

  @override
  Future<void> setVisualPaused(bool paused) async {
    final track = _track;
    if (track != null) track.enabled = !paused;
  }

  @override
  Future<void> stopVisual() async {
    final wasScreen = _source == CaptureSource.screen;
    _track = null;
    _source = null;
    final stream = _stream;
    _stream = null;
    if (stream != null) {
      for (final track in stream.getTracks()) {
        try {
          await track.stop();
        } catch (_) {
          // Already stopped.
        }
      }
      try {
        await stream.dispose();
      } catch (_) {
        // Already disposed.
      }
    }
    if (wasScreen) await _foreground.stop();
  }

  @override
  Future<Uint8List> capturePng() async {
    final track = _track;
    if (track == null) {
      throw const MediaCaptureException(
        CaptureState.revoked,
        'no-live-video-track',
      );
    }
    try {
      final buffer = await track.captureFrame();
      final bytes = buffer.asUint8List();
      await _deleteTemporaryFrame();
      return Uint8List.fromList(bytes);
    } catch (error) {
      if (error is MediaCaptureException) rethrow;
      throw _asCaptureException(error);
    }
  }

  /// flutter_webrtc writes the frame to this one path before handing back
  /// its bytes.  Delete it at once: the app keeps no raw media.
  Future<void> _deleteTemporaryFrame() async {
    try {
      final directory = await getTemporaryDirectory();
      final file = File('${directory.path}/captureFrame.png');
      if (await file.exists()) await file.delete();
    } catch (_) {
      // A cache file that cannot be removed is not a reason to lose the
      // frame; the next capture overwrites it.
    }
  }

  @override
  Future<CapturedAudio> recordAudioClip(Duration max) async {
    final microphone = RecordVoiceMicrophone();
    final chunks = BytesBuilder(copy: false);
    StreamSubscription<Uint8List>? subscription;
    try {
      subscription = microphone.frames.listen(chunks.add);
      await microphone.start();
      await Future<void>.delayed(max);
      await microphone.stop();
      await subscription.cancel();
      subscription = null;
      final pcm = chunks.takeBytes();
      final data = ByteData.sublistView(pcm);
      final samples = Int16List(pcm.length ~/ 2);
      for (var i = 0; i < samples.length; i++) {
        samples[i] = data.getInt16(i * 2, Endian.little);
      }
      final wav = encodeWav(samples, sampleRate: microphone.sampleRate);
      return CapturedAudio(
        wav: wav,
        duration: Duration(
          milliseconds:
              (samples.length / microphone.sampleRate * 1000).round(),
        ),
        capturedAt: DateTime.now(),
      );
    } catch (error) {
      await subscription?.cancel();
      await microphone.stop().catchError((Object _) {});
      if (error is MediaCaptureException) rethrow;
      throw _asCaptureException(error);
    }
  }

  MediaCaptureException _asCaptureException(Object error) {
    final text = '$error'.toLowerCase();
    if (text.contains('permission') ||
        text.contains('denied') ||
        text.contains('notallowed')) {
      return MediaCaptureException(CaptureState.denied, '$error');
    }
    if (text.contains('revoked')) {
      return MediaCaptureException(CaptureState.revoked, '$error');
    }
    if (text.contains('not found') ||
        text.contains('notfound') ||
        text.contains('no camera') ||
        text.contains('unavailable') ||
        text.contains('user didn\'t give permission')) {
      return MediaCaptureException(CaptureState.unavailable, '$error');
    }
    return MediaCaptureException(CaptureState.error, '$error');
  }

  @override
  Future<void> dispose() => stopVisual();
}
