import '../acp/acp_message.dart';
import 'activity.dart';
import 'session.dart';

/// A persistent workspace: one chat, its threads and its memory.
class WorkspaceSummary {
  const WorkspaceSummary({
    required this.id,
    required this.name,
    this.root = '',
    this.project = '',
    this.lastThread,
    this.threads = const [],
    this.model,
    this.thinking,
    this.permissionMode,
    this.nonInteractive = false,
    this.createdAt,
    this.updatedAt,
  });

  factory WorkspaceSummary.fromWire(JsonMap wire) {
    return WorkspaceSummary(
      id: asStringOr(wire['id'], ''),
      name: asStringOr(wire['name'], 'Workspace'),
      root: asStringOr(wire['root'], ''),
      project: asStringOr(wire['project'], ''),
      lastThread: asString(wire['last-thread'] ?? wire['lastThread']),
      threads: [
        for (final item in asMapList(wire['threads']))
          WorkspaceThread.fromWire(item),
      ],
      model: asString(wire['model']),
      thinking: asString(wire['thinking']),
      permissionMode: asString(
        wire['permission-mode'] ?? wire['permissionMode'],
      ),
      nonInteractive: asBool(wire['non-interactive'] ?? wire['nonInteractive']),
      createdAt: parseTime(wire['created']),
      updatedAt: parseTime(wire['updated']),
    );
  }

  final String id;
  final String name;
  final String root;
  final String project;
  final String? lastThread;
  final List<WorkspaceThread> threads;

  /// The defaults a new episode starts with: the model, thinking level,
  /// permission mode and interactive switch the harness resolved for the
  /// workspace, so its first thread can already name them.
  final String? model;
  final String? thinking;
  final String? permissionMode;
  final bool nonInteractive;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  WorkspaceThread? get active {
    for (final thread in threads) {
      if (thread.id == lastThread) return thread;
    }
    return threads.isEmpty ? null : threads.first;
  }

  WorkspaceSummary copyWith({
    List<WorkspaceThread>? threads,
    String? lastThread,
  }) {
    return WorkspaceSummary(
      id: id,
      name: name,
      root: root,
      project: project,
      lastThread: lastThread ?? this.lastThread,
      threads: threads ?? this.threads,
      model: model,
      thinking: thinking,
      permissionMode: permissionMode,
      nonInteractive: nonInteractive,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }
}

/// One request a thread's live episode waits on: a permission prompt or a
/// question.  The workspace shows it in the same card a conversation does.
class WorkspacePendingRequest {
  const WorkspacePendingRequest({
    required this.id,
    required this.kind,
    this.title = '',
  });

  factory WorkspacePendingRequest.fromWire(JsonMap wire) {
    final payload = asMap(wire['payload']);
    return WorkspacePendingRequest(
      id: asStringOr(wire['id'], ''),
      kind: asStringOr(wire['kind'], ''),
      title: asStringOr(
        payload['title'] ?? payload['tool'] ?? payload['question'],
        '',
      ),
    );
  }

  final String id;
  final String kind;
  final String title;

  bool get isQuestion => kind == 'question';
}

/// One topic in a workspace.  Its [state] is `live`, `waiting`, `parked` or
/// `done`, and [episodeStatus] says the finer thing its live episode does:
/// `running`, `blocked`, `idle`, `failed`, `stopped` or `parked`.  [live]
/// names the episode session when one is open, and [pending] is what it
/// waits on.
class WorkspaceThread {
  const WorkspaceThread({
    required this.id,
    required this.title,
    this.state = 'parked',
    this.episodeStatus = '',
    this.live,
    this.episodes = const [],
    this.pending = const [],
    this.pinned = false,
    this.summary = '',
    this.project = '',
    this.tags = const [],
    this.lastAt,
    this.model,
    this.thinking,
    this.permissionMode,
    this.nonInteractive = false,
    this.activity,
  });

