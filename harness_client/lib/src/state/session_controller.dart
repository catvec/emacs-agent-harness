import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../acp/acp_client.dart';
import '../acp/acp_message.dart';
import '../models/activity.dart';
import '../models/session.dart';
import '../models/tool_catalogue.dart';
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

  /// The harness's tools: what people call them, and the allow list of the
  /// calls that fold into a run in the transcript.  Empty until the harness
  /// has answered (and for one that does not say), when nothing folds.
  ToolCatalogue tools = ToolCatalogue.empty;
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

  /// The calls of the transcript that wait for the person to allow them: a
  /// summary line must not fold them away while the session is blocked on
  /// them.
  Set<String> get waitingCalls => {
    for (final request in interactions)
      if (request.toolCallId case final String id when id.isNotEmpty) id,
  };

  /// Whether the harness waits for the person on this conversation: a
  /// request is shown, or the session is blocked.  A closed session waits
  /// for nobody.
  bool get needsAttention =>
      summary?.isInactive != true &&
      (interactions.isNotEmpty || summary?.isBlocked == true);

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
      // What the harness's tools are first, so that the transcript replays
      // into the runs it folds and not into cards that fold a moment later.
      await _loadTools();
      // ACP's session/load resumes the session and replays the transcript.
      await api.loadSession(sessionId, cwd: summary?.cwd);
      // Read again: what a lost connection may have left behind is made up
      // for.  (One lost from here on marks it stale again.)
      _stale = false;
      if (api.capabilities.richNodes) {
        try {
          final info = await api.sessionGet(sessionId);
          adopt(SessionSummary.fromWire(info));
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
      // The messages the turn has not taken are no node of the transcript:
      // the session says which they are.
      transcript.syncPending(_held(summary?.steering));
      transcript.finish();
      _syncPlan();
      promptInFlight = summary?.isRunning == true;
      activity = null;
      if (promptInFlight) {
        unawaited(_refreshActivity());
      }
      await _syncPending();
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
      adopt(SessionSummary.fromWire(info));
    } catch (_) {
      // Not fatal: the transcript is still live.
    }
  }

  /// Take [record], the harness's own record of this session as it stands
  /// (`session/get`, or its entry in `session/list`), as what is known of
  /// it, in place of what was.
  ///
  /// What the harness waits on is in it, and the requests recovered from the
  /// harness ([InteractionRequest.synthetic]) are shown only while it does:
  /// one it no longer lists was answered somewhere else, or belonged to a
  /// turn that ended, or to a session that was closed, and goes.  That is
  /// what keeps a conversation nobody has open honest: the events that
  /// would have told of it are not sent again to a phone that was out of
  /// reach when they were.  A request asked of this client is the harness's
  /// reply to wait for, and is only ever dropped by the harness telling so
  /// ([_dropUnheld]): a record read while it was being asked may not list
  /// it yet.
  ///
  /// With [unlessOlder], a record the harness changed before the one this
  /// holds is let go: a listing of all the sessions that was asked for
  /// before an event is heard may arrive after the conversation read its own
  /// session because of it, and the older word must not undo the newer.
  void adopt(SessionSummary record, {bool unlessOlder = false}) {
    if (_disposed) return;
    final known = summary?.updatedAt;
    final read = record.updatedAt;
    if (unlessOlder && known != null && read != null && read.isBefore(known)) {
      return;
    }
    summary = record;
    _syncPlan();
    _dropRecovered(record);
    _notify();
  }

  /// Drop the recovered requests [record] does not list as pending; all of
  /// them for a closed session.  Whether any went.
  bool _dropRecovered(SessionSummary record) {
    // A record with no word of what is pending (a plain ACP listing) does
    // not say that nothing is.
    if (!record.says('pending') && !record.isInactive) return false;
    final held = record.isInactive
        ? const <String>{}
        : {for (final request in record.pending) request.id};
    var dropped = false;
    for (final request in List.of(interactions)) {
      final id = request.harnessId;
      if (!request.synthetic || id == null || held.contains(id)) continue;
      interactions.remove(request);
      dropped = true;
    }
    if (dropped) activity = null;
    return dropped;
  }

  /// The messages the harness holds for the running turn, as the transcript
  /// takes them ([TranscriptState.syncPending]).
  List<({String id, String text, String? sender})> _held(
    List<QueueItem>? steering,
  ) => [
    for (final item in steering ?? const <QueueItem>[])
      (id: item.id, text: item.text, sender: formatSender(item.from)),
  ];

  /// Read the harness's tools (the api keeps them for the connection, so a
  /// second conversation asks nobody).  An empty answer, which a harness that
  /// does not say or one that could not be reached gives, never replaces
  /// tools that are known: the runs a transcript folds into stay as they
  /// were.
  Future<void> _loadTools() async {
    final found = await api.toolCatalogue();
    if (_disposed || found.isEmpty) return;
    tools = found;
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
  /// soon as it takes it -- or, one sent while the agent works, says it holds
  /// it for the turn's next step (`session/steering-changed`) -- so one that
  /// was never echoed ([echo] still local) never got there: it goes back to
  /// the composer.  One that was echoed is the harness's, and its turn goes
  /// on there.
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
      summary = (summary ?? SessionSummary(id: sessionId)).merge(
        SessionSummary.fromWire(updated),
      );
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
      summary = (summary ?? SessionSummary(id: sessionId)).merge(
        SessionSummary.fromWire(updated),
      );
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
    // The harness asked it of this client after [_syncPending] already found
    // it waiting: the one asked takes the other's place.
    final id = request.harnessId;
    final shown = id == null
        ? -1
        : interactions.indexWhere((other) => other.harnessId == id);
    _applyPendingNews(request);
    if (shown >= 0) {
      interactions[shown] = request;
    } else {
      interactions.add(request);
    }
    activity = const TurnActivity(phase: 'checking');
    _notify();
    return request.completer!.future;
  }

  /// How long after the harness says what it waits on this client gives the
  /// request that comes with it, which is asked right after, to arrive
  /// before reading what the harness holds.
  static const _pendingGrace = Duration(milliseconds: 1200);
  Timer? _pendingTimer;

  /// Read what the harness holds as pending soon, once, however many times
  /// it said so.
  void _syncPendingSoon() {
    _pendingTimer?.cancel();
    _pendingTimer = Timer(_pendingGrace, () {
      _pendingTimer = null;
      if (!_disposed) unawaited(_syncPending(force: true));
    });
  }

  /// The requests the harness holds as pending on this session, as
  /// (id, request) pairs, or null when that cannot be read now.
  Future<List<(String, InteractionRequest)>?> _heldRequests() async {
    final canPermissions = api.can('permission/pending');
    final canQuestions = api.can('question/pending');
    if (!canPermissions && !canQuestions) return null;
    try {
      final permissions = canPermissions
          ? await api.permissionPending(sessionId)
          : const <JsonMap>[];
      final questions = canQuestions
          ? await api.questionPending(sessionId)
          : const <JsonMap>[];
      return [
        for (final item in permissions)
          if (asString(item['id']) case final String id when id.isNotEmpty)
            (id, _syntheticPermission(item)),
        for (final item in questions)
          if (asString(item['id']) case final String id when id.isNotEmpty)
            (id, _syntheticQuestion(item)),
      ];
    } catch (_) {
      return null;
    }
  }

  /// Show what the harness waits on this session for, and nothing else.
  ///
  /// The harness asks the connected clients itself, as the request comes
  /// (see [handleAgentRequest]); this is for what it holds without having
  /// asked this client: what was already waiting when this client
  /// connected, what it asked while the connection was out, what it asked
  /// in a way that was not heard.  Such a request is shown from what the
  /// harness holds ([InteractionRequest.synthetic]) and answered through
  /// it.  A synthetic request the harness no longer holds was answered
  /// somewhere else, and goes.  (Not one asked of this client: it was
  /// asked after what was read here may have been written, and the harness
  /// tells when it is answered, see [_dropUnheld].)
  ///
  /// Without [force] nothing is read for a session the harness holds
  /// nothing on, as far as the summary knows.
  Future<void> _syncPending({bool force = false}) async {
    if (!force &&
        (summary?.pending.isEmpty ?? true) &&
        !interactions.any((request) => request.synthetic)) {
      return;
    }
    final read = await _heldRequests();
    if (read == null || _disposed) return;
    // A closed session waits for nobody, whatever the harness still lists
    // on it (one that closed a session with a question pending did).
    final held = summary?.isInactive == true
        ? const <(String, InteractionRequest)>[]
        : read;
    var changed = false;
    for (final request in List.of(interactions)) {
      final id = request.harnessId;
      if (!request.synthetic || id == null) continue;
      if (held.any((item) => item.$1 == id)) continue;
      interactions.remove(request);
      changed = true;
    }
    for (final (id, request) in held) {
      final shown = interactions.where((other) => other.harnessId == id);
      if (shown.isNotEmpty) {
        if (_learnSummaryFrom(shown.first, request)) changed = true;
        continue;
      }
      _applyPendingNews(request);
      interactions.add(request);
      changed = true;
    }
    if (changed) _notify();
  }

  /// Say what is the summary of the request [shown] from [read], the same
  /// request as the harness holds it now, which may know more of it: the
  /// summary of its call, or that there will be none.  It only goes forward:
  /// a summary is not taken back, and a request does not start to wait for
  /// one.  Returns whether [shown] changed.
  bool _learnSummaryFrom(InteractionRequest shown, InteractionRequest read) {
    if (shown.summary == null && read.summary != null) {
      return shown.learnSummary({
        'summary': read.summary,
        'summary-model': read.summaryModel,
        'summarizing': false,
      });
    }
    if (shown.summarizing && !read.summarizing && read.summary == null) {
      return shown.learnSummary({'summarizing': false});
    }
    return false;
  }

  /// What the harness said of a request this client did not hold yet, by the
  /// request's id: the news of its summary can come before the request does
  /// (one read from the harness is as old as the read).  The newest few.
  final Map<String, JsonMap> _pendingNews = <String, JsonMap>{};
  static const _pendingNewsKept = 20;

  /// The harness says the payload of request [id] was added to with
  /// [changes]: the summary of its call came, or will not.  Shown at once
  /// when the request is; kept for it otherwise.
  void _learnPending(String? id, JsonMap changes) {
    if (id == null || id.isEmpty || changes.isEmpty) return;
    var learned = false;
    for (final request in interactions) {
      if (request.harnessId == id && request.learnSummary(changes)) {
        learned = true;
      }
    }
    if (learned) {
      _notify();
      return;
    }
    if (interactions.any((request) => request.harnessId == id)) return;
    _pendingNews.remove(id);
    _pendingNews[id] = changes;
    while (_pendingNews.length > _pendingNewsKept) {
      _pendingNews.remove(_pendingNews.keys.first);
    }
  }

  /// Have [request], new here, learn what the harness said of it before.
  void _applyPendingNews(InteractionRequest request) {
    final id = request.harnessId;
    if (id == null) return;
    final news = _pendingNews.remove(id);
    if (news != null) request.learnSummary(news);
  }

  /// The harness says what it holds as pending on this session now, as a
  /// list of requests (`session/pending-changed`'s second argument): a
  /// request this client was asked, or recovered, that is not in it was
  /// answered somewhere else (in Emacs, by another device, by a rule), and
  /// goes.  The events come in the order of the requests the harness
  /// sends, so what was asked of this client before the event is what the
  /// event is about.
  void _dropUnheld(Object? held) {
    if (held != null && held is! List) return;
    final ids = {
      for (final item in asMapList(held))
        if (asString(item['id']) case final String id) id,
    };
    for (final request in List.of(interactions)) {
      final id = request.harnessId;
      if (id != null && !ids.contains(id)) _drop(request);
    }
  }

  /// [request] is not waited for any more.  What was asked of this client
  /// is answered empty, which the harness takes for nothing, since it knows.
  void _drop(InteractionRequest request) {
    if (!interactions.remove(request)) return;
    activity = null;
    _release(request);
    _notify();
  }

  void _release(InteractionRequest request) {
    final completer = request.completer;
    if (request.synthetic || completer == null || completer.isCompleted) return;
    if (request.isPermission) {
      completer.complete(request.cancelledPermissionResult());
    } else if (request.isQuestion) {
      completer.complete(request.questionResult('', const []));
    }
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
          // A cheap model's summary of the call, or that one is on its way
          // (the harness keeps these in the payload as it asks them).
          'summary': payload['summary'],
          'summaryModel': payload['summary-model'],
          'summarizing': payload['summarizing'],
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
        // Several options may be ticked (`ask_user`'s allow_multiple): the
        // harness holds it in the payload as `allow-multiple`, and asks it
        // of a client as `allowMultiple`.
        'allowMultiple': payload['allow-multiple'],
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
      _putBack(request);
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
      _putBack(request);
    }
    unawaited(refreshInfo());
  }

  /// An answer that did not reach the harness: the request is still waited
  /// on there, so it is still shown, to be answered again.  (An answer to
  /// what was asked of this client is the reply to the request, which has
  /// no way to fail here.)
  void _putBack(InteractionRequest request) {
    if (request.synthetic && !_disposed && !interactions.contains(request)) {
      interactions.insert(0, request);
    }
    _notify();
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
            final record = SessionSummary.fromWire(session);
            summary = summary == null ? record : summary!.merge(record);
            _syncPlan();
            _dropRecovered(summary!);
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
      case 'session/queue-changed':
        unawaited(refreshInfo());
      case 'session/steering-changed':
        // (session id, the messages the running turn has not taken yet): the
        // harness has a message sent while the agent works, and says so as
        // it takes it.  It waits there, last, until the turn reads it.
        transcript.syncPending(
          _held(QueueItem.listFrom(args.length > 1 ? args[1] : null)),
        );
        _notify();
      case 'session/pending-changed':
        // (session id, what is pending now)
        if (args.length > 1) _dropUnheld(args[1]);
        unawaited(refreshInfo());
        _syncPendingSoon();
      case 'session/pending-updated':
        // (session id, the request's id, what was added to its payload): a
        // cheap model's summary of a permission request's call came, or
        // will not.
        if (args.length > 2) _learnPending(asString(args[1]), asMap(args[2]));
      case 'question/answered':
        // (session id, the question's id, the answer): by whoever did.
        final answered = args.length > 1 ? asString(args[1]) : null;
        for (final request in List.of(interactions)) {
          if (answered != null && request.harnessId == answered) {
            _drop(request);
          }
        }
      case 'session/deleted':
        deleted = true;
        _notify();
      case 'agent/activity-changed':
        unawaited(_refreshActivity());
      case 'session/nodes-removed':
        unawaited(open(force: true));
      case 'harness/reloaded':
        // Reloaded code may have other tools, and fold other calls.
        unawaited(_loadTools().then((_) => _notify()));
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
    _pendingTimer?.cancel();
    for (final request in interactions) {
      _release(request);
    }
    interactions.clear();
    _subscription?.cancel();
    super.dispose();
  }
}
