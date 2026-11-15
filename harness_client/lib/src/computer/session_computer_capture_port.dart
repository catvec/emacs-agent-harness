import 'dart:async';

import 'package:flutter/foundation.dart';

import 'computer_capabilities.dart';
import 'computer_capture_port.dart';
import 'computer_platform.dart';

/// What the media module's one capture session can tell this port.
///
/// It is deliberately narrow: the port owns the OS permission check, the
/// capability states, the generation and the lifecycle rule, and the media
/// module owns the one camera/screen/microphone session.  There is no capture
/// code here and no second recorder, which is what keeps the phone's native
/// capture in one place: `MediaCaptureSession` in `lib/src/media/`.
@immutable
class MediaCaptureSignal {
  const MediaCaptureSignal({
    required this.source,
    required this.state,
    this.detail,
  });

  final ComputerCaptureSource source;

  /// The harness's state for this source, mapped by the adapter.
  final ComputerCapabilityState state;
  final String? detail;
}

/// The seam the app's shared capture session fills in.
///
/// The adapter from `MediaCaptureSession` is a few lines: `start`, `stop`,
/// `captureFrame` and `captureAudioClip` map one to one, and its `states`
/// stream maps a `CaptureState` to the harness's vocabulary.  Until that
/// module is wired, [NoopComputerMediaCapture] answers.
abstract class ComputerMediaCapture {
  /// Whether a capture session is wired in this build.
  bool get present;

  Future<void> start(ComputerCaptureSource source);

  Future<void> stop([ComputerCaptureSource? source]);

  /// One bounded PNG of [source], or null when it is not live.
  Future<Uint8List?> frame(
    ComputerCaptureSource source, {
    int maxWidth = 640,
    int maxHeight = 360,
  });

  /// One bounded WAV clip, or null when the microphone is not available.
  Future<Uint8List?> clip(Duration max);

  /// State changes the media session reports: a track that died, a revoked
  /// permission, a lifecycle stop.
  Stream<MediaCaptureSignal> get signals;

  Future<void> handleLifecycle(String state);

  Future<void> dispose();
}

/// A build with no capture session wired: it offers nothing and says so.
class NoopComputerMediaCapture implements ComputerMediaCapture {
  const NoopComputerMediaCapture([
    this.reason = 'Capture session not connected',
  ]);

  final String reason;

  @override
  bool get present => false;

  @override
  Stream<MediaCaptureSignal> get signals =>
      const Stream<MediaCaptureSignal>.empty();

  @override
  Future<void> start(ComputerCaptureSource source) async {
    throw StateError(reason);
  }

  @override
  Future<void> stop([ComputerCaptureSource? source]) async {}

  @override
  Future<Uint8List?> frame(
    ComputerCaptureSource source, {
    int maxWidth = 640,
    int maxHeight = 360,
  }) async => null;

  @override
  Future<Uint8List?> clip(Duration max) async => null;

  @override
  Future<void> handleLifecycle(String state) async {}

  @override
  Future<void> dispose() async {}
}

/// The phone's capture as the registered computer offers it.
///
/// The OS permission is checked before a source is offered, and a source the
/// person has not answered yet is `available` only while a prompt can still
/// be made: the first tool call asks, and a refusal is then `denied` for good
/// until the person changes it in the OS.  A permission the OS held and no
/// longer does reads `revoked`; the app never resumes a capture after that.
///
/// Every stop, revocation or lifecycle transition bumps [generation], so a
/// frame that finishes afterwards is refused instead of counted.
class SessionComputerCapturePort implements ComputerCapturePort {
  SessionComputerCapturePort({
    required this.platform,
    ComputerMediaCapture media = const NoopComputerMediaCapture(),
    PlatformFacts Function()? facts,
  }) : _media = media,
       _facts = facts ?? (() => const PlatformFacts());

  final ComputerPlatform platform;
  final ComputerMediaCapture _media;

  /// What the OS last said, held by the controller as a value.  Nothing on
  /// the connection path waits for a channel: a state the app has not read
  /// yet is no state at all, and the page says `Not checked` rather than
  /// guessing.
  final PlatformFacts Function() _facts;

  final StreamController<ComputerCaptureEvent> _statuses =
      StreamController<ComputerCaptureEvent>.broadcast();
  StreamSubscription<MediaCaptureSignal>? _signals;

