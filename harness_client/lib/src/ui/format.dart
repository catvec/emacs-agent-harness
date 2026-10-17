import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

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

String projectName(String? path) {
  if (path == null || path.isEmpty) return 'No project';
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
