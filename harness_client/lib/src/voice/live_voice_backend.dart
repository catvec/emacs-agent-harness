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
        final pending = _takeHeld();
        _emit(
          VoicePromptEvent(
            VoicePrompt(
              text: event.text,
              pending: pending.isEmpty ? null : pending,
              id: event.callId,
            ),
          ),
        );
        _emit(const VoicePhaseEvent(VoicePhase.thinking));
      } else if (event is VoiceSpeechEvent) {
        _speechActive = event.active;
        _audioBack?.cancel();
        _audioBack = null;
        if (event.active) {
          unawaited(connection.setRemoteAudioEnabled(false));
        } else if (!_paused) {
          _audioBack = Timer(const Duration(milliseconds: 220), () {
            unawaited(_resumeAudio());
          });
        }
        _emit(event);
      } else if (event is VoicePhaseEvent) {
        if (event.phase == VoicePhase.listening && !_speechActive && !_paused) {
          unawaited(_resumeAudio());
        }
        _emit(event);
      } else {
        _emit(event);
      }
    }
  }

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
    try {
      await connection.send(protocol.interrupt());
      await connection.setMuted(true);
      await connection.setRemoteAudioEnabled(false);
    } catch (error) {
      _fail('Live connection failed', error);
      return;
    }
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
    try {
      await connection.send(protocol.interrupt());
      await connection.setRemoteAudioEnabled(false);
      _audioBack?.cancel();
      _audioBack = Timer(const Duration(seconds: 2), () {
        unawaited(_resumeAudio());
      });
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
  Future<void> speak(String text) async {
    final trimmed = text.trim();
    _heldReplies.remove(trimmed);
    if (_closed || trimmed.isEmpty) return;
    if (_paused || _speechActive) {
      _remember(trimmed);
      _emit(VoiceHeldEvent(trimmed));
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
      _emit(const VoicePhaseEvent(VoicePhase.speaking));
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
