import 'dart:convert';

import 'package:collection/collection.dart';

import '../acp/acp_message.dart';

enum TranscriptKind {
  user,
  assistant,
  thinking,
  tool,
  hint,
  compaction,
  plan,
  unknown,
}

class PlanEntry {
  const PlanEntry({required this.content, required this.status, this.priority});

  static List<PlanEntry> listFrom(Object? value) => [
    for (final entry in asMapList(value))
      PlanEntry(
        content: asStringOr(entry['content'], ''),
        status: asStringOr(entry['status'], 'pending'),
        priority: asString(entry['priority']),
      ),
  ];

  final String content;
  final String status;
  final String? priority;

  bool get isDone => status == 'completed' || status == 'done';
  bool get isActive => status == 'in_progress' || status == 'in-progress';
}

class ToolView {
  ToolView({
    required this.callId,
    this.tool,
    this.title,
    this.kind,
    this.status = 'in_progress',
    this.input,
    this.output,
    this.isError = false,
    this.nodeId,
    this.sender,
    this.attachments = const [],
    this.meta = const {},
  });

  final String callId;
  String? tool;
  String? title;
  String? kind;
  String status;
  Object? input;
  String? output;
  bool isError;
  String? nodeId;
  String? sender;
  List<JsonMap> attachments;

  /// What the harness recorded on the call's result besides its output: how
  /// long it took (`duration`), whether the permission system refused it
  /// (`denied`), the report a `hand_in` call handed in (`report`).
  JsonMap meta;

  bool get isRunning => status == 'in_progress' || status == 'pending';
  bool get isFailed => status == 'failed' || isError;

  /// The permission system refused the call, so it never ran: what it says
  /// is the reason, not output.
  bool get isDenied => asBool(meta['denied']);

  /// How long the call took, in seconds, when the harness timed it.
  double? get duration => asDouble(meta['duration']);

  String get displayTitle {
    final name = title ?? tool;
    if (name != null && name.trim().isNotEmpty) return name.trim();
    return switch (kind) {
      'execute' => 'Run command',
      'read' => 'Read',
      'edit' => 'Edit',
      'delete' => 'Delete',
      'move' => 'Move',
      'search' => 'Search',
      'fetch' => 'Fetch',
      'think' => 'Think',
      _ => 'Tool call',
    };
  }

  Map<String, Object?> toJson() => {
    'callId': callId,
    'tool': tool,
    'title': title,
    'kind': kind,
    'status': status,
    'input': input,
    'output': output,
    'isError': isError,
    'nodeId': nodeId,
  };
}

class TranscriptItem {
  TranscriptItem({
    required this.key,
    required this.kind,
    this.nodeId,
    this.text = '',
    this.sender,
    this.timestamp,
    this.streaming = false,
    this.settled = false,
    this.tool,
    this.node,
    this.localEcho = false,
    this.pending = false,
  });

  String key;
  String? nodeId;
  TranscriptKind kind;
  String text;
  String? sender;
  DateTime? timestamp;
  bool streaming;
  bool settled;
  ToolView? tool;
  JsonMap? node;

  /// A message shown optimistically before the server echoes it.
  bool localEcho;

  /// A message the harness holds for the running turn, which takes it at its
  /// next step.  It is no part of the conversation until then -- the model
  /// has not read it -- so it is shown last, queued, and stands where it was
  /// read once the turn takes it (see [TranscriptState.syncPending]).
  bool pending;

  bool get isUser => kind == TranscriptKind.user;
  bool get isAssistant => kind == TranscriptKind.assistant;
  bool get isThinking => kind == TranscriptKind.thinking;
  bool get isTool => kind == TranscriptKind.tool;
}

/// Turns the stream of `session/update` notifications into a transcript.
///
/// Harness updates carry `_harness.nodeId`, which lets chunks and their final
/// node replace one another cleanly.  Standard ACP updates carry no ids, so
/// they are merged heuristically: assistant and thought chunks continue the
/// last streamed message, while each user chunk is its own message (which is
/// how `session/load` replays history).
///
/// [items] are in the order the updates came in.  What the screen shows is
/// [displayItems], which stands them in the order the harness recorded them:
/// the updates do not always come in it (see [displayItems]).
class TranscriptState {
  final List<TranscriptItem> items = <TranscriptItem>[];
  final List<PlanEntry> plan = <PlanEntry>[];
  final List<String> availableCommands = <String>[];
  final Map<String, ToolView> toolsByCallId = <String, ToolView>{};

