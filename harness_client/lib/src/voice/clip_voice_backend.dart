import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'voice_audio.dart';
import 'voice_backend.dart';
import 'voice_models.dart';
import 'voice_settings.dart';

/// The clip provider: listen continuously, cut an utterance at a pause,
/// transcribe its WAV (or send the WAV itself), and let the agent answer.
///
/// This is the half-duplex path.  The microphone is open while the agent
/// works, so a correction can be started at any time; the agent's reply is
/// spoken by [VoiceSpeech], and starting to talk while it speaks stops it.
class ClipVoiceBackend implements VoiceBackend {
  ClipVoiceBackend({
    required this.microphone,
    required this.transcriber,
    required this.speech,
    required this.delivery,
    required this.endpoint,
    required this.model,
    required this.token,
    required this.language,
    required this.speakReplies,
    this.harnessAddress = '',
    this.vadConfig = const VoiceActivityConfig(),
  });

  final VoiceMicrophone microphone;
  final VoiceTranscriber transcriber;
  final VoiceSpeech speech;
  final ClipDelivery delivery;
  final String endpoint;
  final String model;
  final String token;
  final String language;
  final bool speakReplies;
  final String harnessAddress;
  final VoiceActivityConfig vadConfig;

  final _events = StreamController<VoiceBackendEvent>.broadcast();
  final _queue = <({String id, VoiceUtterance utterance})>[];
  final _framer = PcmFramer();
  late final VoiceActivityDetector _vad = VoiceActivityDetector(
    config: vadConfig,
    onDrop: _droppedByFilter,
  );
  StreamSubscription<Uint8List>? _microphone;
  bool _started = false;
  bool _muted = false;
  bool _paused = false;
  bool _closed = false;
  bool _speaking = false;
  bool _transcribing = false;
  int _generation = 0;
  int _utteranceSequence = 0;
  int _dropSequence = 0;
  final List<String> _heldReplies = <String>[];

  @override
  Stream<VoiceBackendEvent> get events => _events.stream;

  @override
  Future<void> start() async {
    if (_started || _closed) return;
    _started = true;
    _emit(const VoicePhaseEvent(VoicePhase.connecting));
    try {
      await microphone.start();
      await microphone.setMuted(false);
      _microphone = microphone.frames.listen(
        _onBytes,
        onError: (Object error, StackTrace stack) {
          _fail(
            VoiceProblem(
              'Microphone unavailable',
              detail: _oneLine(error),
              recoverable: false,
            ),
          );
        },
      );
      _emit(const VoicePhaseEvent(VoicePhase.listening));
    } catch (error) {
      _fail(
        VoiceProblem(
          _microphoneProblem(error),
          detail: _oneLine(error),
          recoverable: false,
        ),
      );
    }
  }

  void _onBytes(Uint8List bytes) {
    if (_closed) return;
    for (final frame in _framer.add(bytes)) {
      final wasActive = _vad.gateActive;
      final utterances = _vad.addFrame(frame, outputActive: _speaking);
      _emit(VoiceLevelEvent(_vad.level));
      if (wasActive != _vad.gateActive) {
        _emit(VoiceSpeechEvent(_vad.gateActive));
        if (_vad.gateActive) {
          _emit(const VoicePhaseEvent(VoicePhase.hearing));
        } else if (utterances.isEmpty) {
          // A tap or a cough closed the gate without words; the screen can
          // listen again and a held reply may be released after its grace.
          _emit(
            VoicePhaseEvent(_muted ? VoicePhase.muted : VoicePhase.listening),
          );
        }
      }
      if (_speaking && _vad.gateActive) {
        // The gate already required a louder, longer signal while the
        // assistant spoke; this is a real voice taking the floor, not its
        // own echo.
        _takeFloor();
      }
      for (final utterance in utterances) {
        _accept(utterance);
      }
    }
  }

  /// The person's voice takes the floor from the reply: stop the playback and
  /// say so, so the pipeline does not keep showing audio that stopped.
  void _takeFloor() {
    if (!_speaking) return;
    _speaking = false;
    _generation++;
    _emit(VoicePlaybackEvent(playing: false, generation: _generation));
    unawaited(speech.stop());
  }

