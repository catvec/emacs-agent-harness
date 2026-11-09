import '../acp/acp_message.dart';
import 'session.dart';

/// One node of a thread's Logseq page: a note the agent kept, a block the
/// user wrote, or a capture in the day's journal that links the page.
class WorkspaceGraphBlock {
  const WorkspaceGraphBlock({
    required this.id,
    this.text = '',
    this.role = '',
    this.tags = const [],
    this.links = const [],
    this.properties = const {},
    this.page = '',
    this.thread = '',
    this.journal = false,
    this.snippet = '',
    this.at,
  });

  factory WorkspaceGraphBlock.fromWire(JsonMap wire) {
    return WorkspaceGraphBlock(
      id: asStringOr(wire['id'], ''),
      text: asStringOr(wire['text'], ''),
      role: asStringOr(firstString(wire['role']), ''),
      tags: _strings(wire['tags']),
      links: _strings(wire['links']),
      properties: _properties(wire['properties']),
      page: asStringOr(wire['page'], ''),
      thread: asStringOr(firstString(wire['thread']), ''),
      journal: asBool(wire['journal']),
      snippet: asStringOr(wire['snippet'], ''),
      at: parseTime(wire['ts'] ?? wire['created']),
    );
  }

  final String id;
  final String text;
  final String role;
  final List<String> tags;
  final List<String> links;
  final Map<String, String> properties;
  final String page;
  final String thread;
  final bool journal;
  final String snippet;
  final DateTime? at;

  /// The word the graph page puts before a node.
  String get roleLabel {
    return switch (role.toLowerCase()) {
      'user' || 'you' => 'You',
      'assistant' || 'agent' => 'Agent',
      'note' || 'memory' => 'Note',
      _ => role.isEmpty ? 'Block' : role,
    };
  }

  /// The text to show: a search snippet when there is one, else the block.
  String get display => snippet.isEmpty ? text : snippet;
}

/// A page of the graph: its name, its properties and the pages it links.
class WorkspaceGraphPage {
  const WorkspaceGraphPage({
    this.name = '',
    this.title = '',
    this.properties = const {},
    this.tags = const [],
    this.links = const [],
  });

  factory WorkspaceGraphPage.fromWire(JsonMap wire) => WorkspaceGraphPage(
    name: asStringOr(wire['name'] ?? wire['title'], ''),
    title: asStringOr(wire['title'] ?? wire['name'], ''),
    properties: _properties(wire['properties']),
    tags: _strings(wire['tags']),
    links: _strings(wire['links']),
  );

  final String name;
  final String title;
  final Map<String, String> properties;
  final List<String> tags;
  final List<String> links;
}

/// What the graph explorer draws: a thread's page, one node or another page.
///
/// The harness answers all three with one shape.  [status] is `ready`,
/// `missing` (the graph holds no such page or node) or `unavailable` (there
/// is no graph to read); [why] says why when it is not ready.
class WorkspaceGraph {
  const WorkspaceGraph({
    this.status = 'unavailable',
    this.why,
    this.workspace = '',
    this.workspaceName = '',
    this.pageName = '',
    this.thread = '',
    this.threadId = '',
    this.count = 0,
    this.page,
    this.blocks = const [],
    this.links = const [],
    this.backlinks = const [],
    this.block,
    this.children = const [],
  });

  factory WorkspaceGraph.fromWire(JsonMap wire) {
    final page = asMap(wire['page']);
    return WorkspaceGraph(
      status: asStringOr(wire['status'], 'unavailable'),
      why: asString(wire['why']),
      workspace: asStringOr(wire['workspace'], ''),
      workspaceName: asStringOr(wire['workspace-name'], ''),
      pageName: asStringOr(wire['page-name'] ?? wire['name'], ''),
      thread: asStringOr(wire['thread'], ''),
      threadId: asStringOr(wire['thread-id'], ''),
      count: asInt(wire['count']) ?? 0,
      page: page.isEmpty ? null : WorkspaceGraphPage.fromWire(page),
      blocks: [
        for (final item in asMapList(wire['blocks']))
          WorkspaceGraphBlock.fromWire(item),
      ],
      links: _strings(wire['links']),
      backlinks: [
        for (final item in asMapList(wire['backlinks']))
          WorkspaceGraphBlock.fromWire(item),
      ],
      block: asMap(wire['block'] ?? wire['node']).isEmpty
          ? null
          : WorkspaceGraphBlock.fromWire(asMap(wire['block'] ?? wire['node'])),
      children: [
        for (final item in asMapList(wire['children']))
          WorkspaceGraphBlock.fromWire(item),
      ],
    );
  }