  /// The permission each source had the last time it was read, so a grant
  /// that disappears can be reported as revoked rather than as never asked.
  final Map<String, PlatformPermission> _seen = <String, PlatformPermission>{};
  final Set<ComputerCaptureSource> _live = <ComputerCaptureSource>{};
  int _generation = 0;
  bool _disposed = false;
  bool _suspend = false;

  /// The source states last read from the OS, for the endpoint's refresh.
  Map<ComputerCaptureSource, ComputerCapabilityStatus> _states = const {};

  int get generation => _generation;

  bool isLive(ComputerCaptureSource source) => _live.contains(source);

  @override
  Future<Map<ComputerCaptureSource, ComputerCapabilityStatus>>
  capabilities() async {
    final facts = _facts();
    if (!facts.read) {
      // The OS was never asked here (a test, the web, a desktop build), so
      // there is nothing to report: an empty map reads as `Not checked`.
      _listen();
      return const <ComputerCaptureSource, ComputerCapabilityStatus>{};
    }
    final states = <ComputerCaptureSource, ComputerCapabilityStatus>{};
    for (final source in ComputerCaptureSource.values) {
      final name = captureSourcePermission[source]!;
      final permission = facts.permissions[name];
      states[source] = _statusFor(source, permission);
    }
    _states = states;
    _listen();
    return states;
  }

  /// The states last read, without another OS round trip.
  Map<ComputerCaptureSource, ComputerCapabilityStatus> get states => _states;

  ComputerCapabilityStatus _statusFor(
    ComputerCaptureSource source,
    PermissionState? permission,
  ) {
    final name = captureSourcePermission[source]!;
    final previous = _seen[name];
    if (permission != null) _seen[name] = permission.permission;
    // An OS grant that has gone is a revocation, not a state that was never
    // known: the person withdrew it while the app held it.
    final revoked =
        previous == PlatformPermission.granted &&
        permission?.permission == PlatformPermission.denied;
    if (revoked) {
      return ComputerCapabilityStatus(
        state: ComputerCapabilityState.revoked,
        detail: permission?.detail ?? 'Permission revoked',
      );
    }
    if (!_media.present) {
      // The permission may be fine; the capture path is what is missing.  Say
      // which, so the page does not blame the person's permission.
      return ComputerCapabilityStatus(
        state: ComputerCapabilityState.unavailable,
        detail: 'Capture session not connected',
      );
    }
    return capabilityFromPermission(
      permission,
      foregroundOnly:
          source == ComputerCaptureSource.screen ||
          source == ComputerCaptureSource.camera,
      missing: 'No ${source.name} on this platform',
    );
  }

  /// The media session is subscribed to the first time the OS is read, so a
  /// build with no session never opens a stream.
  void _listen() {
    if (_signals != null || !_media.present) return;
    _signals = _media.signals.listen((signal) {
      _live.remove(signal.source);
      if (signal.state != ComputerCapabilityState.available &&
          signal.state != ComputerCapabilityState.foregroundOnly) {
        _generation++;
      }
      _emit(
        signal.source,
        ComputerCapabilityStatus(state: signal.state, detail: signal.detail),
      );
    });
  }

  @override
  Stream<ComputerCaptureEvent> get statuses => _statuses.stream;

  /// Start [source].  The OS is asked only here, and only while the person's
  /// switch is on; a refusal comes back as a denied state instead of a throw.
  @override
  Future<void> start(ComputerCaptureSource source) async {
    if (_disposed) throw StateError('The capture port is closed');
    if (_suspend) {
      throw const ComputerCaptureRefused(
        ComputerCapabilityState.suspended,
        'App in the background',
      );
    }
    final name = captureSourcePermission[source]!;
    // A live read, because this is the moment the OS's answer decides whether
    // anything is captured.  It is bounded: a platform that does not answer
    // leaves the source unavailable instead of holding the call open.
    final permissions = await platform.permissions();
    var permission = permissions[name];
    if (permission == null && !_facts().read) {
      // A platform that was never asked cannot say yes: an unknown state is
      // not a grant, and nothing is captured on a guess.
      throw const ComputerCaptureRefused(
        ComputerCapabilityState.unavailable,
        'Permission not checked',
      );
    }
    _states = {..._states, source: _statusFor(source, permission)};
    if (permission?.permission == PlatformPermission.promptable) {
      permission = await platform.requestPermission(name);
      _states = {..._states, source: _statusFor(source, permission)};
      _emit(source, _states[source]!);
    }
    if (permission == null ||
        permission.permission == PlatformPermission.unavailable) {
      throw ComputerCaptureRefused(
        ComputerCapabilityState.unavailable,
        permission?.detail ?? 'No ${source.name} on this platform',
      );
    }
    if (!permission.granted) {
      _emit(
        source,
        ComputerCapabilityStatus(
          state: ComputerCapabilityState.denied,
          detail: permission.detail ?? 'Permission denied',
        ),
      );
      throw const ComputerCaptureRefused(
        ComputerCapabilityState.denied,
        'Permission denied',
      );
    }
    if (!_media.present) {
      throw const ComputerCaptureRefused(
        ComputerCapabilityState.unavailable,
        'Capture session not connected',
      );
    }
    if (source != ComputerCaptureSource.microphone) {
      // One visual source at a time, as the shared session is built.
      for (final other in _live.toList()) {
        if (other != ComputerCaptureSource.microphone) {
          _live.remove(other);
          await _media.stop(other);
        }
      }
    }
    await _media.start(source);
    _live.add(source);
    _emit(
      source,
      ComputerCapabilityStatus(
        state: source == ComputerCaptureSource.screen ||
                source == ComputerCaptureSource.camera
            ? ComputerCapabilityState.foregroundOnly
            : ComputerCapabilityState.available,
      ),
    );
  }

