import 'dart:convert';

import 'voice_backend.dart';
import 'voice_models.dart';

/// The instructions the voice model is given.  They are prose because they
/// are a model's prompt, not interface copy: the person never sees them.
String liveVoiceInstructions(LiveVoiceConfig config) {
  final history = config.history.isEmpty
      ? ''
      : '\n\nRecent conversation, oldest first:\n${config.history.join('\n')}';
  return '''
You are the voice of an emacs-agent-harness session named "${config.sessionTitle}" in ${config.cwd}.

You talk with the person in real time. Keep the conversation natural and short. Do not read code, diffs, file paths or long lists aloud; say what they mean, and let the screen show the details. Stay quiet while the person thinks.

You have one tool, delegate_to_agent. Call it whenever the person asks for anything that needs the session: work to do, a question about the project, a file to read, a task to check, a change to make, or a correction to work already asked for. Put the person's request in the request field, in their own words where you can. Do not call it for greetings, acknowledgements, or questions about what you can do.

While the agent works, say one short line to acknowledge the request, then wait. The agent's result comes back as the tool result; say it briefly, in your own voice. If the person interrupts you, stop speaking and listen. Do not claim work is done before the agent says it is. Never approve a permission request or answer a question for the person: the app asks them on screen, and you should say that an answer is needed.

Backchannel policy: use occasional short acknowledgements ("mm-hmm", "yeah") while the person speaks, but never compete with their words or your own answer.

Interruption policy: stop speaking when the person starts. Listen to what they say. Do not cancel the agent unless they ask you to.$history''';
}

/// Reads a live provider's data-channel messages and writes ours.
///
/// Two dialects share this codec:
///
///  * the harness voice protocol: plain `caption`, `phase`, `delegate`,
///    `error` and `ready` messages, which a sidecar can speak for any
///    full-duplex model or local pipeline;
///  * OpenAI's Realtime events, which a WebRTC session speaks directly.
///
/// The endpoint decides which is spoken when the offer is made; a message
/// that names an event of the other dialect is simply read as the one it is.
class LiveProtocol {
  const LiveProtocol({required this.openAi});

  final bool openAi;

  static const delegateTool = 'delegate_to_agent';

  List<VoiceBackendEvent> decode(Map<String, Object?> message) {
    final type = _string(message['type']);
    if (type == null || type.isEmpty) return const [];
    return switch (type) {
      // The harness voice protocol.
      'ready' || 'started' => const [VoicePhaseEvent(VoicePhase.listening)],
      'caption' => _caption(message),
      'phase' => _phase(message),
      'speech' => _speech(message),
      'delegate' => _delegate(message),
      'error' => _error(message),

      // OpenAI Realtime.
      'session.created' ||
      'session.updated' => const [VoicePhaseEvent(VoicePhase.listening)],
      'input_audio_buffer.speech_started' => [
        VoiceSpeechEvent(true, id: _itemId(message)),
        const VoicePhaseEvent(VoicePhase.hearing),
      ],
      'input_audio_buffer.speech_stopped' => [
        VoiceSpeechEvent(false, id: _itemId(message)),
        const VoicePhaseEvent(VoicePhase.thinking),
      ],
      'conversation.item.input_audio_transcription.delta' => _caption(
        message,
        speaker: VoiceSpeaker.you,
        textKey: 'delta',
      ),
      'conversation.item.input_audio_transcription.completed' => _userFinal(
        message,
      ),
      'conversation.item.input_audio_transcription.failed' => _segmentFailure(
        message,
      ),
      'response.audio_transcript.delta' || 'response.text.delta' => _caption(
        message,
        speaker: VoiceSpeaker.agent,
        textKey: 'delta',
      ),
      'response.audio_transcript.done' || 'response.text.done' => _caption(
        message,
        speaker: VoiceSpeaker.agent,
        textKey: 'transcript',
        finalized: true,
      ),
      'response.created' || 'response.output_item.added' => const [
        VoicePhaseEvent(VoicePhase.thinking),
      ],
      'response.audio.delta' || 'response.output_audio.delta' => const [
        VoicePhaseEvent(VoicePhase.speaking),
      ],
      'response.function_call_arguments.done' => _functionCall(message),
      'response.done' => const [VoicePhaseEvent(VoicePhase.listening)],
      _ => const [],
    };
  }

