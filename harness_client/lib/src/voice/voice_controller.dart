import 'dart:async';

import 'package:flutter/foundation.dart';

import '../state/session_controller.dart';
import 'voice_backend.dart';
import 'voice_conversation.dart';
import 'voice_media_buttons.dart';
import 'voice_models.dart';
import 'voice_pipeline.dart';
import 'voice_settings.dart';

/// The session side of a voice screen: sends what was heard, and hears what
/// the agent says back.
class SessionVoiceBridge implements VoiceSessionBridge {
  SessionVoiceBridge(this.controller);

  final SessionController controller;
  final List<void Function(String text)> _listeners = [];
  final Set<String> _spoken = <String>{};
  bool _following = false;

  @override
  bool get working => controller.isRunning;

  @override
  bool get blocked => controller.needsAnswer;

  @override
  String? get model => controller.summary?.model;

  @override
  String get sessionId => controller.sessionId;

  @override
  String get sessionTitle => voiceSessionLabel(controller.summary);

  @override
  String get cwd => controller.summary?.cwd ?? '';

  @override
  List<String> get history {
    final out = <String>[];
    for (final item in controller.transcript.displayItems) {
      if (!item.isUser && !item.isAssistant) continue;
      final text = item.text.trim().replaceAll(RegExp(r'\s+'), ' ');
      if (text.isEmpty) continue;
      final who = item.isUser ? 'Person' : 'Agent';
      out.add(
        '$who: ${text.length > 400 ? '${text.substring(0, 399)}…' : text}',
      );
    }
    if (out.length <= 8) return out;
    return out.sublist(out.length - 8);
  }

  @override
  Future<void> send(VoicePrompt prompt) => controller.sendVoice(
    text: prompt.text,
    audio: prompt.audio,
    displayText: prompt.displayText,
  );

  @override
  void addReplyListener(void Function(String text) listener) {
    if (!_following) {
      _following = true;
      _prime();
      controller.addListener(_checkReplies);
    }
    _listeners.add(listener);
  }

  @override
  void removeReplyListener(void Function(String text) listener) {
    _listeners.remove(listener);
    if (_listeners.isEmpty && _following) {
      _following = false;
      controller.removeListener(_checkReplies);
    }
  }

  @override
  void addSessionListener(void Function() listener) =>
      controller.addListener(listener);

  @override
  void removeSessionListener(void Function() listener) =>
      controller.removeListener(listener);

  /// Replies that were already in the transcript, finished, when the voice
  /// screen opened are history, not answers to what is said now.  One still
  /// streaming is not: it is the answer being given as voice attaches (the
  /// walkthrough of a report is sent before its conversation opens), and it
  /// is spoken when it is whole.
  void _prime() {
    for (final item in controller.transcript.items) {
      if (item.isAssistant && !item.streaming) _spoken.add(item.key);
    }
  }

  void _checkReplies() {
    if (_listeners.isEmpty) return;
    for (final item in controller.transcript.items) {
      if (!item.isAssistant || item.streaming) continue;
      final text = item.text.trim();
      if (text.isEmpty || !_spoken.add(item.key)) continue;
      for (final listener in List.of(_listeners)) {
        listener(text);
      }
    }
  }
}

/// The address a reply is spoken to, and what the voice screen shows.
typedef VoiceBackendFactory = VoiceBackend Function(
  VoiceSettings settings,
  String harnessAddress,
);

/// One running voice screen: the state machine between a backend, the
/// session and the widgets.
///
/// It owns no platform channels.  A test, or a screenshot, hands it a
/// backend factory and a [VoiceSessionBridge] that are already scripted.
class VoiceController extends ChangeNotifier {
  VoiceController({
    required VoiceSettings settings,
    required this.bridge,
    required String harnessAddress,
    required VoiceBackendFactory backendFactory,
    required this.onSettingsChanged,
    VoiceMediaButtons? mediaButtons,
    VoiceConversation? conversation,
    this.pendingReleaseDelay = const Duration(milliseconds: 1500),
  }) : conversation = conversation ?? VoiceConversation(),
       _settings = settings,
       _harnessAddress = harnessAddress,
       _backendFactory = backendFactory,
       _mediaButtons = mediaButtons ?? defaultVoiceMediaButtons();

