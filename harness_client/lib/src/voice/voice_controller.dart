import 'dart:async';

import 'package:flutter/foundation.dart';

import '../state/session_controller.dart';
import 'voice_backend.dart';
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
  Future<void> send(VoicePrompt prompt) =>
      controller.sendVoice(text: prompt.text, audio: prompt.audio);

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
  }) : _settings = settings,
       _harnessAddress = harnessAddress,
       _backendFactory = backendFactory;

  VoiceSessionBridge bridge;
  final String _harnessAddress;
  final VoiceBackendFactory _backendFactory;
  final Future<void> Function(VoiceSettings settings) onSettingsChanged;

  VoiceSettings _settings;
  VoiceSettings get settings => _settings;

  VoicePhase phase = VoicePhase.idle;
  VoiceProblem? problem;
  double level = 0;
  bool muted = false;
  bool started = false;
  final List<VoiceCaption> captions = <VoiceCaption>[];

  VoiceBackend? _backend;
  StreamSubscription<VoiceBackendEvent>? _events;
  bool _followSession = false;
  bool _disposed = false;
  bool _stopping = false;
  int _sequence = 0;
  DateTime _lastLevel = DateTime.fromMillisecondsSinceEpoch(0);

  /// The address of the harness this device is signed in to, which the
  /// setup sheet uses to suggest where its speech server is.
  String get harnessAddress => _harnessAddress;

  /// Whether the settings can start a session at all.
  bool get configured => _settings.configuredFor(_harnessAddress);

  /// The status the screen shows: the phase, or the conversation's own state
  /// while the voice provider is idle.
  VoicePhase get displayPhase {
    if (phase.finished) return phase;
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
    captions.clear();
    problem = null;
    muted = false;
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
      case VoicePhaseEvent(:final phase):
        if (phase == VoicePhase.muted) muted = true;
        if (phase == VoicePhase.listening) muted = false;
        _setPhase(phase);
        if (phase == VoicePhase.listening && problem?.recoverable == true) {
          problem = null;
        }
      case VoiceLevelEvent(:final level):
        this.level = level.clamp(0.0, 1.0);
        final now = DateTime.now();
        if (now.difference(_lastLevel) < const Duration(milliseconds: 80)) {
          return;
        }
        _lastLevel = now;
      case VoiceCaptionEvent(:final speaker, :final text, :final finalized):
        _addCaption(speaker, text, finalized: finalized);
      case VoicePromptEvent(:final prompt):
        if (prompt.isEmpty) break;
        unawaited(_send(prompt));
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

  Future<void> _send(VoicePrompt prompt) async {
    try {
      if (prompt.text case final text? when text.trim().isNotEmpty) {
        _addCaption(VoiceSpeaker.you, text.trim(), finalized: true);
      }
      await bridge.send(prompt);
      if (!_disposed) notifyListeners();
    } catch (error) {
      _setProblem(
        VoiceProblem('Send failed', detail: '$error', recoverable: true),
      );
      if (!_disposed) notifyListeners();
    }
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
      final backend = _backend;
      if (backend != null) unawaited(backend.speak(trimmed));
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
    if (_disposed || phase.finished) return;
    final backend = _backend;
    if (backend == null) return;
    muted = !muted;
    _setPhase(muted ? VoicePhase.muted : VoicePhase.listening);
    notifyListeners();
    await backend.setMuted(muted);
  }

  Future<void> interrupt() async {
    if (_disposed || phase.finished) return;
    final backend = _backend;
    if (backend == null) return;
    await backend.interrupt();
    _setPhase(VoicePhase.interrupted);
    notifyListeners();
  }

  Future<void> retry() async {
    if (_disposed) return;
    await _closeBackend();
    started = false;
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
    if (_followSession) {
      _followSession = false;
      bridge.removeReplyListener(_onAgentReply);
      bridge.removeSessionListener(_sessionChanged);
    }
    await _closeBackend();
    _setPhase(VoicePhase.ended);
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (_followSession) {
      _followSession = false;
      bridge.removeReplyListener(_onAgentReply);
      bridge.removeSessionListener(_sessionChanged);
    }
    unawaited(_closeBackend());
    super.dispose();
  }
}