  /// The speech filter ended a burst it did not keep.  It is reported with
  /// the duration and level it measured, and the audio is dropped here.
  void _droppedByFilter(VoiceUtteranceRejection rejection) {
    if (_closed) return;
    _emit(
      VoiceSegmentEvent(
        id: 'r-${++_dropSequence}',
        stage: VoiceSegmentStage.dropped,
        duration: rejection.duration,
        level: rejection.level,
        drop: rejection.reason == VoiceUtteranceDrop.tooShort
            ? VoiceSegmentDrop.tooShort
            : VoiceSegmentDrop.failed,
      ),
    );
  }

  void _accept(VoiceUtterance utterance) {
    if (utterance.duration < vadConfig.minUtterance) {
      _emit(
        VoiceSegmentEvent(
          id: 'r-${++_dropSequence}',
          stage: VoiceSegmentStage.dropped,
          duration: utterance.duration,
          level: utterance.level,
          drop: VoiceSegmentDrop.tooShort,
        ),
      );
      return;
    }
    if (_speaking) {
      // The person took the floor: stop the reply, do not cancel the work.
      _takeFloor();
    }
    final id = 'u-${++_utteranceSequence}';
    _emit(
      VoiceSegmentEvent(
        id: id,
        stage: VoiceSegmentStage.accepted,
        duration: utterance.duration,
        level: utterance.level,
      ),
    );
    _queue.add((id: id, utterance: utterance));
    if (!_transcribing) unawaited(_drain());
  }

  List<String> _takeHeld() {
    final held = List<String>.of(_heldReplies);
    _heldReplies.clear();
    return held;
  }

  Future<void> _drain() async {
    if (_transcribing) return;
    _transcribing = true;
    try {
      while (_queue.isNotEmpty && !_closed) {
        final queued = _queue.removeAt(0);
        final utterance = queued.utterance;
        final promptId = queued.id;
        if (delivery == ClipDelivery.audioPrompt) {
          final pending = _takeHeld();
          _emit(
            VoiceCaptionEvent(
              VoiceSpeaker.you,
              'Voice message',
              finalized: true,
              segmentId: promptId,
            ),
          );
          _emit(
            VoicePromptEvent(
              VoicePrompt(
                audio: utterance.wav,
                pending: pending.isEmpty ? null : pending,
                displayText: 'Voice message',
                id: promptId,
                segmentId: promptId,
              ),
            ),
          );
          _emit(const VoicePhaseEvent(VoicePhase.thinking));
          continue;
        }
        _emit(const VoicePhaseEvent(VoicePhase.transcribing));
        _emit(
          VoiceSegmentEvent(
            id: promptId,
            stage: VoiceSegmentStage.transcribing,
          ),
        );
        String text;
        try {
          text = (await transcriber.transcribe(
            utterance.wav,
            endpoint: endpoint,
            model: model,
            token: token,
            language: language,
          )).trim();
        } catch (error) {
          _emit(
            VoiceSegmentEvent(
              id: promptId,
              stage: VoiceSegmentStage.failed,
              detail: _oneLine(error),
            ),
          );
          _fail(VoiceProblem('Transcription failed', detail: _oneLine(error)));
          _emit(const VoicePhaseEvent(VoicePhase.listening));
          continue;
        }
        if (text.isEmpty) {
          // The burst was kept by the filter and no words came back: it is
          // reported as dropped for having no words, not as silence.
          _emit(
            VoiceSegmentEvent(
              id: promptId,
              stage: VoiceSegmentStage.dropped,
              drop: VoiceSegmentDrop.noWords,
            ),
          );
          _fail(const VoiceProblem('Empty transcript'));
          _emit(const VoicePhaseEvent(VoicePhase.listening));
          continue;
        }
        final pending = _takeHeld();
        _emit(
          VoiceSegmentEvent(
            id: promptId,
            stage: VoiceSegmentStage.transcribed,
            text: text,
          ),
        );
        _emit(
          VoiceCaptionEvent(
            VoiceSpeaker.you,
            text,
            finalized: true,
            segmentId: promptId,
          ),
        );
        _emit(
          VoicePromptEvent(
            VoicePrompt(
              text: text,
              pending: pending.isEmpty ? null : pending,
              id: promptId,
              segmentId: promptId,
            ),
          ),
        );
        _emit(const VoicePhaseEvent(VoicePhase.thinking));
      }
    } finally {
      _transcribing = false;
    }
  }