  VoiceSessionBridge bridge;
  final String _harnessAddress;
  final VoiceBackendFactory _backendFactory;
  final VoiceMediaButtons _mediaButtons;
  final Future<void> Function(VoiceSettings settings) onSettingsChanged;

  VoiceSettings _settings;
  VoiceSettings get settings => _settings;

  VoicePhase phase = VoicePhase.idle;
  VoiceProblem? problem;
  double level = 0;
  bool muted = false;
  bool started = false;
  bool speechActive = false;
  bool paused = false;
  final List<VoiceCaption> captions = <VoiceCaption>[];

  /// Replies that arrived while speech or a pause owned the floor.  They are
  /// attached to the next transcript as explicit context, or released when
  /// the trigger was only a tap; they are never replayed as a stale answer.
  final List<({String text, String id})> _heldReplies =
      <({String text, String id})>[];
  Timer? _heldTimer;
  final Set<String> _sentPrompts = <String>{};

  /// The pipe from microphone to speaker, as the screen and the compact
  /// presentation show it.  It is fed only by events and decisions that
  /// really happened; nothing in it moves on a clock.
  final VoicePipelineTracker pipeline = VoicePipelineTracker();
  VoicePipelineSnapshot get pipelineState => pipeline.snapshot;

  /// The audio side of this call: the raw words, the lines the voice spoke,
  /// and the request that crossed into the chat.  It is cleared when a call
  /// starts or ends, so it never becomes a second session transcript.
  final VoiceConversation conversation;

  /// Turns the session has been given and not finished, oldest first.  A
  /// reply belongs to the turn the session is answering, which is the oldest.
  final List<String> _openTurns = <String>[];
  int _turnSequence = 0;

  /// Bumped whenever the backend is replaced, so an event from a backend that
  /// is gone cannot advance the pipe of the one that replaced it.
  int _backendEpoch = 0;

  /// Whether the backend ended on its own, rather than by the screen's stop:
  /// a closed connection is not the same as a conversation someone ended.
  bool _unexpectedEnd = false;

  /// How long a reply held by a trigger that produced no words waits before
  /// it is spoken.  A transcript cancels the wait; a pause does not speak it.
  final Duration pendingReleaseDelay;

  VoiceBackend? _backend;
  StreamSubscription<VoiceBackendEvent>? _events;
  bool _followSession = false;
  bool _disposed = false;
  bool _stopping = false;
  bool _stopInProgress = false;
  bool _mediaButtonsStarted = false;
  bool _levelReported = false;
  int _sequence = 0;
  int _lifecycle = 0;
  DateTime _lastLevel = DateTime.fromMillisecondsSinceEpoch(0);

  /// The address of the harness this device is signed in to, which the
  /// setup sheet uses to suggest where its speech server is.
  String get harnessAddress => _harnessAddress;

  /// Whether the settings can start a session at all.
  bool get configured => _settings.configuredFor(_harnessAddress);

  /// Whether a stop is in progress.  Its own state, so a compact view can
  /// say `Ending` while the backend and the microphone are being released.
  /// It is false again once the call has ended; [_stopping] stays true as
  /// the guard that keeps stopped calls stopped.
  bool get stopping => _stopInProgress;

  /// Whether the backend has reported a microphone level in this call.  A
  /// provider that reports none (the live stream) is not given an invented
  /// meter.
  bool get levelReported => _levelReported;

  /// Whether assistant output is actually held for the next transcript.
  /// [holdingOutput] also covers a person who is speaking; this is only
  /// output waiting to be said.
  bool get holdingReply => _heldReplies.isNotEmpty;

  /// Whether the call holds the microphone open right now, by the backend's
  /// contract: started, not muted, not paused, not stopping and not
  /// finished.  `connecting` is still opening it.
  bool get microphoneOpen =>
      started &&
      !_stopping &&
      !muted &&
      !paused &&
      !phase.finished &&
      phase != VoicePhase.connecting;

  /// Whether assistant output must wait for the person to finish.
  bool get holdingOutput =>
      speechActive ||
      paused ||
      phase == VoicePhase.hearing ||
      phase == VoicePhase.transcribing;

