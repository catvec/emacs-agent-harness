import 'dart:async';

import '../acp/acp_client.dart';
import '../acp/acp_message.dart';
import '../acp/capabilities.dart';
import '../models/picture.dart';
import '../models/quota.dart';
import '../models/server_info.dart';
import '../models/session.dart';
import '../models/task.dart';
import '../models/tool_catalogue.dart';
import '../models/usage.dart';

class SessionPage {
  const SessionPage(this.sessions, this.nextCursor);
  final List<SessionSummary> sessions;
  final String? nextCursor;
}

/// Typed access to standard ACP and to the harness's `_harness/*` methods.
///
/// A view asks [can] before it offers an enhancement.  If a method still
/// turns out to be missing (an older harness, a disabled module), the name
/// is remembered as unavailable and announced on [degraded], so the UI can
/// hide that one feature instead of surfacing a scary error.
class HarnessApi {
  HarnessApi(AcpClient client, this.capabilities) : _client = client {
    _follow(client);
  }

  AcpClient _client;
  HarnessCapabilities capabilities;
  final Set<String> _unavailable = <String>{};

  /// The tools of this connection's harness, asked for once ([toolCatalogue]);
  /// [_catalogueGeneration] tells an answer that came late that it is stale.
  Future<ToolCatalogue>? _catalogue;
  int _catalogueGeneration = 0;
  final _degraded = StreamController<String>.broadcast();
  final _notifications = StreamController<AcpNotification>.broadcast();
  StreamSubscription<AcpNotification>? _following;

  /// The connection this talks over now.  It changes when the app connects
  /// again after losing the connection ([rebind]), which is why what holds
  /// on to an api (a session, the task board) must not hold on to this.
  AcpClient get client => _client;

  Stream<String> get degraded => _degraded.stream;

  /// What the agent sends, over this connection and the ones that follow
  /// it: a listener stays subscribed when the connection is replaced.
  Stream<AcpNotification> get notifications => _notifications.stream;

  void updateCapabilities(HarnessCapabilities next) {
    capabilities = next;
    _unavailable.clear();
    // It may be another harness, or the same one with other modules.
    forgetTools();
  }

  /// Set while the app is getting a lost connection back.  A request made
  /// then waits for the new connection, for up to [reconnectGrace], instead
  /// of failing on the dead one: what a person asks for in that moment
  /// happens a moment late, rather than not at all.
  bool reconnecting = false;
  Duration reconnectGrace = const Duration(seconds: 10);
  Completer<void>? _back;

  /// Talk over [client] from now on, a new connection to the same harness
  /// after the old one was lost.  What the harness can do is read again
  /// ([capabilities], from the new `initialize`): it may have been
  /// restarted with other modules, and a method that was missing may be
  /// there now.
  void rebind(AcpClient client, HarnessCapabilities capabilities) {
    _following?.cancel();
    _client = client;
    updateCapabilities(capabilities);
    _follow(client);
    reconnecting = false;
    final waiting = _back;
    _back = null;
    if (waiting != null && !waiting.isCompleted) waiting.complete();
  }

  Future<Object?> _request(
    String method, [
    Map<String, Object?>? params,
    Duration? timeout,
  ]) async {
    if (reconnecting && client.isClosed) {
      final back = _back ??= Completer<void>();
      await back.future.timeout(reconnectGrace, onTimeout: () {});
    }
    return client.request(method, params, timeout);
  }

  void _follow(AcpClient client) {
    _following = client.notifications.listen((notification) {
      // A harness that was reloaded may have other tools.  They are forgotten
      // before anyone hears of the reload, so whoever asks for them in
      // answer to it gets the new ones.
      if (notification.method == '_harness/event' &&
          notification.params['event'] == 'harness/reloaded') {
        forgetTools();
      }
      if (!_notifications.isClosed) _notifications.add(notification);
    });
  }

