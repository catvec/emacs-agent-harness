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

  WorkspaceSummary copyWith({List<WorkspaceThread>? threads, String? lastThread}) {
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

/// One topic in a workspace.  Its [state] is `live`, `waiting`, `parked` or
/// `done`; [live] names the episode session when one is open.
class WorkspaceThread {
  const WorkspaceThread({
    required this.id,
    required this.title,
    this.state = 'parked',
    this.live,
    this.episodes = const [],
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
      live: live == null || live.isEmpty ? null : live,
      episodes: [
        for (final episode in asList(wire['episodes'])) asStringOr(episode, ''),
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
  final String? live;
  final List<String> episodes;
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

  WorkspaceThread copyWith({List<String>? tags, String? state, String? live}) {
    return WorkspaceThread(
      id: id,
      title: title,
      state: state ?? this.state,
      live: live ?? this.live,
      episodes: episodes,
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
  const WorkspaceMemoryStatus({this.notes = 0, this.last, this.fullText = false});

  factory WorkspaceMemoryStatus.fromWire(JsonMap wire) => WorkspaceMemoryStatus(
    notes: asInt(wire['notes']) ?? 0,
    last: parseTime(wire['last']),
    fullText: asBool(wire['fts']),
  );

  final int notes;
  final DateTime? last;
  final bool fullText;
}

/// The computer panel's state.  The sandboxed box is staged; until its
/// methods are there the panel is a preview, and says so.
class WorkspaceComputerStatus {
  const WorkspaceComputerStatus({
    this.available = false,
    this.control = 'agent',
    this.backend = '',
    this.url,
    this.error,
    this.preview = true,
  });

  factory WorkspaceComputerStatus.fromWire(JsonMap wire) {
    return WorkspaceComputerStatus(
      available: true,
      control: asStringOr(wire['control'], 'agent'),
      backend: asStringOr(wire['backend'], ''),
      url: asString(wire['url']),
      preview: false,
    );
  }

  final bool available;
  final String control;
  final String backend;
  final String? url;
  final String? error;

  /// True when the harness has no box yet: the panel is a drawn preview.
  final bool preview;

  bool get userControl => control == 'user';

  WorkspaceComputerStatus copyWith({String? control, bool? available}) {
    return WorkspaceComputerStatus(
      available: available ?? this.available,
      control: control ?? this.control,
      backend: backend,
      url: url,
      error: error,
      preview: preview,
    );
  }
}

/// Stopwords for [conceptTags]: the little words of a title that say nothing
/// about what it is about.
const _conceptStopwords = {
  'the', 'and', 'for', 'with', 'from', 'that', 'this', 'into', 'about',
  'under', 'over', 'after', 'before', 'new', 'old', 'one', 'two', 'how',
  'what', 'when', 'why', 'where', 'who', 'are', 'was', 'were', 'will',
  'would', 'should', 'can', 'could', 'not', 'its', 'our', 'your', 'their',
  'has', 'have', 'had', 'get', 'got', 'make', 'made', 'use', 'using',
  'more', 'most', 'less', 'than', 'then', 'also', 'just', 'like',
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
  return [
    for (final word in words) word[0].toUpperCase() + word.substring(1),
  ];
}