  /// The status the screen shows: the phase, or the conversation's own state
  /// while the voice provider is idle.
  VoicePhase get displayPhase {
    if (phase.finished) return phase;
    if (paused) return VoicePhase.paused;
    if (bridge.blocked) return VoicePhase.approval;
    if (muted) return VoicePhase.muted;
    if (phase == VoicePhase.speaking ||
        phase == VoicePhase.hearing ||
        phase == VoicePhase.transcribing) {
      return phase;
    }
    if (bridge.working) return VoicePhase.thinking;
    return phase;
  }

  VoiceCaption? get currentCaption {
    if (captions.isEmpty) return null;
    return captions.last;
  }

  /// Listen to the session's replies from now on, whether or not the
  /// microphone is on: a demo's presenter narrates on its own when its run
  /// starts, and what it says is what the page shows.  What the session has
  /// already said is not repeated.
  void follow() {
    if (_disposed || _followSession) return;
    _followSession = true;
    bridge.addReplyListener(_onAgentReply);
    bridge.addSessionListener(_sessionChanged);
  }

  Future<void> start() async {
    if (_disposed || started) return;
    _lifecycle++;
    started = true;
    _stopping = false;
    _stopInProgress = false;
    _levelReported = false;
    captions.clear();
    conversation.clear();
    problem = null;
    muted = false;
    paused = false;
    speechActive = false;
    _heldReplies.clear();
    _sentPrompts.clear();
    _heldTimer?.cancel();
    _heldTimer = null;
    pipeline.begin();
    _unexpectedEnd = false;
    if (!configured) {
      _setPhase(VoicePhase.failed);
      _setProblem(
        const VoiceProblem(
          'Not configured',
          detail: 'Voice settings',
          recoverable: false,
        ),
      );
      _syncPipeline();
      notifyListeners();
      return;
    }
    follow();
    _setPhase(VoicePhase.connecting);
    _syncPipeline();
    if (!_mediaButtonsStarted) {
      _mediaButtonsStarted = true;
      unawaited(_mediaButtons.start(togglePause));
    }
    notifyListeners();
    await _openBackend();
  }

  Future<void> _openBackend() async {
    final life = _lifecycle;
    final backend = _backendFactory(_settings, _harnessAddress);
    // A stop or a new start may have run while the factory resolved (it is
    // synchronous today, but a test or a platform seam need not keep it so).
    if (_disposed || _stopping || life != _lifecycle) return;
    final epoch = ++_backendEpoch;
    final events = backend.events.listen((event) {
      // A backend that was closed, replaced or restarted must not advance
      // the pipe of the one that replaced it.
      if (_disposed || epoch != _backendEpoch) return;
      _onEvent(event);
    });
    _backend = backend;
    _events = events;
    try {
      await backend.start();
    } catch (error) {
      if (!_disposed && !_stopping && life == _lifecycle) {
        _setPhase(VoicePhase.failed);
        _setProblem(
          VoiceProblem(
            'Voice unavailable',
            detail: '$error',
            recoverable: false,
          ),
        );
        _syncPipeline();
        notifyListeners();
      }
      return;
    }
    if (!_disposed && !_stopping && life == _lifecycle) return;
    // Stop (or a newer call) superseded this start while the backend was
    // opening.  Close what was just opened, so a microphone cannot be left
    // capturing after End.
    await events.cancel();
    if (identical(_events, events)) _events = null;
    if (identical(_backend, backend)) _backend = null;
    try {
      await backend.stop().timeout(
        const Duration(seconds: 3),
        onTimeout: () {},
      );
    } catch (_) {
      // The backend that was superseded is already gone; it is still stopped.
    }
  }