  factory WorkspaceThread.fromWire(JsonMap wire) {
    final live = asString(wire['live']);
    final title = asStringOr(wire['title'], 'Thread');
    final explicit = [
      for (final tag in asList(wire['tags']))
        if (asString(tag) != null) asString(tag)!,
    ];
    return WorkspaceThread(
      id: asStringOr(wire['id'], ''),
      title: title,
      state: asStringOr(wire['state'], 'parked'),
      episodeStatus: asStringOr(
        wire['episode-status'] ?? wire['episodeStatus'],
        '',
      ),
      live: live == null || live.isEmpty ? null : live,
      episodes: [
        for (final episode in asList(wire['episodes'])) asStringOr(episode, ''),
      ],
      pending: [
        for (final item in asMapList(wire['pending']))
          WorkspacePendingRequest.fromWire(item),
      ],
      pinned: asBool(wire['pinned']),
      summary: asStringOr(wire['summary'], ''),
      project: asStringOr(wire['project'], ''),
      tags: explicit.isEmpty ? conceptTags(title) : explicit,
      lastAt: parseTime(wire['last-at'] ?? wire['lastAt']),
      model: asString(wire['model']),
      thinking: asString(wire['thinking']),
      permissionMode: asString(
        wire['permission-mode'] ?? wire['permissionMode'],
      ),
      nonInteractive: asBool(wire['non-interactive'] ?? wire['nonInteractive']),
      activity: asMap(wire['activity']).isEmpty
          ? null
          : TurnActivity.fromWire(asMap(wire['activity'])),
    );
  }

  final String id;
  final String title;
  final String state;
  final String episodeStatus;
  final String? live;
  final List<String> episodes;
  final List<WorkspacePendingRequest> pending;
  final bool pinned;
  final String summary;
  final String project;

  /// The concepts this thread is about.  The harness's workspace record will
  /// carry them when the Logseq tag taxonomy lands; until then the web is
  /// drawn from the thread's title, which is the prototype's hypothesis: a
  /// small set of high-level concepts, not every page.
  final List<String> tags;
  final DateTime? lastAt;

  /// What its live episode runs with, or the workspace's defaults when it
  /// has none: the harness resolves both (`workspace/get`'s `:model`,
  /// `:thinking`, `:permission-mode` and `:non-interactive`).
  final String? model;
  final String? thinking;
  final String? permissionMode;
  final bool nonInteractive;

  /// What its running turn does now, as `agent/activity` says it: waiting
  /// for the model, thinking, writing, or running a tool.  Null when no
  /// turn runs, or from a harness that does not report activity.
  final TurnActivity? activity;

  bool get liveNow => state == 'live' || state == 'waiting';

  /// The status the thread shows, from the finer [episodeStatus] when the
  /// harness sends it and the coarser [state] otherwise.
  String get statusKey {
    if (episodeStatus.isNotEmpty) return episodeStatus;
    return switch (state) {
      'waiting' => 'blocked',
      'live' => 'live',
      'done' => 'done',
      _ => 'parked',
    };
  }

  /// The status in one word, for a row: `Running`, `Blocked`, `Idle`,
  /// `Failed`, `Stopped`, `Inactive`, `Live`, `Done` or `Parked`.
  String get statusWord => switch (statusKey) {
    'running' => 'Running',
    'blocked' => 'Blocked',
    'idle' => 'Idle',
    'failed' => 'Failed',
    'stopped' => 'Stopped',
    'inactive' => 'Inactive',
    'live' => 'Live',
    'done' => 'Done',
    _ => 'Parked',
  };

  /// The status in words, with what a blocked episode waits on when it
  /// knows: `Running`, `Blocked · Permission`, `Blocked · Question`,
  /// `Idle`, `Failed`, `Stopped`, `Inactive`, `Live` or `Parked`.
  String get statusLabel {
    final key = statusKey;
    if (key == 'blocked') {
      final question = pending.any((item) => item.isQuestion);
      return question ? 'Blocked · Question' : 'Blocked · Permission';
    }
    return switch (key) {
      'running' => 'Running',
      'idle' => 'Idle',
      'failed' => 'Failed',
      'stopped' => 'Stopped',
      'inactive' => 'Inactive',
      'live' => 'Live',
      'done' => 'Done',
      _ => 'Parked',
    };
  }

  WorkspaceThread copyWith({
    List<String>? tags,
    String? state,
    String? episodeStatus,
    String? live,
    List<WorkspacePendingRequest>? pending,
    String? model,
    String? thinking,
    String? permissionMode,
    bool? nonInteractive,
    TurnActivity? activity,
  }) {
    return WorkspaceThread(
      id: id,
      title: title,
      state: state ?? this.state,
      episodeStatus: episodeStatus ?? this.episodeStatus,
      live: live ?? this.live,
      episodes: episodes,
      pending: pending ?? this.pending,
      pinned: pinned,
      summary: summary,
      project: project,
      tags: tags ?? this.tags,
      lastAt: lastAt,
      model: model ?? this.model,
      thinking: thinking ?? this.thinking,
      permissionMode: permissionMode ?? this.permissionMode,
      nonInteractive: nonInteractive ?? this.nonInteractive,
      activity: activity ?? this.activity,
    );
  }
}

/// One entry of the workspace timeline.
class WorkspaceEntry {
  const WorkspaceEntry({
    required this.kind,
    this.thread = '',
    this.episode = '',
    this.role = '',
    this.text = '',
    this.reason = '',
    this.title = '',
    this.tokens = 0,
    this.node = '',
    this.streaming = false,
    this.at,
    this.origin = '',
    this.handling = '',
    this.profile = '',
    this.reassignedTo = '',
    this.reassignedBy = '',
    this.delivery = '',
  });

