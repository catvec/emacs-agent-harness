import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:harness_client/src/voice/voice_audition.dart';
import 'package:harness_client/src/voice/voice_backend.dart';
import 'package:harness_client/src/voice/voice_controller.dart';
import 'package:harness_client/src/voice/voice_output.dart';
import 'package:harness_client/src/voice/voice_media_buttons.dart';
import 'package:harness_client/src/voice/voice_models.dart';
import 'package:harness_client/src/voice/voice_settings.dart';

class FakeSession implements VoiceSessionBridge {
  @override
  bool working = false;
  @override
  bool blocked = false;
  @override
  String? model = 'demo:model';

  /// A test can hold the send of a prompt open to exercise End while the
  /// transcript is on its way.
  Completer<void>? sendGate;
  final List<VoicePrompt> sent = <VoicePrompt>[];
  final List<void Function()> sessions = <void Function()>[];
  final List<void Function(String)> replies = <void Function(String)>[];

  /// When set, the next send fails with this message instead of arriving.
  String? failNext;

  /// When true, a send waits for its completer in [pending] to finish, so a
  /// test can keep a turn open and decide when it ends.
  bool hold = false;
  final List<Completer<void>> pending = <Completer<void>>[];

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
    if (failNext case final message?) {
      failNext = null;
      throw Exception(message);
    }
    sent.add(prompt);
    if (sendGate != null) await sendGate!.future;
    if (hold) {
      final done = Completer<void>();
      pending.add(done);
      await done.future;
    }
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

  /// A test can hold a start or a stop open to exercise the race between a
  /// call opening and End, or between End and the microphone being released.
  Completer<void>? startGate;
  Completer<void>? stopGate;

  final _events = StreamController<VoiceBackendEvent>.broadcast();
  bool started = false;
  bool stopped = false;
  bool muted = false;
  bool paused = false;
  int pauses = 0;
  int resumes = 0;
  int interrupts = 0;
  final List<String> spoken = <String>[];
  final List<String> handed = <String>[];

  @override
  Stream<VoiceBackendEvent> get events => _events.stream;

