/// What a person needs to read a tool call: its text made clean, its input
/// as labelled fields, the time it took, and, for the call that hands a
/// task's work in, the report it carries.  Plain Dart, so that it is tested
/// without a widget.
library;

import 'dart:convert';

import '../acp/acp_message.dart';
import 'transcript.dart';

final _ansi = RegExp(r'\x1B\[[0-9;?]*[ -/]*[@-~]');

/// [text] as it is read: the escape sequences of a colored terminal gone,
/// every line ended the same way, and what a progress bar overwrote (the
/// part of a line before its last carriage return) dropped.
String cleanToolText(String text) {
  var clean = text.replaceAll(_ansi, '').replaceAll('\r\n', '\n');
  if (clean.contains('\r')) {
    clean = clean
        .split('\n')
        .map((line) {
          final at = line.lastIndexOf('\r');
          return at < 0 ? line : line.substring(at + 1);
        })
        .join('\n');
  }
  return clean;
}

class _Cleaned {
  _Cleaned(this.source, this.text, this.lines);

  final String source;
  final String text;
  final int lines;
}

final _cleaned = Expando<_Cleaned>('cleaned tool output');

/// What [tool] said, clean, and how many lines it is.  A transcript draws
/// each call again whenever anything in it changes, and a result can be a
/// great deal of text: it is cleaned once, for as long as the output stays
/// the one it was.
({String text, int lines}) outputOf(ToolView tool) {
  final raw = tool.output ?? '';
  var cached = _cleaned[tool];
  if (cached == null || !identical(cached.source, raw)) {
    final text = cleanToolText(raw);
    cached = _Cleaned(
      raw,
      text,
      text.trim().isEmpty ? 0 : toolTextLines(text).length,
    );
    _cleaned[tool] = cached;
  }
  return (text: cached.text, lines: cached.lines);
}

/// The lines of [text], with the line end that closes the last one not
/// counted as a line of its own.  No text is no lines.
List<String> toolTextLines(String text) {
  if (text.isEmpty) return const [];
  final lines = text.split('\n');
  if (lines.length > 1 && lines.last.isEmpty) lines.removeLast();
  return lines;
}

/// [text] in pieces a page builds one at a time: at most [maxLines] lines
/// and [maxChars] characters each, a single line longer than that cut where
/// it is.  Joined by line ends they are the text.
List<String> toolTextChunks(
  String text, {
  int maxLines = 80,
  int maxChars = 20000,
}) {
  final chunks = <String>[];
  final buffer = StringBuffer();
  var lines = 0;
  var chars = 0;
  void flush() {
    if (lines == 0) return;
    chunks.add(buffer.toString());
    buffer.clear();
    lines = 0;
    chars = 0;
  }

  for (final line in toolTextLines(text)) {
    var rest = line;
    // A line no page lays out in one piece: cut it, and keep the pieces.
    while (rest.length > maxChars) {
      flush();
      chunks.add(rest.substring(0, maxChars));
      rest = rest.substring(maxChars);
    }
    if (lines >= maxLines || (lines > 0 && chars + rest.length > maxChars)) {
      flush();
    }
    if (lines > 0) buffer.write('\n');
    buffer.write(rest);
    lines++;
    chars += rest.length + 1;
  }
  flush();
  return chunks;
}

/// "1 line", "48 lines".
String linesLabel(int count) => count == 1 ? '1 line' : '$count lines';

/// How long a call took, as a person says it: "30 ms", "1.2 s", "17 s",
/// "2m 05s".  Nothing for a call that has no time, or one that is not a
/// number of seconds.
String durationLabel(Object? seconds) {
  final value = asDouble(seconds);
  if (value == null || value < 0) return '';
  if (value < 1) return '${(value * 1000).round()} ms';
  if (value < 10) return '${value.toStringAsFixed(1)} s';
  if (value < 60) return '${value.round()} s';
  final whole = value.round();
  return '${whole ~/ 60}m ${(whole % 60).toString().padLeft(2, '0')}s';
}

/// The name of the file at [path], for a line that has little room.
String baseName(String path) {
  final trimmed = path.endsWith('/') && path.length > 1
      ? path.substring(0, path.length - 1)
      : path;
  final at = trimmed.lastIndexOf('/');
  return at < 0 ? trimmed : trimmed.substring(at + 1);
}

/// The name of a tool as the harness calls it: one a client reaches through
/// an MCP server (`mcp__harness__hand_in`) is its own name without the
/// server's.
String baseToolName(String? name) {
  if (name == null) return '';
  final at = name.lastIndexOf('__');
  return name.startsWith('mcp__') && at >= 0 ? name.substring(at + 2) : name;
}

/// How a field of a call's input is shown.
enum ToolFieldStyle {
  /// A shell command, after a prompt.
  command,

  /// Text of any length that is code or data: a path, a pattern, the
  /// content of a file.  Monospace, line breaks as they are.
  code,

  /// What a person wrote for a person (a summary, a prompt): drawn as
  /// markdown.
  prose,

  /// The text an edit takes out.
  removed,

