import 'dart:async';

import 'package:harness_client/src/voice/voice_backend.dart';
import 'package:harness_client/src/voice/voice_controller.dart';
import 'package:harness_client/src/voice/voice_models.dart';
import 'package:harness_client/src/voice/voice_settings.dart';

class FakeSession implements VoiceSessionBridge {
  @override
  bool working = false;
  @override
  bool blocked = false;
  @override
  String? model = 'demo:model';
  final List<VoicePrompt> sent = <VoicePrompt>[];
  final List<void Function()> sessions = <void Function()>[];
  final List<void Function(String)> replies = <void Function(String)>[];

  @override
  String get cwd => '/tmp/project';

  @override
  List<String> get history => const ['Person: earlier', 'Agent: yes'];

  @override
  String get sessionId => 'session-1';

  @override
  String get sessionTitle => 'Build the thing';

  @override
  Future<void> send(VoicePrompt prompt) async {
    sent.add(prompt);
  }

  @override
  void addReplyListener(void Function(String text) listener) =>
      replies.add(listener);

  @override
  void removeReplyListener(void Function(String text) listener) =>
      replies.remove(listener);

  @override
  void addSessionListener(void Function() listener) => sessions.add(listener);

  @override
  void removeSessionListener(void Function() listener) =>
      sessions.remove(listener);

  void reply(String text) {
    for (final listener in List.of(replies)) {
      listener(text);
    }
  }

  void changed() {
    for (final listener in List.of(sessions)) {
      listener();
    }
  }
}

class FakeBackend implements VoiceBackend {
  FakeBackend({this.autoStart = true});

  final bool autoStart;
  final _events = StreamController<VoiceBackendEvent>.broadcast();
  bool started = false;
  bool stopped = false;
  bool muted = false;
  int interrupts = 0;
  final List<String> spoken = <String>[];

  @override
  Stream<VoiceBackendEvent> get events => _events.stream;

  void emit(VoiceBackendEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  @override
  Future<void> start() async {
    started = true;
    if (autoStart) emit(const VoicePhaseEvent(VoicePhase.listening));
  }

  @override
  Future<void> setMuted(bool value) async {
    muted = value;
    emit(VoicePhaseEvent(value ? VoicePhase.muted : VoicePhase.listening));
  }

  @override
  Future<void> interrupt() async {
    interrupts++;
    emit(const VoicePhaseEvent(VoicePhase.interrupted));
  }

  @override
  Future<void> speak(String text) async {
    spoken.add(text);
  }

  @override
  Future<void> stop() async {
    stopped = true;
    if (!_events.isClosed) unawaited(_events.close());
  }
}

class Rig {
  Rig({
    VoiceSettings settings = const VoiceSettings(
      clipDelivery: ClipDelivery.audioPrompt,
    ),
    String address = 'ws://harness.test:9999/acp',
  }) : session = FakeSession() {
    controller = VoiceController(
      settings: settings,
      bridge: session,
      harnessAddress: address,
      backendFactory: (next, at) {
        builtWith = next;
        builtAt = at;
        return backend;
      },
      onSettingsChanged: (next) async {
        saved.add(next);
      },
    );
  }

  final FakeSession session;
  final FakeBackend backend = FakeBackend();
  final List<VoiceSettings> saved = <VoiceSettings>[];
  VoiceSettings? builtWith;
  String? builtAt;
  late final VoiceController controller;
}