  /// The node each node follows, by id, as the harness recorded them (`parent`
  /// on a node; null for the first of a conversation), every node it has told
  /// of, including a result that joined its call and so has no item.  Empty
  /// for an agent that is no harness, whose items are read as they came.
  final Map<String, String?> _parents = <String, String?>{};
  int _counter = 0;
  String? _lastAssistantKey;
  String? _lastThinkingKey;

  bool get isEmpty => items.isEmpty;
  bool get hasStreaming =>
      items.any((item) => item.streaming) ||
      toolsByCallId.values.any((tool) => tool.isRunning);

  List<ToolView> get runningTools =>
      toolsByCallId.values.where((tool) => tool.isRunning).toList();

  void reset() {
    items.clear();
    plan.clear();
    availableCommands.clear();
    toolsByCallId.clear();
    _parents.clear();
    _lastAssistantKey = null;
    _lastThinkingKey = null;
    _counter = 0;
  }

  TranscriptItem addLocalUser(String text) {
    final item = TranscriptItem(
      key: 'local-${_counter++}',
      kind: TranscriptKind.user,
      text: text,
      sender: 'You',
      timestamp: DateTime.now(),
      localEcho: true,
      streaming: false,
    );
    items.add(item);
    return item;
  }

  /// Take back a message that was shown before the harness had it, and
  /// never will.
  void removeLocalEcho(TranscriptItem item) {
    if (item.localEcho) items.remove(item);
  }

  /// What the screen shows, top to bottom: the transcript in the order the
  /// harness recorded it, then the messages the turn has not taken yet
  /// ([TranscriptItem.pending]), pinned last.
  ///
  /// Every node the harness records says which node it follows (`parent`),
  /// so a transcript has an order of its own, whatever order its updates
  /// come in.  They do not always come in it.  A phone that was away misses
  /// what the harness records meanwhile -- a system note such as
  /// "non-interactive on", the messages after it -- and is announced the
  /// newest ones when the connection is back, before it reads the
  /// conversation again: what it missed comes under them, and stands as a
  /// block at the bottom.  A conversation is read by `session/load`, a run
  /// of updates oldest first, and what the harness writes while that run is
  /// on its way can reach the app in the middle of it, as one that came
  /// before the run began stands before all of it.  Shown as it came, a note
  /// stands among messages that are not the ones around it.
  ///
  /// So an item never stands before the item of a node it follows: one that
  /// came first waits for it, and stands right after it, followed in turn by
  /// what waited for it.  While a conversation that has its first node is
  /// still being read, a node that follows one nothing is known of yet waits
  /// at the end, for the nodes of the replay that lead to it, instead of
  /// standing where it came.  Everything else stays where it came, so a
  /// transcript whose nodes name no parent (an agent that is no harness, an
  /// older harness) is read as it was sent, and so is one read from the
  /// middle, a window of its nodes, whose first node follows one it does not
  /// hold.
  List<TranscriptItem> get displayItems {
    final recorded = _inRecordedOrder();
    if (!recorded.any((item) => item.pending)) return recorded;
    return [
      ...recorded.where((item) => !item.pending),
      ...recorded.where((item) => item.pending),
    ];
  }

