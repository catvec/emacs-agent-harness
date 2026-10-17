import '../acp/acp_message.dart';

class TurnActivity {
  const TurnActivity({
    required this.phase,
    this.since,
    this.tool,
    this.title,
    this.detail,
    this.count,
    this.calls = const [],
  });

  factory TurnActivity.fromWire(JsonMap wire) => TurnActivity(
    phase: asStringOr(wire['phase'], ''),
    since: parseActivityTime(wire['since']),
    tool: asString(wire['tool']),
    title: asString(wire['title']),
    detail: asString(wire['detail']),
    count: asInt(wire['count']),
    calls: asMapList(wire['calls']),
  );

  final String phase;
  final DateTime? since;
  final String? tool;
  final String? title;
  final String? detail;
  final int? count;
  final List<JsonMap> calls;

  String get label => switch (phase) {
    'waiting' => 'Waiting for the model',
    'thinking' => 'Thinking',
    'writing' => 'Writing',
    'tool-input' => tool == null ? 'Preparing a tool call' : 'Preparing $tool',
    'compacting' => 'Compacting the context',
    'tool' => _toolLabel,
    'checking' => 'Waiting for permission',
    _ => 'Working',
  };

  String get _toolLabel {
    final multiple = (count ?? calls.length) > 1;
    if (multiple) return '${count ?? calls.length} tools running';
    final name = title ?? tool;
    if (name == null || name.trim().isEmpty) return 'Running a tool';
    return detail == null || detail!.trim().isEmpty ? name : '$name · $detail';
  }

  bool get isTool => phase == 'tool' || phase == 'checking';
}

DateTime? parseActivityTime(Object? value) {
  if (value is num) {
    return DateTime.fromMillisecondsSinceEpoch((value * 1000).round());
  }
  return DateTime.tryParse('$value');
}