  /// Stop following the connection and end the streams.
  void dispose() {
    _following?.cancel();
    _following = null;
    reconnecting = false;
    final waiting = _back;
    _back = null;
    if (waiting != null && !waiting.isCompleted) waiting.complete();
    unawaited(_notifications.close());
    unawaited(_degraded.close());
  }

  bool can(String method) =>
      capabilities.has(method) && !_unavailable.contains(method);

  Future<JsonMap> extension(
    String method, [
    Map<String, Object?>? params,
    Duration? timeout,
  ]) async {
    if (_unavailable.contains(method)) {
      throw AcpException(-32601, '_harness/$method is unavailable.');
    }
    try {
      final result = await _request('_harness/$method', params, timeout);
      return asMap(result);
    } on AcpException catch (error) {
      if (error.isMethodNotFound) {
        _unavailable.add(method);
        if (!_degraded.isClosed) _degraded.add(method);
      }
      rethrow;
    }
  }

  Future<Object?> extensionRaw(
    String method, [
    Map<String, Object?>? params,
    Duration? timeout,
  ]) async {
    if (_unavailable.contains(method)) {
      throw AcpException(-32601, '_harness/$method is unavailable.');
    }
    try {
      return await _request('_harness/$method', params, timeout);
    } on AcpException catch (error) {
      if (error.isMethodNotFound) {
        _unavailable.add(method);
        if (!_degraded.isClosed) _degraded.add(method);
      }
      rethrow;
    }
  }

  /// Standard `session/list`, with the harness's paging cursor.
  Future<SessionPage> listSessions({String? cwd, String? cursor}) async {
    try {
      final result = asMap(
        await _request('session/list', {
          if (cwd != null && cwd.isNotEmpty) 'cwd': cwd,
          if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
        }),
      );
      return SessionPage([
        for (final info in asMapList(result['sessions']))
          SessionSummary.fromAcpInfo(info),
      ], asString(result['nextCursor']));
    } on AcpException catch (error) {
      if (!error.isMethodNotFound && !error.isInvalidParams) rethrow;
      // Older agents may not serve ACP's session/list; the harness's own
      // method lists everything in one page.
      if (!can('session/list')) rethrow;
      final sessions = asMapList(
        await extensionRaw('session/list', {
          'filter': {if (cwd != null && cwd.isNotEmpty) 'project': cwd},
        }),
      );
      return SessionPage([
        for (final wire in sessions) SessionSummary.fromWire(wire),
      ], null);
    }
  }

  Future<JsonMap> newSession({
    required String cwd,
    String? name,
    String? model,
  }) async {
    final result = await _request('session/new', {
      'cwd': cwd,
      'mcpServers': const <Object?>[],
      if (capabilities.isHarness)
        '_harness': {
          if (name != null && name.isNotEmpty) 'name': name,
          if (model != null && model.isNotEmpty) 'model': model,
        },
    });
    return asMap(result);
  }

  Future<JsonMap> loadSession(String sessionId, {String? cwd}) async {
    final result = await _request('session/load', {
      'sessionId': sessionId,
      if (cwd != null && cwd.isNotEmpty) 'cwd': cwd,
      'mcpServers': const <Object?>[],
    });
    return asMap(result);
  }

  Future<JsonMap> prompt(
    String sessionId,
    List<Map<String, Object?>> blocks,
  ) async {
    final result = await _request('session/prompt', {
      'sessionId': sessionId,
      'prompt': blocks,
    }, Duration.zero);
    return asMap(result);
  }

  Future<void> cancel(String sessionId) =>
      client.notify('session/cancel', {'sessionId': sessionId});

  Future<void> setMode(String sessionId, String mode) =>
      _request('session/set_mode', {'sessionId': sessionId, 'modeId': mode});

  Future<void> setModel(String sessionId, String model) =>
      _request('session/set_model', {'sessionId': sessionId, 'modelId': model});

  Future<JsonMap> sessionGet(String sessionId) =>
      extension('session/get', {'id': sessionId});

