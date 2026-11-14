import 'dart:async';

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

({LiveVoiceBackend backend, ScriptedLiveConnection connection, List<VoiceBackendEvent> events})
_live({bool openAi = true, ScriptedLiveConnection? connection}) {
  final live = connection ?? ScriptedLiveConnection();
  final backend = LiveVoiceBackend(
    connection: live,
    protocol: LiveProtocol(openAi: openAi),
    config: _config(),
  );
  final events = <VoiceBackendEvent>[];
  backend.events.listen(events.add);
  return (backend: backend, connection: live, events: events);
}

void _speech(ScriptedLiveConnection connection, String id, bool active) {
  connection.deliver({
    'type': active
        ? 'input_audio_buffer.speech_started'
        : 'input_audio_buffer.speech_stopped',
    'item_id': id,
  });
}

void _caption(ScriptedLiveConnection connection, String id, String text) {
  connection.deliver({
    'type': 'conversation.item.input_audio_transcription.completed',
    'item_id': id,
    'transcript': text,
  });
}

void _delegate(
  ScriptedLiveConnection connection,
  String id,
  String text, {
  String? responseId,
}) {
  connection.deliver({
    'type': 'response.function_call_arguments.done',
    'name': 'delegate_to_agent',
    'call_id': id,
    'item_id': 'output-$id', // A function output item, not a user utterance.
    if (responseId != null) 'response_id': responseId,
    'arguments': '{"request":"$text"}',
  });
}