  /// The text an edit puts in its place.
  added,

  /// A number, a flag, a short list: on the line of its name.
  scalar,
}

/// One labelled field of a call's input.
class ToolField {
  const ToolField(this.name, this.text, this.style);

  final String name;

  /// The value as text, its line breaks real ones.
  final String text;
  final ToolFieldStyle style;

  int get lineCount => toolTextLines(text).length;
}

const _proseKeys = {
  'summary',
  'problem',
  'reproduction',
  'prompt',
  'question',
  'message',
  'description',
  'note',
  'caption',
  'reason',
  'answer',
  'body',
  'instructions',
  'feedback',
  'comment',
  'plan',
};

const _codeKeys = {'content', 'code', 'script', 'diff', 'patch', 'text'};

/// The fields of a call's [input], in the order the call gave them: a
/// string keeps its line breaks (not `\n` in quotes), a command is a
/// command, the two halves of an edit are the text taken out and the text
/// put in, and what is nested is written as JSON.  An input that is only a
/// string is one field with no name.
List<ToolField> toolFields(Object? input) {
  if (input == null) return const [];
  if (input is String) {
    return input.trim().isEmpty
        ? const []
        : [ToolField('', input, ToolFieldStyle.code)];
  }
  if (input is! Map) {
    return [ToolField('', prettyJson(input), ToolFieldStyle.code)];
  }
  final fields = <ToolField>[];
  for (final entry in asMap(input).entries) {
    final name = entry.key;
    final value = entry.value;
    if (value == null) continue;
    if (value is String) {
      if (value.isEmpty) continue;
      final style = switch (name) {
        'command' => ToolFieldStyle.command,
        'old_string' => ToolFieldStyle.removed,
        'new_string' => ToolFieldStyle.added,
        _ when _proseKeys.contains(name) => ToolFieldStyle.prose,
        _ when _codeKeys.contains(name) => ToolFieldStyle.code,
        _ =>
          value.contains('\n') || value.length > 90
              ? ToolFieldStyle.code
              : ToolFieldStyle.scalar,
      };
      fields.add(ToolField(name, value, style));
    } else if (value is num || value is bool) {
      fields.add(ToolField(name, '$value', ToolFieldStyle.scalar));
    } else if (value is List &&
        value.isNotEmpty &&
        value.every((item) => item is String || item is num || item is bool)) {
      final joined = value.join(', ');
      fields.add(
        ToolField(
          name,
          joined,
          joined.length > 90 ? ToolFieldStyle.code : ToolFieldStyle.scalar,
        ),
      );
    } else if (value is List && value.isEmpty ||
        value is Map && value.isEmpty) {
      continue;
    } else {
      fields.add(ToolField(name, prettyJson(value), ToolFieldStyle.code));
    }
  }
  return fields;
}

/// A call's input as text to copy: the value itself when it is the only
/// one, else every field after its name, the lines of a long one under it.
String inputAsText(List<ToolField> fields) {
  if (fields.isEmpty) return '';
  if (fields.length == 1) return fields.first.text;
  return fields
      .map(
        (field) => field.name.isEmpty
            ? field.text
            : field.text.contains('\n')
            ? '${field.name}:\n${field.text}'
            : '${field.name}: ${field.text}',
      )
      .join('\n');
}

final _complaint = RegExp(
  r'error|exception|fail|denied|refused|forbidden|not found|no such|'
  r'cannot|can.t|unable|invalid|undefined|unexpected|timed out|outside',
  caseSensitive: false,
);

/// The words of the line under a failed call's title: the first line that
/// says what went wrong (a tool prints a banner before its error), else its
/// first line; nothing when it said nothing.
String errorPreview(ToolView tool, {int max = 160}) {
  final lines = outputOf(tool).text
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList();
  if (lines.isEmpty) return '';
  final line = lines.firstWhere(_complaint.hasMatch, orElse: () => lines.first);
  return line.length <= max ? line : '${line.substring(0, max - 1)}…';
}

/// One piece of the evidence a task's work was handed in with.
class EvidenceItem {
  const EvidenceItem({
    required this.kind,
    this.caption,
    this.path,
    this.text,
    this.language,
    this.reference,
    this.title,
    this.input,
    this.output,
    this.isError = false,
  });

  /// `image`, `video`, `file`, `code`, `note` or `tool-call`.
  final String kind;
  final String? caption;

  /// Where an image, a video or a file is, on the harness's machine.
  final String? path;

  /// A note's text, or a code block's code.
  final String? text;
  final String? language;

  /// How the call was named, `bash#2`, for a call quoted by reference.
  final String? reference;

  /// What a quoted call was, what it was given and what it said, as it was
  /// when the work was handed in.
  final String? title;
  final String? input;
  final String? output;
  final bool isError;

  bool get isMedia => kind == 'image' || kind == 'video' || kind == 'file';

  /// The words that stand for the item in a list.
  String get label {
    final said = caption?.trim();
    if (said != null && said.isNotEmpty) return said;
    return switch (kind) {
      'note' => truncateLine(text ?? ''),
      'tool-call' => title ?? reference ?? 'Tool call',
      'code' => 'Code',
      _ => path == null ? kind : baseName(path!),
    };
  }