  @override
  Future<void> setMuted(bool muted) async {
    if (_closed || _muted == muted) return;
    _muted = muted;
    try {
      await microphone.setMuted(muted || _paused);
    } catch (error) {
      _fail(VoiceProblem('Microphone unavailable', detail: _oneLine(error)));
      return;
    }
    if (muted) {
      _vad.reset();
      _heldReplies.clear();
      _emit(const VoicePhaseEvent(VoicePhase.muted));
    } else {
      _emit(const VoicePhaseEvent(VoicePhase.listening));
    }
  }

  @override
  Future<void> interrupt() async {
    _generation++;
    _speaking = false;
    _heldReplies.clear();
    _vad.reset();
    await speech.stop();
    _emit(VoicePlaybackEvent(playing: false, generation: _generation));
    if (!_closed && !_muted && !_paused) {
      _emit(const VoicePhaseEvent(VoicePhase.interrupted));
      // The agent may still be working; the next reply is spoken when it
      // arrives, so the screen goes back to listening rather than staying in
      // an interrupted state that would hide the microphone.
      _emit(const VoicePhaseEvent(VoicePhase.listening));
    }
  }

  @override
  Future<void> pause() async {
    if (_closed || _paused) return;
    _paused = true;
    _generation++;
    _speaking = false;
    _heldReplies.clear();
    _vad.reset();
    await speech.stop();
    _emit(VoicePlaybackEvent(playing: false, generation: _generation));
    try {
      await microphone.setMuted(true);
    } catch (error) {
      _fail(VoiceProblem('Microphone unavailable', detail: _oneLine(error)));
    }
    if (!_closed) _emit(const VoicePhaseEvent(VoicePhase.paused));
  }

  @override
  Future<void> resume() async {
    if (_closed || !_paused) return;
    _paused = false;
    _vad.reset();
    try {
      await microphone.setMuted(_muted);
    } catch (error) {
      _fail(VoiceProblem('Microphone unavailable', detail: _oneLine(error)));
      return;
    }
    if (!_closed) {
      _emit(VoicePhaseEvent(_muted ? VoicePhase.muted : VoicePhase.listening));
    }
  }

  @override
  Future<void> speak(String text, {String? replyId}) async {
    final trimmed = text.trim();
    _heldReplies.remove(trimmed);
    if (_closed || !speakReplies || trimmed.isEmpty || _paused) {
      if (trimmed.isNotEmpty && !_closed) {
        _remember(trimmed);
        _emit(VoiceHeldEvent(trimmed, id: replyId));
      }
      return;
    }
    if (_vad.gateActive) {
      _remember(trimmed);
      _emit(VoiceHeldEvent(trimmed, id: replyId));
      return;
    }
    final generation = ++_generation;
    _speaking = true;
    _emit(const VoicePhaseEvent(VoicePhase.speaking));
    // The player starts here: the speech engine is asked to say this reply,
    // and a real engine resolves when the audio has played.
    _emit(
      VoicePlaybackEvent(
        playing: true,
        replyId: replyId,
        generation: generation,
      ),
    );
    try {
      await speech.speak(trimmed);
    } catch (error) {
      if (generation == _generation) {
        _fail(VoiceProblem('Speech unavailable', detail: _oneLine(error)));
        _emit(
          VoicePlaybackEvent(
            playing: false,
            replyId: replyId,
            generation: generation,
          ),
        );
      }
    } finally {
      if (generation == _generation && !_closed) {
        _speaking = false;
        _emit(
          VoicePlaybackEvent(
            playing: false,
            replyId: replyId,
            generation: generation,
          ),
        );
        _emit(
          VoicePhaseEvent(_muted ? VoicePhase.muted : VoicePhase.listening),
        );
      }
    }
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
    await _microphone?.cancel();
    _microphone = null;
    try {
      await microphone.stop();
    } catch (_) {
      // The microphone may already be gone with the app.
    }
    try {
      await speech.stop();
    } catch (_) {
      // Likewise the platform's speech engine.
    }
    _vad.reset();
    _queue.clear();
    _heldReplies.clear();
    _paused = false;
    await _events.close();
  }

