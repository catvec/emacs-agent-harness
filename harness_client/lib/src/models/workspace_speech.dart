import '../acp/acp_message.dart';
import 'session.dart' show parseTime;

/// The workspace's speech floor, as `_harness/workspace/speech` answers it:
/// one record, kept by the harness, that every client reads.
///
/// Nothing here is a queue of this client's own: [speaking], [waiting] and
/// [recent] are what the harness holds, in the order it will speak them, so
/// an Emacs and a phone in the same room show the same floor.
class WorkspaceSpeech {
  const WorkspaceSpeech({
    required this.workspace,
    this.revision = 0,
    this.enabled = true,
    this.hold = false,
    this.holdAt,
    this.solo,
    this.soloTitle,
    this.speaking,
    this.waiting = const [],
    this.active,
    this.count = 0,
    this.recent = const [],
  });

  factory WorkspaceSpeech.fromWire(JsonMap wire) {
    return WorkspaceSpeech(
      workspace: asStringOr(wire['workspace'], ''),
      revision: asInt(wire['revision']) ?? 0,
      enabled: asBool(wire['enabled'] ?? true),
      hold: asBool(wire['hold']),
      holdAt: wire['hold-at'] == null ? null : parseTime(wire['hold-at']),
      solo: asString(wire['solo']),
      soloTitle: asString(wire['solo-title'] ?? wire['soloTitle']),
      speaking: asMap(wire['speaking']).isEmpty
          ? null
          : WorkspaceSpeechEntry.fromWire(asMap(wire['speaking'])),
      waiting: [
        for (final item in asMapList(wire['waiting']))
          WorkspaceSpeechEntry.fromWire(item),
      ],
      active: asString(wire['active']),
      count: asInt(wire['count']) ?? 0,
      recent: [
        for (final item in asMapList(wire['recent']))
          WorkspaceSpeechEntry.fromWire(item),
      ],
    );
  }

  /// An empty floor of [workspace], before the harness has answered.
  factory WorkspaceSpeech.empty(String workspace) =>
      WorkspaceSpeech(workspace: workspace);

  final String workspace;

  /// Only ever grows: an answer older than the copy in hand is dropped.
  final int revision;
  final bool enabled;

  /// The global hold: nothing starts until the resume, and the utterance
  /// playing when it began keeps its place.
  final bool hold;
  final DateTime? holdAt;

  /// The thread whose speech holds the others, and its title.
  final String? solo;
  final String? soloTitle;

  /// The entry holding the floor: playing, or held by [hold].
  final WorkspaceSpeechEntry? speaking;

  /// Every waiting entry, in the order it will be spoken.  An entry under a
  /// solo of another thread stays here, marked [WorkspaceSpeechEntry.held].
  final List<WorkspaceSpeechEntry> waiting;

  /// The thread holding the floor, when one does.
  final String? active;
  final int count;
  final List<WorkspaceSpeechEntry> recent;

  bool get hasSpeech =>
      speaking != null || waiting.isNotEmpty || solo != null || hold;

  /// The waiting entries a solo of another thread keeps from starting.
  List<WorkspaceSpeechEntry> get heldEntries => [
    for (final entry in waiting)
      if (entry.held != null) entry,
  ];

  /// The one-line state, a noun phrase: `2 waiting`, `Speaking`, `Solo`,
  /// `Held`, `Idle` or `No speech`.
  String get stateLabel {
    if (hold) return 'Held';
    if (solo != null) return 'Solo';
    if (count > 0) return '$count waiting';
    if (speaking != null) return 'Speaking';
    if (recent.isNotEmpty) return 'Idle';
    return 'No speech';
  }

  /// Take [floor] as this client's copy when it is not older than the one in
  /// hand.  A stale answer changes nothing, so an out-of-order reply never
  /// rolls the panel back to a queue that has moved.
  static WorkspaceSpeech? newer(WorkspaceSpeech? known, WorkspaceSpeech? floor) {
    if (floor == null) return known;
    if (known == null) return floor;
    return floor.revision >= known.revision ? floor : known;
  }
}

/// One utterance on the floor: what a thread has to say, and what became of
/// it.  [state] is `queued`, `speaking`, `held`, or a finished `finished`,
/// `failed` or `cancelled`.
class WorkspaceSpeechEntry {
  const WorkspaceSpeechEntry({
    required this.id,
    this.workspace = '',
    this.thread = '',
    this.threadTitle = '',
    this.session,
    this.node,
    this.source = 'reply',
    this.text = '',
    this.preview = '',
    this.state = 'queued',
    this.at,
    this.why,
    this.outcome,
    this.held,
    this.played,
  });

  factory WorkspaceSpeechEntry.fromWire(JsonMap wire) {
    return WorkspaceSpeechEntry(
      id: asStringOr(wire['id'], ''),
      workspace: asStringOr(wire['workspace'], ''),
      thread: asStringOr(wire['thread'], ''),
      threadTitle: asStringOr(wire['thread-title'] ?? wire['threadTitle'], ''),
      session: asString(wire['session']),
      node: asString(wire['node']),
      source: asStringOr(wire['source'], 'reply'),
      text: asStringOr(wire['text'], ''),
      preview: asStringOr(wire['preview'], ''),
      state: asStringOr(wire['state'], 'queued'),
      at: parseTime(wire['at']),
      why: asString(wire['why']),
      outcome: asString(wire['outcome']),
      held: asString(wire['held']),
      played: asDouble(wire['played']),
    );
  }

  final String id;
  final String workspace;
  final String thread;
  final String threadTitle;
  final String? session;

  /// The assistant node the words came from, which makes the offer idempotent.
  final String? node;
  final String source;
  final String text;
  final String preview;
  final String state;
  final DateTime? at;

  /// Why a finished entry ended as it did: `Solo`, `Thread removed`,
  /// `Queue full`, `Playback failed`.  Data from the harness, not copy.
  final String? why;
  final String? outcome;

  /// Why a waiting entry does not start now: `Solo`.
  final String? held;

  /// The seconds of the utterance already played, when it was held.
  final double? played;

  bool get speaking => state == 'speaking';
  bool get heldNow => state == 'held';

  /// The thread and its first words, as one line.
  String get label =>
      preview.isEmpty ? threadTitle : '$threadTitle · $preview';

  /// What a finished entry is called: `Spoken`, `Failed` or `Cancelled`.
  String get outcomeWord => switch (state) {
    'finished' => 'Spoken',
    'failed' => 'Failed',
    _ => 'Cancelled',
  };
}
