
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/voice/live_protocol.dart';
import 'package:harness_client/src/voice/live_voice_backend.dart';
import 'package:harness_client/src/voice/voice_backend.dart';
import 'package:harness_client/src/voice/voice_models.dart';

LiveVoiceConfig _config() => LiveVoiceConfig(
  endpoint: 'https://api.openai.com/v1',
  model: 'gpt-live-1',
  token: 'ek_test',
  voice: 'vale',
  language: 'en',
  instructions: 'be brief',
  sessionId: 's1',
  sessionTitle: 'Build the thing',
  cwd: '/tmp/project',
  history: const ['Person: hello'],
);

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  test(
    'a live session opens, speaks, delegates and returns the result',
    () async {
      final connection = ScriptedLiveConnection();
      final backend = LiveVoiceBackend(
        connection: connection,
        protocol: const LiveProtocol(openAi: true),
        config: _config(),
      );
      final events = <VoiceBackendEvent>[];
      backend.events.listen(events.add);
      await backend.start();
      await _settle();
      expect(connection.connected, isTrue);
      expect(connection.sent.first['type'], 'session.update');
      expect(
        events.whereType<VoicePhaseEvent>().last.phase,
        VoicePhase.listening,
      );

      connection.deliver(<String, Object?>{
        'type': 'conversation.item.input_audio_transcription.completed',
        'transcript': 'check the tests',
      });
      await _settle();
      expect(
        events.whereType<VoiceCaptionEvent>().last.text,
        'check the tests',
      );

      connection.deliver(<String, Object?>{
        'type': 'response.function_call_arguments.done',
        'name': 'delegate_to_agent',
        'call_id': 'call_9',
        'arguments': '{"request":"run the tests"}',
      });
      await _settle();
      final prompt = events.whereType<VoicePromptEvent>().single;
      expect(prompt.prompt.text, 'run the tests');

      await backend.speak('they all pass');
      await _settle();
      expect(
        connection.sent.map((message) => message['type']),
        containsAll(<String>['conversation.item.create', 'response.create']),
      );
      final result = connection.sent.firstWhere(
        (message) => message['type'] == 'conversation.item.create',
      );
      expect((result['item']! as Map)['call_id'], 'call_9');
      expect((result['item']! as Map)['output'], 'they all pass');
      expect(
        events.whereType<VoicePhaseEvent>().last.phase,
        VoicePhase.speaking,
        reason: events
            .map(
              (event) =>
                  event.runtimeType.toString() +
                  (event is VoicePhaseEvent ? ':${event.phase.name}' : ''),
            )
            .join(', '),
      );

      connection.deliver(<String, Object?>{'type': 'response.done'});
      await _settle();
      expect(
        events.whereType<VoicePhaseEvent>().last.phase,
        VoicePhase.listening,
      );

      await backend.setMuted(true);
      await _settle();
      expect(connection.muted, isTrue);
      expect(events.whereType<VoicePhaseEvent>().last.phase, VoicePhase.muted);

      await backend.interrupt();
      expect(connection.sent.last['type'], 'response.cancel');
      expect(connection.remoteAudio, isFalse);
      await backend.stop();
      expect(connection.disposed, 1);
    },
  );

  test('the generic protocol speaks its own messages', () async {
    final connection = ScriptedLiveConnection();
    final backend = LiveVoiceBackend(
      connection: connection,
      protocol: const LiveProtocol(openAi: false),
      config: _config(),
    );
    final events = <VoiceBackendEvent>[];
    backend.events.listen(events.add);
    await backend.start();
    await _settle();
    expect(connection.sent.first['type'], 'start');
    expect(connection.sent.first['session'], 's1');

    connection.deliver(<String, Object?>{
      'type': 'delegate',
      'text': 'make a task',
    });
    await _settle();
    expect(
      events.whereType<VoicePromptEvent>().single.prompt.text,
      'make a task',
    );
    await backend.speak('made it');
    expect(connection.sent.last, {'type': 'agent_reply', 'text': 'made it'});
    await backend.stop();
  });

  test('a provider error is a fatal problem', () async {
    final connection = ScriptedLiveConnection();
    final backend = LiveVoiceBackend(
      connection: connection,
      protocol: const LiveProtocol(openAi: false),
      config: _config(),
    );
    final events = <VoiceBackendEvent>[];
    backend.events.listen(events.add);
    await backend.start();
    await _settle();
    connection.deliver(<String, Object?>{
      'type': 'error',
      'message': 'no session',
    });
    await _settle();
    final failure = events.whereType<VoiceFailureEvent>().single;
    expect(failure.problem.label, 'Live connection failed');
    expect(failure.problem.detail, 'no session');
    expect(failure.problem.recoverable, isFalse);
    await backend.stop();
  });

  test('a connection that ends ends the screen', () async {
    final connection = ScriptedLiveConnection();
    final backend = LiveVoiceBackend(
      connection: connection,
      protocol: const LiveProtocol(openAi: false),
      config: _config(),
    );
    final events = <VoiceBackendEvent>[];
    backend.events.listen(events.add);
    await backend.start();
    await _settle();
    await connection.dispose();
    await _settle();
    expect(events.whereType<VoiceEndedEvent>(), isNotEmpty);
  });
}
