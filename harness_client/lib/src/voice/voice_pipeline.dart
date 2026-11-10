import 'package:flutter/foundation.dart';

import 'voice_backend.dart';
import 'voice_models.dart';

/// Where the microphone is, from the capture path's own state.  [live] is not
/// a claim that anything was heard: the meter says what arrived, and
/// [VoicePipelineSnapshot.levelSeen] says whether any level has arrived at all.
enum VoiceInputState {
  off,
  connecting,
  live,
  muted,
  paused,
  failed,
  disconnected,
  ended,
}

extension VoiceInputLabel on VoiceInputState {
  /// A noun phrase or an adjective, as every label in the app is.
  String get label => switch (this) {
    VoiceInputState.off => 'off',
    VoiceInputState.connecting => 'connecting',
    VoiceInputState.live => 'live',
    VoiceInputState.muted => 'muted',
    VoiceInputState.paused => 'paused',
    VoiceInputState.failed => 'failed',
    VoiceInputState.disconnected => 'disconnected',
    VoiceInputState.ended => 'ended',
  };

  /// Whether audio may be reaching the capture path in this state.  A level
  /// that is not arriving is only surprising when it should be.
  bool get captureOpen => this == VoiceInputState.live;
}

/// Where one burst of audio is in the pipe.  [inTurn] and [answered] are set
/// by the screen from the model turn the segment was sent in; the rest come
/// from the capture path's own events.
enum VoicePipelineStage {
  accepted,
  transcribing,
  transcribed,
  inTurn,
  answered,
  dropped,
  failed,
}

extension VoicePipelineStageLabel on VoicePipelineStage {
  String get label => switch (this) {
    VoicePipelineStage.accepted => 'accepted',
    VoicePipelineStage.transcribing => 'transcribing',
    VoicePipelineStage.transcribed => 'transcribed',
    VoicePipelineStage.inTurn => 'in turn',
    VoicePipelineStage.answered => 'answered',
    VoicePipelineStage.dropped => 'dropped',
    VoicePipelineStage.failed => 'failed',
  };

  /// Terminal stages never advance again: a late event cannot resurrect them.
  bool get terminal =>
      this == VoicePipelineStage.dropped ||
      this == VoicePipelineStage.failed ||
      this == VoicePipelineStage.answered;
}

/// The column of the pipe a marker is drawn in.
enum VoicePipelineColumn { filter, transcript, turn }

/// One utterance, as the capture path and the screen saw it.
@immutable
class VoiceSegment {
  const VoiceSegment({
    required this.id,
    required this.stage,
    required this.generation,
    this.duration,
    this.level,
    this.text,
    this.drop,
    this.detail,
    this.turnId,
    this.revision = 0,
    this.seen = 0,
  });

  /// The backend's stable id for this utterance.
  final String id;
  final VoicePipelineStage stage;
  final int generation;

  /// How much audio the burst holds, when the backend measured it.
  final Duration? duration;

  /// The burst's loudest level, 0..1.
  final double? level;

  /// The words so far; a partial replaces it and the final completes it.
  final String? text;
  final VoiceSegmentDrop? drop;

  /// A failure's own words, or what cancelled it.  Data, not interface copy.
  final String? detail;

  /// The model turn that carried it, once it was sent.
  final String? turnId;

  /// How many transcript revisions it has taken; a partial and its final are
  /// the same segment, not two.
  final int revision;

  /// A monotonic ticket, so the view can tell an update from a rebuild.
  final int seen;

  VoiceSegment copyWith({
    VoicePipelineStage? stage,
    Duration? duration,
    double? level,
    String? text,
    VoiceSegmentDrop? drop,
    String? detail,
    String? turnId,
    int? revision,
    int? seen,
  }) => VoiceSegment(
    id: id,
    stage: stage ?? this.stage,
    generation: generation,
    duration: duration ?? this.duration,
    level: level ?? this.level,
    text: text ?? this.text,
    drop: drop ?? this.drop,
    detail: detail ?? this.detail,
    turnId: turnId ?? this.turnId,
    revision: revision ?? this.revision,
    seen: seen ?? this.seen,
  );

  bool get isDropped => stage == VoicePipelineStage.dropped;

