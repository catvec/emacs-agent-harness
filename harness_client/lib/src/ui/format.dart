import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../acp/acp_message.dart';
import '../models/project_roots.dart';

String relativeTime(DateTime? time) {
  if (time == null) return '';
  final now = DateTime.now();
  final difference = now.difference(time);
  if (difference.isNegative) return 'just now';
  if (difference.inSeconds < 45) return 'just now';
  if (difference.inMinutes < 60) return '${difference.inMinutes}m';
  if (difference.inHours < 24) return '${difference.inHours}h';
  if (difference.inDays == 1) return 'yesterday';
  if (difference.inDays < 7) return '${difference.inDays}d';
  if (now.year == time.year) return DateFormat.MMMd().format(time);
  return DateFormat.yMMMd().format(time);
}

String shortAddress(String? uri) {
  if (uri == null) return '';
  return uri
      .replaceFirst(RegExp(r'^wss?://'), '')
      .replaceFirst(RegExp(r'/acp/?$'), '');
}

/// The name of the project at [path].  A git worktree of the harness
/// (`PROJECT/.worktrees/BRANCH`) is named for its project, not for itself.
String projectName(String? path) {
  if (path == null || path.isEmpty) return 'No project';
  path = worktreeOwner(path) ?? path;
  final parts = path.split('/').where((part) => part.isNotEmpty).toList();
  if (parts.isEmpty) return path;
  if (parts.length >= 2 && parts.last == '.git') return parts[parts.length - 2];
  return parts.last;
}

String modelName(String? model) {
  if (model == null || model.isEmpty) return 'Default model';
  final colon = model.indexOf(':');
  if (colon < 0) return model;
  return model.substring(colon + 1);
}

String providerName(String? model) {
  if (model == null || model.isEmpty) return '';
  final colon = model.indexOf(':');
  return colon < 0 ? '' : model.substring(0, colon);
}

String statusLabel(String? status) => switch (status) {
  'running' => 'Running',
  'blocked' => 'Needs you',
  'idle' => 'Idle',
  'inactive' => 'Closed',
  null => 'Unknown',
  _ => status,
};

String kindLabel(String? kind) => switch (kind) {
  'main' => 'Session',
  'fork' => 'Fork',
  'btw' => 'Side chat',
  'subagent' => 'Subagent',
  'internal' => 'Internal',
  null => 'Session',
  _ => kind,
};

String permissionLabel(String? mode) => switch (mode) {
  'ask' => 'Ask',
  'accept-edits' => 'Accept edits',
  'auto' => 'Auto',
  'yolo' => 'YOLO',
  null => 'Ask',
  _ => mode,
};

String toolKindIconLabel(String? kind) => switch (kind) {
  'read' => 'Read',
  'edit' => 'Edit',
  'delete' => 'Delete',
  'move' => 'Move',
  'search' => 'Search',
  'execute' => 'Command',
  'fetch' => 'Fetch',
  'think' => 'Think',
  'meta' => 'Meta',
  _ => 'Tool',
};

Color parseHexColor(String? value, Color fallback) {
  if (value == null) return fallback;
  final hex = value.replaceFirst('#', '');
  final parsed = int.tryParse(hex, radix: 16);
  if (parsed == null) return fallback;
  return Color(hex.length <= 6 ? 0xFF000000 | parsed : parsed);
}

String truncate(String text, int max) {
  final singleLine = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  return singleLine.length <= max
      ? singleLine
      : '${singleLine.substring(0, max - 1)}…';
}

/// What a compaction note says about itself, in a line.  It is what the Emacs
/// chat's header for the note says, so the same note reads the same in both:
/// that the conversation was compacted, how (a brief summary, and who wrote
/// it; a transcript file; a fresh start; the oldest of it cut away; a handoff
/// to a model of another provider) and, for the notes that were made for a
/// reason of their own, why then: the prompt cache was cold or about to
/// lapse, or the turn outgrew its context window.  [node] is the node the
/// harness recorded (its `meta` says how); without one it is just "Context
/// compacted".
String compactionTitle(JsonMap? node) {
  final meta = asMap(node?['meta']);
  final handoff = asMap(meta['handoff']);
  // A compaction from before there were kinds is a summary; one whose
  // context was a sample of the conversation is a brief one.
  final kind =
      asString(meta['compaction']) ??
      (asString(meta['context']) == 'sample' ? 'brief' : null);
  final model = (asString(meta['model']) ?? '').trim();
  final how = handoff.isNotEmpty
      ? ' to hand over to ${modelName(asString(handoff['to']))}'
      : switch (kind) {
          'brief' =>
            model.isEmpty
                ? ' into a brief summary'
                : ' into a brief summary by ${modelName(model)}',
          'transcript' => ' into a transcript file',
          'fresh' => ' to start afresh',
          'truncate' => ' by cutting its oldest context away',
          _ => '',
        };
  final why = asMap(meta['cowboy']).isNotEmpty
      ? ', the prompt cache being cold'
      : asMap(meta['precompact']).isNotEmpty
      ? ', before the prompt cache lapsed'
      : asBool(meta['mid-turn'] ?? meta['midTurn'])
      ? ', in the middle of a turn'
      : '';
  return 'Context compacted$how$why';
}

