import '../acp/acp_message.dart';
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

  bool get isUser => kind == 'message' && role == 'user';
  bool get isAgent => kind == 'message' && role != 'user';
  bool get isDivider => kind == 'divider';
  bool get isBrief => kind == 'brief';

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
    );
  }
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