  final String status;
  final String? why;
  final String workspace;
  final String workspaceName;
  final String pageName;
  final String thread;
  final String threadId;
  final int count;
  final WorkspaceGraphPage? page;
  final List<WorkspaceGraphBlock> blocks;
  final List<String> links;
  final List<WorkspaceGraphBlock> backlinks;
  final WorkspaceGraphBlock? block;
  final List<WorkspaceGraphBlock> children;

  bool get ready => status == 'ready';

  /// A sample graph for the preview and the pictures: a kitchen thread with
  /// its page properties, one note and the day's captures.
  static WorkspaceGraph preview() {
    final now = DateTime.now();
    final page = WorkspaceGraphPage(
      name: 'Threads/Kitchen renovation',
      title: 'Threads/Kitchen renovation',
      properties: {
        'workspace': 'Home',
        'workspace-status': 'active',
        'thread-title': 'Kitchen renovation',
        'summary': 'The tile is matte; the Stone Co sample is still open.',
        'next-action': 'Wait for the Stone Co sample.',
      },
      tags: const ['Thread'],
      links: const ['Stone Co'],
    );
    return WorkspaceGraph(
      status: 'ready',
      workspace: 'w1',
      workspaceName: 'Home',
      pageName: page.name,
      thread: 'Kitchen renovation',
      threadId: 'th1',
      count: 2,
      page: page,
      blocks: [
        WorkspaceGraphBlock(
          id: 'b1',
          role: 'note',
          page: page.name,
          text: 'The tile is matte and the grout is warm grey.',
          tags: const ['Memory'],
          links: const ['Stone Co'],
          properties: const {
            'workspace': 'Home',
            'role': 'note',
            'source-session': 's1',
          },
          at: now.subtract(const Duration(minutes: 12)),
        ),
        WorkspaceGraphBlock(
          id: 'b2',
          role: 'assistant',
          page: page.name,
          text: 'Noted. Ask Stone Co for a sample.',
          properties: const {'workspace': 'Home'},
          at: now.subtract(const Duration(minutes: 13)),
        ),
      ],
      links: const ['Stone Co'],
      backlinks: [
        WorkspaceGraphBlock(
          id: 'b3',
          role: 'user',
          page: '2026-11-08',
          thread: page.name,
          journal: true,
          text: 'The tile is matte. The grout is warm grey.',
          at: now.subtract(const Duration(minutes: 14)),
        ),
      ],
    );
  }
}

List<String> _strings(Object? value) {
  final names = <String>[];
  for (final item in asList(value)) {
    final name = firstString(item);
    if (name != null && name.trim().isNotEmpty && !names.contains(name)) {
      names.add(name.trim());
    }
  }
  return names;
}

/// A plist of properties as ACP carries it: an object, or a list of pairs.
Map<String, String> _properties(Object? value) {
  final pairs = <String, String>{};
  void add(Object? name, Object? text) {
    final key = asString(name);
    if (key == null || key.isEmpty) return;
    final clean = text is List ? firstString(text) : asString(text);
    if (clean != null && clean.isNotEmpty) pairs[key] = clean;
  }

  if (value is Map) {
    value.forEach(add);
  } else {
    for (final pair in asList(value)) {
      if (pair is Map) {
        add(pair['name'] ?? pair['key'], pair['value']);
      } else {
        final items = asList(pair);
        if (items.length >= 2) add(items[0], items[1]);
      }
    }
  }
  return pairs;
}