  factory WorkspaceEntry.fromWire(JsonMap wire) {
    return WorkspaceEntry(
      kind: asStringOr(wire['kind'], 'message'),
      thread: asStringOr(wire['thread'], ''),
      episode: asStringOr(wire['episode'], ''),
      role: asStringOr(wire['role'], ''),
      text: asStringOr(wire['text'], ''),
      reason: asStringOr(wire['reason'] ?? wire['why'], ''),
      title: asStringOr(wire['title'], ''),
      tokens: asInt(wire['tokens']) ?? 0,
      node: asStringOr(wire['node'] ?? wire['nodeId'], ''),
      streaming: asBool(wire['streaming']),
      at: parseTime(wire['at']),
      origin: asStringOr(wire['origin'], ''),
      handling: asStringOr(wire['handling'], ''),
      profile: asStringOr(wire['profile'], ''),
      reassignedTo: _movedField(wire, 'to'),
      reassignedBy: _movedField(wire, 'by'),
      delivery: asStringOr(wire['delivery'], ''),
    );
  }

  final String kind;
  final String thread;
  final String episode;
  final String role;
  final String text;
  final String reason;
  final String title;
  final int tokens;

  /// The session node this message came from.  An assistant reply is one
  /// node: its text grows as chunks arrive, and the node's final content is
  /// the whole message.
  final String node;

  /// Whether the harness is still writing this message.
  final bool streaming;

  final DateTime? at;

  /// The thread the message was addressed to, and the thread whose
  /// episode answers it.  They differ when the router put the words in
  /// another thread, or after a reassignment; both are read from the
  /// harness, never inferred from the text.  Empty when the harness kept
  /// none, which is how an older entry reads.
  final String origin;
  final String handling;

  /// The surface the words arrived through, such as `text' or `voice'.
  final String profile;

  /// Where a reassignment sent the message, and who moved it.  Empty on
  /// a message that never moved.
  final String reassignedTo;
  final String reassignedBy;

  /// What became of the message this entry reports: `queued',
  /// `delivered' or `uncertain'.  Empty on a message.
  final String delivery;

  bool get isUser => kind == 'message' && role == 'user';
  bool get isAgent => kind == 'message' && role != 'user';
  bool get isDivider => kind == 'divider';
  bool get isBrief => kind == 'brief';
  bool get isReassignment => kind == 'reassignment';

  WorkspaceEntry copyWith({
    String? thread,
    String? episode,
    String? role,
    String? text,
    String? node,
    bool? streaming,
    DateTime? at,
  }) {
    return WorkspaceEntry(
      kind: kind,
      thread: thread ?? this.thread,
      episode: episode ?? this.episode,
      role: role ?? this.role,
      text: text ?? this.text,
      reason: reason,
      title: title,
      tokens: tokens,
      node: node ?? this.node,
      streaming: streaming ?? this.streaming,
      at: at ?? this.at,
      origin: origin,
      handling: handling,
      profile: profile,
      reassignedTo: reassignedTo,
      reassignedBy: reassignedBy,
      delivery: delivery,
    );
  }

  /// The words naming where this message came from, or null when that
  /// is plain: the thread that handles it, through the workspace's own
  /// profile.  `titleOf' names a thread id, so the label reads as the
  /// thread's title and not as its id.
  String? originLabel(
    String Function(String thread) titleOf, {
    String defaultProfile = 'text',
  }) {
    final from = origin.isEmpty ? thread : origin;
    final in_ = handling.isEmpty ? thread : handling;
    final surface = profile.isEmpty ? defaultProfile : profile;
    final title = titleOf(from);
    if (from == in_ && surface == defaultProfile) return null;
    if (title.isNotEmpty && from != in_) {
      return surface == defaultProfile
          ? 'From $title'
          : 'From $title · $surface';
    }
    if (surface != defaultProfile) return 'From $surface';
    return null;
  }

