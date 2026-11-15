import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Color;
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_webrtc/flutter_webrtc.dart' show MediaStreamTrack;

/// A source the app can capture for a person.
///
/// [microphone] is a bounded clip for a tool call; live microphone audio is
/// still the voice stack's `VoiceMicrophone`, so there is only ever one
/// recorder.  [camera] and [screen] are the visual sources this module owns.
enum CaptureSource { microphone, camera, screen }

extension CaptureSourceName on CaptureSource {
  /// A noun for a label.  Not a sentence.
  String get label => switch (this) {
    CaptureSource.microphone => 'Microphone',
    CaptureSource.camera => 'Camera',
    CaptureSource.screen => 'Screen',
  };

  bool get isVisual => this != CaptureSource.microphone;
}

/// What a source is doing, as the platform and the app can honestly say.
enum CaptureState {
  off,
  starting,
  live,
  paused,

  /// The OS or the person refused the permission.
  denied,

  /// It was granted, then taken back while the app held it.
  revoked,

  /// The platform or the endpoint has no such source.
  unavailable,

  /// The source needs the app in front, or a foreground service.
  foregroundOnly,

  /// The app went to the background; capture was stopped, not resumed.
  suspended,

  /// A failure that is not a permission decision.
  error,
}

extension CaptureStateName on CaptureState {
  /// A noun phrase or adjective, as every interface label is.
  String get label => switch (this) {
    CaptureState.off => 'Off',
    CaptureState.starting => 'Starting',
    CaptureState.live => 'Live',
    CaptureState.paused => 'Paused',
    CaptureState.denied => 'Permission denied',
    CaptureState.revoked => 'Permission revoked',
    CaptureState.unavailable => 'Unavailable',
    CaptureState.foregroundOnly => 'Foreground only',
    CaptureState.suspended => 'Suspended',
    CaptureState.error => 'Failed',
  };

  bool get active =>
      this == CaptureState.live || this == CaptureState.paused;

  bool get failed =>
      this == CaptureState.denied ||
      this == CaptureState.revoked ||
      this == CaptureState.unavailable ||
      this == CaptureState.error;
}

/// Whether a source can be offered, and why not.
///
/// [reason] is machine data (`no-camera`, `ios-screen-share-needs-broadcast-
/// extension`), not interface copy; a screen maps it to its own noun.
@immutable
class CaptureCapability {
  const CaptureCapability({
    required this.available,
    this.state = CaptureState.off,
    this.reason,
    this.foregroundOnly = false,
    this.frames = true,
  });

  const CaptureCapability.unavailable(String this.reason, {this.frames = false})
    : available = false,
      state = CaptureState.unavailable,
      foregroundOnly = false;

  final bool available;
  final CaptureState state;
  final String? reason;
  final bool foregroundOnly;

  /// Whether a still frame can be taken from this source.  flutter_webrtc's
  /// `captureFrame` is native only, so a browser build offers no visual
  /// source rather than a track whose frames could not be taken.
  final bool frames;

  bool get usable => available;
}

/// The bounds of one capture session.  They are the app's promise, not the
/// provider's: no frame leaves the device above them.
@immutable
class CaptureBounds {
  const CaptureBounds({
    this.width = 640,
    this.height = 360,
    this.fps = 15,
    this.previewWidth = 320,
    this.previewHeight = 180,
    this.maxFrameBytes = 184320,
    this.maxFramesPerMinute = 30,
    this.sampleInterval = const Duration(seconds: 1),
  });

  final int width;
  final int height;
  final int fps;
  final int previewWidth;
  final int previewHeight;
  final int maxFrameBytes;
  final int maxFramesPerMinute;
  final Duration sampleInterval;
}

/// What the capture session is doing now, for the person and for a computer
/// endpoint that advertises only what is live.
@immutable
class CaptureStatus {
  const CaptureStatus({
    this.source,
    this.state = CaptureState.off,
    this.startedAt,
    this.framesCaptured = 0,
    this.detail,
    this.frames = false,
    this.transmitting = false,
  });

  final CaptureSource? source;
  final CaptureState state;
  final DateTime? startedAt;
  final int framesCaptured;

  /// The platform's own words, data rather than interface copy.
  final String? detail;

  /// Whether still frames are taken rather than a continuous track.
  final bool frames;

