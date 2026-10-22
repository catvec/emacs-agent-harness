import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../acp/acp_client.dart';
import '../acp/acp_message.dart';
import '../models/activity.dart';
import '../models/session.dart';
import '../models/transcript.dart';
import '../services/harness_api.dart';
import 'drafts.dart';
import 'interaction.dart';
import 'prompt_attachment.dart';

/// One open conversation.  It listens to the ACP stream for its own session,
/// keeps the transcript in sync with both standard updates and the harness's
/// richer node updates, and owns the interactions the agent blocks on.
class SessionController extends ChangeNotifier {
  SessionController({
    required this.api,
    required this.sessionId,
    this.summary,
    this.drafts,
  }) {
    // The api's own stream, not the connection's: the connection is replaced
    // when the app connects again, and this goes on listening.
    _subscription = api.notifications.listen(_onNotification);
  }

  final HarnessApi api;
  final String sessionId;

  /// Where the unsent text of this conversation's composer is kept, when
  /// the app keeps it (see [DraftStore]): a message that turns out not to
  /// have been sent goes back there.
  final DraftStore? drafts;
  SessionSummary? summary;
  final TranscriptState transcript = TranscriptState();
  TurnActivity? activity;
  String? error;
  bool loading = true;
  bool promptInFlight = false;
  bool cancelling = false;
  bool deleted = false;
  final List<InteractionRequest> interactions = <InteractionRequest>[];
  StreamSubscription<AcpNotification>? _subscription;
  bool _opened = false;
  bool _disposed = false;

  /// Set when the connection was lost and replaced: the transcript may be
  /// behind what the harness has, so the next [open] reads it again.
  bool _stale = false;

  InteractionRequest? get currentInteraction =>
      interactions.isEmpty ? null : interactions.first;

  bool get needsAttention =>
      interactions.isNotEmpty || summary?.isBlocked == true;

  bool get isRunning => promptInFlight || summary?.isRunning == true;

  /// Whether a message can go out now: there is a connection to take it.
  /// While there is none the composer keeps what was typed.
  bool get canSend => !api.client.isClosed;

  /// The connection this session talked over is gone.  What the agent asked
  /// on it (a permission, a question) can no longer be answered there; the
  /// harness still holds it as pending and offers it again to the next
  /// connection ([open] finds it).  What was read of the session may be
  /// behind by then, so the next [open] reads it again.
  ///
  /// Call this after the connection is closed: the answers that complete
  /// the requests below are then dropped, and never reach the harness as a
  /// refusal nobody gave.
  void connectionLost() {
    _stale = true;
    final gone = [
      for (final request in interactions)
        if (!request.synthetic) request,
    ];
    if (gone.isEmpty) return;
    for (final request in gone) {
      interactions.remove(request);
      if (request.isPermission) {
        request.completer?.complete(request.cancelledPermissionResult());
      } else if (request.isQuestion) {
        request.completer?.complete(request.questionResult('', const []));
      }
    }
    activity = null;
    _notify();
  }

  Future<void> open({bool force = false}) async {
    if (_opened && !force && !_stale) {
      await refreshInfo();
      return;
    }
    _opened = true;
    loading = true;
    error = null;
    _notify();
    try {
      // ACP's session/load resumes the session and replays the transcript.
      await api.loadSession(sessionId, cwd: summary?.cwd);
      // Read again: what a lost connection may have left behind is made up
      // for.  (One lost from here on marks it stale again.)
      _stale = false;
      if (api.capabilities.richNodes) {
        try {
          final info = await api.sessionGet(sessionId);
          summary = SessionSummary.fromWire(info);
        } catch (_) {
          // Keep the summary from the list; the replay is still usable.
        }
        try {
          final nodes = await api.sessionNodes(sessionId, limit: 400);
          if (nodes.isNotEmpty) {
            transcript.reset();
            for (final node in nodes) {
              transcript.applyNode(node);
            }
          }
        } catch (_) {
          // Rich nodes are an enhancement; the standard replay stands.
        }
      }
      await refreshInfo();
      transcript.finish();
      _syncPlan();
      promptInFlight = summary?.isRunning == true;
      activity = null;
      if (promptInFlight) {
        unawaited(_refreshActivity());
      }
      await _synthesizePending();
    } on AcpException catch (failure) {
      error = _friendlyError(failure);
    } catch (failure) {
      error = '$failure';
    } finally {
      loading = false;
      _notify();
    }
  }

  void clearError() {
    error = null;
    _notify();
  }

  Future<void> refreshInfo() async {
    if (!api.capabilities.richNodes) return;
    try {
      final info = await api.sessionGet(sessionId);
      summary = SessionSummary.fromWire(info);
      _syncPlan();
      _notify();
    } catch (_) {
      // Not fatal: the transcript is still live.
    }
  }

