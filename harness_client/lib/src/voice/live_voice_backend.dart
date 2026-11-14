import 'dart:async';

import 'voice_backend.dart';
import 'voice_android_audio.dart';
import 'voice_models.dart';
import 'live_protocol.dart';

/// The live provider: one WebRTC stream carries the microphone and the
/// provider's voice; a data channel carries captions and delegation.
///
/// The agent is still the harness session.  When the voice model delegates,
/// the request goes to the session like a typed message, and the finished
/// reply is returned to the voice model to say.  The provider may also answer
/// simple things itself; it is the conversational front, not the worker.
class LiveVoiceBackend
    implements VoiceBackend, VoiceTurnControl, VoiceTurnSources {
  LiveVoiceBackend({
    required this.connection,
    required this.protocol,
    required this.config,
    this.androidAudio = const SilentVoiceAndroidAudio(),
  });

  final LiveVoiceConnection connection;
  final LiveProtocol protocol;
  final LiveVoiceConfig config;

  /// The Android audio session this call plays through: the provider's voice
  /// is played by WebRTC itself, so the session it plays on is what has to be
  /// put on the media stream (see [AndroidVoiceOutput]).  It is held for the
  /// life of the call and given back on [stop]; on a platform that is not
  /// Android every call is a no-op.
  final VoiceAndroidAudio androidAudio;

  final _events = StreamController<VoiceBackendEvent>.broadcast();
  final List<String> _pendingCalls = <String>[];
  final List<List<String>> _committedCalls = <List<String>>[];
  final Set<String> _seenDelegates = <String>{};
  final Map<String, _LiveInput> _inputs = <String, _LiveInput>{};
  final Map<String, String> _inputAliases = <String, String>{};
  final Map<String, List<String>> _responseInputs = <String, List<String>>{};
  final Map<String, List<String>> _promptInputs = <String, List<String>>{};
  final Map<String, bool> _deferredReplies = <String, bool>{};
  StreamSubscription<Map<String, Object?>>? _messages;
  Timer? _audioBack;
  Future<void> _remoteAudio = Future<void>.value();
  bool _started = false;
  bool _closed = false;
  bool _muted = false;
  bool _paused = false;
  bool _speechActive = false;
  bool _turnHeld = false;
  final List<String> _heldReplies = <String>[];

  /// The current input and last handed reply. Ended inputs stay in receipt
  /// order until delegated, rather than being overwritten by the next onset.
  String? _activeSegment;
  int _segmentSequence = 0;
  String? _handedReply;
  int _generation = 0;

  @override
  Stream<VoiceBackendEvent> get events => _events.stream;

  @override
  Future<void> start() async {
    if (_started || _closed) return;
    _started = true;
    _emit(const VoicePhaseEvent(VoicePhase.connecting));
    // The provider's voice is played by the platform's realtime stack, so the
    // session it plays on is configured before the connection exists: the
    // playout attributes are read once, when that stack initializes.
    await androidAudio.beginLive();
    try {
      await connection.connect(config);
      _messages = connection.messages.listen(
        _onMessage,
        onError: (Object error, StackTrace stack) {
          _fail('Live connection failed', error);
        },
        onDone: () {
          if (!_closed) _emit(const VoiceEndedEvent());
        },
      );
      final update = protocol.sessionUpdate(config);
      if (update != null) await connection.send(update);
      if (_audioHeld) await _setRemoteAudioEnabled(false);
      _emit(const VoicePhaseEvent(VoicePhase.listening));
    } catch (error) {
      _fail('Live connection failed', error);
    }
  }

  void _onMessage(Map<String, Object?> message) {
    if (_closed) return;
    if (message['type'] == 'response.done') {
      final response = message['response'];
      final id = response is Map ? response['id'] : null;
      if (id is String) {
        // A completed autonomous response (e.g. a greeting) has no tool result
        // to wait for. Retire its input association instead of attaching it to
        // the next request, and keep only small identity tombstones.
        for (final source in _responseInputs.remove(id) ?? const <String>[]) {
          final input = _inputs[source];
          if (input != null && !input.delegated) {
            input.terminal = true;
            input.text = null;
          }
        }
      }
    }
    if (message['type'] == 'response.created') {
      final response = message['response'];
      final id = response is Map ? response['id'] : null;
      if (id is String && id.isNotEmpty) {
        // An OpenAI response is tied to the inputs known when it began, not
        // a newer onset that happens before its function arguments arrive.
        _responseInputs[id] = _inputs.values
            .where((input) => input.available && (!input.active || input.finalized))
            .map((input) => input.id)
            .toList();
      }
    }
    for (final event in protocol.decode(message)) {
      if (event is VoiceDelegateEvent) {
        final responseId = message['response_id'];
        _onDelegate(event, responseId: responseId is String ? responseId : null);
      } else if (event is VoiceSpeechEvent) {
        _onSpeech(event);
      } else if (event is VoiceSegmentEvent || event is VoiceCaptionEvent) {
        _onUtterance(event);
      } else if (event is VoicePhaseEvent) {
        _onPhase(event);
      } else {
        _emit(event);
      }
    }
  }

  void _onDelegate(VoiceDelegateEvent event, {String? responseId}) {
    final callId = event.callId;
    final key = callId != null && callId.isNotEmpty
        ? 'call:$callId'
        : event.segmentId == null
        ? null
        : 'input:${event.segmentId}';
    // Deduplication precedes both pipeline events and result bookkeeping.
    if (key != null && !_seenDelegates.add(key)) return;
    if (_muted || _paused) {
      _acknowledgeCall(callId);
      return;
    }
    final sources = <_LiveInput>[];
    if (event.segmentId != null) {
      final input = _inputFor(event.segmentId);
      if (!input.available) {
        _acknowledgeCall(callId);
        return;
      }
      sources.add(input);
    } else if (responseId != null && _responseInputs.containsKey(responseId)) {
      final associated = _responseInputs.remove(responseId)!;
      for (final id in associated) {
        final input = _inputs[id];
        if (input != null && input.available) sources.add(input);
      }
      if (associated.isNotEmpty && sources.isEmpty) {
        _acknowledgeCall(callId);
        return;
      }
    } else {
      // Providers without response/input correlation get the oldest ended
      // source, never the newer active utterance. Repeated words are valid;
      // without a stable id they are not duplicate events.
      for (final input in _inputs.values) {
        if (input.available && (!input.active || input.finalized)) {
          sources.add(input);
          break;
        }
      }
      if (sources.isEmpty && _activeSegment != null) {
        final input = _inputs[_activeSegment];
        if (input != null && input.available) sources.add(input);
      }
    }
    if (sources.isEmpty) sources.add(_createInput());
    if (callId != null && callId.isNotEmpty) _pendingCalls.add(callId);
    final segmentIds = List<String>.unmodifiable(
      sources.map((input) => input.id),
    );
    for (final input in sources) {
      input.delegated = true;
      _emit(
        VoiceSegmentEvent(
          id: input.id,
          stage: VoiceSegmentStage.transcribed,
          text: input.text ?? (input == sources.first ? event.text : null),
        ),
      );
    }
    final promptId = callId ?? sources.first.id;
    _promptInputs[promptId] = segmentIds;
    final pending = _takeHeld();
    _emit(
      VoicePromptEvent(
        VoicePrompt(
          text: event.text,
          pending: pending.isEmpty ? null : pending,
          id: promptId,
          segmentId: sources.first.id,
          segmentIds: segmentIds,
          truncated: event.truncated,
        ),
      ),
    );
    _emit(const VoicePhaseEvent(VoicePhase.thinking));
  }

  /// A late provider id aliases an anonymous onset; the accepted pipeline id
  /// never changes. Explicit input ids can arrive out of transcript order.
  _LiveInput _inputFor(String? providerId, {bool onset = false}) {
    if (providerId != null && providerId.isNotEmpty) {
      final known = _inputs[_inputAliases[providerId] ?? providerId];
      if (known != null) return known;
      _LiveInput? anonymous;
      if (onset && _speechActive) {
        anonymous = _inputs[_activeSegment];
      } else if (!onset) {
        for (final input in _inputs.values) {
          if (!input.named && !input.terminal) {
            anonymous = input;
            break;
          }
        }
      }
      if (anonymous != null && !anonymous.named) {
        anonymous.named = true;
        _inputAliases[providerId] = anonymous.id;
        return anonymous;
      }
      return _createInput(providerId);
    }
    final active = _inputs[_activeSegment];
    if (active != null && !active.terminal) return active;
    if (!onset) {
      for (final input in _inputs.values) {
        if (input.available && !input.finalized) return input;
      }
    }
    return _createInput();
  }

  _LiveInput _createInput([String? providerId]) {
    final input = _LiveInput(
      providerId ?? 'live-${++_segmentSequence}',
      named: providerId != null,
    );
    _inputs[input.id] = input;
    if (providerId != null) _inputAliases[providerId] = input.id;
    _emit(VoiceSegmentEvent(id: input.id, stage: VoiceSegmentStage.accepted));
    return input;
  }

  void _onSpeech(VoiceSpeechEvent event) {
    if (_muted || _paused) return;
    _audioBack?.cancel();
    _audioBack = null;
    _LiveInput? input;
    if (event.active) {
      input = _inputFor(event.id, onset: true);
      if (!input.available && _activeSegment != input.id) return;
      final previous = _inputs[_activeSegment];
      if (previous != null && previous != input) previous.active = false;
      _activeSegment = input.id;
      input.active = true;
      _speechActive = true;
      unawaited(_setRemoteAudioEnabled(false));
    } else {
      if (event.id != null) {
        input = _inputFor(event.id);
      } else if (_activeSegment != null) {
        input = _inputs[_activeSegment];
      }
      if (input != null) {
        input.active = false;
        if (input.id == _activeSegment) _activeSegment = null;
        if (input.available && !input.finalized) {
          _emit(
            VoiceSegmentEvent(id: input.id, stage: VoiceSegmentStage.transcribing),
          );
        }
      }
      _speechActive = _activeSegment != null;
      if (!_audioHeld) {
        _audioBack = Timer(const Duration(milliseconds: 220), () {
          unawaited(_resumeAudio());
        });
      }
    }
    _emit(VoiceSpeechEvent(_speechActive, id: input?.id ?? event.id));
  }

  void _onUtterance(VoiceBackendEvent event) {
    if (event is VoiceCaptionEvent) {
      if (event.speaker != VoiceSpeaker.you) {
        _emit(event);
        return;
      }
      if (_muted || _paused) return;
      final input = _inputFor(event.segmentId);
      if (input.terminal) return;
      input.finalized = input.finalized || event.finalized;
      if (!input.committed) input.text = event.text;
      _emit(
        VoiceSegmentEvent(
          id: input.id,
          stage: input.finalized
              ? VoiceSegmentStage.transcribed
              : VoiceSegmentStage.transcribing,
          text: event.text,
        ),
      );
      // Captions and pipeline events use the same fallback id, including
      // caption-only continuations that have not delegated yet.
      _emit(
        VoiceCaptionEvent(
          event.speaker,
          event.text,
          finalized: event.finalized,
          segmentId: input.id,
        ),
      );
    } else if (event is VoiceSegmentEvent) {
      if (_muted || _paused) return;
      final input = _inputFor(event.id);
      if (input.terminal) return;
      if (event.stage == VoiceSegmentStage.dropped ||
          event.stage == VoiceSegmentStage.failed) {
        input.terminal = true;
      }
      _emit(
        VoiceSegmentEvent(
          id: input.id,
          stage: event.stage,
          duration: event.duration,
          level: event.level,
          text: event.text,
          drop: event.drop,
          detail: event.detail,
        ),
      );
    }
  }

  bool get _audioHeld => _paused || _turnHeld || _speechActive;

  void _onPhase(VoicePhaseEvent event) {
    if (_paused) return;
    if (event.phase == VoicePhase.speaking) {
      if (_audioHeld) return; // Disabled remote audio is not actual playback.
      _emit(
        VoicePlaybackEvent(
          playing: true,
          replyId: _handedReply,
          generation: _generation,
        ),
      );
    } else if (event.phase == VoicePhase.listening ||
        event.phase == VoicePhase.interrupted) {
      _emit(
        VoicePlaybackEvent(
          playing: false,
          replyId: _handedReply,
          generation: _generation,
        ),
      );
    }
    if (event.phase == VoicePhase.listening && !_audioHeld) {
      unawaited(_resumeAudio());
    }
    _emit(event);
  }

  void _cancelInput() {
    for (final input in _inputs.values) {
      input.text = null;
      if (input.terminal || input.committed) continue;
      input.terminal = true;
      input.active = false;
      _emit(
        VoiceSegmentEvent(
          id: input.id,
          stage: VoiceSegmentStage.dropped,
          drop: VoiceSegmentDrop.cancelled,
        ),
      );
    }
    _activeSegment = null;
    _speechActive = false;
    _responseInputs.clear();
    _promptInputs.clear();
    _pendingCalls.clear();
    _deferredReplies.clear();
  }

  @override
  Future<void> setTurnHeld(bool held) async {
    if (_closed || _turnHeld == held) return;
    _turnHeld = held;
    _audioBack?.cancel();
    _audioBack = null;
    if (held) {
      _generation++;
      _emit(
        VoicePlaybackEvent(
          playing: false,
          replyId: _handedReply,
          generation: _generation,
        ),
      );
      try {
        await _setRemoteAudioEnabled(false);
      } catch (error) {
        _fail('Live connection failed', error);
      }
    } else {
      await _resumeAudio();
    }
  }

  @override
  void commitTurn(List<String> promptIds) {
    if (_closed) return;
    if (promptIds.isEmpty) {
      _cancelInput();
      return;
    }
    final calls = <String>[];
    for (final id in promptIds) {
      for (final source in _promptInputs.remove(id) ?? const <String>[]) {
        final input = _inputs[source];
        if (input != null) {
          input.committed = true;
          input.text = null;
        }
      }
      if (_pendingCalls.remove(id)) calls.add(id);
    }
    // Keep even an id-less group in order with earlier committed turns.
    _committedCalls.add(calls);
  }

  @override
  void discardPrompt(String promptId) {
    if (_closed) return;
    for (final id in _promptInputs.remove(promptId) ?? const <String>[]) {
      final input = _inputs[id];
      if (input != null) {
        input.terminal = true;
        input.text = null;
      }
    }
    if (_pendingCalls.remove(promptId)) _acknowledgeCall(promptId);
  }

  void _acknowledgeCall(String? callId) {
    if (_closed || callId == null || callId.isEmpty) return;
    final reply = protocol.agentReply('', callId: callId);
    if (reply != null) {
      unawaited(connection.send(reply).catchError((Object error) {
        _fail('Live connection failed', error);
      }));
    }
  }

  @override
  Future<void> setMuted(bool muted) async {
    if (_closed || _muted == muted) return;
    _muted = muted;
    if (muted) {
      _heldReplies.clear();
      _cancelInput();
    }
    try {
      await connection.setMuted(muted || _paused);
      _emit(VoicePhaseEvent(muted ? VoicePhase.muted : VoicePhase.listening));
    } catch (error) {
      _fail('Microphone unavailable', error);
    }
  }

  @override
  Future<void> pause() async {
    if (_closed || _paused) return;
    _paused = true;
    _cancelInput();
    _heldReplies.clear();
    _audioBack?.cancel();
    _audioBack = null;
    _generation++;
    try {
      await connection.send(protocol.interrupt());
      await connection.setMuted(true);
      await _setRemoteAudioEnabled(false);
    } catch (error) {
      _fail('Live connection failed', error);
      return;
    }
    _emit(VoicePlaybackEvent(playing: false, generation: _generation));
    _emit(const VoicePhaseEvent(VoicePhase.paused));
  }

  @override
  Future<void> resume() async {
    if (_closed || !_paused) return;
    _paused = false;
    try {
      await connection.setMuted(_muted);
      await _resumeAudio();
    } catch (error) {
      _fail('Live connection failed', error);
      return;
    }
    _emit(VoicePhaseEvent(_muted ? VoicePhase.muted : VoicePhase.listening));
  }

  @override
  Future<void> interrupt() async {
    if (_closed) return;
    _heldReplies.clear();
    _generation++;
    try {
      await connection.send(protocol.interrupt());
      await _setRemoteAudioEnabled(false);
      _audioBack?.cancel();
      _audioBack = Timer(const Duration(seconds: 2), () {
        unawaited(_resumeAudio());
      });
      _emit(VoicePlaybackEvent(playing: false, generation: _generation));
      _emit(const VoicePhaseEvent(VoicePhase.interrupted));
      _emit(const VoicePhaseEvent(VoicePhase.listening));
    } catch (error) {
      _fail('Live connection failed', error);
    }
  }

  /// Serialize media toggles so a slow earlier enable cannot finish after a
  /// hold's disable. Recheck the gate when each queued enable actually runs.
  Future<void> _setRemoteAudioEnabled(bool enabled) {
    final operation = _remoteAudio.then((_) async {
      if (_closed) return;
      await connection.setRemoteAudioEnabled(enabled && !_audioHeld);
    });
    _remoteAudio = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> _resumeAudio() async {
    _audioBack?.cancel();
    _audioBack = null;
    if (_closed || _audioHeld) return;
    try {
      await _setRemoteAudioEnabled(true);
    } catch (_) {
      // The connection may be gone; its own failure is reported there.
    }
  }

  @override
  Future<void> speak(String text, {String? replyId}) async {
    final trimmed = text.trim();
    _heldReplies.remove(trimmed);
    if (_closed || trimmed.isEmpty) return;
    if (_audioHeld) {
      _remember(trimmed);
      _emit(VoiceHeldEvent(trimmed, id: replyId));
      return;
    }
    final key = replyId ?? trimmed;
    final deferred = _deferredReplies.remove(key);
    final calls = deferred != null
        ? const <String>[]
        : _committedCalls.isNotEmpty
        ? _committedCalls.removeAt(0)
        : <String>[if (_pendingCalls.isNotEmpty) _pendingCalls.removeAt(0)];
    final functionOutput = deferred ?? (protocol.openAi && calls.isNotEmpty);
    final reply = deferred == true
        ? protocol.continuation()
        : protocol.agentReply(trimmed, callId: calls.isEmpty ? null : calls.first);
    if (reply == null) return;
    try {
      await connection.send(reply);
      // All grouped calls finish together. Only the first carries the actual
      // result; the others are acknowledgements, not repeated speech.
      for (final callId in calls.skip(1)) {
        final acknowledgement = protocol.agentReply('', callId: callId);
        if (acknowledgement != null) await connection.send(acknowledgement);
      }
      if (_closed) return;
      if (_audioHeld) {
        _deferReply(trimmed, replyId: replyId, functionOutput: functionOutput);
        return;
      }
      if (calls.isNotEmpty) {
        final follow = protocol.continuation();
        if (follow != null) await connection.send(follow);
      }
      if (_closed) return;
      if (_audioHeld) {
        _deferReply(trimmed, replyId: replyId, functionOutput: functionOutput);
        return;
      }
      // Handed over, not spoken: the provider starts its own audio, and its
      // `speaking` event is what says that playback began.
      _handedReply = replyId;
      if (replyId != null) _emit(VoiceReplyHandedEvent(replyId));
    } catch (error) {
      _fail('Live connection failed', error);
    }
  }

  void _deferReply(
    String text, {
    String? replyId,
    required bool functionOutput,
  }) {
    // A hold arrived during send. Its tool outputs already went out; a retry
    // needs only the continuation, not another turn's result association.
    _deferredReplies[replyId ?? text] = functionOutput;
    _remember(text);
    _emit(VoiceHeldEvent(text, id: replyId));
  }

  List<String> _takeHeld() {
    final held = List<String>.of(_heldReplies);
    _heldReplies.clear();
    _deferredReplies.clear(); // Those results now travel as context, not replay.
    return held;
  }

  void _remember(String text) {
    if (_heldReplies.contains(text)) return;
    _heldReplies.add(text.length > 4000 ? text.substring(0, 4000) : text);
    if (_heldReplies.length > 40) _heldReplies.removeAt(0);
  }

  @override
  Future<void> stop() async {
    if (_closed) return;
    _cancelInput();
    _emit(const VoiceEndedEvent());
    _closed = true;
    _generation++;
    _heldReplies.clear();
    _committedCalls.clear();
    _audioBack?.cancel();
    _audioBack = null;
    await _messages?.cancel();
    _messages = null;
    try {
      await connection.dispose();
    } catch (_) {
      // A peer connection that is already gone is still stopped.
    }
    // The call is over: give the mode, the focus and the volume keys back, so
    // the next thing the phone plays is not treated as call audio.
    await androidAudio.endLive();
    await _events.close();
  }

  void _fail(String label, Object error) {
    if (_closed) return;
    final line = '$error'.trim().split('\n').first.trim();
    _emit(
      VoiceFailureEvent(
        VoiceProblem(
          label,
          detail: line.isEmpty ? error.runtimeType.toString() : line,
          recoverable: false,
        ),
      ),
    );
  }

  void _emit(VoiceBackendEvent event) {
    if (!_closed) _events.add(event);
  }
}

/// Receipt-time identity for one input chunk, independent of a later tool
/// call or response output item. The map containing these preserves onset order.
class _LiveInput {
  _LiveInput(this.id, {required this.named});

  final String id;
  bool named;
  bool active = false;
  bool finalized = false;
  bool delegated = false;
  bool committed = false;
  bool terminal = false;
  String? text;

  bool get available => !delegated && !terminal;
}

/// A [LiveVoiceConnection] driven by a script, for a test or a preview.
class ScriptedLiveConnection implements LiveVoiceConnection {
  ScriptedLiveConnection({List<Map<String, Object?>>? script})
    : script = script ?? <Map<String, Object?>>[];

  final List<Map<String, Object?>> script;
  final _messages = StreamController<Map<String, Object?>>.broadcast();
  final List<Map<String, Object?>> sent = <Map<String, Object?>>[];
  bool connected = false;
  bool muted = false;
  bool remoteAudio = true;
  int disposed = 0;
  int _next = 0;

  @override
  Stream<Map<String, Object?>> get messages => _messages.stream;

  @override
  Future<void> connect(LiveVoiceConfig config) async {
    connected = true;
  }

  @override
  Future<void> send(Map<String, Object?> message) async {
    sent.add(message);
  }

  @override
  Future<void> setMuted(bool value) async {
    muted = value;
  }

  @override
  Future<void> setRemoteAudioEnabled(bool enabled) async {
    remoteAudio = enabled;
  }

  @override
  Future<void> dispose() async {
    disposed++;
    await _messages.close();
  }

  /// Deliver the next scripted provider message, if any.
  void next() {
    if (_next >= script.length || _messages.isClosed) return;
    _messages.add(script[_next++]);
  }

  void deliver(Map<String, Object?> message) {
    if (!_messages.isClosed) _messages.add(message);
  }
}