void main() {
  test('autonomous greeting source retires before a later delegated request', () async {
    final rig = _live();
    await rig.backend.start();
    _speech(rig.connection, 'hello-input', true);
    _speech(rig.connection, 'hello-input', false);
    _caption(rig.connection, 'hello-input', 'Hello.');
    rig.connection.deliver({'type': 'response.created', 'response': {'id': 'greeting'}});
    rig.connection.deliver({'type': 'response.done', 'response': {'id': 'greeting'}});
    await _settle();
    _speech(rig.connection, 'request-input', true);
    _speech(rig.connection, 'request-input', false);
    _caption(rig.connection, 'request-input', 'Fix the tests.');
    rig.connection.deliver({'type': 'response.created', 'response': {'id': 'work'}});
    _delegate(rig.connection, 'work-call', 'Fix the tests.', responseId: 'work');
    await _settle();
    final prompt = rig.events.whereType<VoicePromptEvent>().single.prompt;
    expect(prompt.segmentIds, ['request-input']);
    expect(prompt.text, 'Fix the tests.');
    await rig.backend.stop();
  });

  test('turn hold survives listening and audio timers without muting the mic', () async {
    final rig = _live();
    await rig.backend.start();
    final control = rig.backend as VoiceTurnControl;
    await control.setTurnHeld(true);
    expect(rig.connection.remoteAudio, isFalse);
    expect(rig.connection.muted, isFalse);
    _speech(rig.connection, 'input-1', true);
    _speech(rig.connection, 'input-1', false);
    rig.connection.deliver({'type': 'response.done'});
    rig.connection.deliver({'type': 'response.output_audio.delta'});
    await _settle();
    await rig.backend.speak('Held result', replyId: 'n-held');
    await _settle();
    expect(rig.events.whereType<VoiceHeldEvent>().single.id, 'n-held');
    expect(rig.events.whereType<VoicePlaybackEvent>().any((event) => event.playing), isFalse);
    expect(rig.events.whereType<VoicePhaseEvent>().any((event) => event.phase == VoicePhase.speaking), isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 280));
    expect(rig.connection.remoteAudio, isFalse);
    await rig.backend.interrupt();
    await Future<void>.delayed(const Duration(milliseconds: 2100));
    expect(rig.connection.remoteAudio, isFalse, reason: 'interrupt timer is not turn commitment');
    await rig.backend.pause();
    await rig.backend.resume();
    expect(rig.connection.muted, isFalse);
    expect(rig.connection.remoteAudio, isFalse, reason: 'pause/resume cannot release the hold');
    expect(rig.connection.sent.where((message) => message['type'] == 'response.create'), isEmpty);
    await control.setTurnHeld(false);
    expect(rig.connection.remoteAudio, isTrue);
    await rig.backend.speak('Held result', replyId: 'n-held');
    expect(rig.connection.sent.where((message) => message['type'] == 'response.create'), hasLength(1));
    await rig.backend.stop();
  });

  test('releasing a hold during new speech cannot reopen remote audio', () async {
    final rig = _live();
    await rig.backend.start();
    await rig.backend.setTurnHeld(true);
    _speech(rig.connection, 'input-1', true);
    await _settle();
    await rig.backend.setTurnHeld(false);
    expect(rig.connection.remoteAudio, isFalse);
    expect(rig.connection.muted, isFalse);
    _speech(rig.connection, 'input-1', false);
    await _settle();
    await Future<void>.delayed(const Duration(milliseconds: 280));
    expect(rig.connection.remoteAudio, isTrue);
    await rig.backend.stop();
  });

  test('an earlier slow audio enable cannot finish after a hold disable', () async {
    final connection = _DelayedAudioConnection();
    final rig = _live(connection: connection);
    await rig.backend.start();
    connection.deliver({'type': 'response.done'});
    await connection.enableStarted.future;
    final held = rig.backend.setTurnHeld(true);
    connection.enableReady.complete();
    await held;
    expect(connection.remoteAudio, isFalse);
    expect(connection.audioChanges, [true, false]);
    expect(connection.muted, isFalse);
    await rig.backend.stop();
  });

  test('plain delegation metadata and receipt dedup precede pipeline events', () async {
    final rig = _live(openAi: false);
    await rig.backend.start();
    final message = <String, Object?>{
      'type': 'delegate',
      'id': 'call-7',
      'utterance': 7,
      'text': 'the request and',
      'truncated': true,
    };
    rig.connection.deliver(message);
    rig.connection.deliver(message);
    await _settle();
    final prompt = rig.events.whereType<VoicePromptEvent>().single.prompt;
    expect(prompt.truncated, isTrue);
    expect(prompt.id, 'call-7');
    expect(prompt.segmentId, 'u-7');
    expect(prompt.segmentIds, ['u-7']);
    expect(rig.events.whereType<VoiceSegmentEvent>().where((event) => event.stage == VoiceSegmentStage.accepted), hasLength(1));
    expect(rig.events.whereType<VoiceSegmentEvent>().where((event) => event.stage == VoiceSegmentStage.transcribed), hasLength(1));
    await rig.backend.stop();
  });

  test('untagged delayed delegations use input receipt order, not latest onset', () async {
    final rig = _live();
    await rig.backend.start();
    _speech(rig.connection, 'input-1', true);
    _speech(rig.connection, 'input-1', false);
    _speech(rig.connection, 'input-2', true);
    _delegate(rig.connection, 'call-1', 'first request');
    _caption(rig.connection, 'input-1', 'first request');
    _speech(rig.connection, 'input-2', false);
    _delegate(rig.connection, 'call-2', 'second request');
    await _settle();
    final prompts = rig.events.whereType<VoicePromptEvent>().map((event) => event.prompt);
    expect(prompts.map((prompt) => prompt.segmentId), ['input-1', 'input-2']);
    expect(prompts.map((prompt) => prompt.id), ['call-1', 'call-2']);
    expect(rig.events.whereType<VoiceCaptionEvent>().single.segmentId, 'input-1');
    expect(rig.events.whereType<VoiceSegmentEvent>().where((event) => event.stage == VoiceSegmentStage.accepted), hasLength(2));
    await rig.backend.stop();
  });

  test('a correlated response covers every ended input, never a newer active one', () async {
    final rig = _live();
    await rig.backend.start();
    _speech(rig.connection, 'input-1', true);
    _speech(rig.connection, 'input-1', false);
    _speech(rig.connection, 'input-2', true);
    _speech(rig.connection, 'input-2', false);
    // Transcript completions can arrive in the opposite order.
    _caption(rig.connection, 'input-2', 'then finish it');
    _caption(rig.connection, 'input-1', 'start this and');
    rig.connection.deliver({'type': 'response.created', 'response': {'id': 'response-1'}});
    _speech(rig.connection, 'input-3', true);
    _delegate(rig.connection, 'call-combined', 'start this and then finish it', responseId: 'response-1');
    await _settle();
    final prompt = rig.events.whereType<VoicePromptEvent>().single.prompt;
    expect(prompt.segmentId, 'input-1');
    expect(prompt.segmentIds, ['input-1', 'input-2']);
    expect(prompt.truncated, isFalse);
    final transcribed = rig.events.whereType<VoiceSegmentEvent>().where((event) => event.stage == VoiceSegmentStage.transcribed);
    expect(transcribed.map((event) => event.id), containsAll(['input-1', 'input-2']));
    expect(transcribed.map((event) => event.id), isNot(contains('input-3')));
    expect(rig.events.whereType<VoiceCaptionEvent>().map((event) => event.segmentId), ['input-2', 'input-1']);
    await rig.backend.stop();
  });

  test('anonymous onsets, late input ids, captions and delegate share one segment', () async {
    final rig = _live(openAi: false);
    await rig.backend.start();
    rig.connection.deliver({'type': 'speech', 'active': true});
    rig.connection.deliver({'type': 'caption', 'speaker': 'you', 'text': 'hold'});
    rig.connection.deliver({'type': 'speech', 'active': false, 'utterance': 9});
    rig.connection.deliver({'type': 'caption', 'speaker': 'you', 'text': 'hold on', 'final': true, 'utterance': 9});
    rig.connection.deliver({'type': 'delegate', 'id': 'call-9', 'utterance': 9, 'text': 'hold on'});
    await _settle();
    final accepted = rig.events.whereType<VoiceSegmentEvent>().where((event) => event.stage == VoiceSegmentStage.accepted).single;
    expect(accepted.id, 'live-1');
    expect(rig.events.whereType<VoiceCaptionEvent>().map((event) => event.segmentId), ['live-1', 'live-1']);
    expect(rig.events.whereType<VoicePromptEvent>().single.prompt.segmentIds, ['live-1']);
    await rig.backend.stop();
  });

  test('caption-only input always has a stable pipeline id', () async {
    final rig = _live(openAi: false);
    await rig.backend.start();
    rig.connection.deliver({'type': 'caption', 'speaker': 'you', 'text': 'let me think', 'final': true});
    await _settle();
    final caption = rig.events.whereType<VoiceCaptionEvent>().single;
    expect(caption.segmentId, 'live-1');
    expect(rig.events.whereType<VoicePromptEvent>(), isEmpty, reason: 'captions are not autonomous delegation');
    expect(rig.events.whereType<VoiceSegmentEvent>().last.id, caption.segmentId);
    await rig.backend.stop();
  });

  test('grouped calls, duplicate delegates and late recovery keep reply association', () async {
    final rig = _live();
    await rig.backend.start();
    _delegate(rig.connection, 'call-1', 'first part');
    _delegate(rig.connection, 'call-1', 'first part');
    _delegate(rig.connection, 'call-2', 'second part');
    await _settle();
    expect(rig.events.whereType<VoicePromptEvent>(), hasLength(2));
    final sources = rig.backend as VoiceTurnSources;
    sources.commitTurn(['call-1', 'call-2']);
    await rig.backend.speak('combined result');
    _delegate(rig.connection, 'call-recovery', 'go on');
    await _settle();
    sources.discardPrompt('call-recovery');
    await _settle();
    _delegate(rig.connection, 'call-3', 'next request');
    await _settle();
    sources.commitTurn(['call-3']);
    await rig.backend.speak('next result');
    final outputs = rig.connection.sent.where((message) => message['type'] == 'conversation.item.create').map((message) => message['item']! as Map);
    expect(outputs.map((item) => item['call_id']), ['call-1', 'call-2', 'call-recovery', 'call-3']);
    expect(outputs.map((item) => item['output']), ['combined result', '', '', 'next result']);
    expect(rig.connection.sent.where((message) => message['type'] == 'response.create'), hasLength(2), reason: 'one speech request per committed turn, none for discarded recovery');
    await rig.backend.stop();
  });

  test('empty commitment cancels unsent associations but keeps earlier committed calls', () async {
    final rig = _live();
    await rig.backend.start();
    _delegate(rig.connection, 'call-committed', 'old complete turn');
    await _settle();
    rig.backend.commitTurn(['call-committed']);
    _delegate(rig.connection, 'call-cancelled', 'unfinished and');
    await _settle();
    rig.backend.commitTurn([]);
    _delegate(rig.connection, 'call-new', 'new turn');
    await _settle();
    rig.backend.commitTurn(['call-new']);
    await rig.backend.speak('old result');
    await rig.backend.speak('new result');
    final outputs = rig.connection.sent.where((message) => message['type'] == 'conversation.item.create').map((message) => message['item']! as Map);
    expect(outputs.map((item) => item['call_id']), ['call-committed', 'call-new']);
    await rig.backend.stop();
  });

  test('a hold during tool result send defers continuation without taking next turn', () async {
    final connection = _DelayedReplyConnection();
    final rig = _live(connection: connection);
    await rig.backend.start();
    _delegate(connection, 'call-1', 'first request');
    _delegate(connection, 'call-2', 'second request');
    await _settle();
    rig.backend.commitTurn(['call-1']);
    rig.backend.commitTurn(['call-2']);
    final first = rig.backend.speak('first result', replyId: 'n-1');
    await connection.replyStarted.future;
    await rig.backend.setTurnHeld(true);
    connection.replyReady.complete();
    await first;
    await _settle();
    expect(connection.sent.where((message) => message['type'] == 'response.create'), isEmpty);
    expect(rig.events.whereType<VoiceHeldEvent>().single.id, 'n-1');
    await rig.backend.setTurnHeld(false);
    await rig.backend.speak('first result', replyId: 'n-1');
    await rig.backend.speak('second result', replyId: 'n-2');
    final outputs = connection.sent.where((message) => message['type'] == 'conversation.item.create').map((message) => message['item']! as Map);
    expect(outputs.map((item) => item['call_id']), ['call-1', 'call-2']);
    expect(outputs.map((item) => item['output']), ['first result', 'second result']);
    expect(connection.sent.where((message) => message['type'] == 'response.create'), hasLength(2));
    await rig.backend.stop();
  });

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

      await backend.speak('they all pass', replyId: 'n-1');
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
      // Handed over is not spoken: the provider has the text and starts its
      // own audio later.
      expect(events.whereType<VoiceReplyHandedEvent>().single.replyId, 'n-1');
      expect(
        events.whereType<VoicePhaseEvent>().last.phase,
        VoicePhase.thinking,
        reason: 'text generation is not playback',
      );
      expect(events.whereType<VoicePlaybackEvent>(), isEmpty);

      // The provider's own player is what reports speech.
      connection.deliver(<String, Object?>{'type': 'response.audio.delta'});
      await _settle();
      expect(
        events.whereType<VoicePhaseEvent>().last.phase,
        VoicePhase.speaking,
      );
      final playing = events.whereType<VoicePlaybackEvent>().last;
      expect(playing.playing, isTrue);
      expect(playing.replyId, 'n-1');

      connection.deliver(<String, Object?>{'type': 'response.done'});
      await _settle();
      expect(
        events.whereType<VoicePhaseEvent>().last.phase,
        VoicePhase.listening,
      );
      expect(events.whereType<VoicePlaybackEvent>().last.playing, isFalse);

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

  test('provider speech mutes its own audio until the person stops', () async {
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
    expect(connection.remoteAudio, isTrue);

    connection.deliver(<String, Object?>{
      'type': 'input_audio_buffer.speech_started',
    });
    await _settle();
    expect(events.whereType<VoiceSpeechEvent>().last.active, isTrue);
    expect(connection.remoteAudio, isFalse);

    connection.deliver(<String, Object?>{
      'type': 'input_audio_buffer.speech_stopped',
    });
    await _settle();
    expect(events.whereType<VoiceSpeechEvent>().last.active, isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 280));
    expect(connection.remoteAudio, isTrue);
    await backend.stop();
  });

  test('a reply during speech is held for the next delegation', () async {
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
    connection.deliver(<String, Object?>{
      'type': 'input_audio_buffer.speech_started',
    });
    await _settle();
    await backend.speak('Held reply.');
    await _settle();
    expect(events.whereType<VoiceHeldEvent>().single.text, 'Held reply.');
    expect(
      connection.sent.map((message) => message['type']),
      isNot(contains('conversation.item.create')),
    );

    connection.deliver(<String, Object?>{
      'type': 'response.function_call_arguments.done',
      'name': 'delegate_to_agent',
      'call_id': 'call_10',
      'arguments': '{"request":"run the tests"}',
    });
    await _settle();
    final prompt = events.whereType<VoicePromptEvent>().single;
    expect(prompt.prompt.text, 'run the tests');
    expect(prompt.prompt.pending, ['Held reply.']);
    expect(prompt.prompt.id, 'call_10');
    await backend.stop();
  });

  test('pause silences the provider and resume reopens it', () async {
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
    await backend.pause();
    await _settle();
    expect(connection.muted, isTrue);
    expect(connection.remoteAudio, isFalse);
    expect(events.whereType<VoicePhaseEvent>().last.phase, VoicePhase.paused);
    await backend.speak('During pause.');
    await _settle();
    expect(events.whereType<VoiceHeldEvent>().single.text, 'During pause.');
    await backend.resume();
    await _settle();
    expect(connection.muted, isFalse);
    expect(connection.remoteAudio, isTrue);
    expect(
      events.whereType<VoicePhaseEvent>().last.phase,
      VoicePhase.listening,
    );
    await backend.stop();
  });
}

class _DelayedAudioConnection extends ScriptedLiveConnection {
  final enableStarted = Completer<void>();
  final enableReady = Completer<void>();
  final audioChanges = <bool>[];

  @override
  Future<void> setRemoteAudioEnabled(bool enabled) async {
    audioChanges.add(enabled);
    if (enabled && !enableStarted.isCompleted) {
      enableStarted.complete();
      await enableReady.future;
    }
    await super.setRemoteAudioEnabled(enabled);
  }
}

class _DelayedReplyConnection extends ScriptedLiveConnection {
  final replyStarted = Completer<void>();
  final replyReady = Completer<void>();

  @override
  Future<void> send(Map<String, Object?> message) async {
    await super.send(message);
    if (message['type'] == 'conversation.item.create' && !replyStarted.isCompleted) {
      replyStarted.complete();
      await replyReady.future;
    }
  }
}