/// How many words [text] has, as a count: "1,438 words", "1 word".
String wordCount(String text) {
  final words = RegExp(r'\S+').allMatches(text).length;
  return '${NumberFormat.decimalPattern().format(words)} '
      'word${words == 1 ? '' : 's'}';
}

/// A system note (a hint) of more than this many lines is long.
const longNoteLines = 5;

/// A system note of more characters than this is long, however it breaks.
const longNoteCharacters = 400;

/// Whether [text], the words of a system note, is long enough to be cut to its
/// first lines until the person asks for the rest.  Most notes are a line or
/// two ("non-interactive on", "Handed in for review") and are always shown
/// whole; the ones that are not are the list of what the tool slots did while
/// the machine was busy, and an error that carries what the provider said.
bool isLongNote(String text) {
  final trimmed = text.trim();
  return trimmed.length > longNoteCharacters ||
      '\n'.allMatches(trimmed).length + 1 > longNoteLines;
}

// The syntax `markdownPreview` takes off.  Block syntax is read a line at a
// time; inline syntax inside a line, after the code spans and the escaped
// characters in it are put aside (they are meant as they stand).
final _newline = RegExp(r'\r\n|\r|\n');
final _fence = RegExp(r'^\s{0,3}(?:`{3,}|~{3,})');
final _rule = RegExp(r'^\s{0,3}([-*_])(?:\s*\1){2,}\s*$');
final _setext = RegExp(r'^\s{0,3}=+\s*$');
final _tableRule = RegExp(r'^\s*\|?\s*:?-+:?\s*(?:\|\s*:?-+:?\s*)+\|?\s*$');
final _quote = RegExp(r'^\s{0,3}(?:>\s?)+');
final _heading = RegExp(r'^\s{0,3}#{1,6}(?:\s+|$)');
final _closingHashes = RegExp(r'\s+#+\s*$');
final _pipe = RegExp(r'\s*\|\s*');
final _bullet = RegExp(r'^\s*(?:[-*+]|\d{1,9}[.)])\s+(?:\[[ xX]\]\s+)?');
final _escape = RegExp(r'\\([\\`*_{}\[\]()#+\-.!|>~<])');
final _codeSpan = RegExp(r'(`+)(.+?)\1');
final _htmlComment = RegExp(r'<!--.*?-->');
final _htmlTag = RegExp(
  r'</?(?:br|hr|p|b|i|u|s|em|strong|code|pre|a|img|span|div|ul|ol|li|h[1-6]|'
  r'details|summary|blockquote|table|thead|tbody|tr|th|td|sub|sup|kbd|del|ins|'
  r'mark|small|center)\b[^>]*>',
  caseSensitive: false,
);
const _target = r'\((?:[^()]|\([^()]*\))*\)';
final _image = RegExp('!\\[([^\\]]*)\\]$_target');
final _link = RegExp('\\[([^\\]]*)\\]$_target');
final _referenceLink = RegExp(r'\[([^\]]+)\]\[[^\]]*\]');
final _autolink = RegExp(r'<((?:https?|mailto|harness):[^>\s]+)>');
final _strong = RegExp(r'(\*\*|__)(\S(?:.*?\S)?)\1');
final _emphasisStar = RegExp(r'\*(\S(?:.*?\S)?)\*');
final _emphasisUnderscore = RegExp(
  r'(^|[^A-Za-z0-9_])_(\S(?:.*?\S)?)_(?![A-Za-z0-9_])',
);
final _strike = RegExp(r'~~(\S(?:.*?\S)?)~~');
final _setAside = RegExp('\uE100(\\d+)\uE101');
final _escaped = RegExp('[\uE000-\uE07F]');
const _entities = {
  '&nbsp;': ' ',
  '&amp;': '&',
  '&lt;': '<',
  '&gt;': '>',
  '&quot;': '"',
  '&#39;': "'",
};

