/// Auditioning an output voice: the state machine behind the sheet's one
/// `Audition` control.
///
/// It owns no platform channel.  The engine that actually speaks is a
/// [VoiceAuditionEngine], given to the controller by its owner (the sheet's
/// production engine lives in `lib/src/services/voice_output_io.dart`); a test
/// hands in a scripted one.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'voice_output.dart';

/// One preview: the words to say, and the parameters to say them with.
///
/// [params] is already validated; the controller refuses to build a request
/// from a draft with a problem, so an out-of-range number never reaches an
/// engine and is never spoken with a wrong voice.
@immutable
class VoiceAuditionRequest {
  const VoiceAuditionRequest({required this.text, required this.params});

  final String text;
  final VoiceOutputParams params;

  @override
  bool operator ==(Object other) =>
      other is VoiceAuditionRequest &&
      other.text == text &&
      other.params == params;

  @override
  int get hashCode => Object.hash(text, params);

  @override
  String toString() => 'VoiceAuditionRequest($text, $params)';
}

/// The platform's speech engine, as far as an audition needs it: apply
/// [request]'s voice and parameters, say its words, and stop.  A spoken reply
/// is made through the same parameters, so a preview is what a conversation
/// sounds like.
abstract class VoiceAuditionEngine {
  /// Apply [request] and say its words.
  ///
  /// [onStart] runs once the engine is actually speaking (the platform's own
  /// start callback); the future completes when the words have been said, and
  /// throws when the platform refused.
  Future<void> speak(VoiceAuditionRequest request, {VoidCallback? onStart});

  /// Stop whatever is being said now.  It never throws: an engine that is
  /// already silent has nothing to stop.
  Future<void> stop();
}

/// Builds the engine for one provider, at the moment an audition starts, so a
/// provider change between auditions is seen by the next one.
typedef VoiceAuditionEngineFactory = VoiceAuditionEngine Function();

/// What an audition is doing, as the sheet's control says it.
enum VoiceAuditionState {
  /// The provider cannot audition a voice here: the live provider's realtime
  /// voice is defined by its endpoint, and this client has no verified
  /// catalogue to try one against.
  unavailable,

  /// Nothing is being previewed.  The control reads `Audition`.
  idle,

  /// The engine was told to speak and has not started yet (a platform's first
  /// call is often slow).
  loading,

  /// The engine is saying the words.
  playing,

  /// The last preview ended, or was stopped.  The control still reads
  /// `Audition`; the sheet says `Stopped`.
  stopped,

  /// The engine refused, or did not finish in time.
  /// [VoiceAuditionController.message] holds what it said, and the sheet
  /// offers `Retry`.
  failed,
}

/// The one audition the sheet is running, if any.
///
/// A preview belongs to the moment it was started in.  A new preview, a stop,
/// a change of voice or of a parameter, a change of provider, the sheet
/// closing and a new speech engine all bump [generation]; every start
/// callback, completion, timeout and error of an older generation is then
/// dropped without touching the state or the engine.  A preview that was
/// playing is stopped when it is replaced, and a completion that arrives
/// after that stop is old by the time it does, so a stale callback can never
/// move the state or play a voice that was since changed.
class VoiceAuditionController extends ChangeNotifier {
  VoiceAuditionController({
    required this.engineFactory,
    this.available = true,
    this.timeout = const Duration(seconds: 20),
  });

  /// Builds the engine a preview speaks through.  A new one is made for every
  /// preview, so a preview never inherits the settings of a previous one.
  VoiceAuditionEngineFactory engineFactory;

  /// Whether the provider this sheet is set to can audition at all.  False
  /// puts the controller, and the sheet's control, in
  /// [VoiceAuditionState.unavailable].
  bool available;

  /// How long one preview may take before it counts as
  /// [VoiceAuditionState.failed] and says so, rather than leaving `Playing` on
  /// screen forever.
  final Duration timeout;

  VoiceAuditionState _state = VoiceAuditionState.idle;

  /// The state the sheet shows: [state], or `unavailable` whenever the
  /// provider cannot audition, whatever happened before.
  VoiceAuditionState get state =>
      available ? _state : VoiceAuditionState.unavailable;

  String? _message;

  /// What the engine said when the last preview failed, as data; null
  /// otherwise.
  String? get message => available ? _message : null;

  /// The request being previewed now, or the last one previewed.
  VoiceAuditionRequest? _request;
  VoiceAuditionRequest? get request => _request;

  /// Bumped whenever what is being previewed, or who is previewing it,
  /// changes.  A callback from an older generation does nothing.
  int _generation = 0;
  int get generation => _generation;

  bool _disposed = false;

  /// The engine of the running preview, if there is one: it is the one a stop
  /// has to reach.
  VoiceAuditionEngine? _engine;

