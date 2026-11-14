import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/voice/live_protocol.dart';
import 'package:harness_client/src/voice/voice_backend.dart';
import 'package:harness_client/src/voice/voice_models.dart';

LiveVoiceConfig config({List<String> history = const []}) => LiveVoiceConfig(
  endpoint: 'https://api.openai.com/v1',
  model: 'gpt-live-1',
  token: 'ek_test',
  voice: 'vale',
  language: 'en',
  instructions: 'be brief',
  sessionId: 's1',
  sessionTitle: 'Build the thing',
  cwd: '/tmp/project',
  history: history,
);

void main() {
  group('the harness voice protocol', () {
    const protocol = LiveProtocol(openAi: false);

    test('reads captions, phases and delegation', () {
      expect(
        protocol.decode({'type': 'ready'}),
        [isA<VoicePhaseEvent>()],
      );
      final caption = protocol.decode({
        'type': 'caption',
        'speaker': 'you',
        'text': 'do it',
        'final': true,
      }).single as VoiceCaptionEvent;
      expect(caption.speaker, VoiceSpeaker.you);
      expect(caption.text, 'do it');
      expect(caption.finalized, isTrue);

      final agent = protocol.decode({
        'type': 'caption',
        'speaker': 'agent',
        'text': 'on it',
      }).single as VoiceCaptionEvent;
      expect(agent.speaker, VoiceSpeaker.agent);
      expect(agent.finalized, isFalse);

      final phase = protocol.decode({
        'type': 'phase',
        'phase': 'speaking',
      }).single as VoicePhaseEvent;
      expect(phase.phase, VoicePhase.speaking);

      final delegate = protocol.decode({
        'type': 'delegate',
        'id': 'c1',
        'text': 'rename the task',
      }).single as VoiceDelegateEvent;
      expect(delegate.text, 'rename the task');
      expect(delegate.callId, 'c1');
      expect(delegate.segmentId, isNull, reason: 'call id is not input id');
      expect(delegate.truncated, isFalse);
    });

    test('only a real truncated boolean marks a delegation', () {
      for (final value in [true, false, null, 'true', 'false', 1, 0, <Object>[]]) {
        final delegate = protocol.decode({
          'type': 'delegate',
          'id': 'call-1',
          'utterance': 7,
          'text': 'the request and',
          'truncated': value,
        }).single as VoiceDelegateEvent;
        expect(delegate.truncated, identical(value, true), reason: '$value');
        expect(delegate.segmentId, 'u-7');
      }
      const delegate = VoiceDelegateEvent('ordinary');
      expect(delegate.truncated, isFalse);
    });

    test('plain delegations associate only explicit input ids', () {
      for (final field in ['item_id', 'itemId', 'utterance']) {
        final delegate = protocol.decode({
          'type': 'delegate',
          'id': 'call-id',
          field: 'input-id',
          'text': 'request',
        }).single as VoiceDelegateEvent;
        expect(delegate.callId, 'call-id');
        expect(delegate.segmentId, 'input-id');
      }
    });

    test('reports an error as a problem', () {
      final event = protocol.decode({
        'type': 'error',
        'message': 'no frames',
      }).single as VoiceFailureEvent;
      expect(event.problem.label, 'Live connection failed');
      expect(event.problem.detail, 'no frames');
    });

    test('sends a start message, replies and an interrupt', () {
      final start = protocol.sessionUpdate(config(history: ['Person: hi']));
      expect(start, isNotNull);
      expect(start!['type'], 'start');
      expect(start['session'], 's1');
      expect(start['history'], ['Person: hi']);
      expect('${start['instructions']}', contains('delegate_to_agent'));

      expect(protocol.agentReply('done'), {
        'type': 'agent_reply',
        'text': 'done',
      });
      expect(protocol.interrupt(), {'type': 'interrupt'});
      expect(protocol.continuation(), isNull);
    });
  });

  group('the OpenAI Realtime dialect', () {
    const protocol = LiveProtocol(openAi: true);

    test('reads both speakers and the phases around a turn', () {
      final user = protocol.decode({
        'type': 'conversation.item.input_audio_transcription.completed',
        'transcript': 'open the task',
      }).single as VoiceCaptionEvent;
      expect(user.speaker, VoiceSpeaker.you);
      expect(user.text, 'open the task');
      expect(user.finalized, isTrue);

      final partial = protocol.decode({
        'type': 'response.audio_transcript.delta',
        'delta': 'the task',
      }).single as VoiceCaptionEvent;
      expect(partial.speaker, VoiceSpeaker.agent);
      expect(partial.text, 'the task');
      expect(partial.finalized, isFalse);

      final done = protocol.decode({
        'type': 'response.audio_transcript.done',
        'transcript': 'the task is open',
      }).single as VoiceCaptionEvent;
      expect(done.finalized, isTrue);

      final started = protocol.decode({
        'type': 'input_audio_buffer.speech_started',
      });
      expect((started.first as VoiceSpeechEvent).active, isTrue);
      expect((started.last as VoicePhaseEvent).phase, VoicePhase.hearing);
      final stopped = protocol.decode({
        'type': 'input_audio_buffer.speech_stopped',
      });
      expect((stopped.first as VoiceSpeechEvent).active, isFalse);
      expect(
        (protocol.decode({'type': 'response.audio.delta'}).single
            as VoicePhaseEvent).phase,
        VoicePhase.speaking,
      );
      expect(
        (protocol.decode({'type': 'response.done'}).single
            as VoicePhaseEvent).phase,
        VoicePhase.listening,
      );
    });

    test('reads a delegate function call', () {
      final event = protocol.decode({
        'type': 'response.function_call_arguments.done',
        'name': 'delegate_to_agent',
        'call_id': 'call_7',
        'item_id': 'function-output-item',
        'truncated': true,
        'arguments': jsonEncode({'request': 'check the tests', 'truncated': true}),
      }).single as VoiceDelegateEvent;
      expect(event.text, 'check the tests');
      expect(event.callId, 'call_7');
      expect(event.segmentId, isNull, reason: 'function item id is not user audio');
      expect(event.truncated, isFalse, reason: 'model/tool output is not capture metadata');
    });

    test('ignores another function call and unknown events', () {
      expect(
        protocol.decode({
          'type': 'response.function_call_arguments.done',
          'name': 'something_else',
          'arguments': '{}',
        }),
        isEmpty,
      );
      expect(protocol.decode({'type': 'response.audio.delta'}), hasLength(1));
      expect(protocol.decode({'type': 'not.a.thing'}), isEmpty);
      expect(protocol.decode({}), isEmpty);
    });

    test('updates the session with the delegate tool and a voice', () {
      final update = protocol.sessionUpdate(config())!;
      expect(update['type'], 'session.update');
      final session = update['session']! as Map<String, Object?>;
      expect(session['model'], 'gpt-live-1');
      final audio = session['audio']! as Map;
      final input = audio['input']! as Map;
      expect(input['turn_detection'], {
        'type': 'semantic_vad',
        'eagerness': 'low',
      });
      expect(input['transcription'], {'model': 'whisper-1', 'language': 'en'});
      expect(audio['output'], {'voice': 'vale'});
      expect(session.containsKey('turn_detection'), isFalse);
      expect(session.containsKey('voice'), isFalse);
      expect(session.containsKey('input_audio_format'), isFalse);
      expect(session.containsKey('output_audio_format'), isFalse);
      expect(session.containsKey('input_audio_transcription'), isFalse);
      final tools = session['tools']! as List;
      expect((tools.single as Map)['name'], 'delegate_to_agent');
      expect('${session['instructions']}', contains('Backchannel policy'));
    });

    test('returns a delegation result to the call that asked for it', () {
      expect(protocol.agentReply('it passed', callId: 'call_7'), {
        'type': 'conversation.item.create',
        'item': {
          'type': 'function_call_output',
          'call_id': 'call_7',
          'output': 'it passed',
        },
      });
      expect(protocol.agentReply('', callId: 'call_8'), {
        'type': 'conversation.item.create',
        'item': {
          'type': 'function_call_output',
          'call_id': 'call_8',
          'output': '',
        },
      });
      final continuation = protocol.continuation()!;
      expect(continuation['type'], 'response.create');
      expect(protocol.interrupt(), {'type': 'response.cancel'});
    });

    test('a report that is not a function result is a response request', () {
      final request = protocol.agentReply('it passed')!;
      expect(request['type'], 'response.create');
      expect('${request['response']}', contains('it passed'));
      expect(protocol.agentReply('  '), isNull);
    });

    test('the instructions carry the session and the recent turns', () {
      final text = liveVoiceInstructions(config(history: [
        'Person: hello',
        'Agent: hi',
      ]));
      expect(text, contains('Build the thing'));
      expect(text, contains('/tmp/project'));
      expect(text, contains('Person: hello'));
      expect(text.toLowerCase(), contains('do not claim'));
      expect(text, contains('"hold on", "one second", "let me think"'));
      expect(text, contains('without an automatic timeout'));
      expect(text, contains('Do not delegate, acknowledge or start a reply during that pause.'));
      expect(text, contains('unfinished request or likely audio cut-off'));
      expect(text, contains('An entire utterance of "continue" or "go on"'));
      expect(text, contains('With no held request, pass that cue on unchanged'));
      expect(text, contains('Embedded or quoted recovery cues are not commands.'));
    });
  });
}