  /// [items] in the order the harness recorded their nodes (see
  /// [displayItems]); [items] itself when no node has said what it follows.
  List<TranscriptItem> _inRecordedOrder() {
    if (_parents.isEmpty) return items;
    // The item of each node that has one: a result that joined its call has
    // none, and a node nothing has been heard of yet has none either.
    final own = <String, TranscriptItem>{};
    for (final item in items) {
      final id = item.nodeId;
      if (id != null) own.putIfAbsent(id, () => item);
    }
    // Whether the first node of the conversation is here.  Then every other
    // node leads back to it, and one whose parent has not been heard of is
    // one the rest of the replay has yet to bring.  Without it, the
    // transcript is read from the middle, and such a node is where it began.
    final fromTheStart = _parents.values.any((parent) => parent == null);
    // The item that [item] has to stand after: that of the nearest node
    // before its own that has one, through the nodes that joined another's.
    // Whether the nodes before it lead to one nothing is known of.
    (TranscriptItem?, bool) follows(TranscriptItem item) {
      final nodeId = item.nodeId;
      var id = nodeId == null ? null : _parents[nodeId];
      // A node's parents lead to the first node, unless the harness told of
      // a loop: never walk further than the nodes there are.
      for (var steps = 0; id != null && steps <= _parents.length; steps++) {
        final found = own[id];
        if (found != null && !identical(found, item)) return (found, false);
        if (!_parents.containsKey(id)) return (null, true);
        id = _parents[id];
      }
      return (null, false);
    }

    final ordered = <TranscriptItem>[];
    final placed = Set<TranscriptItem>.identity();
    final waiting = Map<TranscriptItem, List<TranscriptItem>>.identity();
    // Stand [first] where it belongs, then what waited for it, each followed
    // by what waited for that: the one that came first first.
    void place(TranscriptItem first) {
      final pending = <TranscriptItem>[first];
      while (pending.isNotEmpty) {
        final item = pending.removeLast();
        ordered.add(item);
        placed.add(item);
        final followers = waiting.remove(item);
        if (followers != null) pending.addAll(followers.reversed);
      }
    }

    final unheard = <TranscriptItem>[];
    for (final item in items) {
      final (before, lost) = follows(item);
      if (lost && fromTheStart) {
        unheard.add(item);
      } else if (before != null && !placed.contains(before)) {
        (waiting[before] ??= <TranscriptItem>[]).add(item);
      } else {
        place(item);
      }
    }
    // What follows a node nothing is known of stands last, in the order it
    // came, with what waits for it: the replay has not reached its parent.
    unheard.forEach(place);
    // What is still waiting follows an item that never stood anywhere, which
    // a loop in the nodes' parents can do: it stays where it came.
    if (ordered.length < items.length) {
      for (final item in items) {
        if (!placed.contains(item)) ordered.add(item);
      }
    }
    return ordered;
  }

  /// Remember which node [node], one the harness recorded, follows.  A later
  /// word of the same node that names no parent (a note that was added to)
  /// leaves what is known as it is.
  void _noteParent(String nodeId, JsonMap node) {
    if (!node.containsKey('parent') && _parents.containsKey(nodeId)) return;
    final parent = asString(node['parent']);
    _parents[nodeId] = parent == null || parent.isEmpty ? null : parent;
  }

  /// Take [held], the messages the harness says it holds for the running
  /// turn's next step.  A message sent while the agent works is no node of
  /// the transcript until the turn takes it, which is when the harness
  /// echoes it as a message of the user's (`_applyUserChunk`): the
  /// transcript reads in the order the model got things.  So until then it
  /// is [TranscriptItem.pending], shown last.  The message the person sent
  /// from here and showed at once ([TranscriptItem.localEcho]) is the first
  /// of them, whether or not its words are quite the ones the harness
  /// holds (it may have changed them).  A message that is pending and no
  /// longer held was taken back, and goes.  [sender] is the name of whoever
  /// sent a message that the person did not, as `formatSender` reads it.
  void syncPending(List<({String id, String text, String? sender})> held) {
    final ids = {for (final message in held) message.id};
    items.removeWhere((item) => item.pending && !ids.contains(item.nodeId));
    for (final message in held) {
      if (itemForNode(message.id) != null) continue;
      final index = items.indexWhere((item) => item.localEcho);
      if (index >= 0) {
        final local = items[index];
        local
          ..nodeId = message.id
          ..text = message.text.isNotEmpty ? message.text : local.text
          ..sender = message.sender ?? local.sender ?? 'You'
          ..localEcho = false
          ..pending = true;
      } else {
        items.add(
          TranscriptItem(
            key: 'node-${message.id}',
            nodeId: message.id,
            kind: TranscriptKind.user,
            text: message.text,
            sender: message.sender ?? 'You',
            pending: true,
          ),
        );
      }
    }
  }