  Future<JsonMap?> agentActivity(String sessionId) async {
    if (!can('agent/activity')) return null;
    final value = await extensionRaw('agent/activity', {
      'session-id': sessionId,
    });
    if (value is Map) return asMap(value);
    return null;
  }

  Future<List<JsonMap>> sessionNodes(
    String sessionId, {
    int? limit,
    String? before,
  }) async {
    final result = await extensionRaw('session/nodes', {
      'id': sessionId,
      if (limit != null) 'limit': limit,
      if (before != null) 'before': before,
    });
    return asMapList(result);
  }

  Future<JsonMap> renameSession(String sessionId, String name) =>
      extension('session/update', {'id': sessionId, 'name': name});

  Future<JsonMap> forkSession(String sessionId, {String? name}) => extension(
    'session/fork',
    {'id': sessionId, if (name != null) 'name': name},
  );

  /// Turns non-interactive mode on or off for one session.
  Future<JsonMap> setNonInteractive(String sessionId, bool on) =>
      extension('session/update', {'id': sessionId, 'non-interactive': on});

  /// Turns non-interactive mode on or off for every current session and task,
  /// and makes it the default for new ones.
  Future<void> setNonInteractiveEverywhere(bool on) async {
    await extension('session/set-all', {
      'settings': {'non-interactive': on},
      'filter': {'active': true, 'tasks': true},
    });
    if (can('task/set-all')) {
      try {
        await extension('task/set-all', {
          'settings': {'non-interactive': on},
        });
      } on AcpException {
        // Without task mode there are sessions only.
      }
    }
    if (can('config/set')) {
      await extension('config/set', {
        'key': 'harness-non-interactive',
        'value': on ? 't' : 'nil',
        'printed': true,
        'scope': 'global',
      });
    }
  }

  /// Whether new sessions start non-interactive, or null when unknown.
  Future<bool?> defaultNonInteractive(String cwd) async {
    if (!can('config/describe')) return null;
    final described = await configDescribe(cwd);
    for (final setting in asMapList(described['settings'])) {
      if (asString(setting['key']) == 'harness-non-interactive') {
        final value = asString(setting['value']);
        return value == null ? null : value != 'nil';
      }
    }
    return null;
  }

  Future<void> deleteSession(String sessionId) =>
      extension('session/delete', {'id': sessionId});

  Future<void> setPriority(String sessionId, String priority) => extension(
    'priority/set',
    {'session-id': sessionId, 'priority': priority},
  );

  // ---- Tasks -------------------------------------------------------------

  Future<List<HarnessTask>> tasks({String? cwd}) async {
    final result = await extensionRaw('task/list', {
      if (cwd != null && cwd.isNotEmpty) 'cwd': cwd,
    });
    return [for (final wire in asMapList(result)) HarnessTask.fromWire(wire)];
  }

  Future<HarnessTask> task(String id) async =>
      HarnessTask.fromWire(await extension('task/get', {'id': id}));

  /// The task [sessionId] is the session of, or null for a session that is
  /// no task's (`task/for-session` answers nothing for it).
  Future<HarnessTask?> taskOfSession(String sessionId) async {
    final wire = await extension('task/for-session', {'session-id': sessionId});
    final task = HarnessTask.fromWire(wire);
    return task.id.isEmpty ? null : task;
  }

  Future<HarnessTask> submitTask({
    required String cwd,
    required String prompt,
    String? priority,
    bool refine = false,
    bool plan = false,
    bool mainTree = false,
    String? model,
    String? thinking,
    String? permissionMode,
    List<Map<String, Object?>> attachments = const [],
  }) async {
    final result = await extension('task/submit', {
      'cwd': cwd,
      'prompt': prompt,
      'opts': {
        // Pictures sent as data, which the harness keeps as files of the
        // task's own (see `PromptAttachment.toTaskAttachment`).
        if (attachments.isNotEmpty) 'attachments': attachments,
        if (priority != null) 'priority': priority,
        if (refine) 'refine': true,
        if (plan) 'plan': true,
        if (mainTree) 'main-tree': true,
        if (model != null && model.isNotEmpty) 'model': model,
        if (thinking != null && thinking.isNotEmpty) 'thinking': thinking,
        if (permissionMode != null && permissionMode.isNotEmpty)
          'permission-mode': permissionMode,
      },
    });
    return HarnessTask.fromWire(result);
  }