  Future<void> _refreshActivity() async {
    if (!api.capabilities.activity) return;
    try {
      final wire = await api.agentActivity(sessionId);
      activity = wire == null || wire.isEmpty
          ? null
          : TurnActivity.fromWire(wire);
      _notify();
    } catch (_) {
      // Activity is an enhancement.
    }
  }

  void _syncPlan() {
    final todos = summary?.todos ?? const <TodoItem>[];
    if (todos.isEmpty) return;
    transcript.plan
      ..clear()
      ..addAll([
        for (final todo in todos)
          PlanEntry(content: todo.text, status: todo.status),
      ]);
  }

  Future<void> send(
    String text, {
    List<PromptAttachment> attachments = const [],
  }) async {
    final trimmed = text.trim();
    if ((trimmed.isEmpty && attachments.isEmpty) || promptInFlight) return;
    if (!canSend) {
      // The composer does not offer to send while there is no connection;
      // this is for a caller that does not ask.  Nothing is echoed that
      // never left.
      error = 'Not connected to the harness: the message was not sent.';
      _notify();
      return;
    }
    error = null;
    promptInFlight = true;
    cancelling = false;
    final echo = transcript.addLocalUser(
      trimmed.isEmpty ? '(${attachments.length} images)' : trimmed,
    );
    _notify();
    final blocks = <Map<String, Object?>>[
      if (trimmed.isNotEmpty) textBlock(trimmed),
      for (final attachment in attachments) attachment.toBlock(),
    ];
    try {
      final result = await api.prompt(sessionId, blocks);
      final stop = asString(result['stopReason']);
      if (stop == 'refusal' || stop == 'max_tokens') {
        error = switch (stop) {
          'max_tokens' => 'The turn stopped at the model’s output limit.',
          _ => 'The agent refused the prompt.',
        };
      }
      final details = asMap(result['_harness']);
      final reason = asString(details['reason']);
      if (reason != null && reason != 'end-turn' && reason != 'cancelled') {
        error = 'The turn ended: $reason';
      }
    } on AcpException catch (failure) {
      if (failure.isTransport) {
        _interrupted(echo, trimmed, attachments.length);
      } else {
        error = _friendlyError(failure);
      }
    } catch (failure) {
      error = '$failure';
    } finally {
      promptInFlight = false;
      cancelling = false;
      transcript.finish();
      _notify();
      unawaited(refreshInfo());
      unawaited(_refreshActivity());
    }
  }

  /// The connection went while a message was on its way.  The app connects
  /// again by itself and reads the conversation again, which shows what the
  /// harness has; what matters here is a message it does not have, which
  /// must not be lost with the connection.  The harness echoes a message as
  /// soon as it takes it, so one that was never echoed ([echo] still local)
  /// never got there: it goes back to the composer.  One that was echoed is
  /// the harness's, and its turn goes on there.
  void _interrupted(TranscriptItem echo, String text, int images) {
    if (!echo.localEcho) return;
    transcript.removeLocalEcho(echo);
    if (text.isNotEmpty) {
      drafts?.putBack(DraftStore.composerKey(sessionId), text);
    }
    error = text.isNotEmpty
        ? 'The connection was lost before this was sent. It is back in the box.'
        : 'The connection was lost before the images were sent.';
  }

  Future<void> cancel() async {
    if (!promptInFlight && summary?.isRunning != true) return;
    cancelling = true;
    _notify();
    try {
      await api.cancel(sessionId);
    } catch (failure) {
      error = '$failure';
      cancelling = false;
      _notify();
    }
  }

  Future<void> setMode(String mode) async {
    try {
      await api.setMode(sessionId, mode);
      await refreshInfo();
    } on AcpException catch (failure) {
      error = _friendlyError(failure);
      _notify();
    }
  }

  Future<void> setNonInteractive(bool on) async {
    try {
      final updated = await api.setNonInteractive(sessionId, on);
      summary = SessionSummary.fromWire(
        updated,
      ).merge(summary ?? SessionSummary(id: sessionId));
      // A JSON false may be left out of the reply: say what was asked.
      summary = summary!.withNonInteractive(on);
      _notify();
    } on AcpException catch (failure) {
      error = _friendlyError(failure);
      _notify();
    }
  }

  Future<void> setModel(String model) async {
    try {
      await api.setModel(sessionId, model);
      await refreshInfo();
    } on AcpException catch (failure) {
      error = _friendlyError(failure);
      _notify();
    }
  }

  Future<void> rename(String name) async {
    try {
      final updated = await api.renameSession(sessionId, name);
      summary = SessionSummary.fromWire(updated)
          .merge(summary ?? SessionSummary(id: sessionId));
      _notify();
    } on AcpException catch (failure) {
      error = _friendlyError(failure);
      _notify();
    }
  }

