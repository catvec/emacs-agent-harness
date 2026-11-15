import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/media/media_capture.dart';
import 'package:harness_client/src/voice/live_protocol.dart';
import 'package:harness_client/src/voice/live_voice_backend.dart';
import 'package:harness_client/src/voice/voice_backend.dart';

class _MediaConnection implements LiveVoiceConnection, LiveMediaConnection {
  _MediaConnection(this.mediaDelivery);

  @override
  final MediaDelivery mediaDelivery;

  final _messages = StreamController<Map<String, Object?>>.broadcast();
  final List<Map<String, Object?>> sent = <Map<String, Object?>>[];
  final List<CapturedFrame> frames = <CapturedFrame>[];
  final List<CaptureSource> attached = <CaptureSource>[];
  final List<CaptureSource> detached = <CaptureSource>[];
  int disposed = 0;

  @override
  Stream<Map<String, Object?>> get messages => _messages.stream;

  @override
  Future<void> connect(LiveVoiceConfig config) async {}

  @override
  Future<void> send(Map<String, Object?> message) async => sent.add(message);

  @override
  Future<void> setMuted(bool muted) async {}

  @override
  Future<void> setRemoteAudioEnabled(bool enabled) async {}

  @override
  Future<void> attachVideo(CaptureSource source, Object track) async =>
      attached.add(source);

  @override
  Future<void> detachVideo(CaptureSource source) async => detached.add(source);

  @override
  Future<void> sendFrame(CapturedFrame frame) async => frames.add(frame);

  @override
  Future<void> dispose() async {
    disposed++;
    await _messages.close();
  }
}

LiveVoiceBackend _backend(_MediaConnection connection) => LiveVoiceBackend(
  connection: connection,
  protocol: const LiveProtocol(openAi: false),
  config: const LiveVoiceConfig(
    endpoint: 'http://localhost/live',
    model: 'demo',
    token: '',
    voice: '',
    language: '',
    instructions: '',
    sessionId: 's1',
    sessionTitle: 'Demo',
    cwd: '/tmp',
    history: [],
  ),
);

CapturedFrame _frame() => CapturedFrame(
  source: CaptureSource.camera,
  png: Uint8List.fromList(const [1, 2, 3]),
  width: 64,
  height: 36,
  capturedAt: DateTime.utc(2026),
);

void main() {
  test(
    'a provider that accepts frames is announced and gets one still frame',
    () async {
      final connection = _MediaConnection(
        const MediaDelivery(tracks: false, frames: true, maxFps: 1),
      );
      final backend = _backend(connection);
      final events = <VoiceBackendEvent>[];
      final subscription = backend.events.listen(events.add);
      addTearDown(subscription.cancel);

      await backend.start();
      await Future<void>.delayed(Duration.zero);
      expect(
        events.whereType<VoiceMediaDeliveryEvent>().single.delivery.frames,
        isTrue,
      );
      await backend.sendCapturedFrame(_frame());
      await Future<void>.delayed(Duration.zero);
      expect(connection.frames, hasLength(1));
      expect(events.whereType<VoiceMediaFrameEvent>().single.sent, isTrue);
      await backend.stop();
    },
  );

  test('a provider that accepts no frames refuses one and says so', () async {
    final connection = _MediaConnection(
      const MediaDelivery.none(framesReason: 'no-image-input'),
    );
    final backend = _backend(connection);
    final events = <VoiceBackendEvent>[];
    final subscription = backend.events.listen(events.add);
    addTearDown(subscription.cancel);

    await backend.start();
    await Future<void>.delayed(Duration.zero);
    await backend.sendCapturedFrame(_frame());
    await Future<void>.delayed(Duration.zero);
    expect(connection.frames, isEmpty);
    final event = events.whereType<VoiceMediaFrameEvent>().single;
    expect(event.sent, isFalse);
    expect(event.error, 'provider-takes-no-frames');
    await backend.stop();
  });

  test('stopping the call detaches the video source', () async {
    final connection = _MediaConnection(const MediaDelivery(tracks: true));
    final backend = _backend(connection);
    await backend.start();
    await backend.detachCapture();
    await backend.stop();
    expect(connection.disposed, 1);
  });
}