  /// The words naming where a reassignment sent this message, or null.
  String? reassignedLabel(String Function(String thread) titleOf) {
    if (reassignedTo.isEmpty) return null;
    final title = titleOf(reassignedTo);
    final name = title.isEmpty ? reassignedTo : title;
    return reassignedBy.isEmpty
        ? 'Reassigned to $name'
        : 'Reassigned to $name · $reassignedBy';
  }
}

/// A reassignment entry carries where it went and what became of it at
/// the top level, while a message carries it inside `reassigned'.
String _movedField(JsonMap wire, String key) {
  final moved = wire['reassigned'];
  if (moved is Map) {
    final value = moved[key];
    if (value is String) return value;
  }
  return asStringOr(wire[key], '');
}

/// What the workspace's local memory says about itself.
class WorkspaceMemoryStatus {
  const WorkspaceMemoryStatus({
    this.notes = 0,
    this.last,
    this.fullText = false,
  });

  factory WorkspaceMemoryStatus.fromWire(JsonMap wire) => WorkspaceMemoryStatus(
    notes: asInt(wire['notes']) ?? 0,
    last: parseTime(wire['last']),
    fullText: asBool(wire['fts']),
  );

  final int notes;
  final DateTime? last;
  final bool fullText;
}

/// The computer panel's state: the real box the harness runs.
///
/// A box that is off has no [socket] and says why in [reason]; there is
/// no drawn preview and no stand-in screen.  When [live] is true the app
/// watches [socket] with the RFB client it already has.
class WorkspaceComputerStatus {
  const WorkspaceComputerStatus({
    this.available = false,
    this.running = false,
    this.state = 'stopped',
    this.control = 'agent',
    this.backend = '',
    this.socket,
    this.url,
    this.reason,
    this.reasonCode,
    this.width = 0,
    this.height = 0,
    this.isolation = '',
    this.display = '',
    this.home = '',
    this.profile = '',
    this.disk = 0,
    this.missing = const [],
  });

  factory WorkspaceComputerStatus.fromWire(JsonMap wire) {
    final reasonWire = wire['reason'];
    String? reason;
    String? reasonCode;
    if (reasonWire is Map) {
      reason = asString(reasonWire['text']);
      reasonCode = asString(reasonWire['code']);
    } else {
      reason = asString(reasonWire);
    }
    return WorkspaceComputerStatus(
      available: asBool(wire['available']),
      running: asBool(wire['running']),
      state: asStringOr(
        wire['state'],
        asBool(wire['running']) ? 'running' : 'stopped',
      ),
      control: asStringOr(wire['control'], 'agent'),
      backend: asStringOr(wire['backend'], ''),
      socket: asString(wire['socket']),
      url: asString(wire['url']),
      reason: reason,
      reasonCode: reasonCode,
      width: asInt(wire['width']) ?? 0,
      height: asInt(wire['height']) ?? 0,
      isolation: asStringOr(wire['isolation'], ''),
      display: asStringOr(wire['display'], ''),
      home: asStringOr(wire['home'], ''),
      profile: asStringOr(wire['profile'], ''),
      disk: asInt(wire['disk']) ?? 0,
      missing: [
        for (final tool in asList(wire['missing']))
          if ((asString(tool) ?? '').isNotEmpty) asString(tool)!,
      ],
    );
  }

  final bool available;
  final bool running;

  /// `running`, `starting`, `stopped` or `failed`.
  final String state;
  final String control;
  final String backend;

  /// The WebSocket an RFB client speaks to, `ws://HOST:PORT/websockify`.
  final String? socket;

  /// The noVNC page beside it; never opened as the app's screen.
  final String? url;

  /// Why the box cannot be watched, from the harness.
  final String? reason;
  final String? reasonCode;
  final int width;
  final int height;

  /// `local display and process`, the boundary the backend keeps.
  final String isolation;

  /// The X display the box's desktop runs on, such as `:99`.
  final String display;

  /// The box's home directory and its browser profile directory.
  final String home;
  final String profile;

  /// How many bytes the box's state directory takes; 0 when unknown.
  final int disk;

  /// The tools whose absence keeps the box from running.
  final List<String> missing;

  bool get userControl => control == 'user';
  bool get starting => state == 'starting';
  bool get live => available && running && (socket?.isNotEmpty ?? false);
  bool get off => !running;