  Future<String?> fork() async {
    try {
      final forked = await api.forkSession(sessionId);
      return asString(forked['id']);
    } on AcpException catch (failure) {
      error = _friendlyError(failure);
      _notify();
      return null;
    }
  }

  Future<bool> deleteSession() async {
    try {
      await api.deleteSession(sessionId);
      deleted = true;
      _notify();
      return true;
    } on AcpException catch (failure) {
      error = _friendlyError(failure);
      _notify();
      return false;
    }
  }

  Future<void> setPriority(String priority) async {
    try {
      await api.setPriority(sessionId, priority);
      await refreshInfo();
    } on AcpException catch (failure) {
      error = _friendlyError(failure);
      _notify();
    }
  }

  /// Called by [AppController] when a JSON-RPC request arrives for us.
  Future<Object?> handleAgentRequest(String method, JsonMap params) {
    final request = InteractionRequest(
      method: method,
      params: params,
      sessionId: sessionId,
      completer: Completer<Object?>(),
    );
    interactions.add(request);
    activity = const TurnActivity(phase: 'checking');
    _notify();
    return request.completer!.future;
  }

  /// Recover requests that were already waiting when this client connected.
  Future<void> _synthesizePending() async {
    final pending = summary?.pending ?? const <PendingRequest>[];
    if (pending.isEmpty || interactions.isNotEmpty) return;
    final permissions = await api
        .permissionPending(sessionId)
        .catchError((_) => <JsonMap>[]);
    final questions = await api
        .questionPending(sessionId)
        .catchError((_) => <JsonMap>[]);
    for (final item in permissions) {
      interactions.add(_syntheticPermission(item));
    }
    for (final item in questions) {
      interactions.add(_syntheticQuestion(item));
    }
    if (interactions.isNotEmpty) _notify();
  }

  InteractionRequest _syntheticPermission(JsonMap item) {
    final id = asStringOr(item['id'], '');
    final payload = asMap(item['payload']);
    final offered = asList(payload['options'])
        .map((o) => asStringOr(o, ''))
        .toSet();
    final defaults = <JsonMap>[
      {'optionId': 'allow-once', 'name': 'Allow', 'kind': 'allow_once'},
      {
        'optionId': 'allow-session',
        'name': 'Allow for session',
        'kind': 'allow_always',
      },
      {
        'optionId': 'allow-always',
        'name': 'Always allow',
        'kind': 'allow_always',
      },
      {'optionId': 'deny-once', 'name': 'Deny', 'kind': 'reject_once'},
      {
        'optionId': 'deny-always',
        'name': 'Always deny',
        'kind': 'reject_always',
      },
    ];
    return InteractionRequest(
      method: 'session/request_permission',
      sessionId: sessionId,
      synthetic: true,
      pendingId: id,
      params: {
        'sessionId': sessionId,
        'toolCall': {
          'toolCallId': payload['call-id'] ?? id,
          'title': payload['title'] ?? payload['tool'] ?? 'Tool call',
          'kind': payload['kind'],
          'rawInput': payload['input'],
        },
        'options': offered.isEmpty
            ? defaults
            : defaults
                  .where((option) => offered.contains(option['optionId']))
                  .toList(),
        '_harness': {
          'pendingId': id,
          'tool': payload['tool'],
          'paths': payload['paths'],
          'cwd': payload['cwd'],
          'dir': payload['dir'],
          'pattern': payload['pattern'],
          'commands': payload['commands'],
          'covers': payload['covers'],
          'reason': payload['reason'],
        },
      },
    );
  }

  InteractionRequest _syntheticQuestion(JsonMap item) {
    final id = asStringOr(item['id'], '');
    final payload = asMap(item['payload']);
    return InteractionRequest(
      method: '_harness/ask_user',
      sessionId: sessionId,
      synthetic: true,
      pendingId: id,
      params: {
        'sessionId': sessionId,
        'requestId': id,
        'question': payload['question'],
        'options': payload['options'],
        'diagrams': payload['diagrams'],
        'cowboy': payload['cowboy'],
      },
    );
  }

  Future<void> answerPermission(String optionId, {String? pattern}) async {
    final request = _firstOf(isPermission: true);
    if (request == null) return;
    interactions.remove(request);
    activity = null;
    _notify();
    try {
      if (request.synthetic) {
        await api.permissionAnswer(
          sessionId,
          request.pendingId!,
          optionId,
          pattern: pattern,
        );
      } else {
        request.completer?.complete(
          request.permissionResult(optionId, pattern: pattern),
        );
      }
    } on AcpException catch (failure) {
      error = _friendlyError(failure);
      _notify();
    }
    unawaited(refreshInfo());
  }

