import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/media/media_capture.dart';
import 'package:harness_client/src/services/voice_webrtc.dart';

CapturedFrame _frame({CaptureSource source = CaptureSource.camera}) =>
    CapturedFrame(
      source: source,
      png: Uint8List.fromList(const [1, 2, 3, 4]),
      width: 640,
      height: 360,
      capturedAt: DateTime.utc(2026, 11, 8, 12, 0, 0),
    );

void main() {
  test('GPT-Live-1 is not claimed to take images; gpt-realtime is', () {
    expect(openAiTakesImages('gpt-live-1'), isFalse);
    expect(openAiTakesImages('gpt-realtime-2'), isTrue);
    expect(openAiTakesImages('gpt-realtime'), isTrue);
    expect(openAiTakesImages('gpt-4o-realtime-preview'), isTrue);
    expect(openAiTakesImages(''), isFalse);
  });

  test('an OpenAI frame is one input_image part and no response.create', () {
    final message = openAiFrameMessage(_frame());
    expect(message['type'], 'conversation.item.create');
    expect(message.containsKey('response.create'), isFalse);
    final item = message['item']! as Map;
    final content = item['content']! as List;
    expect(content, hasLength(1));
    final part = content.single as Map;
    expect(part['type'], 'input_image');
    expect(
      part['image_url'],
      'data:image/png;base64,${base64Encode([1, 2, 3, 4])}',
    );
    expect(message.toString(), isNot(contains('response.create')));
  });

  test('a frame that would overfill the send queue is dropped', () {
    expect(liveFrameFitsBackpressure(null, 1000), isTrue);
    expect(liveFrameFitsBackpressure(0, 1000), isTrue);
    expect(liveFrameFitsBackpressure(2 * 1024 * 1024, 1), isFalse);
    expect(liveFrameFitsBackpressure(1200 * 1024, 600 * 1024), isTrue);
    expect(liveFrameFitsBackpressure(1500 * 1024, 600 * 1024), isFalse);
  });

  test('a generic frame says its source, bytes and timestamp', () {
    final message = harnessFrameMessage(
      _frame(source: CaptureSource.screen),
      7,
    );
    expect(message['type'], 'frame');
    expect(message['protocol'], 1);
    expect(message['source'], 'screen');
    expect(message['mimeType'], 'image/png');
    expect(message['data'], base64Encode([1, 2, 3, 4]));
    expect(message['width'], 640);
    expect(message['height'], 360);
    expect(message['capturedAt'], '2026-11-08T12:00:00.000Z');
    expect(message['sequence'], 7);
  });
}
