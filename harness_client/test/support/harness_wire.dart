// A conversation as the harness records it, and what it sends for it.
//
// Every node the harness records says which node it follows (`parent`), the
// order of the transcript.  What is sent for a node is the ACP update that
// stands for it and the whole node beside it (`_harness/node`), in the shapes
// `harness-acp--node-updates` makes -- the shapes of a real harness's stream,
// recorded with the demo provider:
//
//  * a replay (`session/load`) sends a node's update first and the node after
//    it;
//  * a node announced as it is recorded (live) is the same, but for a
//    message of the agent or a thought, whose text comes as chunks while the
//    node is announced first with what it has, and again when it is final;
//  * a hint, a plan and a compaction have no update of their own: the node
//    is all there is.
//
// The tests of how the app orders a transcript write what a harness sends in
// the order it did not, so the helpers here send nothing: they make the
// updates and the test says when each one arrives.

import 'package:harness_client/src/models/transcript.dart';

typedef Wire = Map<String, Object?>;

class WireConversation {
  final List<Wire> nodes = [];
  int _n = 0;
  String? _last;

  /// The id the next node gets.
  String get nextId => 'n${_n + 1}';

  /// The node written last, or null.
  String? get last => _last;

  /// Write a node.  It follows the node before it, unless [extra] names its
  /// `parent` (null for the first of a conversation).
  Wire node(String kind, Map<String, Object?> extra) {
    final id = 'n${++_n}';
    final written = <String, Object?>{
      'id': id,
      'kind': kind,
      'ts': 1000.0 + _n,
      'parent': _last,
      ...extra,
    };
    // The next node follows this one, whatever id it was given.
    _last = written['id'] as String;
    nodes.add(written);
    return written;
  }

  Wire user(String text, [Map<String, Object?> extra = const {}]) =>
      node('user', {'content': text, ...extra});

  Wire say(String text, [Map<String, Object?> extra = const {}]) =>
      node('assistant', {'content': text, ...extra});

  Wire think(String text) => node('thinking', {'content': text});

  /// A system note, such as "non-interactive on".
  Wire hint(String text, [Map<String, Object?> extra = const {}]) =>
      node('hint', {'content': text, ...extra});

  Wire call(String callId, String tool, {String? title}) => node('tool-call', {
    'call-id': callId,
    'tool': tool,
    'title': title ?? tool,
    'input': {'path': 'a.dart'},
    'meta': {'model': 'demo:scripted'},
  });

  Wire result(String callId, [String output = 'ok']) => node('tool-result', {
    'call-id': callId,
    'output': output,
    'meta': {'duration': 0.1},
  });

  /// Every node, as `session/load` replays them.
  List<Wire> replay() => [
    for (final node in nodes) ...updates(node, live: false),
  ];

  /// What the harness sends for [node]: its update and the node.
  static List<Wire> updates(Wire node, {required bool live}) {
    final id = node['id'];
    final harness = {'nodeId': id};
    final text = node['content'];
    final whole = <String, Object?>{
      'sessionUpdate': '_harness/node',
      'node': node,
    };
    switch (node['kind']) {
      case 'user':
        // A message the user did not write says who sent it.
        final meta = node['meta'];
        final from = meta is Map ? meta['from'] : null;
        return [
          {
            'sessionUpdate': 'user_message_chunk',
            'content': {'type': 'text', 'text': text},
            '_harness': {...harness, 'from': ?from},
          },
          whole,
        ];
      case 'assistant' || 'thinking':
        final chunk = <String, Object?>{
          'sessionUpdate': node['kind'] == 'thinking'
              ? 'agent_thought_chunk'
              : 'agent_message_chunk',
          'content': {'type': 'text', 'text': text},
          '_harness': harness,
        };
        // A live node is announced with the text it has, its text goes on as
        // chunks, and the node is announced again when it is final.
        return live ? [whole, chunk, whole] : [chunk, whole];
      case 'tool-call':
        return [
          {
            'sessionUpdate': 'tool_call',
            'toolCallId': node['call-id'],
            'title': node['title'],
            'kind': 'read',
            'status': 'in_progress',
            'rawInput': node['input'],
            '_harness': {...harness, 'tool': node['tool']},
          },
          whole,
        ];
      case 'tool-result':
        return [
          {
            'sessionUpdate': 'tool_call_update',
            'toolCallId': node['call-id'],
            'status': 'completed',
            'rawOutput': node['output'],
            '_harness': harness,
          },
          whole,
        ];
      default:
        return [whole];
    }
  }
}

/// What a transcript shows, one string an item: the words of a message, a
/// note or a thought, and `[tool NAME]` for a call.  A message whose sender
/// is not the person's is `SENDER: words`.
List<String> shown(Iterable<TranscriptItem> items) => [
  for (final item in items)
    if (item.tool != null)
      '[tool ${item.tool!.tool}]'
    else if (item.isUser && item.sender != null && item.sender != 'You')
      '${item.sender}: ${item.text}'
    else
      item.text,
];