  /// The column it is drawn in: the stage at which it stopped, or where it
  /// continues now.
  VoicePipelineColumn get column => switch (stage) {
    VoicePipelineStage.accepted => VoicePipelineColumn.filter,
    VoicePipelineStage.transcribing ||
    VoicePipelineStage.transcribed => VoicePipelineColumn.transcript,
    VoicePipelineStage.inTurn ||
    VoicePipelineStage.answered => VoicePipelineColumn.turn,
    VoicePipelineStage.dropped =>
      drop == VoiceSegmentDrop.noWords ||
              drop == VoiceSegmentDrop.retargeted
          ? VoicePipelineColumn.transcript
          : VoicePipelineColumn.filter,
    VoicePipelineStage.failed => VoicePipelineColumn.transcript,
  };

  /// A short word for the dropped segment's reason, and nothing else.
  String? get dropLabel => switch (drop) {
    VoiceSegmentDrop.tooShort => 'too short',
    VoiceSegmentDrop.noWords => 'no words',
    VoiceSegmentDrop.retargeted => 'retargeted',
    VoiceSegmentDrop.cancelled => 'cancelled',
    VoiceSegmentDrop.failed => 'failed',
    null => null,
  };
}

/// One agent turn the screen sent, and the segments and replies it carries.
@immutable
class VoiceTurn {
  const VoiceTurn({
    required this.id,
    required this.stage,
    required this.generation,
    this.segmentIds = const [],
    this.replyIds = const [],
    this.detail,
  });

  final String id;

  /// `working`, `done` or `failed`; a working turn that has a reply reads
  /// `replied`.
  final String stage;
  final int generation;
  final List<String> segmentIds;
  final List<String> replyIds;
  final String? detail;

  bool get working => stage == 'working';
  bool get failed => stage == 'failed';
  bool get replied => replyIds.isNotEmpty;

  String get label => switch (stage) {
    'failed' => 'failed',
    'working' => replyIds.isEmpty ? 'working' : 'replied',
    _ => 'done',
  };

  VoiceTurn copyWith({
    String? stage,
    List<String>? segmentIds,
    List<String>? replyIds,
    String? detail,
  }) => VoiceTurn(
    id: id,
    stage: stage ?? this.stage,
    generation: generation,
    segmentIds: segmentIds ?? this.segmentIds,
    replyIds: replyIds ?? this.replyIds,
    detail: detail ?? this.detail,
  );
}

/// One piece of the agent's answer on the voice side.
enum VoiceReplyStage {
  ready,
  held,
  handed,
  speaking,
  spoken,
  interrupted,
  dropped,
  failed,
}

extension VoiceReplyStageLabel on VoiceReplyStage {
  String get label => switch (this) {
    VoiceReplyStage.ready => 'ready',
    VoiceReplyStage.held => 'held',
    VoiceReplyStage.handed => 'handed',
    VoiceReplyStage.speaking => 'speaking',
    VoiceReplyStage.spoken => 'spoken',
    VoiceReplyStage.interrupted => 'interrupted',
    VoiceReplyStage.dropped => 'dropped',
    VoiceReplyStage.failed => 'failed',
  };

  bool get terminal =>
      this == VoiceReplyStage.spoken ||
      this == VoiceReplyStage.interrupted ||
      this == VoiceReplyStage.dropped ||
      this == VoiceReplyStage.failed;

  bool get audible =>
      this != VoiceReplyStage.spoken &&
      this != VoiceReplyStage.interrupted &&
      this != VoiceReplyStage.dropped &&
      this != VoiceReplyStage.failed;
}

/// A reply the screen decided to speak, with what the provider did with it.
@immutable
class VoiceReply {
  const VoiceReply({
    required this.id,
    required this.stage,
    required this.generation,
    this.text,
    this.turnId,
    this.detail,
  });

  final String id;
  final VoiceReplyStage stage;
  final int generation;

  /// The reply's own words, kept only as long as the marker shows.
  final String? text;

  /// The turn that produced it, when the screen could attribute it.
  final String? turnId;
  final String? detail;

  VoiceReply copyWith({VoiceReplyStage? stage, String? detail}) => VoiceReply(
    id: id,
    stage: stage ?? this.stage,
    generation: generation,
    text: text,
    turnId: turnId,
    detail: detail ?? this.detail,
  );
}

/// What the speaker endpoint is doing, from the replies and the provider's
/// own playback state.
enum VoiceOutputState {
  silent,
  ready,
  held,
  handed,
  speaking,
  interrupted,
  failed,
}