  /// Whether the frame or track is being handed to a provider.  A local
  /// preview and a workspace frame are false: the person has not shared it
  /// continuously.
  final bool transmitting;

  CaptureStatus copyWith({
    CaptureSource? source,
    CaptureState? state,
    DateTime? startedAt,
    int? framesCaptured,
    String? detail,
    bool? frames,
    bool? transmitting,
  }) => CaptureStatus(
    source: source ?? this.source,
    state: state ?? this.state,
    startedAt: startedAt ?? this.startedAt,
    framesCaptured: framesCaptured ?? this.framesCaptured,
    detail: detail ?? this.detail,
    frames: frames ?? this.frames,
    transmitting: transmitting ?? this.transmitting,
  );

  @override
  String toString() =>
      'CaptureStatus(${source?.name}, ${state.name}, frames=$frames, '
      'transmitting=$transmitting)';
}

/// One still frame, already within the bounds.  The PNG bytes are held for
/// the call that needs them and are never written to storage by this app.
@immutable
class CapturedFrame {
  const CapturedFrame({
    required this.source,
    required this.png,
    required this.width,
    required this.height,
    required this.capturedAt,
  });

  final CaptureSource source;
  final Uint8List png;
  final int width;
  final int height;
  final DateTime capturedAt;

  int get byteLength => png.length;

  String get mimeType => 'image/png';

  String get label => switch (source) {
    CaptureSource.camera => 'Camera frame',
    CaptureSource.screen => 'Screen frame',
    CaptureSource.microphone => 'Frame',
  };
}

/// A bounded microphone clip, in WAV, for a tool that asks to hear.
@immutable
class CapturedAudio {
  const CapturedAudio({
    required this.wav,
    required this.duration,
    required this.capturedAt,
  });

  final Uint8List wav;
  final Duration duration;
  final DateTime capturedAt;

  String get mimeType => 'audio/wav';
}

/// A failure the platform adapter reports, with the state it means.
class MediaCaptureException implements Exception {
  const MediaCaptureException(this.state, this.reason);

  final CaptureState state;
  final String reason;

  @override
  String toString() => reason;
}

/// The platform seam: what the real flutter_webrtc adapter and a test fake
/// implement.  A platform returns a full-size PNG; [MediaCaptureSession]
/// downscales it and enforces the bounds, so a fake does not have to.
abstract class MediaCapturePlatform {
  Future<Map<CaptureSource, CaptureCapability>> capabilities();

  /// Start [source] and keep it until [stopVisual].  One visual source at a
  /// time; the session stops the old one before it calls this.
  Future<MediaStreamTrack?> startVisual(
    CaptureSource source, {
    required int width,
    required int height,
    required int fps,
  });

  Future<void> setVisualPaused(bool paused);

  Future<void> stopVisual();

  /// A full-size PNG of the live visual source.
  Future<Uint8List> capturePng();

  /// A WAV clip of at most [max].  The session refuses when voice owns the
  /// microphone.
  Future<CapturedAudio> recordAudioClip(Duration max);

  Future<void> dispose();
}

/// One capture session for the app: one visual source at a time, bounded
/// frames, and an explicit stop for every path out.
///
/// It is the seam the voice/WebRTC path and a computer endpoint share.
/// Starting is always a person's action; a lifecycle background stops the
/// source and never resumes it.  No frame is written to storage, and only
/// the current source is held.
class MediaCaptureSession extends ChangeNotifier {
  MediaCaptureSession({
    MediaCapturePlatform? platform,
    this.bounds = const CaptureBounds(),
    DateTime Function()? now,
  }) : _platform = platform,
       _now = now ?? DateTime.now;

  final MediaCapturePlatform? _platform;
  final DateTime Function() _now;
  final CaptureBounds bounds;

  final StreamController<CaptureStatus> _states =
      StreamController<CaptureStatus>.broadcast();

  CaptureStatus _status = const CaptureStatus();
  MediaStreamTrack? _track;
  bool _disposed = false;
  bool _paused = false;
  int _generation = 0;

  /// Whether the voice stack owns the microphone.  The computer endpoint's
  /// audio tool refuses while this is true, so there are never two
  /// recorders.
  bool microphoneInUse = false;

  /// The live track of the visual source, for a WebRTC sender to carry.
  MediaStreamTrack? get videoTrack => _track;

  CaptureStatus get status => _status;

