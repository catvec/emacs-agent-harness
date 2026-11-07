import 'dart:async';

import 'package:flutter/foundation.dart';

import '../state/session_controller.dart';
import 'voice_backend.dart';
import 'voice_media_buttons.dart';
import 'voice_models.dart';
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

  /// Replies that were already in the transcript when the voice screen
  /// opened are history, not answers to what is said now.
  void _prime() {
    for (final item in controller.transcript.items) {
      if (item.isAssistant) _spoken.add(item.key);
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
    this.pendingReleaseDelay = const Duration(milliseconds: 1500),
  }) : _settings = settings,
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
  final List<String> _heldReplies = <String>[];
  Timer? _heldTimer;
  final Set<String> _sentPrompts = <String>{};

  /// How long a reply held by a trigger that produced no words waits before
  /// it is spoken.  A transcript cancels the wait; a pause does not speak it.
  final Duration pendingReleaseDelay;

  VoiceBackend? _backend;
  StreamSubscription<VoiceBackendEvent>? _events;
  bool _followSession = false;
  bool _disposed = false;
  bool _stopping = false;
  bool _mediaButtonsStarted = false;
  int _sequence = 0;
  DateTime _lastLevel = DateTime.fromMillisecondsSinceEpoch(0);

  /// The address of the harness this device is signed in to, which the
  /// setup sheet uses to suggest where its speech server is.
  String get harnessAddress => _harnessAddress;

  /// Whether the settings can start a session at all.
  bool get configured => _settings.configuredFor(_harnessAddress);

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

  Future<void> start() async {
    if (_disposed || started) return;
    started = true;
    _stopping = false;
    captions.clear();
    problem = null;
    muted = false;
    paused = false;
    speechActive = false;
    _heldReplies.clear();
    _sentPrompts.clear();
    _heldTimer?.cancel();
    _heldTimer = null;
    if (!configured) {
      _setPhase(VoicePhase.failed);
      _setProblem(
        const VoiceProblem(
          'Not configured',
          detail: 'Voice settings',
          recoverable: false,
        ),
      );
      notifyListeners();
      return;
    }
    if (!_followSession) {
      _followSession = true;
      bridge.addReplyListener(_onAgentReply);
      bridge.addSessionListener(_sessionChanged);
    }
    _setPhase(VoicePhase.connecting);
    if (!_mediaButtonsStarted) {
      _mediaButtonsStarted = true;
      unawaited(_mediaButtons.start(togglePause));
    }
    notifyListeners();
    await _openBackend();
  }

  Future<void> _openBackend() async {
    final backend = _backendFactory(_settings, _harnessAddress);
    _backend = backend;
    _events = backend.events.listen(_onEvent);
    try {
      await backend.start();
    } catch (error) {
      _setPhase(VoicePhase.failed);
      _setProblem(
        VoiceProblem('Voice unavailable', detail: '$error', recoverable: false),
      );
      notifyListeners();
    }
  }

  void _onEvent(VoiceBackendEvent event) {
    if (_disposed) return;
    switch (event) {
      case VoiceSpeechEvent(:final active):
        speechActive = active;
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
      case VoiceLevelEvent(:final level):
        this.level = level.clamp(0.0, 1.0);
        final now = DateTime.now();
        if (now.difference(_lastLevel) < const Duration(milliseconds: 80)) {
          return;
        }
        _lastLevel = now;
      case VoiceHeldEvent(:final text):
        _holdReply(text);
      case VoiceCaptionEvent(:final speaker, :final text, :final finalized):
        _addCaption(speaker, text, finalized: finalized);
      case VoicePromptEvent(:final prompt):
        if (prompt.isEmpty) break;
        unawaited(_sendPrompt(prompt));
      case VoiceFailureEvent(:final problem):
        _setProblem(problem);
        if (!problem.recoverable) {
          _setPhase(VoicePhase.failed);
          unawaited(_closeBackend());
        }
      case VoiceProblemCleared():
        problem = null;
      case VoiceEndedEvent():
        _setPhase(VoicePhase.ended);
      case VoiceDelegateEvent():
        break;
    }
    notifyListeners();
  }

  Future<void> _sendPrompt(VoicePrompt prompt) async {
    if (prompt.id case final id? when id.isNotEmpty) {
      if (!_sentPrompts.add(id)) return;
    }
    _heldTimer?.cancel();
    _heldTimer = null;
    final held = <String>[...?prompt.pending, ..._heldReplies];
    _heldReplies.clear();
    final context = _pendingContext(held);
    final text = _withContext(prompt.text, context);
    final display = prompt.spokenText;
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
        ),
      );
      if (!_disposed) notifyListeners();
    } catch (error) {
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
    final held = List<String>.of(_heldReplies);
    _heldReplies.clear();
    final backend = _backend;
    if (backend == null) return;
    for (final text in held) {
      await backend.speak(text);
    }
    if (!_disposed) notifyListeners();
  }

  void _holdReply(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    if (_heldReplies.contains(trimmed)) return;
    _heldReplies.add(
      trimmed.length > 4000 ? trimmed.substring(0, 4000) : trimmed,
    );
    if (_heldReplies.length > 40) _heldReplies.removeAt(0);
  }

  void _sessionChanged() {
    if (!_disposed) notifyListeners();
  }

  void _onAgentReply(String text) {
    if (_disposed) return;
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    _addCaption(VoiceSpeaker.agent, trimmed, finalized: true);
    if (_settings.speakReplies) {
      if (paused) {
        // A reply that arrives while the conversation is paused is shown,
        // not queued for a stale replay when it resumes.
      } else if (holdingOutput) {
        _holdReply(trimmed);
      } else {
        final backend = _backend;
        if (backend != null) unawaited(backend.speak(trimmed));
      }
    }
    notifyListeners();
  }

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
      _heldReplies.clear();
    }
    _setPhase(muted ? VoicePhase.muted : VoicePhase.listening);
    notifyListeners();
    await backend.setMuted(muted);
  }

  /// Pause the conversation without ending it: microphone off, provider
  /// audio silent, replies held.  The session and its turn keep running.
  Future<void> pause() async {
    if (_disposed || paused || phase.finished) return;
    paused = true;
    _heldTimer?.cancel();
    _heldTimer = null;
    _heldReplies.clear();
    final backend = _backend;
    if (backend != null) await backend.pause();
    _setPhase(VoicePhase.paused);
    notifyListeners();
  }

  /// Resume a paused conversation with the same session and settings.
  Future<void> resume() async {
    if (_disposed || !paused || phase.finished) return;
    paused = false;
    final backend = _backend;
    if (backend != null) await backend.resume();
    _setPhase(muted ? VoicePhase.muted : VoicePhase.listening);
    notifyListeners();
  }

  Future<void> togglePause() => paused ? resume() : pause();

  Future<void> interrupt() async {
    if (_disposed || phase.finished) return;
    _heldTimer?.cancel();
    _heldTimer = null;
    _heldReplies.clear();
    final backend = _backend;
    if (backend == null) return;
    await backend.interrupt();
    _setPhase(paused ? VoicePhase.paused : VoicePhase.interrupted);
    notifyListeners();
  }

  Future<void> retry() async {
    if (_disposed) return;
    _heldTimer?.cancel();
    _heldTimer = null;
    _heldReplies.clear();
    _sentPrompts.clear();
    speechActive = false;
    paused = false;
    await _closeBackend();
    started = false;
    _stopping = false;
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
    await _closeBackend();
    started = true;
    _setPhase(VoicePhase.connecting);
    await _openBackend();
  }

  void _setPhase(VoicePhase next) {
    phase = next;
  }

  void _setProblem(VoiceProblem next) {
    problem = next;
  }

  Future<void> _closeBackend() async {
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
    _heldTimer?.cancel();
    _heldTimer = null;
    _heldReplies.clear();
    speechActive = false;
    paused = false;
    if (_followSession) {
      _followSession = false;
      bridge.removeReplyListener(_onAgentReply);
      bridge.removeSessionListener(_sessionChanged);
    }
    _stopMediaButtons();
    await _closeBackend();
    _setPhase(VoicePhase.ended);
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
    _heldTimer?.cancel();
    _heldTimer = null;
    _heldReplies.clear();
    if (_followSession) {
      _followSession = false;
      bridge.removeReplyListener(_onAgentReply);
      bridge.removeSessionListener(_sessionChanged);
    }
    _stopMediaButtons();
    unawaited(_closeBackend());
    super.dispose();
  }
}