  TranscriptItem? itemForNode(String? nodeId) {
    if (nodeId == null) return null;
    for (final item in items) {
      if (item.nodeId == nodeId) return item;
    }
    return null;
  }

  /// Apply one `session/update` object (the value of `update`).
  void apply(JsonMap update) {
    final kind = asStringOr(update['sessionUpdate'], '');
    final harness = asMap(update['_harness']);
    final nodeId = asString(harness['nodeId']);
    final timestamp = parseTimeForTranscript(harness['ts']);
    switch (kind) {
      case 'user_message_chunk':
        _applyUserChunk(update, nodeId, timestamp, harness);
      case 'agent_message_chunk':
        _applyTextChunk(update, nodeId, TranscriptKind.assistant, timestamp);
      case 'agent_thought_chunk':
        _applyTextChunk(update, nodeId, TranscriptKind.thinking, timestamp);
      case 'tool_call':
        _applyToolCall(update, nodeId, harness);
      case 'tool_call_update':
        _applyToolUpdate(update, harness);
      case 'plan':
        plan
          ..clear()
          ..addAll(PlanEntry.listFrom(update['entries']));
      case 'available_commands_update':
        availableCommands
          ..clear()
          ..addAll(
            [
              for (final command in asMapList(update['availableCommands']))
                asStringOr(command['name'], ''),
            ]..removeWhere((name) => name.isEmpty),
          );
      case 'current_mode_update':
      case '_harness/session':
      case '_harness/activity':
      case '_harness/session_deleted':
        // Session-level; the controller handles these.
        break;
      case '_harness/node':
        applyNode(asMap(update['node']));
      default:
        break;
    }
  }

  /// Put [item], a message the harness has just echoed, last.
  ///
  /// The harness echoes a message when the model reads it, and the transcript
  /// is in the order the model got things.  A message sent while the agent
  /// worked was shown where it was sent, with what the agent did after that
  /// below it; it stands after all of it now, where the reply to it comes.
  void _standAtEnd(TranscriptItem item) {
    if (items.isEmpty || identical(items.last, item)) return;
    items
      ..remove(item)
      ..add(item);
  }

  void _applyUserChunk(
    JsonMap update,
    String? nodeId,
    DateTime? timestamp,
    JsonMap harness,
  ) {
    final text = textOf(update['content']);
    final sender = formatSender(harness['from']);
    final existing = itemForNode(nodeId);
    if (existing != null) {
      existing.text = text.isNotEmpty ? text : existing.text;
      existing.sender = sender ?? existing.sender;
      existing.streaming = false;
      if (existing.pending) {
        // The turn took the message the harness held: it stands where the
        // model read it.
        existing.pending = false;
        _standAtEnd(existing);
      }
      return;
    }
    if (nodeId == null) {
      final local = items.lastWhere(
        (item) => item.localEcho,
        orElse: () => TranscriptItem(key: '', kind: TranscriptKind.user),
      );
      if (local.key.isNotEmpty) {
        local
          ..text = text
          ..nodeId = null
          ..localEcho = false
          ..sender = sender ?? 'You';
        _standAtEnd(local);
        return;
      }
      items.add(
        TranscriptItem(
          key: 'user-${_counter++}',
          kind: TranscriptKind.user,
          text: text,
          sender: sender ?? 'You',
          timestamp: timestamp,
        ),
      );
      return;
    }
    final localIndex = items.indexWhere((item) => item.localEcho);
    if (localIndex >= 0) {
      // The echoed message is the one we showed optimistically.  Adopt it
      // whether or not the text is identical, so the same turn never shows
      // twice.
      final local = items[localIndex];
      local
        ..nodeId = nodeId
        ..text = text.isNotEmpty ? text : local.text
        ..localEcho = false
        ..sender = sender ?? 'You';
      _standAtEnd(local);
      return;
    }
    items.add(
      TranscriptItem(
        key: 'node-$nodeId',
        nodeId: nodeId,
        kind: TranscriptKind.user,
        text: text,
        sender: sender ?? 'You',
        timestamp: timestamp,
      ),
    );
  }