  // The actions on a task.  The harness checks the state of the task each
  // one is given, and answers with an error where it does not apply (an
  // [AcpException], whose message is the harness's own); the app offers what
  // applies (see `TaskActions`) and says what the harness says of the rest.

  Future<HarnessTask> startTask(String id) async =>
      HarnessTask.fromWire(await extension('task/start', {'id': id}));

  Future<HarnessTask> queueTask(String id) async =>
      HarnessTask.fromWire(await extension('task/queue', {'id': id}));

  Future<HarnessTask> verifyTask(String id) async =>
      HarnessTask.fromWire(await extension('task/verify', {'id': id}));

  Future<HarnessTask> rejectTask(String id, String feedback) async =>
      HarnessTask.fromWire(
        await extension('task/reject', {'id': id, 'feedback': feedback}),
      );

  /// Write [text] to the session of task [id] (`task/prompt`): the harness
  /// answers `true`, not the task.
  Future<void> promptTask(String id, String text) async {
    await extensionRaw('task/prompt', {'id': id, 'text': text});
  }

  Future<HarnessTask> retryTask(String id) async =>
      HarnessTask.fromWire(await extension('task/retry', {'id': id}));

  /// Send the branch of task [id] through the merge queue again, after a
  /// merge that failed (`task/merge`).
  Future<HarnessTask> mergeTask(String id) async =>
      HarnessTask.fromWire(await extension('task/merge', {'id': id}));

  /// Stop task [id], or drop it when it never started (`task/cancel`): the
  /// harness answers `true`, or nothing for a task it took off the board.
  Future<void> cancelTask(String id) async {
    await extensionRaw('task/cancel', {'id': id});
  }

  /// Put task [id] back in the pending queue and hold it there (`task/pause`).
  Future<HarnessTask> pauseTask(String id) async =>
      HarnessTask.fromWire(await extension('task/pause', {'id': id}));

  /// End the pause of task [id] (`task/resume`).
  Future<HarnessTask> resumeTask(String id) async =>
      HarnessTask.fromWire(await extension('task/resume', {'id': id}));

  /// Stop task [id] and put it back in the pending queue, where it starts
  /// again when its turn comes (`task/return-to-pending`).
  Future<HarnessTask> returnTaskToPending(String id) async =>
      HarnessTask.fromWire(
        await extension('task/return-to-pending', {'id': id}),
      );

  Future<HarnessTask> completeTask(String id) async =>
      HarnessTask.fromWire(await extension('task/complete', {'id': id}));

  /// Archive task [id], or bring it back when [restore] is set.  The flag is
  /// sent only when it is true: the harness takes an explicit false for set.
  Future<HarnessTask> archiveTask(String id, {bool restore = false}) async =>
      HarnessTask.fromWire(
        await extension('task/archive', {
          'id': id,
          if (restore) 'restore': true,
        }),
      );

  /// Forget task [id] (`task/delete`), and its session too when
  /// [deleteSession] is set; a task that never started takes its session
  /// along either way.  The worktree, if any, is kept.
  Future<void> deleteTask(String id, {bool deleteSession = false}) async {
    await extensionRaw('task/delete', {
      'id': id,
      if (deleteSession) 'delete-session': true,
    });
  }

  // A task's priority is its session's: `setPriority` above gives it.

  Future<TaskSlots> taskSlots({String? cwd}) async => TaskSlots.fromWire(
    await extension('task/slots', {
      if (cwd != null && cwd.isNotEmpty) 'cwd': cwd,
    }),
  );

  Future<TaskSettingsInfo> taskSettings({String? cwd}) async =>
      TaskSettingsInfo.fromWire(
        await extension('task/settings', {
          if (cwd != null && cwd.isNotEmpty) 'cwd': cwd,
        }),
      );

