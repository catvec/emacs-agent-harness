import 'dart:async';

import '../acp/acp_message.dart';

class PermissionOption {
  const PermissionOption({
    required this.id,
    required this.name,
    required this.kind,
  });

  final String id;
  final String name;
  final String kind;

  bool get isAllow => id.startsWith('allow');
  bool get isAlways => id.endsWith('always') || id.endsWith('session');
}

/// One request the agent is blocking on: a permission decision or an
/// `ask_user` question.  [synthetic] requests are the ones the harness was
/// already waiting on when this client connected; they are answered through
/// `_harness/permission/answer` or `question/answer`, not by replying to a
/// JSON-RPC request this client never received.
class InteractionRequest {
  InteractionRequest({
    required this.method,
    required this.params,
    required this.sessionId,
    this.completer,
    this.synthetic = false,
    this.pendingId,
  }) : createdAt = DateTime.now();

  final String method;
  final JsonMap params;
  final String sessionId;
  final Completer<Object?>? completer;
  final bool synthetic;
  final String? pendingId;
  final DateTime createdAt;

  bool get isPermission =>
      method == 'session/request_permission' ||
      method.endsWith('request_permission');
  bool get isQuestion =>
      method == '_harness/ask_user' || method.endsWith('ask_user');

  JsonMap get toolCall => asMap(params['toolCall']);
  JsonMap get harness => asMap(params['_harness']);

  /// The call a permission request is about: its `toolCallId` is the
  /// `call-id` of the call in the transcript.  Null for a question.
  String? get toolCallId =>
      isPermission ? asString(toolCall['toolCallId']) : null;

  /// The id the harness holds this request by, as pending on its session:
  /// the one the request came with, or was recovered by.  What says whether
  /// the harness still waits for it, and whether two requests are the same.
  String? get harnessId {
    final id = pendingId ?? (isQuestion ? questionId : null) ??
        asString(harness['pendingId']);
    return id == null || id.isEmpty ? null : id;
  }

  String get title {
    if (isQuestion) {
      final question = asString(params['question']);
      if (question != null && question.trim().isNotEmpty) {
        return question.trim();
      }
      return 'The agent has a question';
    }
    final title = asString(toolCall['title']);
    if (title != null && title.trim().isNotEmpty) return title.trim();
    final tool = asString(harness['tool']);
    if (tool != null) return tool;
    return 'Permission requested';
  }

  String? get subtitle {
    if (isQuestion) return null;
    final kind = asString(toolCall['kind']);
    final reason = asString(harness['reason']);
    final paths = asList(harness['paths'])
        .map((p) => asStringOr(p, ''))
        .where((p) => p.isNotEmpty)
        .toList();
    final cwd = asString(harness['cwd']);
    final showCwd =
        cwd != null &&
        cwd.isNotEmpty &&
        !paths.any((path) => path == cwd || path.startsWith(cwd));
    final parts = <String>[
      if (kind != null) kind,
      if (paths.isNotEmpty) paths.join(', '),
      if (showCwd) 'in $cwd',
      if (reason != null && reason.trim().isNotEmpty) reason,
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  Object? get input => toolCall['rawInput'];

  List<PermissionOption> get options => [
    for (final option in asMapList(params['options']))
      PermissionOption(
        id: asStringOr(option['optionId'], ''),
        name: asStringOr(option['name'], asStringOr(option['optionId'], '')),
        kind: asStringOr(option['kind'], ''),
      ),
  ]..removeWhere((option) => option.id.isEmpty);

  List<String> get questionOptions =>
      [for (final option in asList(params['options'])) asStringOr(option, '')]
        ..removeWhere((option) => option.isEmpty);

  List<JsonMap> get diagrams => asMapList(params['diagrams']);

  String? get questionId => asString(params['requestId']);

  JsonMap get cowboy => asMap(params['cowboy']);

  /// The result to send back for a normal JSON-RPC request.
  JsonMap permissionResult(String optionId, {String? pattern}) => {
    'outcome': {'outcome': 'selected', 'optionId': optionId},
    if (pattern != null && pattern.trim().isNotEmpty)
      '_harness': {'pattern': pattern},
  };

  JsonMap cancelledPermissionResult() => {
    'outcome': {'outcome': 'cancelled'},
  };

  JsonMap questionResult(String answer, List<JsonMap> attachments) => {
    'answer': answer,
    if (attachments.isNotEmpty) 'attachments': attachments,
  };
}