  List<VoiceBackendEvent> _caption(
    Map<String, Object?> message, {
    VoiceSpeaker? speaker,
    String textKey = 'text',
    bool finalized = false,
  }) {
    final who = speaker ?? _speaker(message['speaker']);
    final text = _string(message[textKey]) ?? _string(message['text']) ?? '';
    if (who == null || text.isEmpty) return const [];
    return [
      VoiceCaptionEvent(
        who,
        text,
        finalized: finalized || _bool(message['final']) == true,
        segmentId: _itemId(message),
      ),
    ];
  }

  /// The person's transcription for one item: a final caption, or, when the
  /// provider finished with no words at all, the drop that really happened.
  /// An empty final is not silence; it is a kept burst with no transcript.
  List<VoiceBackendEvent> _userFinal(Map<String, Object?> message) {
    final id = _itemId(message);
    final text =
        _string(message['transcript']) ?? _string(message['text']) ?? '';
    if (text.trim().isEmpty) {
      if (id == null || id.isEmpty) return const [];
      return [
        VoiceSegmentEvent(
          id: id,
          stage: VoiceSegmentStage.dropped,
          drop: VoiceSegmentDrop.noWords,
        ),
      ];
    }
    return [
      VoiceCaptionEvent(VoiceSpeaker.you, text, finalized: true, segmentId: id),
    ];
  }

  List<VoiceBackendEvent> _segmentFailure(Map<String, Object?> message) {
    final id = _itemId(message);
    if (id == null || id.isEmpty) return const [];
    final error = message['error'];
    final detail = error is Map
        ? _string(error['message']) ?? _string(error['code'])
        : _string(message['message']);
    return [
      VoiceSegmentEvent(
        id: id,
        stage: VoiceSegmentStage.failed,
        detail: detail,
      ),
    ];
  }

  /// The provider's own name for the input item a message is about.
  String? _itemId(Map<String, Object?> message) {
    final item = _string(message['item_id']) ?? _string(message['itemId']);
    if (item != null && item.isNotEmpty) return item;
    final utterance = message['utterance'];
    if (utterance is num) return 'u-$utterance';
    if (utterance is String && utterance.isNotEmpty) return utterance;
    final id = _string(message['id']);
    return id != null && id.isNotEmpty ? id : null;
  }

  List<VoiceBackendEvent> _speech(Map<String, Object?> message) {
    final active = _bool(message['active']) ?? _bool(message['on']);
    if (active == null) return const [];
    return [VoiceSpeechEvent(active, id: _itemId(message))];
  }

  List<VoiceBackendEvent> _phase(Map<String, Object?> message) {
    final name = _string(message['phase']) ?? _string(message['state']);
    if (name == null || name.isEmpty) return const [];
    final phase = switch (name) {
      'listening' => VoicePhase.listening,
      'hearing' => VoicePhase.hearing,
      'transcribing' => VoicePhase.transcribing,
      'thinking' => VoicePhase.thinking,
      'speaking' => VoicePhase.speaking,
      'muted' => VoicePhase.muted,
      'interrupted' => VoicePhase.interrupted,
      'approval' => VoicePhase.approval,
      'ended' => VoicePhase.ended,
      'failed' => VoicePhase.failed,
      // A phase this client does not know is reported as unknown rather
      // than silently leaving the previous word on screen.
      _ => VoicePhase.unknown,
    };
    if (phase == VoicePhase.hearing) {
      return [
        VoiceSpeechEvent(true, id: _itemId(message)),
        VoicePhaseEvent(phase),
      ];
    }
    if (phase == VoicePhase.transcribing || phase == VoicePhase.listening) {
      return [
        VoiceSpeechEvent(false, id: _itemId(message)),
        VoicePhaseEvent(phase),
      ];
    }
    return [VoicePhaseEvent(phase)];
  }

  List<VoiceBackendEvent> _delegate(Map<String, Object?> message) {
    final text =
        _string(message['text']) ??
        _string(message['request']) ??
        _string(message['transcript']) ??
        '';
    if (text.trim().isEmpty) return const [];
    return [
      VoiceDelegateEvent(
        text.trim(),
        callId: _string(message['id']) ?? _string(message['callId']),
      ),
    ];
  }