extension VoiceOutputLabel on VoiceOutputState {
  String get label => switch (this) {
    VoiceOutputState.silent => 'silent',
    VoiceOutputState.ready => 'ready',
    VoiceOutputState.held => 'held',
    VoiceOutputState.handed => 'handed',
    VoiceOutputState.speaking => 'speaking',
    VoiceOutputState.interrupted => 'interrupted',
    VoiceOutputState.failed => 'failed',
  };
}

/// A picture of the pipe at one moment.  It holds no audio, only what the
/// stages and their events say.
@immutable
class VoicePipelineSnapshot {
  const VoicePipelineSnapshot({
    required this.generation,
    required this.input,
    required this.level,
    required this.levelSeen,
    required this.levelAt,
    required this.speechActive,
    required this.segments,
    required this.turns,
    required this.replies,
    required this.accepted,
    required this.dropped,
    required this.spoken,
    required this.playing,
    this.problemLabel,
  });

  final int generation;
  final VoiceInputState input;

  /// The last level the capture path reported, 0..1.  It is the level before
  /// the speech filter, so it answers "is the microphone reaching the app".
  final double level;

  /// Whether any level has arrived since the conversation began.  A backend
  /// that sends none (a live provider's own VAD) leaves this false, and the
  /// meter must then say that it has no data rather than show silence.
  final bool levelSeen;
  final DateTime? levelAt;

  /// Whether the capture gate hears speech now, before any transcript exists.
  final bool speechActive;

  final List<VoiceSegment> segments;
  final List<VoiceTurn> turns;
  final List<VoiceReply> replies;

  /// Totals for the conversation, which outlive the bounded lists.
  final int accepted;
  final int dropped;
  final int spoken;

  /// Whether the provider's own player is playing audio now.
  final bool playing;

  /// The backend's own problem label, shown with the meter: a refused
  /// microphone permission, an unavailable capture device, and so on.
  final String? problemLabel;

  static const empty = VoicePipelineSnapshot(
    generation: 0,
    input: VoiceInputState.off,
    level: 0,
    levelSeen: false,
    levelAt: null,
    speechActive: false,
    segments: [],
    turns: [],
    replies: [],
    accepted: 0,
    dropped: 0,
    spoken: 0,
    playing: false,
  );

  /// How long a level may be missing before the meter says it has no data.
  static const staleAfter = Duration(seconds: 2);

  /// Whether the last level is too old to stand for the present.
  bool levelStale(DateTime now) {
    if (!levelSeen) return true;
    final at = levelAt;
    if (at == null) return true;
    return now.difference(at) > staleAfter;
  }

  /// The microphone line under the meter.
  String get inputLabel => 'Mic · ${input.label}';

  /// The level line under the meter.  No telemetry is said plainly, so a
  /// missing level is never read as a quiet room.
  String meterLabel(DateTime now) {
    // A closed or paused microphone sends no levels; that is not a quiet
    // room, so the meter says it has no data rather than 0%.
    if (!input.captureOpen) return 'Level · no data';
    return levelStale(now)
        ? 'Level · no data'
        : 'Level · ${(level * 100).round()}%';
  }

  VoiceTurn? get currentTurn {
    for (final turn in turns.reversed) {
      if (turn.working) return turn;
    }
    return turns.isEmpty ? null : turns.last;
  }

  /// The turn line, or null before anything was sent.
  String? get turnLabel {
    final turn = currentTurn;
    return turn == null ? null : 'Turn · ${turn.label}';
  }

  /// What the speaker endpoint is doing now.
  VoiceOutputState get output {
    if (playing || replies.any((r) => r.stage == VoiceReplyStage.speaking)) {
      return VoiceOutputState.speaking;
    }
    final live = replies.where((r) => r.stage.audible).toList();
    if (live.any((r) => r.stage == VoiceReplyStage.failed)) {
      return VoiceOutputState.failed;
    }
    if (live.any((r) => r.stage == VoiceReplyStage.handed)) {
      return VoiceOutputState.handed;
    }
    if (live.any((r) => r.stage == VoiceReplyStage.held)) {
      return VoiceOutputState.held;
    }
    if (live.any((r) => r.stage == VoiceReplyStage.ready)) {
      return VoiceOutputState.ready;
    }
    if (replies.any((r) => r.stage == VoiceReplyStage.interrupted)) {
      return VoiceOutputState.interrupted;
    }
    return VoiceOutputState.silent;
  }