  void _onEvent(VoiceBackendEvent event) {
    if (_disposed || _stopping) return;
    switch (event) {
      case VoiceSpeechEvent(:final active):
        speechActive = active;
        pipeline.gate(active);
        if (active) {
          _heldTimer?.cancel();
          _heldTimer = null;
        } else if (_heldReplies.isNotEmpty &&
            !paused &&
            phase != VoicePhase.hearing &&
            phase != VoicePhase.transcribing) {
          _scheduleHeldRelease();
        }
      case VoicePhaseEvent(:final phase):
        if (phase == VoicePhase.muted) muted = true;
        _setPhase(phase);
        if (phase == VoicePhase.listening && problem?.recoverable == true) {
          problem = null;
        }
        if ((phase == VoicePhase.listening ||
                phase == VoicePhase.muted ||
                phase == VoicePhase.thinking) &&
            !speechActive &&
            !paused &&
            _heldReplies.isNotEmpty) {
          _scheduleHeldRelease();
        }
        if (phase == VoicePhase.paused) paused = true;
      case VoiceLevelEvent(:final level):
        _levelReported = true;
        this.level = level.clamp(0.0, 1.0);
        pipeline.level(this.level);
        final now = DateTime.now();
        if (now.difference(_lastLevel) < const Duration(milliseconds: 80)) {
          return;
        }
        _lastLevel = now;
      case VoiceSegmentEvent(
        :final id,
        :final stage,
        :final duration,
        :final level,
        :final text,
        :final drop,
        :final detail,
      ):
        switch (stage) {
          case VoiceSegmentStage.accepted:
            pipeline.accept(id, duration: duration, level: level);
          case VoiceSegmentStage.transcribing:
            pipeline.transcribing(id);
          case VoiceSegmentStage.transcribed:
            pipeline.transcript(id, text ?? '', finalized: true);
          case VoiceSegmentStage.dropped:
            pipeline.drop(
              id,
              drop: drop ?? VoiceSegmentDrop.cancelled,
              detail: detail,
            );
          case VoiceSegmentStage.failed:
            pipeline.fail(id, detail: detail);
        }
      case VoicePlaybackEvent(
        :final playing,
        :final replyId,
        :final generation,
      ):
        pipeline.playback(
          playing: playing,
          replyId: replyId,
          generation: generation,
        );
      case VoiceReplyHandedEvent(:final replyId):
        pipeline.replyHanded(replyId);
      case VoiceHeldEvent(:final text, :final id):
        _holdReply(text, id: id);
      case VoiceCaptionEvent(:final speaker, :final text, :final finalized):
        _addCaption(speaker, text, finalized: finalized);
        if (speaker == VoiceSpeaker.agent && finalized) {
          // The provider's own spoken line, outside the chat's transcript.
          conversation.say(text, source: 'provider');
        }
      case VoicePromptEvent(:final prompt):
        if (prompt.isEmpty) break;
        unawaited(_sendPrompt(prompt));
      case VoiceFailureEvent(:final problem):
        _setProblem(problem);
        pipeline.problem(problem);
        if (!problem.recoverable) {
          _cancelPending();
          _setPhase(VoicePhase.failed);
          unawaited(_closeBackend());
        }
      case VoiceProblemCleared():
        problem = null;
        pipeline.problem(null);
      case VoiceEndedEvent():
        _unexpectedEnd = !_stopping;
        pipeline.end(
          state: _unexpectedEnd
              ? VoiceInputState.disconnected
              : VoiceInputState.ended,
        );
        _setPhase(VoicePhase.ended);
      case VoiceDelegateEvent():
        break;
    }
    _syncPipeline();
    notifyListeners();
  }

  /// The microphone and the pipe's other inputs, from the screen's own state.
  void _syncPipeline() {
    final state = switch (phase) {
      VoicePhase.ended =>
        _unexpectedEnd ? VoiceInputState.disconnected : VoiceInputState.ended,
      VoicePhase.failed => VoiceInputState.failed,
      VoicePhase.connecting => VoiceInputState.connecting,
      VoicePhase.idle => VoiceInputState.off,
      _ when paused => VoiceInputState.paused,
      _ when muted => VoiceInputState.muted,
      _ => VoiceInputState.live,
    };
    pipeline.input(state);
    pipeline.problem(problem);
  }

  /// Audio that was still waiting to become a request when the conversation
  /// stopped.  It will not be sent, and the pipe says so.
  void _cancelPending() {
    for (final segment in pipelineState.segments) {
      if (segment.stage.terminal) continue;
      pipeline.drop(
        segment.id,
        drop: VoiceSegmentDrop.cancelled,
        detail: 'cancelled',
      );
    }
  }