  @override
  Future<void> stop([ComputerCaptureSource? source]) async {
    _generation++;
    if (source == null) {
      _live.clear();
      await _media.stop();
    } else {
      _live.remove(source);
      await _media.stop(source);
    }
    if (_disposed) return;
    for (final each in source == null
        ? ComputerCaptureSource.values
        : <ComputerCaptureSource>[source]) {
      final permission = _seen[captureSourcePermission[each]!];
      _emit(
        each,
        ComputerCapabilityStatus(
          state: permission == PlatformPermission.denied
              ? ComputerCapabilityState.denied
              : (_media.present
                    ? ComputerCapabilityState.unavailable
                    : ComputerCapabilityState.unavailable),
          detail: permission == PlatformPermission.denied
              ? 'Permission denied'
              : 'Off',
        ),
      );
    }
  }

  @override
  Future<Uint8List?> capturePng(
    ComputerCaptureSource source, {
    int maxWidth = 640,
    int maxHeight = 360,
  }) async {
    if (_disposed || _suspend) return null;
    final generation = _generation;
    final png = await _media.frame(
      source,
      maxWidth: maxWidth,
      maxHeight: maxHeight,
    );
    if (_disposed || generation != _generation) return null;
    if (png == null) return null;
    if (png.length > maxFrameBytes) {
      throw const ComputerCaptureRefused(
        ComputerCapabilityState.error,
        'Frame over the size bound',
      );
    }
    return png;
  }

  @override
  Future<Uint8List?> captureAudio({
    Duration max = const Duration(seconds: 10),
  }) async {
    if (_disposed || _suspend) return null;
    final generation = _generation;
    await start(ComputerCaptureSource.microphone);
    final wav = await _media.clip(max);
    if (_disposed || generation != _generation) return null;
    return wav;
  }

  /// The app moved to another lifecycle state.  A live capture stops, the
  /// state says suspended, and nothing resumes by itself: coming back leaves
  /// the source off until a person or a tool call starts it again.
  @override
  Future<void> handleLifecycle(String state) async {
    if (_disposed) return;
    final background =
        state == 'paused' || state == 'hidden' || state == 'detached';
    if (background) {
      _suspend = true;
      _generation++;
      if (_live.isNotEmpty) {
        final live = _live.toList();
        _live.clear();
        await _media.stop();
        await _media.handleLifecycle(state);
        for (final source in live) {
          _emit(
            source,
            const ComputerCapabilityStatus(
              state: ComputerCapabilityState.suspended,
              detail: 'App in the background',
            ),
          );
        }
      }
      return;
    }
    if (state == 'resumed') {
      // The permission may have changed while the app was away; the states
      // are re-read, and a source is never restarted.
      _suspend = false;
      _generation++;
      await _media.handleLifecycle(state);
      await capabilities();
    } else {
      await _media.handleLifecycle(state);
    }
  }

  void _emit(ComputerCaptureSource source, ComputerCapabilityStatus status) {
    _states = {..._states, source: status};
    if (!_disposed && !_statuses.isClosed) {
      _statuses.add(
        ComputerCaptureEvent(source: source, status: status, startedAt: null),
      );
    }
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _generation++;
    await _signals?.cancel();
    await _media.dispose();
    await _statuses.close();
  }
}

/// The largest frame this port hands out, matching the harness's picture
/// bounds.
const int maxFrameBytes = 184320;
