import 'dart:async';

import 'package:flutter/foundation.dart';

import '../state/session_controller.dart';
import 'voice_backend.dart';
import 'voice_conversation.dart';
import 'voice_media_buttons.dart';
import 'voice_models.dart';
import 'voice_pipeline.dart';
import 'voice_settings.dart';
import 'voice_turn_completion.dart';

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
    required VoiceSessionBridge bridge,
    required String harnessAddress,
    required VoiceBackendFactory backendFactory,
    required this.onSettingsChanged,
    VoiceMediaButtons? mediaButtons,
    VoiceConversation? conversation,
    this.pendingReleaseDelay = const Duration(milliseconds: 1500),
    this.turnCompletionDelay = const Duration(milliseconds: 1200),
    this.pendingTextLimit = 100000,
  }) : conversation = conversation ?? VoiceConversation(),
       _bridge = bridge,
       _settings = settings,
       _harnessAddress = harnessAddress,
       _backendFactory = backendFactory,
       _mediaButtons = mediaButtons ?? defaultVoiceMediaButtons();

  VoiceSessionBridge _bridge;
  VoiceSessionBridge get bridge => _bridge;

  /// A running call is pinned to its conversation. Retargeting ends it rather
  /// than delivering a late transcription to whichever thread is selected now.
  set bridge(VoiceSessionBridge next) {
    if (identical(next, _bridge)) return;
    if (_followSession) {
      _bridge.removeReplyListener(_onAgentReply);
      _bridge.removeSessionListener(_sessionChanged);
    }
    _cancelPending(drop: VoiceSegmentDrop.retargeted, detail: 'retargeted');
    _bridge = next;
    _rememberRoute();
    if (_followSession) {
      _bridge.addReplyListener(_onAgentReply);
      _bridge.addSessionListener(_sessionChanged);
    }
    if (started && !phase.finished) unawaited(stop());
  }

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
  // Receipt deduplication precedes accumulation, not just delivery. Accepted
  // source order wins over the order asynchronous transcripts happen to finish.
  final Set<String> _receivedPrompts = <String>{};
  final Map<String, _VoiceInput> _inputs = <String, _VoiceInput>{};
  final Map<String, String> _captionDraft = <String, String>{};
  Timer? _completionTimer;
  int _pendingGeneration = 0;
  int _inputSequence = 0;
  bool _backendTurnHeld = false;
  String? _routeSessionId;
  String? _routeCwd;

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

  /// Ordinary transcript endings get a fresh grace after speech and every
  /// outstanding transcription settle. Explicit intent and cut-offs never expire.
  final Duration turnCompletionDelay;

  /// A safe bound, not a truncation limit. Exceeding it stops capture with the
  /// full unsent words still visible; it never sends a shortened request.
  final int pendingTextLimit;

  VoiceBackend? _backend;
  StreamSubscription<VoiceBackendEvent>? _events;
  bool _followSession = false;
  bool _disposed = false;
  bool _stopping = false;
  bool _stopInProgress = false;
  bool _replacingBackend = false;
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
      _outstandingInput ||
      pendingSpeech.isNotEmpty ||
      phase == VoicePhase.hearing ||
      phase == VoicePhase.transcribing;

  String get _captionText {
    final captions = _captionDraft.entries.toList()
      ..sort((a, b) => _inputs[a.key]!.order.compareTo(_inputs[b.key]!.order));
    return captions.map((entry) => entry.value).join(' ');
  }

  /// The original words, independent of the agent's work and its captions.
  /// Caption-only live holds are visible too, but are never invented requests.
  String get pendingSpeech {
    final draft = _draft;
    return [
      if (draft.text.isNotEmpty) draft.text,
      if (_captionDraft.isNotEmpty) _captionText,
    ].join(' ');
  }

  VoiceTurnReason? get pendingReason {
    final draft = _draft;
    final caption = _captionText;
    if (caption.isNotEmpty) return classifyVoiceTurn(caption);
    return draft.text.isEmpty ? null : draft.reason;
  }

  bool get _outstandingInput => _inputs.values.any(
    (input) => !input.cancelled && !input.consumed && !input.transcribed,
  );

  bool get _inputSettled =>
      !_disposed &&
      started &&
      !_stopping &&
      !_replacingBackend &&
      !phase.finished &&
      !paused &&
      !muted &&
      !speechActive &&
      !_outstandingInput &&
      phase != VoicePhase.hearing &&
      phase != VoicePhase.transcribing;

  /// Manual submission cannot cut across speech or transcription. Nondelegated
  /// live captions remain provider-owned, so have no submission action.
  bool get canSendPending => _inputSettled && _draft.text.isNotEmpty;

  Future<void> sendPendingNow() async {
    if (!canSendPending) return;
    await _commitPending();
  }

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
    _replacingBackend = false;
    _levelReported = false;
    captions.clear();
    conversation.clear();
    problem = null;
    muted = false;
    paused = false;
    speechActive = false;
    _heldReplies.clear();
    _cancelPending();
    _inputs.clear();
    _receivedPrompts.clear();
    _rememberRoute();
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
    _backendTurnHeld = false;
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
    if (_disposed || _stopping || _replacingBackend || !_checkRoute()) return;
    switch (event) {
      case VoiceSpeechEvent(:final active):
        if (muted || paused) break;
        speechActive = active;
        pipeline.gate(active);
        _cancelCompletion();
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
        if (phase == VoicePhase.muted) {
          muted = true;
          speechActive = false;
          _cancelPending();
        }
        if (phase == VoicePhase.paused) {
          paused = true;
          speechActive = false;
          _cancelPending();
        }
        if ((muted || paused) &&
            phase != VoicePhase.muted &&
            phase != VoicePhase.paused &&
            !phase.finished) {
          break;
        }
        _setPhase(phase);
        if (phase == VoicePhase.hearing || phase == VoicePhase.transcribing) {
          _cancelCompletion();
        }
        if (phase == VoicePhase.listening &&
            problem?.recoverable == true &&
            pendingSpeech.isEmpty) {
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
        final input = _input(id, segmentId: id);
        if (input.cancelled || input.consumed) break;
        if (muted || paused) {
          input.cancelled = true;
          pipeline.drop(id, drop: VoiceSegmentDrop.cancelled);
          break;
        }
        switch (stage) {
          case VoiceSegmentStage.accepted:
            pipeline.accept(id, duration: duration, level: level);
            if (!input.transcribed) _cancelCompletion();
          case VoiceSegmentStage.transcribing:
            pipeline.transcribing(id);
            if (!input.transcribed) _cancelCompletion();
          case VoiceSegmentStage.transcribed:
            pipeline.transcript(id, text ?? '', finalized: true);
            input.transcribed = true;
            _cancelCompletion();
          case VoiceSegmentStage.dropped:
            input.transcribed = true;
            input.failed = drop == VoiceSegmentDrop.failed;
            pipeline.drop(
              id,
              drop: drop ?? VoiceSegmentDrop.cancelled,
              detail: detail,
            );
            _cancelCompletion();
          case VoiceSegmentStage.failed:
            input.transcribed = true;
            input.failed = true;
            pipeline.fail(id, detail: detail);
            _cancelCompletion();
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
      case VoiceCaptionEvent(
        :final speaker,
        :final text,
        :final finalized,
        :final segmentId,
      ):
        _addCaption(speaker, text, finalized: finalized);
        if (speaker == VoiceSpeaker.you && finalized && !muted && !paused) {
          _onUserCaption(text, segmentId: segmentId);
        }
        if (speaker == VoiceSpeaker.agent && finalized) {
          // The provider's own spoken line, outside the chat's transcript.
          conversation.say(text, source: 'provider');
        }
      case VoicePromptEvent(:final prompt):
        // Even a prompt with no words goes through: the segment it names
        // is then dropped with a reason instead of waiting forever.
        _receivePrompt(prompt);
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
        _cancelPending();
        _heldTimer?.cancel();
        _heldTimer = null;
        _dropHeld('ended');
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
    _enforcePendingLimit();
    _advancePending();
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

  /// Audio and words still waiting to become a request are canceled, never
  /// flushed into a stopped or newly selected conversation.
  void _cancelPending({
    VoiceSegmentDrop drop = VoiceSegmentDrop.cancelled,
    String detail = 'cancelled',
  }) {
    _cancelCompletion();
    _captionDraft.clear();
    final backend = _backend;
    if (backend case VoiceTurnSources control) control.commitTurn(const []);
    for (final input in _inputs.values) {
      if (!input.consumed) input.cancelled = true;
      input.prompt = null;
      input.sources.clear();
    }
    for (final segment in pipelineState.segments) {
      if (segment.stage.terminal || segment.stage == VoicePipelineStage.inTurn) {
        continue;
      }
      pipeline.drop(segment.id, drop: drop, detail: detail);
    }
    _syncTurnHold();
  }

  _VoiceInput _input(String key, {String? segmentId}) => _inputs.putIfAbsent(
    key,
    () => _VoiceInput(key, ++_inputSequence, segmentId: segmentId),
  );

  _VoiceDraft get _draft {
    final inputs = <_VoiceInput>[];
    final words = <String>[];
    final sources = <String>{};
    var release = false;
    var truncated = false;
    for (final input in _inputs.values) {
      if (input.cancelled || input.consumed) continue;
      final prompt = input.prompt;
      if (prompt == null) {
        // A recovery caption can finish before earlier STT. Interpret it by
        // source order when those earlier words arrive, not by arrival order.
        if (input.recovery && words.isNotEmpty) {
          release = true;
          if (input.segmentId != null) sources.add(input.segmentId!);
        }
        continue;
      }
      inputs.add(input);
      final text = prompt.text?.trim() ?? '';
      sources.addAll(input.sources);
      if (words.isNotEmpty && isVoiceTurnRecovery(text)) {
        // Control cues stay in captions, never in the combined session request.
        release = true;
      } else {
        words.add(text);
        release = false;
        truncated = prompt.truncated;
      }
    }
    // Later words cannot reconstruct failed audio. Missing input stays sticky
    // for this turn until explicit recovery/submission or cancellation.
    final missingWords = _inputs.values.any((input) =>
        !input.cancelled && !input.consumed && input.failed);
    final text = words.join(' ');
    return _VoiceDraft(
      text,
      inputs,
      sources.toList(),
      classifyVoiceTurn(text, truncated: truncated || missingWords),
      release,
    );
  }

  void _receivePrompt(VoicePrompt prompt) {
    if (prompt.id case final id? when id.isNotEmpty) {
      if (!_receivedPrompts.add(id)) return;
    }
    final sources = <String>{
      if (prompt.segmentId case final id? when id.isNotEmpty) id,
      ...prompt.segmentIds.where((id) => id.isNotEmpty),
    };
    if (sources.isEmpty) {
      if (prompt.id case final id? when id.isNotEmpty) sources.add(id);
    }
    final inputs = [
      for (final source in sources) _input(source, segmentId: source),
    ]..sort((a, b) => a.order.compareTo(b.order));
    if (inputs.any((input) => input.cancelled || input.consumed ||
        input.prompt != null || input.covered)) {
      final backend = _backend;
      if (backend case VoiceTurnSources control) {
        if (prompt.id case final id? when id.isNotEmpty) control.discardPrompt(id);
      }
      return;
    }
    final input = inputs.isEmpty
        ? _input('anonymous-${++_inputSequence}')
        : inputs.first;
    if (muted || paused || phase.finished) {
      for (final source in inputs) {
        source.cancelled = true;
        if (source.segmentId != null) pipeline.drop(source.segmentId!);
      }
      return;
    }
    _cancelCompletion();
    final raw = prompt.text?.trim() ?? '';
    for (final source in inputs) {
      source.transcribed = true;
      if (source != input) source.covered = true;
      _captionDraft.remove(source.key);
    }
    if (sources.isEmpty) {
      _captionDraft.removeWhere((key, value) =>
          key.startsWith('caption-') && value == raw);
    }
    input.transcribed = true;
    input.sources.addAll(inputs.map((source) => source.segmentId).whereType<String>());
    if (raw.isEmpty && prompt.audio == null) {
      input.consumed = true;
      for (final source in sources) {
        pipeline.drop(source, drop: VoiceSegmentDrop.noWords, detail: 'no words');
      }
      _scheduleHeldRelease();
      return;
    }
    final shown = prompt.spokenText;
    if (shown != null && shown.trim().isNotEmpty) {
      _addCaption(VoiceSpeaker.you, shown.trim(), finalized: true);
    }
    for (final source in sources) {
      if (raw.isNotEmpty) pipeline.transcript(source, raw, finalized: true);
    }
    if (prompt.audio != null) {
      // Audio-only delivery has no lexical information. Preserve its existing
      // clip behavior; it cannot obey spoken pause/recovery cues locally.
      input.consumed = true;
      unawaited(_deliverPrompt(prompt, sources.toList()));
      return;
    }
    input.prompt = prompt;
  }

  void _onUserCaption(String text, {String? segmentId}) {
    final raw = text.trim();
    if (raw.isEmpty) return;
    final input = segmentId == null
        ? _input('caption-${++_inputSequence}')
        : _input(segmentId, segmentId: segmentId);
    if (input.cancelled || input.consumed) return;
    input.transcribed = true;
    input.recovery = isVoiceTurnRecovery(raw);
    if (input.recovery) {
      _captionDraft.removeWhere((key, _) => _inputs[key]!.order <= input.order);
      _cancelCompletion();
      return;
    }
    if (input.prompt != null || input.covered) return;
    if (_inputs.values.any((later) => !later.cancelled && !later.consumed &&
        later.recovery && later.order > input.order)) {
      return;
    }
    // A provider may decide not to delegate a greeting. Only explicit holds
    // get a caption-only draft; no caption becomes an invented work request.
    final key = input.key;
    final before = _captionDraft[key];
    _captionDraft[key] = raw;
    final reason = classifyVoiceTurn(_captionText);
    if (reason == VoiceTurnReason.grace) {
      _captionDraft.clear();
    } else if (before != raw) {
      _cancelCompletion();
    }
  }

  void _cancelCompletion() {
    _pendingGeneration++;
    _completionTimer?.cancel();
    _completionTimer = null;
  }

  void _enforcePendingLimit() {
    if (phase.finished || pendingSpeech.length <= pendingTextLimit) return;
    _cancelCompletion();
    speechActive = false;
    pipeline.gate(false);
    _heldTimer?.cancel();
    _heldTimer = null;
    _dropHeld('input limit');
    _setProblem(const VoiceProblem('Unsent speech limit', recoverable: false));
    _setPhase(VoicePhase.failed);
    // Retain the complete draft/captions for inspection; stop only capture and
    // dispatch. Nothing is silently clipped or flushed to the agent.
    for (final segment in pipelineState.segments) {
      if (!segment.stage.terminal && segment.stage != VoicePipelineStage.inTurn) {
        pipeline.drop(segment.id, detail: 'unsent speech limit');
      }
    }
    unawaited(_closeBackend());
  }

  void _advancePending() {
    _syncTurnHold();
    if (!canSendPending) {
      _completionTimer?.cancel();
      _completionTimer = null;
      return;
    }
    final draft = _draft;
    // A newer caption-only pause owns the floor even when an older delegated
    // request arrives late. Only its delegation, recovery or manual override
    // may release the known request; caption-only words are never synthesized.
    if (_captionDraft.isNotEmpty) return;
    if (draft.release) {
      unawaited(_commitPending());
      return;
    }
    if (draft.reason != VoiceTurnReason.grace || _completionTimer != null) return;
    final generation = _pendingGeneration;
    final life = _lifecycle;
    final epoch = _backendEpoch;
    _completionTimer = Timer(turnCompletionDelay, () {
      _completionTimer = null;
      if (_disposed || life != _lifecycle || epoch != _backendEpoch ||
          generation != _pendingGeneration || !_checkRoute() ||
          !canSendPending || _draft.reason != VoiceTurnReason.grace) {
        return;
      }
      unawaited(_commitPending());
    });
  }

  Future<void> _commitPending() async {
    if (!canSendPending || !_checkRoute()) return;
    final draft = _draft;
    final first = draft.inputs.first.prompt!;
    _cancelCompletion();
    final backend = _backend;
    if (backend case VoiceTurnSources control) {
      control.commitTurn([
        for (final input in draft.inputs)
          if (input.prompt!.id case final id? when id.isNotEmpty) id,
      ]);
    }
    for (final input in _inputs.values) {
      if (!input.cancelled && input.transcribed) {
        if (input.segmentId case final id? when !draft.sources.contains(id)) {
          pipeline.drop(id, detail: 'no delegation');
        }
        input.consumed = true;
        // Keep only an id/order tombstone, never a second growing transcript.
        input.prompt = null;
        input.sources.clear();
      }
    }
    _captionDraft.clear();
    _syncTurnHold();
    await _deliverPrompt(
      VoicePrompt(
        text: draft.text,
        displayText: draft.text,
        id: first.id,
        segmentId: draft.sources.isEmpty ? null : draft.sources.first,
        segmentIds: draft.sources,
        truncated: draft.reason == VoiceTurnReason.cutOff,
      ),
      draft.sources,
    );
  }

  void _syncTurnHold() {
    final backend = _backend;
    final held = !_disposed && !_stopping && !_replacingBackend &&
        !phase.finished && holdingOutput;
    if (backend case VoiceTurnControl control when _backendTurnHeld != held) {
      _backendTurnHeld = held;
      // A backend owns reporting failures from its transport. Capability failures
      // must not escape an unawaited UI/event callback.
      unawaited(control.setTurnHeld(held).catchError((Object _) {}));
    }
  }

  Future<void> _deliverPrompt(VoicePrompt prompt, List<String> sources) async {
    if (_disposed || _stopping || !_checkRoute()) return;
    final life = _lifecycle;
    final epoch = _backendEpoch;
    final target = bridge;
    _heldTimer?.cancel();
    _heldTimer = null;
    _dropHeld('superseded');
    final text = prompt.text?.trim();
    if (text != null && text.isNotEmpty) conversation.hear(raw: text, sent: text);
    final turnId = 't-${++_turnSequence}';
    _openTurns.add(turnId);
    pipeline.turnSent(turnId);
    for (final source in sources) {
      pipeline.turnSent(turnId, segmentId: source);
    }
    notifyListeners();
    try {
      await target.send(prompt);
      if (_disposed || life != _lifecycle || epoch != _backendEpoch) return;
      _openTurns.remove(turnId);
      pipeline.turnAnswered(turnId);
      pipeline.turnDone(turnId);
      notifyListeners();
    } catch (error) {
      if (_disposed || life != _lifecycle || epoch != _backendEpoch) return;
      _openTurns.remove(turnId);
      pipeline.turnFailed(turnId, detail: '$error');
      for (final source in sources) {
        pipeline.fail(source, detail: '$error');
      }
      _setProblem(VoiceProblem('Send failed', detail: '$error', recoverable: true));
      notifyListeners();
    }
  }

  void _scheduleHeldRelease() {
    _heldTimer?.cancel();
    if (_disposed || _stopping || holdingOutput || _heldReplies.isEmpty) return;
    final life = _lifecycle;
    final epoch = _backendEpoch;
    _heldTimer = Timer(pendingReleaseDelay, () {
      if (life != _lifecycle || epoch != _backendEpoch) return;
      _heldTimer = null;
      unawaited(_releaseHeld());
    });
  }

  Future<void> _releaseHeld() async {
    if (_disposed || _stopping || holdingOutput || _heldReplies.isEmpty) return;
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

  void _rememberRoute() {
    _routeSessionId = bridge.sessionId;
    _routeCwd = bridge.cwd;
  }

  bool _checkRoute() {
    if (_routeSessionId == null) _rememberRoute();
    if (_routeSessionId == bridge.sessionId && _routeCwd == bridge.cwd) {
      return true;
    }
    _cancelPending(drop: VoiceSegmentDrop.retargeted, detail: 'retargeted');
    _dropHeld('retargeted');
    if (started && !_stopping) unawaited(stop());
    return false;
  }

  void _sessionChanged() {
    if (_disposed) return;
    _checkRoute();
    notifyListeners();
  }

  void _onAgentReply(String text) {
    if (_disposed || !_checkRoute()) return;
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
      speechActive = false;
      pipeline.gate(false);
      _cancelPending();
      _dropHeld('muted');
    }
    _setPhase(muted ? VoicePhase.muted : VoicePhase.listening);
    _syncTurnHold();
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
    speechActive = false;
    pipeline.gate(false);
    _heldTimer?.cancel();
    _heldTimer = null;
    _cancelPending();
    _dropHeld('paused');
    _setPhase(VoicePhase.paused);
    final backend = _backend;
    if (backend != null) await backend.pause();
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
    _receivedPrompts.clear();
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
    // Everything a backend was built with is compared, endpoint changes and
    // the output voice's own settings alike: a changed output voice, rate,
    // pitch or volume rebuilds the clip provider's speech engine exactly as a
    // changed endpoint reopens the provider, so ordinary replies are spoken
    // the way the sheet previewed them.
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
        next.realtimeVoice != _settings.realtimeVoice ||
        next.outputVoice != _settings.outputVoice ||
        next.outputVoiceLocale != _settings.outputVoiceLocale ||
        next.speechRate != _settings.speechRate ||
        next.speechPitch != _settings.speechPitch ||
        next.speechVolume != _settings.speechVolume;
    if (restart && wasRunning) {
      _replacingBackend = true;
      _lifecycle++;
      _heldTimer?.cancel();
      _heldTimer = null;
      _cancelPending();
      _dropHeld('restart');
    }
    final life = _lifecycle;
    _settings = next;
    await onSettingsChanged(next);
    if (!_disposed) notifyListeners();
    if (!restart || !wasRunning) return;
    if (_disposed || _stopping || life != _lifecycle) return;
    await _closeBackend();
    if (_disposed || _stopping || life != _lifecycle) return;
    pipeline.end(state: VoiceInputState.off);
    _inputs.clear();
    _receivedPrompts.clear();
    _openTurns.clear();
    speechActive = false;
    _replacingBackend = false;
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
    _cancelPending();
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

/// A source keeps its acceptance order even when its transcript arrives late.
class _VoiceInput {
  _VoiceInput(this.key, this.order, {this.segmentId});

  final String key;
  final int order;
  final String? segmentId;
  final Set<String> sources = <String>{};
  VoicePrompt? prompt;
  bool transcribed = false;
  bool failed = false;
  bool cancelled = false;
  bool consumed = false;
  bool covered = false;
  bool recovery = false;
}

class _VoiceDraft {
  const _VoiceDraft(this.text, this.inputs, this.sources, this.reason, this.release);

  final String text;
  final List<_VoiceInput> inputs;
  final List<String> sources;
  final VoiceTurnReason reason;
  final bool release;
}