  String get speakerLabel => 'Voice · ${output.label}';

  /// The counts that are worth a word, joined as the rest of the app joins
  /// them.
  String? get countLabel {
    final parts = <String>[
      if (accepted > 0) '$accepted accepted',
      if (dropped > 0) '$dropped dropped',
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  /// Every fact of the pipe on one line.  A screen reader reads it, and the
  /// compact presentation shows it, so nothing about the pipe is carried by
  /// colour or motion alone.
  String summary(DateTime now) => _line([
    inputLabel,
    meterLabel(now),
    if (speechActive) 'Speech · heard',
    if (countLabel case final counts?) counts,
    if (turnLabel case final turn?) turn,
    speakerLabel,
    if (problemLabel case final problem?) problem,
  ]);

  /// The same facts, without the meter and without a turn's history, for the
  /// compact presentation and the buddy.
  String shortSummary(DateTime now) => _line([
    inputLabel,
    if (countLabel case final counts?) counts,
    if (turnLabel case final turn?) turn,
    speakerLabel,
    if (problemLabel case final problem?) problem,
  ]);

  /// Every marker as a line of words, for the detail view and a screen
  /// reader: ids are data, so a reader can match a marker to its event.
  List<String> get details => [
    for (final segment in segments) _segmentDetail(segment),
    for (final turn in turns) _turnDetail(turn),
    for (final reply in replies) _replyDetail(reply),
  ];

  static String _segmentDetail(VoiceSegment segment) => _line([
    segment.id,
    segment.stage.label,
    if (segment.duration case final duration?) voicePipelineDuration(duration),
    if (segment.dropLabel case final reason?) reason,
    if (segment.text case final text? when text.trim().isNotEmpty)
      '"${voicePipelineExcerpt(text)}"',
    if (segment.detail case final detail? when detail.trim().isNotEmpty) detail,
  ]);

  static String _turnDetail(VoiceTurn turn) => _line([
    turn.id,
    turn.label,
    if (turn.segmentIds.isNotEmpty)
      '${turn.segmentIds.length} ${turn.segmentIds.length == 1 ? 'utterance' : 'utterances'}',
    if (turn.replyIds.isNotEmpty)
      '${turn.replyIds.length} ${turn.replyIds.length == 1 ? 'reply' : 'replies'}',
    if (turn.detail case final detail? when detail.trim().isNotEmpty) detail,
  ]);

  static String _replyDetail(VoiceReply reply) => _line([
    reply.id,
    reply.stage.label,
    if (reply.turnId case final turn? when turn.isNotEmpty) turn,
    if (reply.text case final text? when text.trim().isNotEmpty)
      '"${voicePipelineExcerpt(text)}"',
    if (reply.detail case final detail? when detail.trim().isNotEmpty) detail,
  ]);
}

/// A short duration for a marker: `640ms`, `1.4s`, `12s`.
String voicePipelineDuration(Duration duration) {
  final millis = duration.inMilliseconds;
  if (millis < 1000) return '${millis}ms';
  final seconds = millis / 1000;
  if (seconds < 10) return '${seconds.toStringAsFixed(1)}s';
  return '${seconds.round()}s';
}

/// The first words of a transcript, for a detail line.
String voicePipelineExcerpt(String text, {int max = 48}) {
  final line = text.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (line.length <= max) return line;
  return '${line.substring(0, max - 1)}…';
}

String _line(List<String?> parts) =>
    parts.whereType<String>().where((part) => part.isNotEmpty).join(' · ');

/// The pipe's state, built from real events and the screen's own decisions.
///
/// Every rule here is a rule about what really happened: a burst appears only
/// when the capture path kept it, a marker moves only when the stage it is
/// waiting on reports, and an event with an id that already ended is ignored
/// rather than brought back.  Nothing advances on a clock.
class VoicePipelineTracker {
  VoicePipelineTracker({
    DateTime Function()? clock,
    this.maxSegments = 6,
    this.maxTurns = 3,
    this.maxReplies = 3,
  }) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;

  /// How many markers each column keeps; the totals keep the rest.
  final int maxSegments;
  final int maxTurns;
  final int maxReplies;

  VoiceInputState _input = VoiceInputState.off;
  VoiceProblem? _problem;
  double _level = 0;
  bool _levelSeen = false;
  DateTime? _levelAt;
  bool _speechActive = false;
  bool _playing = false;
  int _playbackGeneration = 0;

  final List<VoiceSegment> _segments = [];
  final List<VoiceTurn> _turns = [];
  final List<VoiceReply> _replies = [];

  int _generation = 0;
  int _accepted = 0;
  int _dropped = 0;
  int _spoken = 0;
  int _segmentSequence = 0;
  int _replySequence = 0;
  int _tick = 0;

  /// Events that named something already ended, or a generation that is over.
  /// Kept so a test can assert a late event changed nothing.
  int get ignoredEvents => _ignored;
  int _ignored = 0;

  int get generation => _generation;

  VoicePipelineSnapshot? _cached;

  VoicePipelineSnapshot get snapshot {
    final cached = _cached;
    if (cached != null) return cached;
    return _cached = VoicePipelineSnapshot(
      generation: _generation,
      input: _input,
      level: _level,
      levelSeen: _levelSeen,
      levelAt: _levelAt,
      speechActive: _speechActive,
      segments: List.unmodifiable(_segments),
      turns: List.unmodifiable(_turns),
      replies: List.unmodifiable(_replies),
      accepted: _accepted,
      dropped: _dropped,
      spoken: _spoken,
      playing: _playing,
      problemLabel: _problem?.label,
    );
  }

  void _changed() {
    _cached = null;
    _tick++;
  }

  /// A conversation begins: a new generation, so nothing from the last one
  /// can be advanced by a late event.
  void begin() {
    _generation++;
    _segments.clear();
    _turns.clear();
    _replies.clear();
    _accepted = 0;
    _dropped = 0;
    _spoken = 0;
    _segmentSequence = 0;
    _replySequence = 0;
    _ignored = 0;
    _level = 0;
    _levelSeen = false;
    _levelAt = null;
    _speechActive = false;
    _playing = false;
    _problem = null;
    _input = VoiceInputState.connecting;
    _changed();
  }

  /// The conversation stops.  The markers stay as the last true picture of
  /// it; the microphone and the speaker are closed.
  void end({VoiceInputState state = VoiceInputState.ended}) {
    _input = state;
    _speechActive = false;
    _playing = false;
    _level = 0;
    _levelSeen = false;
    _levelAt = null;
    for (final reply in List.of(_replies)) {
      if (reply.stage.audible) {
        _setReply(reply.id, VoiceReplyStage.dropped, detail: 'ended');
      }
    }
    _changed();
  }

  void input(VoiceInputState state) {
    if (_input == state) return;
    _input = state;
    if (!state.captureOpen) {
      _speechActive = false;
    }
    _changed();
  }

  void problem(VoiceProblem? problem) {
    if (_problem?.label == problem?.label) {
      _problem = problem;
      return;
    }
    _problem = problem;
    _changed();
  }

  void level(double value) {
    _level = value.isFinite ? value.clamp(0.0, 1.0) : 0;
    _levelSeen = true;
    _levelAt = _clock();
    _changed();
  }

  void gate(bool active) {
    if (_speechActive == active) return;
    _speechActive = active;
    _changed();
  }

  // ---------------------------------------------------------------- capture

  /// The capture path kept this burst for transcription.
  void accept(String id, {Duration? duration, double? level}) {
    if (id.isEmpty) return;
    final existing = _segment(id);
    if (existing != null) {
      _ignored++;
      return;
    }
    _segments.add(
      VoiceSegment(
        id: id,
        stage: VoicePipelineStage.accepted,
        generation: _generation,
        duration: duration,
        level: level,
        seen: _tick,
      ),
    );
    _accepted++;
    _trimSegments();
    _changed();
  }

  /// The capture path ended a burst it did not keep.  It is shown as what it
  /// was: audio that did not reach a model, with the measurement the filter
  /// made.
  void reject({
    Duration? duration,
    double? level,
    String? id,
    VoiceSegmentDrop drop = VoiceSegmentDrop.tooShort,
    String? detail,
  }) {
    final segmentId = (id == null || id.isEmpty)
        ? 'r-${++_segmentSequence}'
        : id;
    if (_segment(segmentId) != null) {
      _ignored++;
      return;
    }
    _segments.add(
      VoiceSegment(
        id: segmentId,
        stage: VoicePipelineStage.dropped,
        generation: _generation,
        duration: duration,
        level: level,
        drop: drop,
        detail: detail,
        seen: _tick,
      ),
    );
    _dropped++;
    _trimSegments();
    _changed();
  }

  /// Speech to text is running on it.
  void transcribing(String id) {
    final segment = _segment(id);
    if (segment == null) {
      // The accept event was lost but the utterance is really being
      // transcribed; show it at the stage it is at, not a made-up history.
      accept(id);
    }
    _advanceStage(id, VoicePipelineStage.transcribing);
  }

  /// Words arrived, whole or in part.  A partial keeps the segment where it
  /// is and only replaces its text; the final moves it on.
  void transcript(String id, String text, {bool finalized = false}) {
    var segment = _segment(id);
    if (segment == null) {
      accept(id);
      _advanceStage(id, VoicePipelineStage.transcribing);
      segment = _segment(id);
    }
    if (segment == null || segment.stage.terminal) {
      _ignored++;
      return;
    }
    final next = finalized
        ? VoicePipelineStage.transcribed
        : VoicePipelineStage.transcribing;
    _replaceSegment(
      segment.copyWith(
        // A partial that arrives after the final is the same segment; it
        // corrects nothing and must not move it backwards.
        stage: _rank(segment.stage) > _rank(next) ? segment.stage : next,
        text: text.trim().isEmpty ? segment.text : text.trim(),
        revision: segment.revision + 1,
        seen: _tick,
      ),
    );
    _changed();
  }

  /// The segment stopped before it was sent: mute, pause, stop, a restart, or
  /// a failure.  A terminal segment is never moved again.
  void drop(
    String id, {
    VoiceSegmentDrop drop = VoiceSegmentDrop.cancelled,
    String? detail,
  }) {
    final segment = _segment(id);
    if (segment == null) {
      _segments.add(
        VoiceSegment(
          id: id,
          stage: VoicePipelineStage.dropped,
          generation: _generation,
          drop: drop,
          detail: detail,
          seen: _tick,
        ),
      );
      _dropped++;
      _trimSegments();
      _changed();
      return;
    }
    if (segment.stage.terminal || segment.stage == VoicePipelineStage.inTurn) {
      _ignored++;
      return;
    }
    _replaceSegment(
      segment.copyWith(
        stage: drop == VoiceSegmentDrop.failed
            ? VoicePipelineStage.failed
            : VoicePipelineStage.dropped,
        drop: drop,
        detail: detail,
        seen: _tick,
      ),
    );
    _dropped++;
    _changed();
  }

  void fail(String id, {String? detail}) {
    final segment = _segment(id);
    if (segment == null) {
      _segments.add(
        VoiceSegment(
          id: id,
          stage: VoicePipelineStage.failed,
          generation: _generation,
          detail: detail,
          seen: _tick,
        ),
      );
      _trimSegments();
      _changed();
      return;
    }
    if (segment.stage.terminal) {
      _ignored++;
      return;
    }
    _replaceSegment(
      segment.copyWith(
        stage: VoicePipelineStage.failed,
        detail: detail,
        seen: _tick,
      ),
    );
    _changed();
  }

  // -------------------------------------------------------------- model turn

  /// The screen sent the segment's words to the session.  A turn that already
  /// exists takes another segment: several utterances can feed one turn.
  void turnSent(String turnId, {String? segmentId}) {
    if (turnId.isEmpty) return;
    final existing = _turn(turnId);
    if (existing != null) {
      if (segmentId == null || segmentId.isEmpty) return;
      if (existing.segmentIds.contains(segmentId)) return;
      _replaceTurn(
        existing.copyWith(segmentIds: [...existing.segmentIds, segmentId]),
      );
    } else {
      _turns.add(
        VoiceTurn(
          id: turnId,
          stage: 'working',
          generation: _generation,
          segmentIds: [
            if (segmentId != null && segmentId.isNotEmpty) segmentId,
          ],
        ),
      );
      _trimTurns();
    }
    final segment = segmentId == null ? null : _segment(segmentId);
    if (segment != null && !segment.stage.terminal) {
      _replaceSegment(
        segment.copyWith(
          stage: VoicePipelineStage.inTurn,
          turnId: turnId,
          seen: _tick,
        ),
      );
    }
    _changed();
  }

  /// The session finished the turn.
  void turnDone(String turnId) {
    final turn = _turn(turnId);
    if (turn == null || turn.stage != 'working') {
      _ignored++;
      return;
    }
    _replaceTurn(turn.copyWith(stage: 'done'));
    _changed();
  }

  /// The turn failed: the send threw, or the session reported an error.  Its
  /// segments stay where they are; the turn says what happened.
  void turnFailed(String turnId, {String? detail}) {
    final turn = _turn(turnId);
    if (turn == null || turn.stage != 'working') {
      _ignored++;
      return;
    }
    _replaceTurn(turn.copyWith(stage: 'failed', detail: detail));
    _changed();
  }

  /// The session answered the turn: its segments reach their last stage.
  void turnAnswered(String turnId) {
    final turn = _turn(turnId);
    if (turn == null) return;
    for (final segmentId in turn.segmentIds) {
      final segment = _segment(segmentId);
      if (segment == null || segment.stage.terminal) continue;
      _replaceSegment(
        segment.copyWith(stage: VoicePipelineStage.answered, seen: _tick),
      );
    }
    _changed();
  }

  // ----------------------------------------------------------------- output

  /// A reply the screen decided to speak.  Returns the id it gave it, which
  /// the backend's playback events use.
  String replyReady(String text, {String? turnId}) {
    final id = 'n-${++_replySequence}';
    _replies.add(
      VoiceReply(
        id: id,
        stage: VoiceReplyStage.ready,
        generation: _generation,
        text: text.trim().isEmpty ? null : text.trim(),
        turnId: turnId,
      ),
    );
    if (turnId != null) {
      final turn = _turn(turnId);
      if (turn != null) {
        _replaceTurn(turn.copyWith(replyIds: [...turn.replyIds, id]));
        turnAnswered(turnId);
      }
    }
    _trimReplies();
    _changed();
    return id;
  }

  /// The backend will not speak it until the person stops talking.
  void replyHeld(String id) {
    final reply = _reply(id);
    if (reply == null || reply.stage.terminal) {
      _ignored++;
      return;
    }
    if (reply.stage == VoiceReplyStage.held) return;
    _setReply(id, VoiceReplyStage.held);
  }

  /// The gate opened with no words, so the held reply may be spoken.
  void replyReleased(String id) {
    final reply = _reply(id);
    if (reply == null || reply.stage != VoiceReplyStage.held) {
      _ignored++;
      return;
    }
    _setReply(id, VoiceReplyStage.ready);
  }

  /// The reply was handed to the voice provider.  Handed is not speaking: a
  /// live provider starts its own audio later, and may not start it at all.
  void replyHanded(String id) {
    final reply = _reply(id);
    if (reply == null || reply.stage.terminal) {
      _ignored++;
      return;
    }
    _setReply(id, VoiceReplyStage.handed);
  }

  /// The reply will not be spoken: mute, pause, an interruption or the end.
  void replyDropped(
    String id, {
    VoiceSegmentDrop drop = VoiceSegmentDrop.cancelled,
    String? detail,
  }) {
    final reply = _reply(id);
    if (reply == null || reply.stage.terminal) {
      _ignored++;
      return;
    }
    _setReply(
      id,
      drop == VoiceSegmentDrop.failed
          ? VoiceReplyStage.failed
          : VoiceReplyStage.dropped,
      detail: detail,
    );
  }

  void replyFailed(String id, {String? detail}) {
    final reply = _reply(id);
    if (reply == null || reply.stage.terminal) {
      _ignored++;
      return;
    }
    _setReply(id, VoiceReplyStage.failed, detail: detail);
  }

  /// The voice output device started or stopped playing, as the backend's own
  /// player reported it.  [replyId] names the reply when the backend knows
  /// which one it is; [generation] is the backend's, so a completion from a
  /// playback that was interrupted does not end the next one.
  void playback({required bool playing, String? replyId, int? generation}) {
    final reported = generation;
    if (reported != null) {
      if (reported < _playbackGeneration) {
        // The end of a playback that was already replaced by a newer one.
        _ignored++;
        return;
      }
      _playbackGeneration = reported;
    }
    if (playing) {
      _playing = true;
      final target = replyId != null
          ? _reply(replyId)
          : _lastReplyWhere((reply) => reply.stage == VoiceReplyStage.handed);
      if (target == null || target.stage.terminal) {
        // Audio for something the pipe no longer holds: the speaker says
        // that sound is playing, but no reply is moved by it.
        _ignored++;
        _changed();
        return;
      }
      _setReply(target.id, VoiceReplyStage.speaking);
      return;
    }
    _playing = false;
    final target = replyId != null
        ? _reply(replyId)
        : _lastReplyWhere((reply) => reply.stage == VoiceReplyStage.speaking);
    if (target == null) {
      _changed();
      return;
    }
    if (target.stage == VoiceReplyStage.handed) {
      // The provider finished a reply it was given without ever reporting a
      // start: it was handed over, and this does not claim it was heard.
      _changed();
      return;
    }
    if (target.stage != VoiceReplyStage.speaking) {
      // A stop for a reply that is not playing is stale, not a transition.
      _ignored++;
      _changed();
      return;
    }
    _setReply(target.id, VoiceReplyStage.spoken);
    _spoken++;
  }

  VoiceReply? _lastReplyWhere(bool Function(VoiceReply) test) {
    for (final reply in _replies.reversed) {
      if (test(reply)) return reply;
    }
    return null;
  }

  /// The person or the screen stopped the audio.  What was playing or waiting
  /// to play will not be said.
  void interrupted() {
    _playing = false;
    for (final reply in List.of(_replies)) {
      if (reply.stage == VoiceReplyStage.speaking ||
          reply.stage == VoiceReplyStage.handed) {
        _setReply(reply.id, VoiceReplyStage.interrupted);
      }
    }
    _changed();
  }

  // ---------------------------------------------------------------- internals

  VoiceSegment? _segment(String id) {
    for (final segment in _segments) {
      if (segment.id == id) return segment;
    }
    return null;
  }

  VoiceTurn? _turn(String id) {
    for (final turn in _turns) {
      if (turn.id == id) return turn;
    }
    return null;
  }

  VoiceReply? _reply(String id) {
    for (final reply in _replies) {
      if (reply.id == id) return reply;
    }
    return null;
  }

  void _replaceSegment(VoiceSegment segment) {
    final index = _segments.indexWhere((item) => item.id == segment.id);
    if (index >= 0) _segments[index] = segment;
  }

  void _replaceTurn(VoiceTurn turn) {
    final index = _turns.indexWhere((item) => item.id == turn.id);
    if (index >= 0) _turns[index] = turn;
  }

  void _setReply(String id, VoiceReplyStage stage, {String? detail}) {
    final index = _replies.indexWhere((item) => item.id == id);
    if (index < 0) return;
    final reply = _replies[index];
    if (reply.stage == stage) return;
    _replies[index] = reply.copyWith(stage: stage, detail: detail);
    _changed();
  }

  void _advanceStage(String id, VoicePipelineStage stage) {
    final segment = _segment(id);
    if (segment == null || segment.stage.terminal) {
      _ignored++;
      return;
    }
    if (_rank(segment.stage) >= _rank(stage)) return;
    _replaceSegment(
      segment.copyWith(
        stage: stage,
        seen: _tick,
        // A segment that answers keeps its turn link; nothing else changes.
      ),
    );
    _changed();
  }

  static int _rank(VoicePipelineStage stage) => switch (stage) {
    VoicePipelineStage.accepted => 0,
    VoicePipelineStage.transcribing => 1,
    VoicePipelineStage.transcribed => 2,
    VoicePipelineStage.inTurn => 3,
    VoicePipelineStage.answered => 4,
    VoicePipelineStage.dropped => 5,
    VoicePipelineStage.failed => 5,
  };

  void _trimSegments() {
    while (_segments.length > maxSegments) {
      final index = _segments.indexWhere((segment) => segment.stage.terminal);
      _segments.removeAt(index >= 0 ? index : 0);
    }
  }

  void _trimTurns() {
    while (_turns.length > maxTurns) {
      _turns.removeAt(0);
    }
  }

  void _trimReplies() {
    while (_replies.length > maxReplies) {
      final index = _replies.indexWhere((reply) => reply.stage.terminal);
      _replies.removeAt(index >= 0 ? index : 0);
    }
  }
}
