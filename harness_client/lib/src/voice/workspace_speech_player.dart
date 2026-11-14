import 'dart:async';

import '../models/workspace_speech.dart';
import '../models/workspace_speech_claim.dart';
import 'voice_backend.dart';
import '../services/harness_api.dart';

/// The floor's methods a speaker needs, as the app calls them.  The tests
/// put a scripted floor here, so the queue, the claim and the advance are
/// exercised without a harness.
abstract class WorkspaceSpeechGateway {
  Future<WorkspaceSpeechClaim> claim(
    String workspace,
    String entry, {
    required String client,
  });

  Future<WorkspaceSpeech> advance(
    String workspace,
    String entry, {
    String outcome = 'finished',
    String? why,
  });
}

/// This client's speaker for the workspace's speech floor.
///
/// The floor says what should be said and in what order; this says it here.
/// It claims the entry before it speaks, so a phone and a desktop in the same
/// room say the words once, and it reports what became of the utterance, so
/// the queue moves only when the words really ended.  It keeps no queue of
/// its own: [pump] is given the floor and starts the one entry the harness
/// says is speaking, or nothing.
class WorkspaceSpeechPlayer {
  WorkspaceSpeechPlayer({
    required this.gateway,
    required this.speech,
    required this.client,
    this.speakReplies = true,
  });

  final WorkspaceSpeechGateway gateway;

  /// The platform's speech engine: the same seam the clip voice provider
  /// speaks through, so a test hands it a script and no audio is played.
  ///
  /// It is asked for only when there are words to say, so a client whose
  /// engine cannot be opened at all -- a phone without one, a test that has
  /// no platform channel -- still shows the floor and still claims nothing.
  final VoiceSpeech Function() speech;

  /// This device's name, which the floor records as the entry's holder.
  final String client;

  /// Whether this device says anything at all.  Off keeps it silent while
  /// the floor still shows and another client speaks.
  final bool speakReplies;

  /// The entry being said now, or null.
  String? _entry;
  String? _workspace;
  int _generation = 0;
  bool _stopped = false;

  /// Non-nil while a claim is in flight, so two arrivals claim once.
  bool _starting = false;

  /// The utterance this client is saying, or null.
  String? get entry => _entry;

  /// Whether this client is the one saying the floor's words now.
  bool get playing => _entry != null;

  /// Say what [floor] says should be said, if this client should say it.
  ///
  /// One utterance at a time: while one plays, nothing else starts.  A held
  /// floor starts nothing, and the words playing when a hold begins are
  /// stopped *quietly* -- the floor keeps them, so they are not cancelled.
  Future<void> pump(WorkspaceSpeech? floor) async {
    if (floor == null || _stopped) return;
    if (floor.hold) {
      if (_entry != null) await _stopQuietly();
      return;
    }
    if (!speakReplies) return;
    final speaking = floor.speaking;
    if (speaking == null || !speaking.speaking) return;
    if (_entry != null || _starting) return;
    final id = floor.workspace;
    if (id.isEmpty) return;
    final generation = _generation;
    _workspace = id;
    _starting = true;
    WorkspaceSpeechClaim claim;
    try {
      claim = await gateway.claim(id, speaking.id, client: client);
    } finally {
      _starting = false;
    }
    if (generation != _generation || _stopped) return;
    if (!claim.claimed) {
      // Another client has the floor: this one stays quiet rather than talk
      // over it.  A claim the floor held back, or an entry that yielded
      // meanwhile, is nothing to say here.
      return;
    }
    await _say(speaking, generation);
  }

  /// Stop what this client is saying and report it interrupted, as a person
  /// talking over the assistant does: the floor moves on rather than
  /// replaying it.
  Future<void> interrupt({String why = 'Interrupted'}) async {
    final entry = _entry;
    final workspace = _workspace;
    _generation++;
    _entry = null;
    if (entry == null || workspace == null) return;
    await _stopEngine();
    await gateway.advance(workspace, entry, outcome: 'cancelled', why: why);
  }

  /// Forget everything and stop the engine: the workspace is gone, or the
  /// screen is closed.  Nothing is reported, so a floor that is still there
  /// keeps its queue.
  Future<void> dispose() async {
    _stopped = true;
    _generation++;
    _entry = null;
    await _stopEngine();
  }

  /// The engine this client is saying its words through, once it has one.
  VoiceSpeech? _engine;

  /// Stop the engine this client opened, and forget it: nothing is opened
  /// for a stop, so a client that never spoke stops nothing.
  Future<void> _stopEngine() async {
    final engine = _engine;
    _engine = null;
    if (engine == null) return;
    try {
      await engine.stop();
    } catch (_) {
      // An engine that is not speaking has nothing to stop.
    }
  }

  /// Stop the words without reporting them: a hold keeps them on the floor.
  Future<void> _stopQuietly() async {
    _generation++;
    _entry = null;
    await _stopEngine();
  }

  Future<void> _say(WorkspaceSpeechEntry entry, int generation) async {
    final workspace = _workspace;
    if (workspace == null) return;
    final text = entry.text.trim().isEmpty ? entry.preview.trim() : entry.text.trim();
    if (text.isEmpty) {
      await gateway.advance(
        workspace,
        entry.id,
        outcome: 'cancelled',
        why: 'Nothing to say',
      );
      return;
    }
    _entry = entry.id;
    VoiceSpeech engine;
    try {
      engine = _engine ??= speech();
    } catch (_) {
      _entry = null;
      await gateway.advance(
        workspace,
        entry.id,
        outcome: 'failed',
        why: 'Speech unavailable',
      );
      return;
    }
    try {
      await engine.speak(text);
    } catch (_) {
      if (generation != _generation) return;
      _entry = null;
      await gateway.advance(
        workspace,
        entry.id,
        outcome: 'failed',
        why: 'Playback failed',
      );
      return;
    }
    if (generation != _generation) return;
    _entry = null;
    await gateway.advance(workspace, entry.id);
  }
}

/// The floor as [HarnessApi] answers it, for the app's own speaker.
class ApiWorkspaceSpeechGateway implements WorkspaceSpeechGateway {
  ApiWorkspaceSpeechGateway(this.api);

  final HarnessApi api;

  @override
  Future<WorkspaceSpeechClaim> claim(
    String workspace,
    String entry, {
    required String client,
  }) => api.workspaceSpeechClaim(workspace, entry, client: client);

  @override
  Future<WorkspaceSpeech> advance(
    String workspace,
    String entry, {
    String outcome = 'finished',
    String? why,
  }) => api.workspaceSpeechAdvance(
    workspace,
    entry,
    outcome: outcome,
    why: why,
  );
}