  // The queue of a project.  Each takes the project: without one the harness
  // would act on the project of its own working directory, which a person
  // never meant.

  /// Suspend the pending queue of the project [cwd]: none of its waiting
  /// tasks starts on its own until it is resumed (`task/suspend-queue`).
  /// A task at work goes on, and an explicit start still starts a task.
  Future<void> suspendQueue({required String cwd}) =>
      extensionRaw('task/suspend-queue', {'cwd': cwd});

  /// Let the waiting tasks of [cwd] start again, at once, by priority
  /// (`task/resume-queue`).
  Future<void> resumeQueue({required String cwd}) =>
      extensionRaw('task/resume-queue', {'cwd': cwd});

  /// Put the backlog of [cwd] in [mode], `auto` or `manual`: in auto mode a
  /// task whose write-up finishes joins the queue by itself
  /// (`task/set-backlog-mode`).  It moves no task that is waiting.
  Future<void> setBacklogMode(String mode, {required String cwd}) =>
      extensionRaw('task/set-backlog-mode', {'mode': mode, 'cwd': cwd});

  /// Suspend the queue of [cwd] if it runs, else resume it
  /// (`task/toggle-queue`): for a harness that has no way to set it.
  Future<void> toggleTaskQueue({required String cwd}) =>
      extensionRaw('task/toggle-queue', {'cwd': cwd});

  /// Switch the backlog of [cwd] between manual and auto queueing
  /// (`task/toggle-backlog-mode`): for a harness that has no way to set it.
  Future<void> toggleBacklogMode({required String cwd}) =>
      extensionRaw('task/toggle-backlog-mode', {'cwd': cwd});

  /// Pause every task of the project [cwd], of every project without it
  /// (`task/pause-all`): those at work, and those waiting for a slot.  The
  /// ids of the tasks paused.
  Future<List<String>> pauseAllTasks({String? cwd}) async => _ids(
    await extensionRaw('task/pause-all', {
      if (cwd != null && cwd.isNotEmpty) 'cwd': cwd,
    }),
  );

  /// End the pause of every paused task of [cwd], of every project without
  /// it (`task/resume-all`).  The ids of the tasks resumed.
  Future<List<String>> resumeAllTasks({String? cwd}) async => _ids(
    await extensionRaw('task/resume-all', {
      if (cwd != null && cwd.isNotEmpty) 'cwd': cwd,
    }),
  );

  /// Suspend the queue of every project that has one worth listing
  /// (`task/suspend-all-queues`).  How many queues there were.
  Future<int> suspendAllQueues() async =>
      _projects(await extensionRaw('task/suspend-all-queues'));

  /// Resume every suspended queue (`task/resume-all-queues`).  How many were
  /// suspended.
  Future<int> resumeAllQueues() async =>
      _projects(await extensionRaw('task/resume-all-queues'));

  int _projects(Object? result) => asList(asMap(result)['projects']).length;

  List<String> _ids(Object? result) => [
    for (final id in asList(asMap(result)['ids']))
      if (asString(id) case final text? when text.isNotEmpty) text,
  ];

  // ---- Usage -------------------------------------------------------------

  /// Usage of one directory ([project]), or of all of [projects], which is
  /// how a project and its git worktrees are asked for together.
  Future<UsageAggregate> usageTotals({
    String? project,
    List<String>? projects,
  }) async => UsageAggregate.fromWire(
    await extension('usage/totals', {
      if (project != null && project.isNotEmpty) 'project': project,
      if (projects != null && projects.isNotEmpty) 'projects': projects,
    }),
  );

  Future<List<UsageAggregate>> usageSummary({
    required String groupBy,
    String? project,
    List<String>? projects,
  }) async {
    final result = await extensionRaw('usage/summary', {
      'group-by': groupBy,
      if (project != null && project.isNotEmpty) 'project': project,
      if (projects != null && projects.isNotEmpty) 'projects': projects,
    });
    return [for (final row in asMapList(result)) UsageAggregate.fromWire(row)];
  }