  Stream<CaptureStatus> get states => _states.stream;

  CaptureSource? get source => _status.source;

  bool get active => _status.state.active;

  bool get transmitting => _status.transmitting;

  MediaCapturePlatform get _backend {
    final platform = _platform;
    if (platform == null) {
      throw const MediaCaptureException(
        CaptureState.unavailable,
        'media capture is not available on this build',
      );
    }
    return platform;
  }

  /// What this platform can offer.  `microphoneInUse` is folded into the
  /// microphone row, so a caller sees the honest state.
  Future<Map<CaptureSource, CaptureCapability>> capabilities() async {
    final Map<CaptureSource, CaptureCapability> caps;
    try {
      caps = await _backend.capabilities();
    } catch (error) {
      return {
        for (final source in CaptureSource.values)
          source: CaptureCapability.unavailable('$error'),
      };
    }
    if (!microphoneInUse) return caps;
    return {
      ...caps,
      CaptureSource.microphone: const CaptureCapability(
        available: false,
        state: CaptureState.denied,
        reason: 'microphone-in-use',
        frames: false,
      ),
    };
  }

  /// Start [source].  Starting a visual source stops the one before it; a
  /// source that cannot be offered changes nothing.
  Future<void> start(CaptureSource source) async {
    if (_disposed) return;
    if (source == CaptureSource.microphone) {
      throw const MediaCaptureException(
        CaptureState.unavailable,
        'live microphone audio is owned by the voice stack; use captureAudioClip',
      );
    }
    if (_status.state.active && _status.source == source) {
      if (_paused) await resume();
      return;
    }
    await _stopVisual(notify: false);
    final generation = ++_generation;
    _paused = false;
    _emit(
      CaptureStatus(
        source: source,
        state: CaptureState.starting,
        frames: false,
      ),
    );
    try {
      final platform = _backend;
      final caps = await platform.capabilities();
      final cap = caps[source];
      if (cap == null || !cap.available) {
        throw MediaCaptureException(
          cap?.state ?? CaptureState.unavailable,
          cap?.reason ?? 'source-unavailable',
        );
      }
      if (!cap.frames) {
        throw MediaCaptureException(
          CaptureState.unavailable,
          'frame-capture-unavailable',
        );
      }
      final track = await platform.startVisual(
        source,
        width: bounds.width,
        height: bounds.height,
        fps: bounds.fps,
      );
      if (_disposed || generation != _generation) {
        await platform.stopVisual();
        return;
      }
      _track = track;
      _status = CaptureStatus(
        source: source,
        state: CaptureState.live,
        startedAt: _now(),
        frames: true,
        transmitting: false,
      );
      _emit(_status);
    } catch (error) {
      if (_disposed || generation != _generation) return;
      _track = null;
      final failure = _failureOf(error);
      _status = CaptureStatus(
        source: source,
        state: failure.state,
        detail: failure.reason,
      );
      _emit(_status);
      rethrow;
    }
  }

  /// Stop [source], or every source.  It never throws: this is the path End
  /// and a revoked permission take.
  Future<void> stop([CaptureSource? source]) async {
    if (_disposed) return;
    if (source == null || source == _status.source) {
      await _stopVisual(notify: true);
    }
  }

  Future<void> _stopVisual({required bool notify}) async {
    _generation++;
    final visualSource = _status.source;
    _paused = false;
    _track = null;
    if (visualSource != null) {
      try {
        await _platform?.stopVisual();
      } catch (_) {
        // The track is already gone; stopping is best effort.
      }
    }
    if (_disposed) return;
    if (visualSource != null && notify) {
      _status = CaptureStatus(
        source: visualSource,
        state: CaptureState.off,
        framesCaptured: _status.framesCaptured,
      );
      _emit(_status);
    }
  }

  Future<void> pause() async {
    if (_disposed || _status.state != CaptureState.live || _paused) return;
    _paused = true;
    try {
      await _platform?.setVisualPaused(true);
    } catch (_) {
      // A paused track is a courtesy; the state below is what the UI says.
    }
    _status = _status.copyWith(state: CaptureState.paused, transmitting: false);
    _emit(_status);
  }

  Future<void> resume() async {
    if (_disposed || _status.state != CaptureState.paused || !_paused) return;
    _paused = false;
    try {
      await _platform?.setVisualPaused(false);
    } catch (_) {
      // See pause().
    }
    _status = _status.copyWith(state: CaptureState.live);
    _emit(_status);
  }

