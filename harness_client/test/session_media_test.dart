import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/models/session_media.dart';

void main() {
  test('a vision model is a frame endpoint with explicit bounds', () {
    final media = SessionMediaCapabilities.fromWire(const {
      'session': 's1',
      'endpoint': 'session/prompt',
      'images': true,
      'realtime': false,
      'realtime-reason': 'no-media-sink',
      'frames': {
        'supported': true,
        'max-bytes': 184320,
        'max-width': 640,
        'max-height': 360,
        'max-per-minute': 30,
        'mime-types': ['image/png', 'image/jpeg'],
      },
      'model': 'demo:sees',
      'vision': true,
    });
    expect(media.session, 's1');
    expect(media.endpoint, 'session/prompt');
    expect(media.frames, isTrue);
    expect(media.realtime, isFalse);
    expect(media.realtimeReason, 'no-media-sink');
    expect(media.maxBytes, 184320);
    expect(media.maxWidth, 640);
    expect(media.maxHeight, 360);
    expect(media.maxPerMinute, 30);
    expect(media.mimeTypes, ['image/png', 'image/jpeg']);
    expect(media.vision, isTrue);
    expect(media.visionUnconfirmed, isFalse);
    expect(media.unavailableReason, isNull);
  });

  test('a model without vision is not offered frames', () {
    final media = SessionMediaCapabilities.fromWire(const {
      'session': 's1',
      'images': true,
      'vision': false,
      'reason': 'model-without-vision',
    });
    expect(media.frames, isFalse);
    expect(media.visionUnconfirmed, isFalse);
    expect(media.unavailableReason, 'model-without-vision');
  });

  test('an unknown vision answer is honest and warns', () {
    final media = SessionMediaCapabilities.fromWire(const {
      'session': 's1',
      'images': true,
      'vision': 'unknown',
      'reason': 'vision-unknown',
    });
    expect(media.vision, isNull);
    expect(media.frames, isTrue);
    expect(media.visionUnconfirmed, isTrue);
    expect(media.unavailableReason, isNull);
  });

  test('a harness without image prompts has no frame endpoint', () {
    final media = SessionMediaCapabilities.fromWire(const {
      'session': 's1',
      'images': false,
    });
    expect(media.frames, isFalse);
    expect(media.unavailableReason, 'harness-without-image-prompts');
  });
}