  Future<void> _sendPrompt(VoicePrompt prompt) async {
    if (prompt.id case final id? when id.isNotEmpty) {
      if (!_sentPrompts.add(id)) return;
    }
    final raw = prompt.text?.trim() ?? '';
    final distilled = raw.isEmpty ? null : conversation.distilledText(raw);
    if (raw.isNotEmpty && distilled == null) {
      // Nothing but mumbles: the voice conversation keeps the words, the
      // session gets no request, and the segment says why it stopped.
      conversation.hear(raw: raw);
      final segment = prompt.segmentId ?? prompt.id;
      if (segment != null && segment.isNotEmpty) {
        pipeline.drop(
          segment,
          drop: VoiceSegmentDrop.noRequest,
          detail: 'no request',
        );
      }
      _scheduleHeldRelease();
      if (!_disposed) notifyListeners();
      return;
    }
    final request = distilled == null
        ? prompt.text
        : conversation.request(distilled);
    _heldTimer?.cancel();
    _heldTimer = null;
    final held = <String>[
      ...?prompt.pending,
      for (final piece in _heldReplies) piece.text,
    ];
    for (final piece in _heldReplies) {
      pipeline.replyDropped(piece.id, detail: 'context');
    }
    _heldReplies.clear();
    final context = _pendingContext(held);
    final text = _withContext(request, context);
    if (distilled != null) {
      conversation.hear(raw: raw, distilled: distilled, sent: text);
    }
    final display = prompt.spokenText;
    final turnId = 't-${++_turnSequence}';
    _openTurns.add(turnId);
    pipeline.turnSent(turnId, segmentId: prompt.segmentId ?? prompt.id);
    try {
      if (display case final shown? when shown.trim().isNotEmpty) {
        _addCaption(VoiceSpeaker.you, shown.trim(), finalized: true);
      }
      await bridge.send(
        VoicePrompt(
          text: text,
          audio: prompt.audio,
          displayText: display,
          id: prompt.id,
          segmentId: prompt.segmentId,
        ),
      );
      _openTurns.remove(turnId);
      pipeline.turnDone(turnId);
      if (!_disposed) notifyListeners();
    } catch (error) {
      _openTurns.remove(turnId);
      pipeline.turnFailed(turnId, detail: '$error');
      _setProblem(
        VoiceProblem('Send failed', detail: '$error', recoverable: true),
      );
      if (!_disposed) notifyListeners();
    }
  }

  String? _withContext(String? text, String context) {
    final body = text?.trim() ?? '';
    if (context.isEmpty) {
      return body.isEmpty ? text : body;
    }
    return body.isEmpty ? context : '$body\n\n$context';
  }

  String _pendingContext(List<String> held) {
    if (held.isEmpty) return '';
    final seen = <String>{};
    final unique = <String>[];
    for (final text in held) {
      final trimmed = text.trim();
      if (trimmed.isEmpty || !seen.add(trimmed)) continue;
      unique.add(trimmed);
    }
    if (unique.isEmpty) return '';
    // A full turn result contains the sentence pieces that were held while
    // it streamed; keep the larger text, not both.
    final kept = unique
        .where(
          (text) => !unique.any(
            (other) => other.length > text.length && other.contains(text),
          ),
        )
        .toList();
    return '<voice-turn-context>\n'
        'assistant_output: held (not spoken)\n'
        'held_output:\n'
        '${kept.map((text) => '- $text').join('\n')}\n'
        'decision: answer the new speech; fold the held output in only if '
        'it is still relevant; do not assume it was heard.\n'
        '</voice-turn-context>';
  }

  void _scheduleHeldRelease() {
    _heldTimer?.cancel();
    if (paused || speechActive || _heldReplies.isEmpty) return;
    _heldTimer = Timer(pendingReleaseDelay, () {
      _heldTimer = null;
      unawaited(_releaseHeld());
    });
  }