  Future<List<LiveUsage>> usageLive() async {
    final result = await extensionRaw('usage/live-all');
    return [for (final row in asMapList(result)) LiveUsage.fromWire(row)];
  }

  Future<List<OutputRate>> usageRates() async {
    final result = await extensionRaw('usage/rates');
    return [for (final row in asMapList(result)) OutputRate.fromWire(row)];
  }

  Future<List<JsonMap>> budgets() async =>
      asMapList(await extensionRaw('usage/budgets'));

  /// How [provider] bills its calls and, for a plan, how much of its quota
  /// is used (`provider/quota`).  Null for a provider that says nothing.
  /// [refresh] has the provider ask its source again first, which can take
  /// a few seconds; it makes no model call.
  Future<ProviderQuota?> providerQuota(
    String provider, {
    bool refresh = false,
  }) async {
    final result = await extensionRaw('provider/quota', {
      'providerId': provider,
      'refresh': refresh,
    }, const Duration(seconds: 30));
    if (result is! Map || result.isEmpty) return null;
    return ProviderQuota.fromWire(provider, asMap(result));
  }

  // ---- Projects, providers, server ---------------------------------------

  /// The directories of the harness's sessions and tasks, as it names their
  /// projects: main checkouts.  An older harness lists a git worktree or a
  /// scratch directory of an agent's among them, as it lists what a task
  /// was made in, so the app folds these like any other directory (see
  /// `ProjectRoots`).
  Future<List<String>> projects() async {
    if (!can('insights/projects')) return const [];
    final result = await extensionRaw('insights/projects');
    return [for (final item in asList(result)) asStringOr(item, '')]
      ..removeWhere((item) => item.isEmpty);
  }

  /// The main checkout each of [directories] belongs to, as the harness
  /// finds it on disk (`project/mains`): a git worktree, wherever it was
  /// made, belongs to the checkout it was made from, and the work in a
  /// scratch directory of an agent's to the project of its session.  A
  /// directory no project's work is in, such as a scratch directory whose
  /// session is gone, is answered with ''.  Directories the harness gives
  /// no answer for are left out; a harness without the method answers none.
  Future<Map<String, String>> mainProjects(List<String> directories) async {
    if (directories.isEmpty || !can('project/mains')) return const {};
    // It reads no more than a few files for each directory, and the app
    // waits for it to show its projects: a harness that does not answer soon
    // is as good as one without it, the paths say what they can.
    final result = await extensionRaw('project/mains', {
      'roots': directories,
    }, const Duration(seconds: 10));
    final found = <String, String>{};
    for (final row in asMapList(result)) {
      final root = asString(row['root']);
      final main = asString(row['main']);
      if (root != null && root.isNotEmpty && main != null) found[root] = main;
    }
    return found;
  }

  Future<List<ProviderInfo>> providers() async {
    final list = asMapList(await extensionRaw('provider/list'));
    return [for (final wire in list) ProviderInfo.fromWire(wire)];
  }

  Future<List<ModelInfo>> models() async {
    final result = await extensionRaw(
      'provider/models',
      null,
      const Duration(seconds: 20),
    );
    final list = asList(result);
    return [
      for (final item in list)
        if (item is Map)
          ModelInfo.fromWire(asMap(item))
        else if (item is String && item.isNotEmpty)
          ModelInfo(id: item, name: item),
    ];
  }

  Future<HarnessVersion> version() async =>
      HarnessVersion.fromWire(await extension('harness/version'));

  Future<List<HarnessModule>> modules() async {
    final result = await extensionRaw('harness/modules');
    return [
      for (final item in asMapList(result))
        if (asString(item['name'] ?? item['module']) != null)
          HarnessModule.fromWire(item),
    ];
  }

  Future<JsonMap> configDescribe(String cwd) =>
      extension('config/describe', {'cwd': cwd});

