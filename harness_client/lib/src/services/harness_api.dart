import 'dart:async';

import '../acp/acp_client.dart';
import '../acp/acp_message.dart';
import '../acp/capabilities.dart';
import '../models/server_info.dart';
import '../models/session.dart';
import '../models/task.dart';
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
  HarnessApi(this.client, this.capabilities);

  final AcpClient client;
  HarnessCapabilities capabilities;
  final Set<String> _unavailable = <String>{};
  final _degraded = StreamController<String>.broadcast();

  Stream<String> get degraded => _degraded.stream;

  void updateCapabilities(HarnessCapabilities next) {
    capabilities = next;
    _unavailable.clear();
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
      final result = await client.request('_harness/$method', params, timeout);
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
      return await client.request('_harness/$method', params, timeout);
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
        await client.request('session/list', {
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
    final result = await client.request('session/new', {
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
    final result = await client.request('session/load', {
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
    final result = await client.request('session/prompt', {
      'sessionId': sessionId,
      'prompt': blocks,
    }, Duration.zero);
    return asMap(result);
  }

  Future<void> cancel(String sessionId) =>
      client.notify('session/cancel', {'sessionId': sessionId});

  Future<void> setMode(String sessionId, String mode) => client.request(
    'session/set_mode',
    {'sessionId': sessionId, 'modeId': mode},
  );

  Future<void> setModel(String sessionId, String model) => client.request(
    'session/set_model',
    {'sessionId': sessionId, 'modelId': model},
  );

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
  }) async {
    final result = await extension('task/submit', {
      'cwd': cwd,
      'prompt': prompt,
      'opts': {
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

  Future<HarnessTask> promptTask(String id, String text) async =>
      HarnessTask.fromWire(
        await extension('task/prompt', {'id': id, 'text': text}),
      );

  Future<HarnessTask> retryTask(String id) async =>
      HarnessTask.fromWire(await extension('task/retry', {'id': id}));

  Future<HarnessTask> cancelTask(String id) async =>
      HarnessTask.fromWire(await extension('task/cancel', {'id': id}));

  Future<HarnessTask> completeTask(String id) async =>
      HarnessTask.fromWire(await extension('task/complete', {'id': id}));

  Future<HarnessTask> archiveTask(String id, {bool restore = false}) async =>
      HarnessTask.fromWire(
        await extension('task/archive', {
          'id': id,
          if (restore) 'restore': true,
        }),
      );

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

  Future<void> toggleTaskQueue({String? cwd}) => extension(
    'task/toggle-queue',
    {if (cwd != null && cwd.isNotEmpty) 'cwd': cwd},
  );

  Future<void> toggleBacklogMode({String? cwd}) => extension(
    'task/toggle-backlog-mode',
    {if (cwd != null && cwd.isNotEmpty) 'cwd': cwd},
  );

  // ---- Usage -------------------------------------------------------------

  Future<UsageAggregate> usageTotals({String? project}) async =>
      UsageAggregate.fromWire(
        await extension('usage/totals', {
          if (project != null && project.isNotEmpty) 'project': project,
        }),
      );

  Future<List<UsageAggregate>> usageSummary({
    required String groupBy,
    String? project,
  }) async {
    final result = await extensionRaw('usage/summary', {
      'group-by': groupBy,
      if (project != null && project.isNotEmpty) 'project': project,
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

  // ---- Projects, providers, server ---------------------------------------

  Future<List<String>> projects() async {
    if (!can('insights/projects')) return const [];
    final result = await extensionRaw('insights/projects');
    return [for (final item in asList(result)) asStringOr(item, '')]
      ..removeWhere((item) => item.isEmpty);
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

  Future<JsonMap> toolsList([String? sessionId]) =>
      extension('tools/list', {if (sessionId != null) 'session-id': sessionId});
}