/// The words of [text], which is Markdown, as one line of at most [max]
/// characters: what a row of a list shows of something a person is to read in
/// full elsewhere (the report a task was handed in with).  A row cannot draw a
/// heading or a list, and the characters Markdown is typed with -- `##`, `**`,
/// backticks, the address of a link -- are noise there, so they go: a heading,
/// a list item or a table cell is its words, a link is its text, a code block
/// is its code.  Words that only look like syntax (`snake_case`, `2 * 3`,
/// `List<String>`) stay as they are.  The blocks -- a heading, a paragraph, an
/// item of a list -- are told apart by a dot between them, the lines of a
/// paragraph run on.
String markdownPreview(String text, {int max = 140}) {
  final blocks = <String>[];
  // Whether the next line of prose goes on with the block before it: the
  // line of a paragraph, or of an item of a list, that is not a block of its
  // own.
  var running = false;
  var fenced = false;
  var length = 0;

  // A [block] of its own, or a line more of the one before when [running]; a
  // heading or a row is [closed]: nothing goes on with it.
  void add(String words, {required bool block, bool closed = false}) {
    words = words.trim();
    if (words.isNotEmpty) {
      if (running && !block && blocks.isNotEmpty) {
        blocks.last = '${blocks.last} $words';
      } else {
        blocks.add(words);
      }
      length += words.length;
    }
    if (closed) {
      running = false;
    } else if (words.isNotEmpty) {
      running = true;
    }
  }

  for (var line in text.split(_newline)) {
    // Enough to cut a line out of: the rest of a long report is not read.
    if (length > max * 2) break;
    if (_fence.hasMatch(line)) {
      fenced = !fenced;
      running = false;
      continue;
    }
    if (fenced) {
      add(line, block: true, closed: true);
      continue;
    }
    // A blank line, a rule and the line under a title end what came before.
    if (line.trim().isEmpty ||
        _rule.hasMatch(line) ||
        _setext.hasMatch(line) ||
        _tableRule.hasMatch(line)) {
      running = false;
      continue;
    }
    line = line.replaceFirst(_quote, '');
    final heading = _heading.firstMatch(line);
    if (heading != null) {
      final words = line
          .substring(heading.end)
          .replaceFirst(_closingHashes, '');
      add(_inlineWords(words), block: true, closed: true);
      continue;
    }
    final item = _bullet.hasMatch(line);
    if (item) line = line.replaceFirst(_bullet, '');
    // The cells of a table row.
    final row =
        line.contains('|') &&
        (line.trimLeft().startsWith('|') ||
            line.trimRight().endsWith('|') ||
            line.contains(' | '));
    if (row) line = line.replaceAll(_pipe, ' ');
    add(_inlineWords(line), block: item || row, closed: row);
  }
  return truncate(blocks.join(' · '), max);
}

/// [line] without its inline syntax.
String _inlineWords(String line) {
  // What is meant as it stands is put aside: an escaped character becomes a
  // character of the private use area (U+E000 plus its code), a code span a
  // marker with its number; both come back at the end.
  final spans = <String>[];
  var text = line
      .replaceAllMapped(
        _escape,
        (match) => String.fromCharCode(0xE000 + match[1]!.codeUnitAt(0)),
      )
      .replaceAllMapped(_codeSpan, (match) {
        spans.add(match[2]!.trim());
        return '\uE100${spans.length - 1}\uE101';
      });
  text = text
      .replaceAll(_htmlComment, ' ')
      .replaceAllMapped(_autolink, (match) => match[1]!)
      .replaceAll(_htmlTag, ' ')
      .replaceAllMapped(_image, (match) => match[1]!)
      .replaceAllMapped(_link, (match) => match[1]!)
      .replaceAllMapped(_referenceLink, (match) => match[1]!)
      .replaceAllMapped(_strong, (match) => match[2]!)
      .replaceAllMapped(_emphasisStar, (match) => match[1]!)
      .replaceAllMapped(
        _emphasisUnderscore,
        (match) => '${match[1]}${match[2]}',
      )
      .replaceAllMapped(_strike, (match) => match[1]!);
  for (final entity in _entities.entries) {
    text = text.replaceAll(entity.key, entity.value);
  }
  return text
      .replaceAllMapped(_setAside, (match) => spans[int.parse(match[1]!)])
      .replaceAllMapped(
        _escaped,
        (match) => String.fromCharCode(match[0]!.codeUnitAt(0) - 0xE000),
      );
}