  WorkspaceComputerStatus copyWith({
    String? control,
    String? state,
    bool? available,
    bool? running,
  }) {
    return WorkspaceComputerStatus(
      available: available ?? this.available,
      running: running ?? this.running,
      state: state ?? this.state,
      control: control ?? this.control,
      backend: backend,
      socket: socket,
      url: url,
      reason: reason,
      reasonCode: reasonCode,
      width: width,
      height: height,
      isolation: isolation,
      display: display,
      home: home,
      profile: profile,
      disk: disk,
      missing: missing,
    );
  }
}

/// Stopwords for [conceptTags]: the little words of a title that say nothing
/// about what it is about.
const _conceptStopwords = {
  'the',
  'and',
  'for',
  'with',
  'from',
  'that',
  'this',
  'into',
  'about',
  'under',
  'over',
  'after',
  'before',
  'new',
  'old',
  'one',
  'two',
  'how',
  'what',
  'when',
  'why',
  'where',
  'who',
  'are',
  'was',
  'were',
  'will',
  'would',
  'should',
  'can',
  'could',
  'not',
  'its',
  'our',
  'your',
  'their',
  'has',
  'have',
  'had',
  'get',
  'got',
  'make',
  'made',
  'use',
  'using',
  'more',
  'most',
  'less',
  'than',
  'then',
  'also',
  'just',
  'like',
};

/// Return the high-level concepts a title names, at most two.
///
/// This is the prototype's stand-in for the Logseq tags the dreaming process
/// will maintain: the useful level is a few concepts a person would
/// recognise, not every word or every block.
List<String> conceptTags(String title) {
  final words = <String>[];
  for (final raw in title.split(RegExp(r'[^A-Za-z0-9]+'))) {
    final word = raw.trim();
    if (word.length < 4) continue;
    final lower = word.toLowerCase();
    if (_conceptStopwords.contains(lower)) continue;
    if (!words.contains(lower)) words.add(lower);
    if (words.length == 2) break;
  }
  return [for (final word in words) word[0].toUpperCase() + word.substring(1)];
}

/// One message waiting in a session's own queue, as `workspace/inbox'
/// reads it.  The inbox is read where the messages stand, so nothing is
/// copied into a second queue and a message answered elsewhere is seen
/// here at once.
class WorkspaceInboxItem {
  const WorkspaceInboxItem({
    this.session = '',
    this.workspace = '',
    this.workspaceName = '',
    this.thread = '',
    this.title = 'Thread',
    this.text = '',
    this.state = 'queued',
    this.why = '',
    this.at,
  });

  factory WorkspaceInboxItem.fromWire(JsonMap wire) => WorkspaceInboxItem(
    session: asStringOr(wire['session'], ''),
    workspace: asStringOr(wire['workspace'], ''),
    workspaceName: asStringOr(wire['workspace-name'], ''),
    thread: asStringOr(wire['thread'], ''),
    title: asStringOr(wire['title'], 'Thread'),
    text: asStringOr(wire['text'], ''),
    state: asStringOr(wire['state'], 'queued'),
    why: asStringOr(wire['why'], ''),
    at: parseTime(wire['at']),
  );

  final String session;

  /// The workspace the message waits in, and its name: a row of the
  /// `all' scope says which workspace it belongs to as well as which
  /// thread, so a person reading across workspaces is not guessing.
  final String workspace;
  final String workspaceName;

  final String thread;
  final String title;
  final String text;

  /// `queued' in the session's queue, `waiting' for a message a running
  /// turn has not taken, or `unavailable' when the session cannot be read.
  final String state;

  /// Why an item is unavailable, or empty.
  final String why;

  final DateTime? at;

  bool get isUnavailable => state == 'unavailable';

  /// The word the row shows for this item's state.
  String get stateLabel => switch (state) {
    'queued' => 'Queued',
    'waiting' => 'Waiting',
    'unavailable' => 'Unavailable',
    _ => 'Unavailable',
  };
}

/// One thread's share of an inbox.
class WorkspaceInboxGroup {
  const WorkspaceInboxGroup({
    this.workspace = '',
    this.name = '',
    this.thread = '',
    this.title = 'Thread',
    this.items = const [],
    this.queued = 0,
    this.waiting = 0,
    this.unavailable = 0,
  });