  void _applyTextChunk(
    JsonMap update,
    String? nodeId,
    TranscriptKind kind,
    DateTime? timestamp,
  ) {
    final text = textOf(update['content']);
    if (text.isEmpty) return;
    TranscriptItem? existing = itemForNode(nodeId);
    if (existing != null && existing.kind != kind) existing = null;
    if (existing == null && nodeId == null) {
      final lastKey = kind == TranscriptKind.assistant
          ? _lastAssistantKey
          : _lastThinkingKey;
      if (lastKey != null) {
        final last = items.where((item) => item.key == lastKey).firstOrNull;
        if (last != null && last.streaming) existing = last;
      }
    }
    if (existing != null) {
      existing.text += text;
      existing.streaming = true;
      return;
    }
    final item = TranscriptItem(
      key: nodeId != null ? 'node-$nodeId' : 'stream-${_counter++}',
      nodeId: nodeId,
      kind: kind,
      text: text,
      sender: kind == TranscriptKind.assistant ? 'Agent' : null,
      timestamp: timestamp ?? DateTime.now(),
      streaming: true,
    );
    items.add(item);
    if (kind == TranscriptKind.assistant) {
      _lastAssistantKey = item.key;
    } else {
      _lastThinkingKey = item.key;
    }
  }

  void _applyToolCall(JsonMap update, String? nodeId, JsonMap harness) {
    final callId = asStringOr(update['toolCallId'], 'call-${_counter++}');
    final tool =
        toolsByCallId[callId] ?? ToolView(callId: callId, nodeId: nodeId);
    tool
      ..tool = asString(harness['tool']) ?? tool.tool
      ..title = asString(update['title']) ?? tool.title
      ..kind = asString(update['kind']) ?? toolKindFor(tool.tool) ?? tool.kind
      ..status = asStringOr(update['status'], tool.status)
      ..input = update['rawInput'] ?? tool.input
      ..sender = formatSender(harness['from']) ?? tool.sender;
    toolsByCallId[callId] = tool;
    // The call's own item, or the one its result made when that came first
    // (see [applyNode]): the item stands for the call from now on.
    final existing =
        (nodeId != null ? itemForNode(nodeId) : null) ?? _itemForTool(callId);
    if (existing != null) {
      existing
        ..tool = tool
        ..kind = TranscriptKind.tool
        ..streaming = tool.isRunning;
      if (nodeId != null) existing.nodeId = nodeId;
      return;
    }
    final item = TranscriptItem(
      key: nodeId != null ? 'node-$nodeId' : 'tool-$callId',
      nodeId: nodeId,
      kind: TranscriptKind.tool,
      tool: tool,
      streaming: tool.isRunning,
      timestamp: DateTime.now(),
    );
    items.add(item);
    _finishStreamingText();
  }

  void _applyToolUpdate(JsonMap update, JsonMap harness) {
    final callId = asString(update['toolCallId']);
    if (callId == null) return;
    final tool = toolsByCallId[callId] ?? ToolView(callId: callId);
    tool
      ..status = asStringOr(update['status'], tool.status)
      ..isError = tool.isError || asString(update['status']) == 'failed'
      ..output = extractToolOutput(update) ?? tool.output;
    if (tool.title == null) tool.title = asString(update['title']);
    if (asList(harness['attachments']).isNotEmpty) {
      tool.attachments = asMapList(harness['attachments']);
    }
    toolsByCallId[callId] = tool;
    final item = _itemForTool(callId);
    if (item != null) {
      item
        ..tool = tool
        ..streaming = tool.isRunning;
    }
  }

  void _finishStreamingText() {
    for (final item in items) {
      if (item.kind == TranscriptKind.assistant ||
          item.kind == TranscriptKind.thinking) {
        item.streaming = false;
      }
    }
    _lastAssistantKey = null;
    _lastThinkingKey = null;
  }

  TranscriptItem? _itemForTool(String callId) {
    for (final item in items) {
      if (item.tool?.callId == callId) return item;
    }
    return null;
  }

