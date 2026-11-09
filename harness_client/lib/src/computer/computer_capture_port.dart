import 'dart:async';
import 'dart:typed_data';

import 'computer_capabilities.dart';

/// A source a phone can capture from.
enum ComputerCaptureSource {
  screen('view'),
  camera('camera'),
  microphone('audio');

  const ComputerCaptureSource(this.capability);
  final String capability;
}

/// What a capture implementation reports while it runs.
class ComputerCaptureEvent {
  const ComputerCaptureEvent({
    required this.source,
    required this.status,
    this.startedAt,
    this.framesSent = 0,
  });

  final ComputerCaptureSource source;
  final ComputerCapabilityStatus status;
  final DateTime? startedAt;
  final int framesSent;
}

/// The narrow seam between this registration layer and the live-media work.
///
/// Capture, permission prompts, camera/screen lifecycle and the Android
/// mediaProjection foreground service belong to the live-video task; this
/// layer only asks for a bounded frame or clip when a harness tool calls,
/// and reads the state it must advertise.  [NoopComputerCapturePort] is the
/// honest default on a platform or in a build without that seam.
abstract class ComputerCapturePort {
  /// What each source can do now, without prompting for anything.
  Future<Map<ComputerCaptureSource, ComputerCapabilityStatus>> capabilities();

  /// State changes: a permission denied or revoked, a capture stopped, a
  /// lifecycle transition.
  Stream<ComputerCaptureEvent> get statuses;

  /// Start [source] (an OS prompt may follow); returns when it is live or
  /// the permission is refused.
  Future<void> start(ComputerCaptureSource source);

  /// Stop one source, or every source when [source] is nil.
  Future<void> stop([ComputerCaptureSource? source]);

  /// One bounded PNG from a live [source], or null when it is not live.
  Future<Uint8List?> capturePng(
    ComputerCaptureSource source, {
    int maxWidth = 640,
    int maxHeight = 360,
  });

  /// One bounded WAV clip from the microphone.
  Future<Uint8List?> captureAudio({Duration max = const Duration(seconds: 10)});

  /// The app moved to another lifecycle state; capture stops and never
  /// resumes by itself.
  Future<void> handleLifecycle(String state);

  Future<void> dispose();
}

/// A port for a build with no capture: it offers nothing and says why.
class NoopComputerCapturePort implements ComputerCapturePort {
  NoopComputerCapturePort({
    this.reason = 'No capture implementation on this platform',
  });

  final String reason;

  @override
  Future<Map<ComputerCaptureSource, ComputerCapabilityStatus>>
  capabilities() async {
    return <ComputerCaptureSource, ComputerCapabilityStatus>{
      for (final source in ComputerCaptureSource.values)
        source: ComputerCapabilityStatus(
          state: ComputerCapabilityState.unavailable,
          detail: reason,
        ),
    };
  }

  @override
  Stream<ComputerCaptureEvent> get statuses =>
      const Stream<ComputerCaptureEvent>.empty();

  @override
  Future<void> start(ComputerCaptureSource source) async {
    throw StateError(reason);
  }

  @override
  Future<void> stop([ComputerCaptureSource? source]) async {}

  @override
  Future<Uint8List?> capturePng(
    ComputerCaptureSource source, {
    int maxWidth = 640,
    int maxHeight = 360,
  }) async {
    throw StateError(reason);
  }

  @override
  Future<Uint8List?> captureAudio({
    Duration max = const Duration(seconds: 10),
  }) async {
    throw StateError(reason);
  }

  @override
  Future<void> handleLifecycle(String state) async {}

  @override
  Future<void> dispose() async {}
}