  /// Say whether the provider is receiving this capture.  A local preview is
  /// false; a track or a sampled frame handed to a provider is true.
  Future<void> setTransmitting(bool transmitting) async {
    if (_disposed || !_status.state.active) return;
    if (_status.transmitting == transmitting) return;
    _status = _status.copyWith(transmitting: transmitting);
    _emit(_status);
  }

  /// A still frame within the bounds, or null when no visual source is
  /// live or paused.  The platform's full-size PNG is downscaled here; a
  /// too-large frame is retried smaller and then refused, never sent.
  Future<CapturedFrame?> captureFrame({bool preview = false}) async {
    if (_disposed || !_status.state.active || _status.source == null) {
      return null;
    }
    final source = _status.source!;
    final int fullWidth = preview ? bounds.previewWidth : bounds.width;
    final int fullHeight = preview ? bounds.previewHeight : bounds.height;
    final maxBytes = preview ? 120000 : bounds.maxFrameBytes;
    try {
      final raw = await _backend.capturePng();
      var width = fullWidth;
      var height = fullHeight;
      var png = raw;
      for (var attempt = 0; attempt < 5; attempt++) {
        final resized = await _resizePng(
          raw,
          maxWidth: width,
          maxHeight: height,
        );
        png = resized.$1;
        width = resized.$2;
        height = resized.$3;
        if (png.length <= maxBytes) break;
        // Encoded bytes grow with the number of pixels, so one proportional
        // step lands near the bound; 0.8 steps would spend several decodes
        // and leave the frame smaller than it needed to be.
        final ratio = math.sqrt(maxBytes / png.length) * 0.95;
        width = math.max(1, (width * ratio).round());
        height = math.max(1, (height * ratio).round());
      }
      if (png.length > maxBytes) {
        throw const MediaCaptureException(
          CaptureState.error,
          'frame-too-large',
        );
      }
      if (_disposed) return null;
      if (!preview) {
        _status = _status.copyWith(framesCaptured: _status.framesCaptured + 1);
        _emit(_status);
      }
      return CapturedFrame(
        source: source,
        png: png,
        width: width,
        height: height,
        capturedAt: _now(),
      );
    } catch (error) {
      if (_disposed) return null;
      final failure = _failureOf(error);
      if (failure.state == CaptureState.denied ||
          failure.state == CaptureState.revoked) {
        _status = _status.copyWith(
          state: failure.state,
          detail: failure.reason,
          transmitting: false,
        );
        _emit(_status);
      } else if (!preview) {
        _status = _status.copyWith(detail: failure.reason);
        _emit(_status);
      }
      return null;
    }
  }

  /// A bounded microphone clip, for the computer endpoint.  Refuses while
  /// voice owns the microphone and while a visual source is transmitting to
  /// keep the resource story simple.
  Future<CapturedAudio?> captureAudioClip({
    Duration max = const Duration(seconds: 10),
  }) async {
    if (_disposed) return null;
    if (microphoneInUse) {
      throw const MediaCaptureException(
        CaptureState.denied,
        'microphone-in-use',
      );
    }
    final previous = _status;
    _emit(
      const CaptureStatus(
        source: CaptureSource.microphone,
        state: CaptureState.starting,
        frames: false,
      ),
    );
    try {
      final clip = await _backend.recordAudioClip(max);
      _status = CaptureStatus(
        source: CaptureSource.microphone,
        state: CaptureState.off,
        startedAt: previous.startedAt,
        framesCaptured: previous.framesCaptured,
      );
      _emit(_status);
      return clip;
    } catch (error) {
      final failure = _failureOf(error);
      _status = CaptureStatus(
        source: CaptureSource.microphone,
        state: failure.state,
        detail: failure.reason,
      );
      _emit(_status);
      rethrow;
    }
  }