  Future<void> _releaseHeld() async {
    if (_disposed || paused || speechActive || _heldReplies.isEmpty) return;
    final held = List<({String text, String id})>.of(_heldReplies);
    _heldReplies.clear();
    final backend = _backend;
    if (backend == null) return;
    for (final piece in held) {
      pipeline.replyReleased(piece.id);
      pipeline.replyHanded(piece.id);
      conversation.say(piece.text, source: 'commentary');
      await backend.speak(piece.text, replyId: piece.id);
    }
    if (!_disposed) notifyListeners();
  }

  void _holdReply(String text, {String? id}) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    if (_heldReplies.any((piece) => piece.text == trimmed)) return;
    final replyId = id ?? _replyForHeld(trimmed);
    pipeline.replyHeld(replyId);
    _heldReplies.add((
      text: trimmed.length > 4000 ? trimmed.substring(0, 4000) : trimmed,
      id: replyId,
    ));
    if (_heldReplies.length > 40) _heldReplies.removeAt(0);
  }

  /// A backend that reports held text without an id still gets a marker: the
  /// reply the screen decided to speak, or a new one for text it never saw.
  String _replyForHeld(String text) {
    for (final reply in pipelineState.replies) {
      if (reply.text == text && reply.stage.audible) return reply.id;
    }
    return pipeline.replyReady(text, turnId: _turnForReply());
  }

  void _sessionChanged() {
    if (!_disposed) notifyListeners();
  }

  void _onAgentReply(String text) {
    if (_disposed) return;
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    _addCaption(VoiceSpeaker.agent, trimmed, finalized: true);
    if (_settings.speakReplies && !paused) {
      final turnId = _turnForReply();
      final replyId = pipeline.replyReady(trimmed, turnId: turnId);
      if (holdingOutput) {
        _holdReply(trimmed, id: replyId);
      } else {
        final backend = _backend;
        if (backend != null) {
          pipeline.replyHanded(replyId);
          conversation.say(trimmed, source: 'result');
          unawaited(backend.speak(trimmed, replyId: replyId));
        }
      }
    }
    notifyListeners();
  }

  /// The turn the session is answering: the oldest one it has not finished.
  /// Several utterances that reached one turn are shown as its sources, and
  /// a turn with several replies shows them all.
  String? _turnForReply() => _openTurns.isEmpty ? null : _openTurns.first;

  void _addCaption(
    VoiceSpeaker speaker,
    String text, {
    required bool finalized,
  }) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    if (captions.isNotEmpty) {
      final last = captions.last;
      if (last.speaker == speaker && !last.finalized) {
        captions[captions.length - 1] = last.copyWith(
          text: trimmed,
          finalized: finalized,
        );
        return;
      }
      if (last.speaker == speaker && last.finalized && last.text == trimmed) {
        return;
      }
    }
    captions.add(
      VoiceCaption(
        speaker: speaker,
        text: trimmed,
        finalized: finalized,
        sequence: _sequence++,
      ),
    );
  }

  Future<void> toggleMute() async {
    if (_disposed || paused || phase.finished) return;
    final backend = _backend;
    if (backend == null) return;
    muted = !muted;
    if (muted) {
      _heldTimer?.cancel();
      _heldTimer = null;
      _dropHeld('muted');
    }
    _setPhase(muted ? VoicePhase.muted : VoicePhase.listening);
    _syncPipeline();
    notifyListeners();
    await backend.setMuted(muted);
  }

  /// Held replies will not be spoken; the pipe says why.
  void _dropHeld(String reason) {
    for (final piece in _heldReplies) {
      pipeline.replyDropped(piece.id, detail: reason);
    }
    _heldReplies.clear();
  }

  /// Pause the conversation without ending it: microphone off, provider
  /// audio silent, replies held.  The session and its turn keep running.
  Future<void> pause() async {
    if (_disposed || paused || phase.finished) return;
    paused = true;
    _heldTimer?.cancel();
    _heldTimer = null;
    _dropHeld('paused');
    final backend = _backend;
    if (backend != null) await backend.pause();
    _setPhase(VoicePhase.paused);
    _syncPipeline();
    notifyListeners();
  }

  /// Resume a paused conversation with the same session and settings.
  Future<void> resume() async {
    if (_disposed || !paused || phase.finished) return;
    paused = false;
    final backend = _backend;
    if (backend != null) await backend.resume();
    _setPhase(muted ? VoicePhase.muted : VoicePhase.listening);
    _syncPipeline();
    notifyListeners();
  }

  Future<void> togglePause() => paused ? resume() : pause();

  Future<void> interrupt() async {
    if (_disposed || phase.finished) return;
    _heldTimer?.cancel();
    _heldTimer = null;
    _dropHeld('interrupted');
    final backend = _backend;
    if (backend == null) return;
    pipeline.interrupted();
    await backend.interrupt();
    _setPhase(paused ? VoicePhase.paused : VoicePhase.interrupted);
    _syncPipeline();
    notifyListeners();
  }

  Future<void> retry() async {
    if (_disposed) return;
    _lifecycle++;
    _heldTimer?.cancel();
    _heldTimer = null;
    _dropHeld('restart');
    _sentPrompts.clear();
    _openTurns.clear();
    speechActive = false;
    paused = false;
    _cancelPending();
    await _closeBackend();
    pipeline.end(state: VoiceInputState.off);
    started = false;
    _stopping = false;
    _stopInProgress = false;
    problem = null;
    await start();
  }

  Future<void> updateSettings(VoiceSettings next) async {
    if (_disposed || next == _settings) return;
    final wasRunning = started && !phase.finished;
    final restart =
        next.provider != _settings.provider ||
        next.clipDelivery != _settings.clipDelivery ||
        next.speechEndpoint != _settings.speechEndpoint ||
        next.speechModel != _settings.speechModel ||
        next.speechToken != _settings.speechToken ||
        next.language != _settings.language ||
        next.realtimeEndpoint != _settings.realtimeEndpoint ||
        next.realtimeModel != _settings.realtimeModel ||
        next.realtimeToken != _settings.realtimeToken ||
        next.realtimeVoice != _settings.realtimeVoice;
    _settings = next;
    await onSettingsChanged(next);
    if (!_disposed) notifyListeners();
    if (!restart || !wasRunning) return;
    _lifecycle++;
    _cancelPending();
    await _closeBackend();
    pipeline.end(state: VoiceInputState.off);
    started = true;
    _setPhase(VoicePhase.connecting);
    pipeline.begin();
    _syncPipeline();
    await _openBackend();
  }

  void _setPhase(VoicePhase next) {
    phase = next;
  }

  void _setProblem(VoiceProblem next) {
    problem = next;
  }

  Future<void> _closeBackend() async {
    // Anything the backend still has queued belongs to a pipe that is over.
    _backendEpoch++;
    final events = _events;
    _events = null;
    await events?.cancel();
    final backend = _backend;
    _backend = null;
    await backend?.stop().timeout(const Duration(seconds: 3), onTimeout: () {});
  }

  Future<void> stop() async {
    if (_disposed || _stopping) return;
    _stopping = true;
    _stopInProgress = true;
    _lifecycle++;
    _unexpectedEnd = false;
    _heldTimer?.cancel();
    _heldTimer = null;
    _dropHeld('ended');
    _openTurns.clear();
    conversation.clear();
    speechActive = false;
    paused = false;
    if (_followSession) {
      _followSession = false;
      bridge.removeReplyListener(_onAgentReply);
      bridge.removeSessionListener(_sessionChanged);
    }
    _stopMediaButtons();
    _cancelPending();
    await _closeBackend();
    pipeline.end();
    _setPhase(VoicePhase.ended);
    _stopInProgress = false;
    if (!_disposed) notifyListeners();
  }

  void _stopMediaButtons() {
    if (!_mediaButtonsStarted) return;
    _mediaButtonsStarted = false;
    unawaited(_mediaButtons.stop());
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _lifecycle++;
    _heldTimer?.cancel();
    _heldTimer = null;
    _heldReplies.clear();
    if (_followSession) {
      _followSession = false;
      bridge.removeReplyListener(_onAgentReply);
      bridge.removeSessionListener(_sessionChanged);
    }
    _stopMediaButtons();
    conversation.clear();
    pipeline.end();
    unawaited(_closeBackend());
    super.dispose();
  }
}