  List<VoiceBackendEvent> _functionCall(Map<String, Object?> message) {
    final name = _string(message['name']);
    final call = message['call'];
    final callMap = call is Map ? Map<String, Object?>.from(call) : const {};
    final function = name ?? _string(callMap['name']);
    if (function != delegateTool) return const [];
    final raw = _string(message['arguments']) ?? _string(callMap['arguments']);
    if (raw == null) return const [];
    Object? parsed;
    try {
      parsed = jsonDecode(raw);
    } catch (_) {
      // A provider that sends the request as plain text is still usable.
      parsed = raw;
    }
    final text = parsed is Map
        ? _string(parsed['request']) ?? _string(parsed['text']) ?? ''
        : '$parsed';
    if (text.trim().isEmpty) return const [];
    return [
      VoiceDelegateEvent(
        text.trim(),
        callId: _string(message['call_id']) ?? _string(callMap['call_id']),
      ),
    ];
  }

  List<VoiceBackendEvent> _error(Map<String, Object?> message) {
    final error = message['error'];
    final errorMap = error is Map ? Map<String, Object?>.from(error) : const {};
    final detail =
        _string(errorMap['message']) ??
        _string(message['message']) ??
        _string(message['detail']) ??
        'The live provider reported an error.';
    return [
      VoiceFailureEvent(
        VoiceProblem(
          'Live connection failed',
          detail: detail,
          recoverable: false,
        ),
      ),
    ];
  }

  /// What is sent once the data channel opens, or null for a dialect that
  /// learns nothing at start.
  Map<String, Object?>? sessionUpdate(LiveVoiceConfig config) {
    if (!openAi) {
      return <String, Object?>{
        'type': 'start',
        'protocol': 1,
        'session': config.sessionId,
        'title': config.sessionTitle,
        'cwd': config.cwd,
        'language': config.language,
        'instructions': liveVoiceInstructions(config),
        'history': config.history,
      };
    }
    final voice = config.voice.trim();
    return <String, Object?>{
      'type': 'session.update',
      'session': <String, Object?>{
        'type': 'realtime',
        'model': config.model,
        if (voice.isNotEmpty) 'voice': voice,
        'instructions': liveVoiceInstructions(config),
        'input_audio_format': 'pcm16',
        'output_audio_format': 'pcm16',
        'input_audio_transcription': <String, Object?>{
          if (config.language.trim().isNotEmpty) 'language': config.language,
          'model': 'whisper-1',
        },
        'turn_detection': <String, Object?>{
          'type': 'server_vad',
          'silence_duration_ms': 800,
          'prefix_padding_ms': 300,
        },
        'tools': <Object?>[
          <String, Object?>{
            'type': 'function',
            'name': delegateTool,
            'description': 'Ask the emacs-agent-harness session to do the request and return its result.',
            'parameters': <String, Object?>{
              'type': 'object',
              'properties': <String, Object?>{
                'request': <String, Object?>{
                  'type': 'string',
                  'description': 'The request, in the person\'s own words.',
                },
              },
              'required': <Object?>['request'],
            },
          },
        ],
        'tool_choice': 'auto',
      },
    };
  }

  /// The agent's finished result, to be spoken or shown by the provider.
  Map<String, Object?>? agentReply(String text, {String? callId}) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;
    if (!openAi) {
      return <String, Object?>{'type': 'agent_reply', 'text': trimmed};
    }
    if (callId != null && callId.isNotEmpty) {
      return <String, Object?>{
        'type': 'conversation.item.create',
        'item': <String, Object?>{
          'type': 'function_call_output',
          'call_id': callId,
          'output': trimmed,
        },
      };
    }
    return <String, Object?>{
      'type': 'response.create',
      'response': <String, Object?>{
        'instructions':
            'The agent finished. Say its result to the person briefly, in '
            'your own voice, without reading code, paths or a list aloud: '
            '$trimmed',
      },
    };
  }

  /// The follow-up that makes a provider speak a function result it just got.
  Map<String, Object?>? continuation() {
    if (!openAi) return null;
    return <String, Object?>{
      'type': 'response.create',
      'response': <String, Object?>{
        'instructions':
            'The agent finished. Say its result to the person briefly, in '
            'your own voice, without reading code, paths or a list aloud.',
      },
    };
  }

  Map<String, Object?> interrupt() => openAi
      ? <String, Object?>{'type': 'response.cancel'}
      : <String, Object?>{'type': 'interrupt'};

  VoiceSpeaker? _speaker(Object? value) {
    final text = _string(value)?.toLowerCase();
    return switch (text) {
      'you' || 'user' || 'person' => VoiceSpeaker.you,
      'agent' || 'assistant' || 'harness' => VoiceSpeaker.agent,
      _ => null,
    };
  }

  String? _string(Object? value) => value is String ? value : null;

  bool? _bool(Object? value) => value is bool ? value : null;
}