  void _fail(VoiceProblem problem) {
    if (_closed) return;
    _emit(VoiceFailureEvent(problem));
  }

  void _emit(VoiceBackendEvent event) {
    if (!_closed) _events.add(event);
  }

  static String _microphoneProblem(Object error) {
    final text = '$error'.toLowerCase();
    if (text.contains('permission') || text.contains('denied')) {
      return 'Microphone permission denied';
    }
    return 'Microphone unavailable';
  }

  static String _oneLine(Object error) {
    final line = '$error'.trim().split('\n').first.trim();
    if (line.isEmpty) return error.runtimeType.toString();
    return line.length <= 160 ? line : '${line.substring(0, 159)}…';
  }
}

/// A WAV clip from a synthetic or recorded source, for a test or for a
/// caller that already has one.  It never opens a platform channel.
class MemoryVoiceMicrophone implements VoiceMicrophone {
  MemoryVoiceMicrophone({this.sampleRate = 16000});
  final _frames = StreamController<Uint8List>.broadcast();
  bool _open = false;
  bool muted = false;

  @override
  final int sampleRate;

  @override
  Stream<Uint8List> get frames => _frames.stream;

  bool get isOpen => _open;

  @override
  Future<void> start() async {
    _open = true;
  }

  @override
  Future<void> setMuted(bool value) async {
    muted = value;
  }

  /// Play PCM16 bytes as if the microphone heard them.
  void hear(Uint8List bytes) {
    if (_open && !muted && !_frames.isClosed) _frames.add(bytes);
  }

  @override
  Future<void> stop() async {
    _open = false;
    await _frames.close();
  }
}

/// Builds a silent, then noisy PCM16 frame for tests and previews.
Int16List voiceFrame({
  required int samples,
  double amplitude = 0.0,
  double frequency = 220,
  int sampleRate = 16000,
  int phase = 0,
}) {
  final frame = Int16List(samples);
  for (var i = 0; i < samples; i++) {
    final value = amplitude <= 0
        ? 0
        : amplitude *
              math.sin(2 * math.pi * frequency * (phase + i) / sampleRate);
    frame[i] = (value.clamp(-1.0, 1.0) * 32767).round();
  }
  return frame;
}

/// A transcriber that answers with a script, for a test or a preview.
class ScriptedVoiceTranscriber implements VoiceTranscriber {
  ScriptedVoiceTranscriber(this.answers);
  final List<String> answers;
  final List<Uint8List> heard = <Uint8List>[];
  int _next = 0;

  @override
  Future<String> transcribe(
    Uint8List wav, {
    required String endpoint,
    required String model,
    required String token,
    required String language,
  }) async {
    heard.add(wav);
    if (answers.isEmpty) return '';
    final answer = answers[_next % answers.length];
    _next++;
    return answer;
  }

  @override
  Future<void> dispose() async {}
}

/// A speech engine that records what it was asked to say.
class RecordingVoiceSpeech implements VoiceSpeech {
  final List<String> spoken = <String>[];
  int stops = 0;
  Completer<void>? _current;

  @override
  Future<void> speak(String text) async {
    spoken.add(text);
    _current = Completer<void>();
    // A test or a preview can end it; a real engine ends at the end of the
    // audio.  Returning at once would hide the speaking phase.
    await _current!.future;
  }

  void finish() {
    final current = _current;
    _current = null;
    if (current != null && !current.isCompleted) current.complete();
  }

  @override
  Future<void> stop() async {
    stops++;
    finish();
  }
}