  Future<void> dismissPermission() async {
    final request = _firstOf(isPermission: true);
    if (request == null) return;
    interactions.remove(request);
    activity = null;
    _notify();
    if (request.synthetic) {
      try {
        await api.permissionAnswer(sessionId, request.pendingId!, 'deny-once');
      } catch (_) {}
    } else {
      request.completer?.complete(request.cancelledPermissionResult());
    }
    unawaited(refreshInfo());
  }

  Future<void> answerQuestion(
    String answer, {
    List<Map<String, Object?>> attachments = const [],
  }) async {
    final request = _firstOf(isQuestion: true);
    if (request == null) return;
    interactions.remove(request);
    activity = null;
    _notify();
    try {
      if (request.synthetic) {
        await api.answerQuestion(
          sessionId,
          request.pendingId!,
          answer,
          attachments: attachments,
        );
      } else {
        request.completer?.complete(
          request.questionResult(answer, attachments),
        );
      }
    } on AcpException catch (failure) {
      error = _friendlyError(failure);
      _notify();
    }
    unawaited(refreshInfo());
  }

  Future<void> cancelQuestion() async {
    final request = _firstOf(isQuestion: true);
    if (request == null) return;
    interactions.remove(request);
    activity = null;
    _notify();
    if (request.synthetic &&
        request.pendingId != null &&
        api.can('question/cancel')) {
      try {
        await api.extension('question/cancel', {
          'session-id': sessionId,
          'pid': request.pendingId,
        });
      } catch (_) {}
    } else {
      request.completer?.complete(request.questionResult('', const []));
    }
    unawaited(refreshInfo());
  }

  Future<Uint8List?> questionImage(int index) async {
    final request = currentInteraction;
    if (request == null || !request.isQuestion) return null;
    final id = request.questionId ?? request.pendingId;
    if (id == null) return null;
    if (!api.can('question/image')) return null;
    try {
      final result = await api.questionImage(sessionId, id, index);
      final data = asString(result['data']);
      if (data == null) return null;
      return base64Decode(data);
    } catch (_) {
      return null;
    }
  }

  InteractionRequest? _firstOf({
    bool isPermission = false,
    bool isQuestion = false,
  }) {
    for (final request in interactions) {
      if (isPermission && request.isPermission) return request;
      if (isQuestion && request.isQuestion) return request;
    }
    return null;
  }

  void _onNotification(AcpNotification notification) {
    if (notification.method == 'session/update') {
      final sid = asString(notification.params['sessionId']);
      if (sid != sessionId) return;
      final update = asMap(notification.params['update']);
      final kind = asString(update['sessionUpdate']);
      switch (kind) {
        case '_harness/session':
          final session = asMap(update['session']);
          if (session.isNotEmpty) {
            summary = summary == null
                ? SessionSummary.fromWire(session)
                : SessionSummary.fromWire(session).merge(summary!);
            _syncPlan();
          }
        case '_harness/activity':
          final raw = update['activity'];
          activity = raw is Map && asMap(raw).isNotEmpty
              ? TurnActivity.fromWire(asMap(raw))
              : null;
        case '_harness/session_deleted':
          deleted = true;
        case 'current_mode_update':
          unawaited(refreshInfo());
        default:
          transcript.apply(update);
      }
      _notify();
      return;
    }
    if (notification.method == '_harness/event') {
      _onEvent(
        asStringOr(notification.params['event'], ''),
        asList(notification.params['args']),
      );
    }
  }

  void _onEvent(String event, List<Object?> args) {
    final sid = args.isNotEmpty ? asString(args[0]) : null;
    if (sid != null && sid != sessionId) return;
    switch (event) {
      case 'agent/turn-started':
        promptInFlight = true;
        _notify();
      case 'agent/turn-ended':
        promptInFlight = false;
        cancelling = false;
        activity = null;
        transcript.finish();
        _notify();
        unawaited(refreshInfo());
      case 'session/status':
      case 'session/pending-changed':
      case 'session/queue-changed':
        unawaited(refreshInfo());
      case 'session/deleted':
        deleted = true;
        _notify();
      case 'agent/activity-changed':
        unawaited(_refreshActivity());
      case 'session/nodes-removed':
        unawaited(open(force: true));
    }
  }

  String _friendlyError(AcpException failure) {
    if (failure.isAuthRequired) {
      return 'This harness needs authentication. Reconnect with its token.';
    }
    if (failure.isMethodNotFound) {
      return 'This server does not support that operation.';
    }
    return failure.message;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final request in interactions) {
      if (request.synthetic) continue;
      if (request.isPermission) {
        request.completer?.complete(request.cancelledPermissionResult());
      } else if (request.isQuestion) {
        request.completer?.complete(request.questionResult('', const []));
      }
    }
    interactions.clear();
    _subscription?.cancel();
    super.dispose();
  }
}
