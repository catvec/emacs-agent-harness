import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/services/voice_http.dart';
import 'package:harness_client/src/voice/voice_audio.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  final wav = encodeWav(Int16List.fromList([1, 2, 3]));

  test('uploads a WAV to a whisper.cpp server and reads its text', () async {
    late http.Request seen;
    final client = MockClient((request) async {
      seen = request;
      return http.Response(
        '{"text":"  hello there  "}',
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });
    final transcriber = HttpVoiceTranscriber(client: client);
    final text = await transcriber.transcribe(
      wav,
      endpoint: 'http://127.0.0.1:8080/inference',
      model: '',
      token: '',
      language: 'en',
    );
    expect(text, 'hello there');
    expect(seen.method, 'POST');
    expect(seen.url.toString(), 'http://127.0.0.1:8080/inference');
    final body = latin1.decode(seen.bodyBytes);
    expect(body, contains('name="file"'));
    expect(body, contains('filename="utterance.wav"'));
    expect(body, contains('name="response_format"'));
    expect(body, contains('name="language"'));
    expect(body, contains('en'));
  });

  test('sends the model and the bearer token an OpenAI endpoint takes',
      () async {
    late http.Request seen;
    final client = MockClient((request) async {
      seen = request;
      return http.Response(
        jsonEncode({'text': 'make a task'}),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final transcriber = HttpVoiceTranscriber(client: client);
    final text = await transcriber.transcribe(
      wav,
      endpoint: 'https://api.openai.com/v1/audio/transcriptions',
      model: 'whisper-1',
      token: 'sk-test',
      language: '',
    );
    expect(text, 'make a task');
    expect(seen.headers['Authorization'], 'Bearer sk-test');
    final body = latin1.decode(seen.bodyBytes);
    expect(body, contains('whisper-1'));
    expect(body, isNot(contains('name="language"')));
  });

  test('reads a plain text answer', () async {
    final client = MockClient(
      (request) async => http.Response('a plain transcript', 200),
    );
    final transcriber = HttpVoiceTranscriber(client: client);
    expect(
      await transcriber.transcribe(
        wav,
        endpoint: 'https://speech.test/inference',
        model: '',
        token: '',
        language: '',
      ),
      'a plain transcript',
    );
  });

  test('reports a refused clip with the server’s own words', () async {
    final client = MockClient(
      (request) async => http.Response(
        jsonEncode({
          'error': {'message': 'bad key'},
        }),
        401,
        headers: {'content-type': 'application/json'},
      ),
    );
    final transcriber = HttpVoiceTranscriber(client: client);
    await expectLater(
      transcriber.transcribe(
        wav,
        endpoint: 'https://speech.test/inference',
        model: '',
        token: '',
        language: '',
      ),
      throwsA(
        isA<VoiceHttpException>()
            .having((error) => error.status, 'status', 401)
            .having((error) => error.message, 'message', contains('bad key')),
      ),
    );
  });

  test('an answer that is not a transcript is refused', () async {
    final client = MockClient(
      (request) async => http.Response('{"text": 42}', 200),
    );
    final transcriber = HttpVoiceTranscriber(client: client);
    await expectLater(
      transcriber.transcribe(
        wav,
        endpoint: 'https://speech.test/inference',
        model: '',
        token: '',
        language: '',
      ),
      throwsA(isA<VoiceHttpException>()),
    );
  });

  test('a bad URL is refused before anything is sent', () async {
    final client = MockClient((request) async {
      throw StateError('should not be sent');
    });
    final transcriber = HttpVoiceTranscriber(client: client);
    await expectLater(
      transcriber.transcribe(
        wav,
        endpoint: 'not a url',
        model: '',
        token: '',
        language: '',
      ),
      throwsA(isA<VoiceHttpException>()),
    );
  });
}