  /// An item as the report has it (a `kind`, and what the harness resolved:
  /// the file, the call as it was), or as the call asked for it (exactly one
  /// of `image`, `video`, `file`, `code`, `note`, `tool_call`).
  static EvidenceItem? fromWire(Object? wire) {
    if (wire is String) {
      return wire.trim().isEmpty
          ? null
          : EvidenceItem(kind: 'note', text: wire.trim());
    }
    final item = asMap(wire);
    if (item.isEmpty) return null;
    final caption = asString(item['caption']);
    final kind = asString(item['kind']);
    if (kind != null) {
      return switch (kind) {
        'tool-call' => EvidenceItem(
          kind: kind,
          caption: caption,
          title: asString(item['title']),
          reference: asString(item['tool']),
          input: _jsonText(item['input']),
          output: asString(item['output']),
          isError: asBool(item['is-error'] ?? item['isError']),
        ),
        'code' => EvidenceItem(
          kind: kind,
          caption: caption,
          text: asString(item['code']),
          language: asString(item['language']),
        ),
        'note' => EvidenceItem(
          kind: kind,
          caption: caption,
          text: asString(item['text'] ?? item['note']),
        ),
        _ => EvidenceItem(
          kind: kind,
          caption: caption,
          path: asString(item['path']),
        ),
      };
    }
    for (final media in const ['image', 'video', 'file']) {
      if (item[media] != null) {
        return EvidenceItem(
          kind: media,
          caption: caption,
          path: asString(item[media]),
        );
      }
    }
    if (item['code'] != null) {
      return EvidenceItem(
        kind: 'code',
        caption: caption,
        text: asString(item['code']),
        language: asString(item['language']),
      );
    }
    if (item['note'] != null) {
      return EvidenceItem(
        kind: 'note',
        caption: caption,
        text: asString(item['note']),
      );
    }
    if (item['tool_call'] != null) {
      return EvidenceItem(
        kind: 'tool-call',
        caption: caption,
        reference: asString(item['tool_call']),
      );
    }
    return null;
  }

  static String? _jsonText(Object? value) {
    if (value == null) return null;
    if (value is String) {
      // The harness keeps the input of a quoted call as JSON text, cut short
      // when it was long: show it as it reads when it parses.
      try {
        return prettyJson(jsonDecode(value));
      } catch (_) {
        return value;
      }
    }
    return prettyJson(value);
  }
}

/// A line's worth of [text]: its first non-empty line, cut.
String truncateLine(String text, {int max = 90}) {
  final first = text
      .split('\n')
      .map((line) => line.trim())
      .firstWhere((line) => line.isNotEmpty, orElse: () => '');
  return first.length <= max ? first : '${first.substring(0, max - 1)}…';
}

/// What a `hand_in` call handed in: why, what was done, how to see it, and
/// the evidence.  It is the report on the call's result when the harness
/// kept one there (it has resolved the evidence by then), else what the
/// call asked for.
class HandInReport {
  const HandInReport({
    required this.problem,
    required this.summary,
    this.reproduction,
    this.evidence = const [],
    this.cannotContinue = false,
    this.noMerge = false,
  });

  final String problem;
  final String summary;
  final String? reproduction;
  final List<EvidenceItem> evidence;
  final bool cannotContinue;
  final bool noMerge;

  /// Whether there is anything of it to show.
  bool get isEmpty =>
      problem.isEmpty &&
      summary.isEmpty &&
      (reproduction ?? '').isEmpty &&
      evidence.isEmpty;

  /// The report of [tool], when it is a `hand_in` call that went through.
  static HandInReport? of(ToolView tool) {
    if (baseToolName(tool.tool) != 'hand_in') return null;
    final resolved = asMap(tool.meta['report']);
    final input = asMap(tool.input);
    final from = resolved.isNotEmpty ? resolved : input;
    if (from.isEmpty) return null;
    // The flags are on the report when it is resolved (the harness writes
    // its keys in kebab case), in the call's input when it asked for them.
    bool flag(String snake) {
      final kebab = snake.replaceAll('_', '-');
      final camel = snake.replaceAllMapped(
        RegExp(r'_([a-z])'),
        (match) => match[1]!.toUpperCase(),
      );
      return asBool(
        from[kebab] ??
            from[camel] ??
            from[snake] ??
            input[snake] ??
            input[kebab] ??
            input[camel],
      );
    }

    final report = HandInReport(
      problem: asStringOr(from['problem'], '').trim(),
      summary: asStringOr(from['summary'], '').trim(),
      reproduction: asString(from['reproduction'])?.trim(),
      evidence: [
        for (final item in asList(from['evidence']))
          if (EvidenceItem.fromWire(item) case final EvidenceItem found) found,
      ],
      cannotContinue: flag('cannot_continue'),
      noMerge: flag('no_merge'),
    );
    return report.isEmpty ? null : report;
  }
}