  /// Whether this generation is loading or playing: the control reads `Stop`
  /// then.
  bool get isActive =>
      available &&
      (_state == VoiceAuditionState.loading ||
          _state == VoiceAuditionState.playing);

  /// Whether the last preview failed, so the sheet offers `Retry`.
  bool get isFailed => available && _state == VoiceAuditionState.failed;

  /// Speak [request] now, replacing any preview that was running.
  ///
  /// The caller validates the draft first: a request with a problem is
  /// refused before it is handed in, and the controller speaks nothing.
  ///
  /// The state moves to [VoiceAuditionState.loading] at once, so the control
  /// says so in the frame the person pressed it; the engine of any preview
  /// that was running is stopped behind that, and its completion cannot bring
  /// it back.
  Future<void> audition(VoiceAuditionRequest request) async {
    if (_disposed) return;
    if (!available) {
      _set(VoiceAuditionState.unavailable);
      return;
    }
    final generation = _begin();
    _request = request;
    _message = null;
    _set(VoiceAuditionState.loading);
    final engine = engineFactory();
    _engine = engine;
    try {
      final speaking = engine.speak(
        request,
        onStart: () {
          if (_disposed || generation != _generation) return;
          _set(VoiceAuditionState.playing);
        },
      );
      await speaking.timeout(
        timeout,
        onTimeout: () => throw VoiceAuditionTimeout(timeout),
      );
      if (_disposed || generation != _generation) return;
      _engine = null;
      _set(VoiceAuditionState.stopped);
    } catch (error) {
      if (_disposed || generation != _generation) return;
      _engine = null;
      unawaited(_silence(engine));
      _message = _oneLine(error);
      _set(VoiceAuditionState.failed);
    }
  }

  /// Stop the preview that is running.  The state moves on at once, and a
  /// completion the stopped preview already scheduled is ignored, so it cannot
  /// go on to `Playing` or `Stopped` from its own words.
  Future<void> stop() async {
    if (_disposed || !available) return;
    final wasActive = isActive;
    final hadFailure = _state == VoiceAuditionState.failed;
    _begin();
    if (!wasActive && !hadFailure) return;
    _message = null;
    _set(VoiceAuditionState.stopped);
  }

  /// Something the preview depends on changed: its voice, one of its
  /// parameters, or the provider.  A preview that was running is stopped, and
  /// its completion does not bring it back; the control returns to `Audition`
  /// (or to `Retry` while the last words are still a failure the person has
  /// not retried).
  Future<void> invalidate() async {
    if (_disposed || !available || !isActive) return;
    _begin();
    _message = null;
    _set(VoiceAuditionState.stopped);
  }

  /// The provider changed.  A preview that was running is stopped, and the
  /// control follows the provider: `Audition · unavailable` for the live
  /// provider, `Audition` for the clip one.
  Future<void> setAvailable(bool next) async {
    if (_disposed || next == available) return;
    _begin();
    available = next;
    _state = next ? VoiceAuditionState.idle : VoiceAuditionState.unavailable;
    _message = null;
    _request = null;
    notifyListeners();
  }

  /// A new speech engine, for the same provider: whatever was playing belongs
  /// to the engine that is gone.
  Future<void> replaceEngine(VoiceAuditionEngineFactory factory) async {
    if (_disposed) return;
    await stop();
    engineFactory = factory;
    _begin();
    notifyListeners();
  }

  /// End the preview for good.  The engine is stopped without waiting, since
  /// the sheet is going away; its completion finds the generation old.
  void disposeAudition() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    final engine = _engine;
    _engine = null;
    if (engine != null) unawaited(_silence(engine));
  }

  @override
  void dispose() {
    disposeAudition();
    super.dispose();
  }

  /// Own the next generation: bump the counter, and tell the engine of any
  /// running preview to be quiet.  Every callback that belongs to an older
  /// generation compares its number with [generation] and does nothing.
  int _begin() {
    _generation++;
    final engine = _engine;
    _engine = null;
    if (engine != null) unawaited(_silence(engine));
    return _generation;
  }

  Future<void> _silence(VoiceAuditionEngine engine) async {
    try {
      await engine.stop();
    } catch (_) {
      // A stop that fails has still told the engine to be quiet.
    }
  }

  void _set(VoiceAuditionState next) {
    if (_disposed) return;
    _state = next;
    notifyListeners();
  }

  static String _oneLine(Object error) {
    final line = '$error'.trim().split('\n').first.trim();
    if (line.isEmpty) return error.runtimeType.toString();
    return line.length <= 160 ? line : '${line.substring(0, 159)}…';
  }
}

/// A preview that has not finished in time.  It is reported as a failure with
/// its own words, so the sheet says `Failed` and offers `Retry` rather than
/// waiting forever.
class VoiceAuditionTimeout implements Exception {
  const VoiceAuditionTimeout(this.after);

  final Duration after;

  @override
  String toString() => 'Speech timeout · ${after.inSeconds}s';
}
