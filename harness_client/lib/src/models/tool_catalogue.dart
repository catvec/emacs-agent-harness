/// What the app knows of the harness's tools: what people call each one, and
/// whether its calls may fold into a run under one summary line in the
/// transcript.  Plain Dart, so that it is tested without a widget.
///
/// The harness says both in `tools/list`.  A spec has a `label` (what people
/// read, "Read file", for `read_file`) and `coalescable`: the tool is on the
/// harness's allow list of the calls a chat may fold away.  The list is short
/// on purpose.  It holds the quiet reads and the commands among them, and not
/// what writes, what acts on other sessions, what waits for the user or what
/// reaches the web: a call the person should see must not hide under a line.
/// The Emacs chat reads the same flag, so a stretch of calls folds the same
/// way in both, and the app keeps no list of its own that could drift from
/// the harness's.
library;

import '../acp/acp_message.dart';
import 'tool_display.dart';

/// One tool, as `tools/list` describes it.
class ToolSpec {
  const ToolSpec({
    required this.name,
    this.label = '',
    this.kind,
    this.coalescable = false,
  });

  factory ToolSpec.fromWire(JsonMap wire) => ToolSpec(
    name: asStringOr(wire['name'], '').trim(),
    label: asStringOr(wire['label'], '').trim(),
    kind: asString(wire['kind']),
    coalescable: asBool(wire['coalescable']),
  );

  /// The name the model calls the tool by: `read_file`.
  final String name;

  /// What people read: "Read file".  Empty when the harness gave none.
  final String label;

  /// The permission class: read, write, exec, net or meta.
  final String? kind;

  /// Whether the tool is on the allow list of calls that fold into a run.
  final bool coalescable;
}

/// Every tool of a harness, by name.
class ToolCatalogue {
  const ToolCatalogue._(this._specs);

  factory ToolCatalogue(Iterable<ToolSpec> specs) => ToolCatalogue._({
    for (final spec in specs)
      if (spec.name.isNotEmpty) spec.name: spec,
  });

  /// What a harness without `tools/list` has, and what the app holds until it
  /// has asked: no tool is known, so no call folds.
  static const ToolCatalogue empty = ToolCatalogue._({});

  /// The answer of `tools/list`: an array of specs.  Anything else is no
  /// tools, and an entry without a name is left out.
  factory ToolCatalogue.fromWire(Object? wire) => ToolCatalogue([
    for (final spec in asMapList(wire)) ToolSpec.fromWire(spec),
  ]);

  final Map<String, ToolSpec> _specs;

  bool get isEmpty => _specs.isEmpty;
  int get length => _specs.length;
  Iterable<ToolSpec> get specs => _specs.values;

  /// The spec of the tool a call was made to.  A tool reached through an MCP
  /// server (`mcp__harness__read_file`) is its own name without the server's.
  ToolSpec? operator [](String? tool) =>
      tool == null || tool.isEmpty ? null : _specs[baseToolName(tool)];

  /// Whether calls of [tool] fold into a run: only those of the tools on the
  /// harness's allow list do, and every other call is a card of its own.
  bool folds(String? tool) => this[tool]?.coalescable ?? false;

  /// What people call [tool]: its label, else its name.
  String labelOf(String? tool) {
    final label = this[tool]?.label ?? '';
    return label.isNotEmpty ? label : baseToolName(tool);
  }
}