  void emit(VoiceBackendEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  @override
  Future<void> start() async {
    started = true;
    if (startGate != null) await startGate!.future;
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
  Future<void> pause() async {
    paused = true;
    pauses++;
    emit(const VoicePhaseEvent(VoicePhase.paused));
  }

  @override
  Future<void> resume() async {
    paused = false;
    resumes++;
    emit(VoicePhaseEvent(muted ? VoicePhase.muted : VoicePhase.listening));
  }

  @override
  Future<void> speak(String text, {String? replyId}) async {
    spoken.add(text);
    handed.add(replyId ?? '');
  }

  @override
  Future<void> stop() async {
    stopped = true;
    if (stopGate != null) await stopGate!.future;
    if (!_events.isClosed) unawaited(_events.close());
  }
}

class FakeMediaButtons implements VoiceMediaButtons {
  VoidCallback? toggle;
  int starts = 0;
  int stops = 0;

  @override
  Future<void> start(VoidCallback toggle) async {
    starts++;
    this.toggle = toggle;
  }

  @override
  Future<void> stop() async {
    stops++;
    toggle = null;
  }

  void press() => toggle?.call();
}

class Rig {
  Rig({
    VoiceSettings settings = const VoiceSettings(
      clipDelivery: ClipDelivery.audioPrompt,
    ),
    String address = 'ws://harness.test:9999/acp',
    Duration pendingReleaseDelay = const Duration(milliseconds: 1500),
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
      mediaButtons: media,
      pendingReleaseDelay: pendingReleaseDelay,
    );
  }

  final FakeSession session;
  final FakeBackend backend = FakeBackend();
  final FakeMediaButtons media = FakeMediaButtons();
  final List<VoiceSettings> saved = <VoiceSettings>[];
  VoiceSettings? builtWith;
  String? builtAt;
  late final VoiceController controller;
}

/// A scripted device voice catalogue: the answers `FlutterTts.getVoices` and
/// `getSpeechRateValidRange` would give, or the failures they would raise.
class FakeVoiceCatalogue implements VoiceOutputCatalogue {
  FakeVoiceCatalogue({
    this.voices = const <VoiceOutputVoice>[],
    this.rateRange,
    this.voicesError,
    this.rateError,
  });

  /// What the device reported, exactly as the sheet lists it.
  List<VoiceOutputVoice> voices;

  /// The range the platform accepts, or null for a platform that has none.
  VoiceRateRange? rateRange;

  /// What `getVoices` threw, when it did.
  Object? voicesError;

  /// What `getSpeechRateValidRange` threw, when it did.
  Object? rateError;

  int voiceCalls = 0;
  int rateCalls = 0;

  @override
  Future<List<VoiceOutputVoice>> loadVoices() async {
    voiceCalls++;
    if (voicesError case final error?) throw error;
    return voices;
  }

  @override
  Future<VoiceRateRange?> loadRateRange() async {
    rateCalls++;
    if (rateError case final error?) throw error;
    return rateRange;
  }
}

/// A scripted speech engine for an audition: it records the request it was
/// given, says it began when the test says so, and ends when the test says so
/// (or at once, for an engine that never really speaks).
class FakeAuditionEngine implements VoiceAuditionEngine {
  FakeAuditionEngine({
    this.autoFinish = false,
    this.failure,
    this.startsImmediately = false,
  });

  /// Whether the words end as soon as they start.
  final bool autoFinish;

  /// What the platform raised instead of speaking.
  Object? failure;

  /// Every preview this engine was asked to say, in order.
  final List<VoiceAuditionRequest> spoken = <VoiceAuditionRequest>[];
  int stops = 0;
  bool started = false;
  bool finished = false;
  Completer<void>? _current;
  VoidCallback? _onStart;

  /// Whether the platform said the audio began as soon as it was asked to
  /// speak.  False leaves the preview `Loading` until [begin] says otherwise,
  /// which is what a slow engine looks like.
  bool startsImmediately = false;

  @override
  Future<void> speak(
    VoiceAuditionRequest request, {
    VoidCallback? onStart,
  }) async {
    spoken.add(request);
    if (failure case final error?) throw error;
    started = true;
    _onStart = onStart;
    if (startsImmediately) onStart?.call();
    if (autoFinish) {
      finished = true;
      return;
    }
    _current = Completer<void>();
    await _current!.future;
    finished = true;
  }

  /// The platform says the audio began (a preview that did not start at once).
  void begin() {
    final callback = _onStart;
    _onStart = null;
    callback?.call();
  }

  /// The words ended on their own.
  void finish() {
    final current = _current;
    _current = null;
    if (current != null && !current.isCompleted) current.complete();
  }

  /// The platform refused in the middle of the words.
  void fail(Object error) {
    final current = _current;
    _current = null;
    if (current != null && !current.isCompleted) current.completeError(error);
  }

  @override
  Future<void> stop() async {
    stops++;
    finish();
  }
}

/// A factory of [FakeAuditionEngine]s that keeps every engine it made, so a
/// test can see which of them spoke and which were stopped.
class FakeAuditionEngines {
  FakeAuditionEngines({this.autoFinish = false, this.startsImmediately = false});

  final bool autoFinish;
  final bool startsImmediately;
  final List<FakeAuditionEngine> engines = <FakeAuditionEngine>[];

  /// What the next engine to be made raises instead of speaking; cleared
  /// once one has.
  Object? nextFailure;

  int get made => engines.length;
  FakeAuditionEngine get last => engines.last;

  /// Every preview any engine was asked to say, in order.
  List<VoiceAuditionRequest> get spoken => [
    for (final engine in engines) ...engine.spoken,
  ];

  FakeAuditionEngine call() {
    final engine = FakeAuditionEngine(
      autoFinish: autoFinish,
      failure: nextFailure,
      startsImmediately: startsImmediately,
    );
    nextFailure = null;
    engines.add(engine);
    return engine;
  }
}
