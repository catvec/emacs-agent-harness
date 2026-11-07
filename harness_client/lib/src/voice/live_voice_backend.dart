import 'dart:async';

import 'voice_backend.dart';
import 'voice_models.dart';
import 'live_protocol.dart';

/// The live provider: one WebRTC stream carries the microphone and the
/// provider's voice; a data channel carries captions and delegation.
///
/// The agent is still the harness session.  When the voice model delegates,
/// the request goes to the session like a typed message, and the finished
/// reply is returned to the voice model to say.  The provider may also answer
/// simple things itself; it is the conversational front, not the worker.
class LiveVoiceBackend implements VoiceBackend {
  LiveVoiceBackend({
    required this.connection,
    required this.protocol,
    required this.config,
  });

  final LiveVoiceConnection connection;
  final LiveProtocol protocol;
  final LiveVoiceConfig config;

  final _events = StreamController<VoiceBackendEvent>.broadcast();
  final List<String> _pendingCalls = <String>[];
  StreamSubscription<Map<String, Object?>>? _messages;
  Timer? _audioBack;
  bool _started = false;
  bool _closed = false;
  bool _muted = false;
  bool _paused = false;
  bool _speechActive = false;
  final List<String> _heldReplies = <String>[];

  /// The pipeline segment of the utterance being heard now, and the reply
  /// last handed to the provider, so its own playback state can be named.
  String? _segment;
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
      _emit(const VoicePhaseEvent(VoicePhase.listening));
    } catch (error) {
      _fail('Live connection failed', error);
    }
  }

  void _onMessage(Map<String, Object?> message) {
    if (_closed) return;
    for (final event in protocol.decode(message)) {
      if (event is VoiceDelegateEvent) {
        if (event.callId != null && event.callId!.isNotEmpty) {
          _pendingCalls.add(event.callId!);
        }
        final segment = _segment ??= _newSegment();
        // The delegation is the transcript this provider made of the
        // utterance; the pipeline showed it as speech before any words.
        _emit(
          VoiceSegmentEvent(
            id: segment,
            stage: VoiceSegmentStage.transcribed,
            text: event.text,
          ),
        );
        final pending = _takeHeld();
        _emit(
          VoicePromptEvent(
            VoicePrompt(
              text: event.text,
              pending: pending.isEmpty ? null : pending,
              id: event.callId,
              segmentId: segment,
            ),
          ),
        );
        _emit(const VoicePhaseEvent(VoicePhase.thinking));
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

  /// The provider's own speech gate.  Its onset opens a segment; a later
  /// event for the same item adopts the provider's id instead of adding a
  /// second segment for one utterance.
  void _onSpeech(VoiceSpeechEvent event) {
    final wasActive = _speechActive;
    _speechActive = event.active;
    _audioBack?.cancel();
    _audioBack = null;
    if (event.active) {
      if (!wasActive || _segment == null) {
        _segment = event.id ?? _newSegment();
        _emit(
          VoiceSegmentEvent(id: _segment!, stage: VoiceSegmentStage.accepted),
        );
      }
      unawaited(connection.setRemoteAudioEnabled(false));
    } else if (!_paused) {
      _audioBack = Timer(const Duration(milliseconds: 220), () {
        unawaited(_resumeAudio());
      });
    }
    _emit(event);
  }

  /// A transcript for the utterance being heard, or the provider's report
  /// that it found no words in it.  Its segment id is the provider's own,
  /// else the onset's.
  void _onUtterance(VoiceBackendEvent event) {
    if (event is VoiceCaptionEvent) {
      if (event.speaker != VoiceSpeaker.you) {
        _emit(event);
        return;
      }
      final id = event.segmentId ?? _segment ?? (_segment = _newSegment());
      _emit(
        VoiceSegmentEvent(
          id: id,
          stage: event.finalized
              ? VoiceSegmentStage.transcribed
              : VoiceSegmentStage.transcribing,
          text: event.text,
        ),
      );
    }
    _emit(event);
  }

  void _onPhase(VoicePhaseEvent event) {
    if (event.phase == VoicePhase.speaking) {
      // The provider's player is playing its reply; this is the real speech,
      // not the text that was handed to it.
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
    if (event.phase == VoicePhase.listening && !_speechActive && !_paused) {
      unawaited(_resumeAudio());
    }
    _emit(event);
  }

  String _newSegment() => 'live-${++_segmentSequence}';

  @override
  Future<void> setMuted(bool muted) async {
    if (_closed || _muted == muted) return;
    _muted = muted;
    if (muted) _heldReplies.clear();
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
    _speechActive = false;
    _heldReplies.clear();
    _audioBack?.cancel();
    _audioBack = null;
    _generation++;
    try {
      await connection.send(protocol.interrupt());
      await connection.setMuted(true);
      await connection.setRemoteAudioEnabled(false);
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
      await connection.setRemoteAudioEnabled(true);
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
      await connection.setRemoteAudioEnabled(false);
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

  Future<void> _resumeAudio() async {
    _audioBack?.cancel();
    _audioBack = null;
    if (_closed || _paused) return;
    try {
      await connection.setRemoteAudioEnabled(true);
    } catch (_) {
      // The connection may be gone; its own failure is reported there.
    }
  }

  @override
  Future<void> speak(String text, {String? replyId}) async {
    final trimmed = text.trim();
    _heldReplies.remove(trimmed);
    if (_closed || trimmed.isEmpty) return;
    if (_paused || _speechActive) {
      _remember(trimmed);
      _emit(VoiceHeldEvent(trimmed, id: replyId));
      return;
    }
    final callId = _pendingCalls.isEmpty ? null : _pendingCalls.removeAt(0);
    final reply = protocol.agentReply(trimmed, callId: callId);
    if (reply == null) return;
    try {
      await connection.send(reply);
      if (callId != null) {
        final follow = protocol.continuation();
        if (follow != null) await connection.send(follow);
      }
      // Handed over, not spoken: the provider starts its own audio, and its
      // `speaking` event is what says that playback began.
      _handedReply = replyId;
      if (replyId != null) _emit(VoiceReplyHandedEvent(replyId));
    } catch (error) {
      _fail('Live connection failed', error);
    }
  }

  List<String> _takeHeld() {
    final held = List<String>.of(_heldReplies);
    _heldReplies.clear();
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
    _emit(const VoiceEndedEvent());
    _closed = true;
    _generation++;
    _heldReplies.clear();
    _audioBack?.cancel();
    _audioBack = null;
    await _messages?.cancel();
    _messages = null;
    try {
      await connection.dispose();
    } catch (_) {
      // A peer connection that is already gone is still stopped.
    }
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