  /// The app went to the background.  Stop a live visual source and say
  /// suspended; nothing starts again by itself when it comes back.
  Future<void> handleLifecycle(AppLifecycleState state) async {
    if (_disposed) return;
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        if (_status.state.active) {
          final was = _status;
          await _stopVisual(notify: false);
          _status = CaptureStatus(
            source: was.source,
            state: CaptureState.suspended,
            startedAt: was.startedAt,
            framesCaptured: was.framesCaptured,
            detail: 'app-backgrounded',
          );
          _emit(_status);
        }
      case AppLifecycleState.resumed:
      case AppLifecycleState.inactive:
        break;
    }
  }

  /// Mark the current source as revoked by the OS, for a platform callback
  /// or a computer endpoint that saw the track die.
  Future<void> markRevoked([String? reason]) async {
    if (_disposed || !_status.state.active) return;
    await _stopVisual(notify: false);
    _status = _status.copyWith(
      state: CaptureState.revoked,
      detail: reason ?? 'permission-revoked',
      transmitting: false,
    );
    _emit(_status);
  }

  void _emit(CaptureStatus status) {
    _status = status;
    if (!_states.isClosed) _states.add(status);
    if (!_disposed) notifyListeners();
  }

  MediaCaptureException _failureOf(Object error) {
    if (error is MediaCaptureException) return error;
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
        text.contains('unavailable')) {
      return MediaCaptureException(CaptureState.unavailable, '$error');
    }
    return MediaCaptureException(CaptureState.error, '$error');
  }

  Future<(Uint8List, int, int)> _resizePng(
    Uint8List png, {
    required int maxWidth,
    required int maxHeight,
  }) async {
    // Decode once, scale with the engine's own drawing, encode once.  Asking
    // the codec to decode at the target size instead decodes the same bytes
    // twice, which is the largest part of a frame's cost.
    final codec = await ui.instantiateImageCodec(png);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final scale = math.min(
      1.0,
      math.min(maxWidth / image.width, maxHeight / image.height),
    );
    final width = math.max(1, (image.width * scale).round());
    final height = math.max(1, (image.height * scale).round());
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawImageRect(
      image,
      ui.Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      ui.Paint()..filterQuality = ui.FilterQuality.medium,
    );
    final picture = recorder.endRecording();
    final resized = await picture.toImage(width, height);
    final data = await resized.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    codec.dispose();
    resized.dispose();
    picture.dispose();
    if (data == null) {
      throw const MediaCaptureException(CaptureState.error, 'encode-failed');
    }
    return (
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      width,
      height,
    );
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _track = null;
    unawaited(_platform?.stopVisual().catchError((Object _) {}));
    unawaited(_states.close());
    super.dispose();
  }
}

/// What a provider accepts from a capture session.
///
/// [tracks] is a real WebRTC video track carried in the call; [frames] are
/// still images sent one at a time into the same conversation.  A provider
/// that offers neither is not given a false `live video` label.
@immutable
class MediaDelivery {
  const MediaDelivery({
    this.tracks = false,
    this.frames = false,
    this.tracksReason,
    this.framesReason,
    this.maxFps = 30,
  });

  const MediaDelivery.none({this.tracksReason, this.framesReason})
    : tracks = false,
      frames = false,
      maxFps = 0;

  final bool tracks;
  final bool frames;
  final String? tracksReason;
  final String? framesReason;
  final int maxFps;

  bool get any => tracks || frames;

  MediaDelivery copyWith({
    bool? tracks,
    bool? frames,
    String? tracksReason,
    String? framesReason,
    int? maxFps,
  }) => MediaDelivery(
    tracks: tracks ?? this.tracks,
    frames: frames ?? this.frames,
    tracksReason: tracksReason ?? this.tracksReason,
    framesReason: framesReason ?? this.framesReason,
    maxFps: maxFps ?? this.maxFps,
  );
}

/// A picture of the frame itself for a preview.  It is kept in memory only,
/// replaced on every sample, and dropped when capture stops.
@immutable
class MediaPreview {
  const MediaPreview(this.png, this.at);

  final Uint8List png;
  final DateTime at;
}

/// A colour for a capture state, in the app's palette.
Color captureStateColor(CaptureState state) => switch (state) {
  CaptureState.live => const Color(0xFF8FBF9F),
  CaptureState.starting || CaptureState.foregroundOnly =>
    const Color(0xFFD9B36C),
  CaptureState.paused || CaptureState.suspended => const Color(0xFFB9AEA3),
  CaptureState.denied ||
  CaptureState.revoked ||
  CaptureState.unavailable ||
  CaptureState.error => const Color(0xFFD65A36),
  CaptureState.off => const Color(0xFF8A817C),
};
