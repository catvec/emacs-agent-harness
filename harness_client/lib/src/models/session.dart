import '../acp/acp_message.dart';
import 'project_roots.dart';

/// ACP's session/list entry, merged with the harness's fuller session plist
/// when its extensions are present.
class SessionSummary {
  const SessionSummary({
    required this.id,
    this.title,
    this.cwd,
    this.project,
    this.model,
    this.kind,
    this.status,
    this.parentId,
    this.updatedAt,
    this.createdAt,
    this.lastMessageAt,
    this.usage,
    this.contextWindow,
    this.permissionMode,
    this.todos = const [],
    this.pending = const [],
    this.queue = const [],
    this.worktree,
    this.head,
    this.plan,
    this.virtual = false,
    this.extra = const {},
  });

  factory SessionSummary.fromAcpInfo(JsonMap info) {
    final meta = asMap(info['_meta']);
    final id = asStringOr(info['sessionId'], asStringOr(info['id'], ''));
    return SessionSummary(
      id: id,
      title: _nonBlank(asString(info['title'])),
      cwd: asString(info['cwd']),
      project: asString(meta['project']),
      model: asString(meta['model']),
      kind: asString(meta['kind']),
      status: asString(meta['status']) ?? 'idle',
      parentId: asString(meta['parentId']),
      updatedAt: parseTime(info['updatedAt'] ?? info['updated']),
      createdAt: parseTime(info['created']),
      lastMessageAt: parseTime(info['lastMessage']),
      usage: Usage.fromWire(info['usage']),
      contextWindow: asInt(info['contextWindow']),
      permissionMode: asString(info['permissionMode']),
      todos: TodoItem.listFrom(info['todos']),
      pending: PendingRequest.listFrom(info['pending']),
      queue: QueueItem.listFrom(info['queue']),
      worktree: asString(info['worktree']),
      head: asString(info['head']),
      plan: asString(info['plan']),
      virtual:
          id.startsWith('harness:') ||
          asBool(asMap(info['_harness'])['virtual']),
      extra: info,
    );
  }

  /// A session plist from `_harness/session/list`, `session/get`, or a
  /// `_harness/session` update.
  factory SessionSummary.fromWire(JsonMap wire) {
    final id = asStringOr(wire['id'], asStringOr(wire['sessionId'], ''));
    return SessionSummary(
      id: id,
      title: _nonBlank(asString(wire['name'] ?? wire['title'])),
      cwd: asString(wire['cwd']),
      project: asString(wire['project']),
      model: asString(wire['model']),
      kind: asString(wire['kind']),
      status: asString(wire['status']) ?? 'inactive',
      parentId: asString(wire['parentId'] ?? wire['parent-id']),
      updatedAt: parseTime(wire['updated'] ?? wire['updatedAt']),
      createdAt: parseTime(wire['created']),
      lastMessageAt: parseTime(wire['lastMessage'] ?? wire['last-message']),
      usage: Usage.fromWire(wire['usage']),
      contextWindow: asInt(wire['contextWindow'] ?? wire['context-window']),
      permissionMode: asString(
        wire['permissionMode'] ?? wire['permission-mode'],
      ),
      todos: TodoItem.listFrom(wire['todos']),
      pending: PendingRequest.listFrom(wire['pending']),
      queue: QueueItem.listFrom(wire['queue']),
      worktree: asString(wire['worktree']),
      head: asString(wire['head']),
      plan: asString(wire['plan']),
      virtual: id.startsWith('harness:'),
      extra: wire,
    );
  }

  final String id;
  final String? title;
  final String? cwd;
  final String? project;
  final String? model;
  final String? kind;
  final String? status;
  final String? parentId;
  final DateTime? updatedAt;
  final DateTime? createdAt;
  final DateTime? lastMessageAt;
  final Usage? usage;
  final int? contextWindow;
  final String? permissionMode;
  final List<TodoItem> todos;
  final List<PendingRequest> pending;
  final List<QueueItem> queue;
  final String? worktree;
  final String? head;
  final String? plan;
  final bool virtual;
  final JsonMap extra;

  String get displayTitle {
    final name = title;
    if (name != null && name.trim().isNotEmpty) return name.trim();
    return 'Untitled session';
  }

  /// The name of the project the session works for: a git worktree of the
  /// harness is named for its project.
  String get projectName {
    final source = worktreeOwner(project ?? cwd) ?? project ?? cwd;
    if (source == null) return '';
    final parts = source.split('/').where((part) => part.isNotEmpty).toList();
    return parts.isEmpty ? source : parts.last;
  }

  bool get isActive => status == 'running' || status == 'blocked';
  bool get isBlocked => status == 'blocked';
  bool get isRunning => status == 'running';
  bool get isInactive => status == 'inactive';

  DateTime? get touchedAt => lastMessageAt ?? updatedAt;