  /// Replace or settle an item from a full harness node.
  void applyNode(JsonMap node) {
    final nodeId = asString(node['id']);
    final kind = asStringOr(node['kind'], '');
    final content = asString(node['content']) ?? '';
    final meta = asMap(node['meta']);
    final sender = formatSender(meta['from']);
    final timestamp = parseTimeForTranscript(node['ts']);
    if (nodeId == null) return;
    // Every node, whether or not it has an item of its own: the nodes after
    // it are placed by it (see [displayItems]).
    _noteParent(nodeId, node);
    switch (kind) {
      case 'user':
        final existing = itemForNode(nodeId);
        if (existing != null) {
          existing
            ..text = content.isNotEmpty ? content : existing.text
            ..sender = sender ?? existing.sender
            ..localEcho = false
            ..settled = true;
          if (existing.pending) {
            // The turn took the message: it stands where the model read it.
            existing.pending = false;
            _standAtEnd(existing);
          }
        } else {
          items.add(
            TranscriptItem(
              key: 'node-$nodeId',
              nodeId: nodeId,
              kind: TranscriptKind.user,
              text: content,
              sender: sender ?? 'You',
              timestamp: timestamp,
              settled: true,
              node: node,
            ),
          );
        }
      case 'assistant':
      case 'thinking':
        final targetKind = kind == 'thinking'
            ? TranscriptKind.thinking
            : TranscriptKind.assistant;
        var item = itemForNode(nodeId);
        item ??= _lastStreamingOfKind(targetKind);
        if (item != null) {
          if (content.isNotEmpty) item.text = content;
          item
            ..nodeId = nodeId
            ..kind = targetKind
            ..streaming = false
            ..settled = true
            ..node = node
            ..timestamp ??= timestamp;
        } else {
          item = TranscriptItem(
            key: 'node-$nodeId',
            nodeId: nodeId,
            kind: targetKind,
            text: content,
            sender: targetKind == TranscriptKind.assistant ? 'Agent' : null,
            timestamp: timestamp,
            settled: true,
            node: node,
          );
          items.add(item);
        }
        if (targetKind == TranscriptKind.assistant) {
          _lastAssistantKey = item.key;
        }
      case 'tool-call':
        final callId = asStringOr(node['callId'] ?? node['call-id'], '');
        if (callId.isEmpty) return;
        final tool = toolsByCallId[callId] ?? ToolView(callId: callId);
        tool
          ..tool = asString(node['tool']) ?? tool.tool
          ..title = asString(node['title']) ?? tool.title
          ..input = node['input'] ?? tool.input
          ..kind = tool.kind ?? toolKindFor(asString(node['tool']))
          ..nodeId = nodeId
          ..sender = sender ?? tool.sender
          ..isError = asBool(node['isError'] ?? node['is-error']);
        if (tool.status == 'in_progress' && tool.output != null) {
          tool.status = tool.isError ? 'failed' : 'completed';
        }
        toolsByCallId[callId] = tool;
        var item = itemForNode(nodeId) ?? _itemForTool(callId);
        if (item != null) {
          item
            ..nodeId = nodeId
            ..tool = tool
            ..kind = TranscriptKind.tool;
        } else {
          item = TranscriptItem(
            key: 'node-$nodeId',
            nodeId: nodeId,
            kind: TranscriptKind.tool,
            tool: tool,
            timestamp: timestamp,
          );
          items.add(item);
        }
      case 'tool-result':
        final callId = asStringOr(node['callId'] ?? node['call-id'], '');
        if (callId.isEmpty) return;
        final tool = toolsByCallId[callId] ?? ToolView(callId: callId);
        tool
          ..output = asString(node['output']) ?? tool.output
          ..isError = asBool(node['isError'] ?? node['is-error'])
          ..status = asBool(node['isError'] ?? node['is-error'])
              ? 'failed'
              : 'completed'
          ..nodeId = tool.nodeId ?? nodeId
          ..sender = sender ?? tool.sender
          ..meta = meta.isEmpty ? tool.meta : meta;
        if (asList(node['attachments']).isNotEmpty) {
          tool.attachments = asMapList(node['attachments']);
        }
        toolsByCallId[callId] = tool;
        final item = _itemForTool(callId);
        if (item != null) {
          item
            ..tool = tool
            ..streaming = false;
        } else {
          items.add(
            TranscriptItem(
              key: 'node-$nodeId',
              nodeId: nodeId,
              kind: TranscriptKind.tool,
              tool: tool,
              timestamp: timestamp,
            ),
          );
        }
      case 'hint':
        _upsertSimple(nodeId, TranscriptKind.hint, content, timestamp, node);
      case 'compaction':
        _upsertSimple(
          nodeId,
          TranscriptKind.compaction,
          content,
          timestamp,
          node,
        );
      case 'plan':
        _upsertSimple(nodeId, TranscriptKind.plan, content, timestamp, node);
      default:
        if (content.isNotEmpty) {
          _upsertSimple(
            nodeId,
            TranscriptKind.unknown,
            content,
            timestamp,
            node,
          );
        }
    }
  }