  Future<List<JsonMap>> permissionPending(String sessionId) async {
    if (!can('permission/pending')) return const [];
    return asMapList(
      await extensionRaw('permission/pending', {'session-id': sessionId}),
    );
  }

  Future<List<JsonMap>> questionPending(String sessionId) async {
    if (!can('question/pending')) return const [];
    return asMapList(
      await extensionRaw('question/pending', {'session-id': sessionId}),
    );
  }

  Future<JsonMap> questionImage(
    String sessionId,
    String requestId,
    int index,
  ) => extension('question/image', {
    'session-id': sessionId,
    'pid': requestId,
    'index': index,
  });

  /// The picture [path], a file of the harness's machine that session
  /// [sessionId]'s transcript shows (`session/image`): a screenshot a task
  /// handed in, or an image `read_file` read.  The transcript names it by
  /// its path, which only the harness can open, so the harness reads it.
  /// It answers only for a file the transcript shows, and only for a
  /// picture; the [AcpException] it fails with says why in words for a
  /// person (the file is gone, it is too large).  A picture can be large
  /// and the connection a phone's, so the wait is longer than a request's.
  Future<Picture> sessionImage(String sessionId, String path) async {
    final result = await extension('session/image', {
      'id': sessionId,
      'path': path,
    }, const Duration(seconds: 90));
    return Picture.fromWire(result);
  }

  Future<void> permissionAnswer(
    String sessionId,
    String pendingId,
    String optionId, {
    String? pattern,
  }) async {
    final parts = optionId.split('-');
    final behavior = parts.first == 'allow' ? 'allow' : 'deny';
    final scope = parts.length > 1 ? parts[1] : 'once';
    await extension('permission/answer', {
      'session-id': sessionId,
      'pending-id': pendingId,
      'answer': {
        'behavior': behavior,
        'scope': scope,
        if (pattern != null) 'pattern': pattern,
      },
    });
  }

  Future<void> answerQuestion(
    String sessionId,
    String requestId,
    String answer, {
    List<Map<String, Object?>> attachments = const [],
  }) async {
    await extension('question/answer', {
      'session-id': sessionId,
      'pid': requestId,
      'answer': {
        'answer': answer,
        if (attachments.isNotEmpty) 'attachments': attachments,
      },
    });
  }

  // ---- Tools -------------------------------------------------------------

  /// Every tool of the harness: what people call it, and whether its calls
  /// fold into a run in the transcript (the allow list, `coalescable`).
  ///
  /// All the tools, not those one session is offered: a transcript can hold
  /// calls of a tool that session no longer has, and they read by their
  /// labels and fold like the rest.  It is asked for once for this connection
  /// and kept: a harness that is reloaded (`harness/reloaded`) or reached
  /// again after a lost connection ([rebind]) may have other tools, and is
  /// asked again.  A harness without the method, or that fails to answer, has
  /// [ToolCatalogue.empty]: no call folds.  A failure is not kept, so that
  /// the next ask tries again.
  Future<ToolCatalogue> toolCatalogue({bool refresh = false}) {
    if (!can('tools/list')) return Future.value(ToolCatalogue.empty);
    final kept = _catalogue;
    if (kept != null && !refresh) return kept;
    final generation = ++_catalogueGeneration;
    final fetch = _fetchCatalogue(generation);
    _catalogue = fetch;
    return fetch;
  }

  Future<ToolCatalogue> _fetchCatalogue(int generation) async {
    try {
      // A short wait: the conversation opens on it, and one without a
      // catalogue still opens, with nothing folded.
      return ToolCatalogue.fromWire(
        await extensionRaw('tools/list', null, const Duration(seconds: 10)),
      );
    } catch (_) {
      if (generation == _catalogueGeneration) _catalogue = null;
      return ToolCatalogue.empty;
    }
  }

  /// Ask for the tools again the next time they are needed.
  void forgetTools() {
    _catalogue = null;
    _catalogueGeneration++;
  }
}