  factory WorkspaceInboxGroup.fromWire(JsonMap wire) {
    final counts = asMap(wire['counts']);
    return WorkspaceInboxGroup(
      workspace: asStringOr(wire['workspace'], ''),
      name: asStringOr(wire['name'], ''),
      thread: asStringOr(wire['thread'], ''),
      title: asStringOr(wire['title'], 'Thread'),
      items: [
        for (final item in asMapList(wire['items']))
          WorkspaceInboxItem.fromWire(item),
      ],
      queued: asInt(counts['queued']) ?? 0,
      waiting: asInt(counts['waiting']) ?? 0,
      unavailable: asInt(counts['unavailable']) ?? 0,
    );
  }

  final String workspace;
  final String name;
  final String thread;
  final String title;
  final List<WorkspaceInboxItem> items;
  final int queued;
  final int waiting;
  final int unavailable;
}

/// What waits to be sent in a workspace: every thread, one thread, one
/// session, or every workspace's threads.
class WorkspaceInbox {
  const WorkspaceInbox({
    this.workspace = '',
    this.name = '',
    this.scope = 'workspace',
    this.items = const [],
    this.groups = const [],
    this.queued = 0,
    this.waiting = 0,
    this.unavailable = 0,
    this.revision = 0,
  });

  factory WorkspaceInbox.fromWire(JsonMap wire) {
    final counts = asMap(wire['counts']);
    return WorkspaceInbox(
      workspace: asStringOr(wire['workspace'], ''),
      name: asStringOr(wire['name'], ''),
      scope: asStringOr(wire['scope'], 'workspace'),
      items: [
        for (final item in asMapList(wire['items']))
          WorkspaceInboxItem.fromWire(item),
      ],
      groups: [
        for (final group in asMapList(wire['threads']))
          WorkspaceInboxGroup.fromWire(group),
      ],
      queued: asInt(counts['queued']) ?? 0,
      waiting: asInt(counts['waiting']) ?? 0,
      unavailable: asInt(counts['unavailable']) ?? 0,
      revision: asInt(wire['revision']) ?? 0,
    );
  }

  final String workspace;

  /// The workspace's name, so the sheet says which workspace's inbox it
  /// shows rather than naming an id.
  final String name;

  final String scope;
  final List<WorkspaceInboxItem> items;

  /// Each thread with items, in the order the harness names them.
  final List<WorkspaceInboxGroup> groups;

  final int queued;
  final int waiting;
  final int unavailable;
  final int revision;

  bool get isEmpty => items.isEmpty;

  /// The words naming how many items are in each state, or empty when
  /// nothing waits.
  String get countsLabel {
    final parts = <String>[
      if (queued > 0) '$queued queued',
      if (waiting > 0) '$waiting waiting',
      if (unavailable > 0) '$unavailable unavailable',
    ];
    return parts.join(' · ');
  }
}

/// What a reassignment did, as `workspace/reassign' answers it.
class WorkspaceReassignment {
  const WorkspaceReassignment({
    this.status = 'stale',
    this.thread = '',
    this.session,
    this.node,
    this.text = '',
    this.delivery = 'uncertain',
    this.why = '',
    this.repeated = false,
  });

  factory WorkspaceReassignment.fromWire(JsonMap wire) =>
      WorkspaceReassignment(
        status: asStringOr(wire['status'], 'stale'),
        thread: asStringOr(wire['thread'], ''),
        session: asString(wire['session']),
        node: asString(wire['node']),
        text: asStringOr(wire['text'], ''),
        delivery: asStringOr(wire['delivery'], 'uncertain'),
        why: asStringOr(wire['why'], ''),
        repeated: asStringOr(wire['status'], '') == 'repeated',
      );

  /// `queued', `waiting', `forwarded', `repeated', `stale' or
  /// `unreachable'.
  final String status;

  final String thread;
  final String? session;
  final String? node;
  final String text;

  /// What became of the copy in the thread the message was written in:
  /// `queued', `delivered' or `uncertain'.
  final String delivery;

  final String why;
  final bool repeated;

  /// The words naming what happened, for [titleOf] naming the target
  /// thread.  Each outcome reads as its own words, so a message moved
  /// before anything read it is never confused with one the model had.
  String summary(String Function(String thread) titleOf) {
    final name = titleOf(thread).isEmpty ? thread : titleOf(thread);
    return switch (status) {
      'queued' => 'Queued · $name',
      'waiting' => 'Waiting · $name',
      'forwarded' => 'Forwarded · $name · $delivery',
      'repeated' => 'Repeated · $name',
      'stale' => 'Stale · ${why.isEmpty ? name : why}',
      'unreachable' => 'Unreachable · ${why.isEmpty ? name : why}',
      _ => '${status.isEmpty ? 'Reassign' : status} · $name',
    };
  }
}