  void _upsertSimple(
    String nodeId,
    TranscriptKind kind,
    String text,
    DateTime? timestamp,
    JsonMap node,
  ) {
    final existing = itemForNode(nodeId);
    if (existing != null) {
      existing
        ..text = text
        ..kind = kind
        ..settled = true
        ..node = node;
      return;
    }
    items.add(
      TranscriptItem(
        key: 'node-$nodeId',
        nodeId: nodeId,
        kind: kind,
        text: text,
        timestamp: timestamp,
        settled: true,
        node: node,
      ),
    );
  }

  TranscriptItem? _lastStreamingOfKind(TranscriptKind kind) {
    for (final item in items.reversed) {
      if (item.kind == kind && item.streaming) return item;
    }
    return null;
  }

  /// The turn is over: nothing is streaming any more.
  void finish() {
    for (final item in items) {
      item.streaming = false;
    }
    for (final tool in toolsByCallId.values) {
      if (tool.status == 'in_progress' && tool.output == null) {
        tool.status = 'completed';
      }
    }
    _lastAssistantKey = null;
    _lastThinkingKey = null;
  }
}

/// ACP's tool kinds are not on a harness node; infer the common ones from
/// the tool's name so a replayed transcript still shows the right icon.
String? toolKindFor(String? tool) {
  if (tool == null) return null;
  final name = tool.toLowerCase();
  if (name.contains('read') ||
      name.contains('list_dir') ||
      name.contains('glob')) {
    return 'read';
  }
  if (name.contains('write') ||
      name.contains('edit') ||
      name.contains('patch')) {
    return 'edit';
  }
  if (name.contains('delete') || name.contains('remove')) return 'delete';
  if (name.contains('move') || name.contains('rename')) return 'move';
  if (name.contains('search') ||
      name.contains('grep') ||
      name.contains('find')) {
    return 'search';
  }
  if (name == 'bash' ||
      name == 'shell' ||
      name.contains('terminal') ||
      name.contains('command')) {
    return 'execute';
  }
  if (name.contains('fetch') || name.contains('http') || name.contains('web')) {
    return 'fetch';
  }
  if (name.contains('think')) return 'think';
  return null;
}

String? extractToolOutput(JsonMap update) {
  final raw = asString(update['rawOutput'] ?? update['raw-output']);
  if (raw != null) return raw;
  final content = update['content'];
  if (content is String) return content;
  for (final block in asMapList(content)) {
    final text = textOf(block['content'] ?? block);
    if (text.isNotEmpty) return text;
  }
  return null;
}

String? formatSender(Object? from) {
  if (from == null) return null;
  if (from is String) return from.isEmpty ? null : from;
  final map = asMap(from);
  if (map.isEmpty) return null;
  final kind = asString(map['kind']);
  if (kind == 'system') {
    final source = asString(map['source']);
    return source == null ? 'Harness' : 'Harness · $source';
  }
  if (kind == 'session') {
    return asString(map['name']) ?? asString(map['id']) ?? 'Another session';
  }
  return asString(map['name']) ?? asString(map['id']) ?? kind;
}

DateTime? parseTimeForTranscript(Object? value) {
  if (value == null) return null;
  if (value is num) {
    return DateTime.fromMillisecondsSinceEpoch((value * 1000).round());
  }
  return DateTime.tryParse('$value');
}

/// Pretty-print a tool's raw input for the detail sheet.
String prettyJson(Object? value) {
  if (value == null) return '';
  if (value is String) return value;
  try {
    return const JsonEncoder.withIndent('  ').convert(value);
  } catch (_) {
    return '$value';
  }
}
