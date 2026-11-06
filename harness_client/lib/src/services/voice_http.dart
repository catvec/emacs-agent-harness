import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../voice/voice_backend.dart';

/// A speech endpoint said no, or answered something that is not a transcript.
class VoiceHttpException implements Exception {
  const VoiceHttpException(this.message, {this.status});
  final String message;
  final int? status;

  @override
  String toString() => status == null ? message : '$message ($status)';
}

/// Uploads one WAV clip and reads the transcript.
///
/// It speaks the two shapes the voice docs use without a wrapper:
///
///  * whisper.cpp's `whisper-server` (`/inference`): multipart `file`, a JSON
///    answer whose `text` is the transcript;
///  * an OpenAI-compatible `/v1/audio/transcriptions`: the same multipart,
///    with the model and a bearer token, and the same `text`.
///
/// A server that answers the transcript as plain text is accepted too.
class HttpVoiceTranscriber implements VoiceTranscriber {
  HttpVoiceTranscriber({
    http.Client? client,
    this.timeout = const Duration(seconds: 45),
    this.maxResponseBytes = 4 * 1024 * 1024,
  }) : _client = client ?? http.Client(),
       _owned = client == null;

  final http.Client _client;
  final bool _owned;
  final Duration timeout;
  final int maxResponseBytes;

  @override
  Future<String> transcribe(
    Uint8List wav, {
    required String endpoint,
    required String model,
    required String token,
    required String language,
  }) async {
    final uri = Uri.tryParse(endpoint.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw const VoiceHttpException('The speech endpoint is not a URL.');
    }
    final request = http.MultipartRequest('POST', uri)
      ..files.add(
        http.MultipartFile.fromBytes('file', wav, filename: 'utterance.wav'),
      )
      ..fields['response_format'] = 'json';
    if (model.trim().isNotEmpty) request.fields['model'] = model.trim();
    if (language.trim().isNotEmpty) {
      request.fields['language'] = language.trim();
    }
    if (token.trim().isNotEmpty) {
      request.headers['Authorization'] = 'Bearer ${token.trim()}';
    }
    try {
      final streamed = await _client.send(request).timeout(timeout);
      final response = await http.Response.fromStream(streamed)
          .timeout(timeout);
      final body = response.body;
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw VoiceHttpException(
          _oneLine(body).isEmpty
              ? 'The speech endpoint refused the clip.'
              : _oneLine(body),
          status: response.statusCode,
        );
      }
      if (response.bodyBytes.length > maxResponseBytes) {
        throw const VoiceHttpException(
          'The speech endpoint answered more than a transcript.',
        );
      }
      return _readTranscript(body, response.headers['content-type'] ?? '');
    } on VoiceHttpException {
      rethrow;
    } on TimeoutException {
      throw const VoiceHttpException('The speech endpoint timed out.');
    } catch (error) {
      throw VoiceHttpException(
        'The speech endpoint failed: ${_oneLine('$error')}',
      );
    }
  }

  String _readTranscript(String body, String contentType) {
    final text = body.trim();
    if (text.isEmpty) return '';
    if (contentType.contains('json') || text.startsWith('{')) {
      try {
        final decoded = jsonDecode(text);
        if (decoded is Map) {
          final value = decoded['text'];
          if (value is String) return value.trim();
          final error = decoded['error'];
          if (error is String) throw VoiceHttpException(error);
          if (error is Map && error['message'] is String) {
            throw VoiceHttpException(error['message'] as String);
          }
          throw const VoiceHttpException(
            'The speech endpoint sent no transcript.',
          );
        }
      } on VoiceHttpException {
        rethrow;
      } catch (_) {
        // A server that says JSON but sends plain text is still readable.
      }
    }
    return text;
  }

  static String _oneLine(String text) {
    final line = text.trim().split('\n').first.trim();
    if (line.isEmpty) return '';
    return line.length <= 160 ? line : '${line.substring(0, 159)}…';
  }

  @override
  Future<void> dispose() async {
    if (_owned) _client.close();
  }
}