  SessionSummary merge(SessionSummary newer) {
    if (newer.id != id) return this;
    return SessionSummary(
      id: id,
      title: newer.title ?? title,
      cwd: newer.cwd ?? cwd,
      project: newer.project ?? project,
      model: newer.model ?? model,
      kind: newer.kind ?? kind,
      status: newer.status ?? status,
      parentId: newer.parentId ?? parentId,
      updatedAt: newer.updatedAt ?? updatedAt,
      createdAt: newer.createdAt ?? createdAt,
      lastMessageAt: newer.lastMessageAt ?? lastMessageAt,
      usage: newer.usage ?? usage,
      contextWindow: newer.contextWindow ?? contextWindow,
      permissionMode: newer.permissionMode ?? permissionMode,
      todos: newer.todos.isNotEmpty ? newer.todos : todos,
      pending: newer.pending.isNotEmpty ? newer.pending : pending,
      queue: newer.queue.isNotEmpty ? newer.queue : queue,
      worktree: newer.worktree ?? worktree,
      head: newer.head ?? head,
      plan: newer.plan ?? plan,
      virtual: virtual || newer.virtual,
      extra: {...extra, ...newer.extra},
    );
  }
}

String? _nonBlank(String? value) =>
    value == null || value.trim().isEmpty ? null : value.trim();

DateTime? parseTime(Object? value) {
  if (value == null) return null;
  if (value is num) {
    final seconds = value > 100000000000 ? value / 1000 : value;
    return DateTime.fromMillisecondsSinceEpoch((seconds * 1000).round());
  }
  if (value is String) {
    final parsed = DateTime.tryParse(value);
    if (parsed != null) return parsed.toLocal();
    final number = double.tryParse(value);
    if (number != null) return parseTime(number);
  }
  return null;
}

class Usage {
  const Usage({
    this.input = 0,
    this.output = 0,
    this.cacheRead = 0,
    this.cacheWrite = 0,
    this.cost = 0,
    this.listCost = 0,
    this.context = 0,
    this.turns = 0,
    this.lastOutput = 0,
    this.streamOutput = 0,
    this.streamSeconds = 0,
    this.billing,
    this.plan,
    this.contextWindow,
  });

  static Usage? fromWire(Object? value) {
    if (value == null) return null;
    final map = asMap(value);
    if (map.isEmpty) return null;
    return Usage(
      input: asInt(map['input']) ?? 0,
      output: asInt(map['output']) ?? 0,
      cacheRead: asInt(map['cacheRead'] ?? map['cache-read']) ?? 0,
      cacheWrite: asInt(map['cacheWrite'] ?? map['cache-write']) ?? 0,
      cost: asDouble(map['cost']) ?? 0,
      listCost: asDouble(map['listCost'] ?? map['list-cost']) ?? 0,
      context: asInt(map['context']) ?? 0,
      turns: asInt(map['turns']) ?? 0,
      lastOutput: asInt(map['lastOutput'] ?? map['last-output']) ?? 0,
      streamOutput: asInt(map['streamOutput'] ?? map['stream-output']) ?? 0,
      streamSeconds:
          asDouble(map['streamSeconds'] ?? map['stream-seconds']) ?? 0,
      billing: asString(map['billing']),
      plan: asString(map['plan']),
      contextWindow: asInt(map['contextWindow']),
    );
  }

  final int input;
  final int output;
  final int cacheRead;
  final int cacheWrite;
  final double cost;
  final double listCost;
  final int context;
  final int turns;
  final int lastOutput;
  final int streamOutput;
  final double streamSeconds;
  final String? billing;
  final String? plan;
  final int? contextWindow;

  int get totalTokens => input + output + cacheRead + cacheWrite;
  double? get outputRate =>
      streamSeconds > 0 ? streamOutput / streamSeconds : null;
  int get contextInUse => context + lastOutput;
}

class TodoItem {
  const TodoItem({required this.id, required this.text, required this.status});

  static List<TodoItem> listFrom(Object? value) => [
    for (final item in asMapList(value))
      if (asString(item['text'] ?? item['content']) != null)
        TodoItem(
          id: asStringOr(item['id'], ''),
          text: asStringOr(item['text'] ?? item['content'], ''),
          status: asStringOr(item['status'], 'pending'),
        ),
  ];

  final String id;
  final String text;
  final String status;

  bool get isDone => status == 'done' || status == 'completed';
  bool get isInProgress => status == 'in-progress' || status == 'in_progress';
}

class PendingRequest {
  const PendingRequest({
    required this.id,
    required this.kind,
    this.payload = const {},
    this.created,
  });

  static List<PendingRequest> listFrom(Object? value) => [
    for (final item in asMapList(value))
      if (asString(item['id']) != null)
        PendingRequest(
          id: asStringOr(item['id'], ''),
          kind: asStringOr(item['kind'], 'permission'),
          payload: asMap(item['payload']),
          created: parseTime(item['created']),
        ),
  ];

  final String id;
  final String kind;
  final JsonMap payload;
  final DateTime? created;
}

class QueueItem {
  const QueueItem({required this.id, required this.text});

  static List<QueueItem> listFrom(Object? value) => [
    for (final item in asMapList(value))
      QueueItem(
        id: asStringOr(item['id'], ''),
        text: asStringOr(item['text'], ''),
      ),
  ];

  final String id;
  final String text;
}
