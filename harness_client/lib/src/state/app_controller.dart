import 'dart:async';

import 'package:flutter/foundation.dart';

import '../acp/acp_client.dart';
import '../acp/acp_message.dart';
import '../acp/capabilities.dart';
import '../acp/acp_transport.dart';
import '../acp/connection_target.dart';
import '../models/server_info.dart';
import '../models/session.dart';
import '../services/harness_api.dart';
import '../state/session_controller.dart';
import '../state/settings_controller.dart';
import '../state/task_controller.dart';
import '../state/usage_controller.dart';

enum ConnectionPhase {
  disconnected,
  connecting,
  authenticating,
  connected,
  needsAuth,
  failed,
}

typedef AcpConnector = Future<AcpTransport> Function(
  ConnectionTarget target,
  String token,
);

class AppController extends ChangeNotifier {
  AppController({required this.settings, AcpConnector? connector})
    : _connector = connector;

  final SettingsController settings;
  final AcpConnector? _connector;
  AcpClient? _client;
  HarnessApi? api;
  HarnessCapabilities? capabilities;
  ConnectionPhase phase = ConnectionPhase.disconnected;
  String? error;
  String? address;
  List<SessionSummary> sessions = const [];
  List<String> projects = const [];
  String? selectedProject;
  TaskController? tasks;
  UsageController? usage;
  ServerOverview? server;
  bool serverLoading = false;
  String? activeSessionId;
  String? lastActionError;
  final Map<String, SessionController> _sessions =
      <String, SessionController>{};
  final Map<String, String> _sessionSignatures = <String, String>{};
  StreamSubscription<AcpNotification>? _subscription;
  StreamSubscription<String>? _degradedSubscription;
  Timer? _sessionRefresh;
  int _connectionGeneration = 0;
  bool _disposed = false;

  bool get isConnected => phase == ConnectionPhase.connected;
  HarnessCapabilities? get capability => capabilities;
  AcpClient? get client => _client;
  HarnessApi? get harness => api;
  bool get web => kIsWeb;

  SessionController? get activeSession =>
      activeSessionId == null ? null : _sessions[activeSessionId];

  SessionSummary? summaryFor(String id) {
    final controller = _sessions[id];
    if (controller?.summary != null) return controller!.summary;
    for (final session in sessions) {
      if (session.id == id) return session;
    }
    return null;
  }

  bool needsAttention(String id) => _sessions[id]?.needsAttention == true;

  int get attentionCount =>
      _sessions.values.where((controller) => controller.needsAttention).length;

  bool get hasTasks => capabilities?.tasks == true && tasks != null;
  bool get hasUsage => capabilities?.usage == true && usage != null;

  Future<void> connect(String address, {String token = ''}) async {
    final generation = ++_connectionGeneration;
    await _teardown(keepPhase: true);
    phase = ConnectionPhase.connecting;
    this.address = address;
    error = null;
    lastActionError = null;
    _notify();
    try {
      final target = ConnectionTarget.parse(address, web: kIsWeb);
      final transport =
          await (_connector?.call(target, token) ??
              target.connect(token: token));
      if (generation != _connectionGeneration) {
        await transport.close();
        return;
      }
      final client = AcpClient(
        transport,
        logger: kDebugMode ? (message) => debugPrint('ACP $message') : null,
      );
      _client = client;
      _subscription = client.notifications.listen(_onNotification);
      final initialized = await client.initialize();
      capabilities = HarnessCapabilities.fromInitialize(initialized);
      api = HarnessApi(client, capabilities!);
      _degradedSubscription = api!.degraded.listen(_onDegraded);
      client.requestHandler = _onAgentRequest;
      if (token.isNotEmpty) {
        phase = ConnectionPhase.authenticating;
        _notify();
        try {
          await client.authenticate(methodId: 'token', token: token);
        } on AcpException catch (failure) {
          if (failure.isAuthRequired) {
            phase = ConnectionPhase.needsAuth;
            error = 'That token was not accepted.';
            _notify();
            return;
          }
          // An agent with no token method can still be usable without auth.
          if (!failure.isMethodNotFound) rethrow;
        }
      }
      await _loadInitial(throwOnAuth: true);
      if (generation != _connectionGeneration) return;
      phase = ConnectionPhase.connected;
      _notify();
      await settings.rememberConnectionDetails(address, token);
      _scheduleInitialLoads();
    } on AcpException catch (failure) {
      if (failure.isAuthRequired) {
        phase = ConnectionPhase.needsAuth;
        error = failure.message;
      } else {
        phase = ConnectionPhase.failed;
        error = failure.message;
        await _teardown(keepPhase: true);
      }
      _notify();
    } catch (failure) {
      phase = ConnectionPhase.failed;
      error = _cleanError(failure);
      await _teardown(keepPhase: true);
      _notify();
    }
  }

  Future<void> submitToken(String token) async {
    final client = _client;
    if (client == null) return;
    phase = ConnectionPhase.authenticating;
    error = null;
    _notify();
    try {
      await client.authenticate(methodId: 'token', token: token);
      await _loadInitial(throwOnAuth: true);
      phase = ConnectionPhase.connected;
      _notify();
      if (address != null) {
        await settings.rememberConnectionDetails(address!, token);
      }
      _scheduleInitialLoads();
    } on AcpException catch (failure) {
      phase = failure.isAuthRequired
          ? ConnectionPhase.needsAuth
          : ConnectionPhase.failed;
      error = failure.isAuthRequired
          ? 'That token was not accepted.'
          : failure.message;
      _notify();
    }
  }

  /// The harness's QR pairing: this call waits until the code is scanned.
  Future<void> pair() async {
    final client = _client;
    if (client == null) return;
    phase = ConnectionPhase.authenticating;
    error = null;
    _notify();
    try {
      await client.authenticate(methodId: 'pair');
      await _loadInitial(throwOnAuth: true);
      phase = ConnectionPhase.connected;
      _notify();
      if (address != null) {
        await settings.rememberConnectionDetails(address!, '');
      }
      _scheduleInitialLoads();
    } on AcpException catch (failure) {
      phase = ConnectionPhase.needsAuth;
      error = failure.message;
      _notify();
    }
  }

  Future<void> _loadInitial({bool throwOnAuth = false}) async {
    await refreshSessions(throwOnAuth: throwOnAuth);
    await refreshProjects();
  }

  void _scheduleInitialLoads() {
    if (capabilities?.tasks == true) {
      tasks = TaskController(api!);
      unawaited(tasks!.load(project: selectedProject, showSpinner: false));
    }
    if (capabilities?.usage == true) {
      usage = UsageController(api!);
      unawaited(usage!.load(project: selectedProject, showSpinner: false));
    }
    unawaited(refreshServer());
  }

  Future<void> refreshSessions({
    bool throwOnAuth = false,
    bool showSpinner = false,
  }) async {
    final service = api;
    if (service == null) return;
    try {
      List<SessionSummary> loaded;
      if (service.can('session/list')) {
        final raw = await service.extensionRaw('session/list');
        loaded = [
          for (final wire in asMapList(raw)) SessionSummary.fromWire(wire),
        ];
      } else {
        loaded = [];
        String? cursor;
        var pages = 0;
        do {
          final page = await service.listSessions(cursor: cursor);
          loaded.addAll(page.sessions);
          cursor = page.nextCursor;
          pages++;
        } while (cursor != null && cursor.isNotEmpty && pages < 10);
      }
      loaded =
          loaded
              .where(
                (session) =>
                    !session.virtual &&
                    session.kind != 'internal' &&
                    !session.id.startsWith('harness:'),
              )
              .toList()
            ..sort(_sortByTouched);
      sessions = loaded;
      if (selectedProject == null || !projects.contains(selectedProject)) {
        selectedProject = _defaultProject();
      }
      _notify();
    } on AcpException catch (failure) {
      if (failure.isAuthRequired) {
        phase = ConnectionPhase.needsAuth;
        error = failure.message;
        _notify();
        if (throwOnAuth) rethrow;
        return;
      }
      error = failure.message;
      _notify();
      if (throwOnAuth) rethrow;
    }
  }

  int _sortByTouched(SessionSummary a, SessionSummary b) {
    final at = a.touchedAt?.millisecondsSinceEpoch ?? 0;
    final bt = b.touchedAt?.millisecondsSinceEpoch ?? 0;
    return bt.compareTo(at);
  }

  Future<void> refreshProjects() async {
    final service = api;
    if (service == null) return;
    final found = <String>{};
    if (service.can('insights/projects')) {
      try {
        found.addAll(await service.projects());
      } catch (_) {}
    }
    for (final session in sessions) {
      final project = session.project ?? session.cwd;
      if (project != null && project.isNotEmpty) found.add(project);
    }
    for (final task in tasks?.tasks ?? const []) {
      final project = task.project ?? task.cwd;
      if (project != null && project.isNotEmpty) found.add(project);
    }
    projects = found.toList()..sort();
    if (selectedProject == null || !projects.contains(selectedProject)) {
      selectedProject = _defaultProject();
    }
    _notify();
  }

  String? _defaultProject() {
    if (projects.isNotEmpty) {
      for (final session in sessions) {
        final project = session.project ?? session.cwd;
        if (project != null && projects.contains(project)) return project;
      }
      return projects.first;
    }
    for (final session in sessions) {
      final project = session.project ?? session.cwd;
      if (project != null && project.isNotEmpty) return project;
    }
    return null;
  }

  void selectProject(String? project) {
    selectedProject = project;
    _notify();
    if (tasks != null) unawaited(tasks!.load(project: project));
    if (usage != null) unawaited(usage!.load(project: project));
    unawaited(refreshServer());
  }

  SessionController sessionController(String id) {
    final existing = _sessions[id];
    if (existing != null) return existing;
    final controller = SessionController(
      api: api!,
      sessionId: id,
      summary: summaryFor(id),
    );
    _sessions[id] = controller;
    controller.addListener(() => _onSessionChanged(id));
    _sessionSignatures[id] = _signature(controller);
    return controller;
  }

  SessionController openSession(String id) {
    activeSessionId = id;
    final controller = sessionController(id);
    unawaited(controller.open());
    return controller;
  }

  void closeSession() {
    activeSessionId = null;
    _notify();
  }

  /// A session worth opening from a task or a link.
  Future<SessionController?> openSessionById(String id) async {
    if (!sessions.any((session) => session.id == id)) {
      await refreshSessions();
    }
    if (!sessions.any((session) => session.id == id)) {
      lastActionError = 'That session is not in the list.';
      _notify();
      return null;
    }
    return openSession(id);
  }

  Future<String?> createSession({
    required String cwd,
    String? name,
    String? model,
  }) async {
    final service = api;
    if (service == null) return null;
    try {
      lastActionError = null;
      final result = await service.newSession(
        cwd: cwd,
        name: name,
        model: model,
      );
      final id = asString(result['sessionId']);
      if (id == null) {
        throw const AcpException(-32603, 'The agent created no session.');
      }
      await refreshSessions();
      openSession(id);
      return id;
    } on AcpException catch (failure) {
      lastActionError = failure.message;
      _notify();
      return null;
    }
  }

  void _onSessionChanged(String id) {
    final controller = _sessions[id];
    if (controller == null) return;
    final signature = _signature(controller);
    if (signature == _sessionSignatures[id]) return;
    _sessionSignatures[id] = signature;
    final summary = controller.summary;
    if (summary != null) _upsertSession(summary, notify: false);
    _notify();
  }

  String _signature(SessionController controller) {
    final summary = controller.summary;
    return '${summary?.title}|${summary?.status}|${summary?.model}|'
        '${summary?.todos.length}|${controller.interactions.length}|'
        '${controller.deleted}';
  }

  void _upsertSession(SessionSummary summary, {bool notify = true}) {
    if (summary.virtual ||
        summary.kind == 'internal' ||
        summary.id.startsWith('harness:')) {
      return;
    }
    final index = sessions.indexWhere((session) => session.id == summary.id);
    if (index < 0) {
      sessions = [...sessions, summary]..sort(_sortByTouched);
    } else {
      final copy = [...sessions];
      copy[index] = summary.merge(copy[index]);
      sessions = copy..sort(_sortByTouched);
    }
    if (notify) _notify();
  }

  Future<Object?> _onAgentRequest(String method, JsonMap params) async {
    if (method == 'session/request_permission' ||
        method == '_harness/ask_user') {
      final sid = asString(params['sessionId']);
      if (sid == null || sid.isEmpty) {
        throw const AcpException(-32602, 'A request without a sessionId.');
      }
      final controller = sessionController(sid);
      if (activeSessionId != sid) {
        lastActionError = controller.currentInteraction == null
            ? 'A session needs your attention.'
            : controller.currentInteraction!.title;
      }
      _notify();
      return controller.handleAgentRequest(method, params);
    }
    throw AcpException(-32601, 'Method not found: $method');
  }

  void _onNotification(AcpNotification notification) {
    if (notification.method == 'session/update') {
      final sid = asString(notification.params['sessionId']);
      if (sid == null) return;
      final update = asMap(notification.params['update']);
      final kind = asString(update['sessionUpdate']);
      if (kind == '_harness/session') {
        final wire = asMap(update['session']);
        if (wire.isNotEmpty) _upsertSession(SessionSummary.fromWire(wire));
      } else if (kind == '_harness/session_deleted') {
        sessions = sessions.where((session) => session.id != sid).toList();
        _notify();
      }
      return;
    }
    if (notification.method != '_harness/event') return;
    final event = asStringOr(notification.params['event'], '');
    final args = asList(notification.params['args']);
    tasks?.applyEvent(event, args);
    usage?.applyEvent(event, args);
    switch (event) {
      case 'session/created':
      case 'session/deleted':
      case 'session/status':
      case 'agent/turn-started':
      case 'agent/turn-ended':
        _scheduleSessionRefresh();
      case 'task/changed':
      case 'task/review':
      case 'task/done':
        if (tasks != null) _scheduleSessionRefresh();
      case 'harness/reloaded':
      case 'config/changed':
      case 'provider/models-updated':
        unawaited(refreshServer());
      case 'usage/budgets-changed':
        unawaited(
          usage?.load(project: selectedProject, showSpinner: false) ??
              Future.value(),
        );
    }
  }

  void _scheduleSessionRefresh() {
    _sessionRefresh?.cancel();
    _sessionRefresh = Timer(const Duration(milliseconds: 350), () {
      unawaited(refreshSessions());
      unawaited(refreshProjects());
    });
  }

  void _onDegraded(String method) {
    lastActionError =
        'This harness does not offer $method; that view is hidden.';
    _notify();
  }

  Future<void> refreshServer() async {
    final service = api;
    if (service == null) return;
    serverLoading = true;
    _notify();
    HarnessVersion? version;
    var modules = const <HarnessModule>[];
    var providers = const <ProviderInfo>[];
    var models = const <ModelInfo>[];
    var projects = const <String>[];
    var budgets = const <JsonMap>[];
    try {
      if (service.can('harness/version')) {
        version = await service.version().catchError(
          (_) => const HarnessVersion(),
        );
      }
      if (service.can('harness/modules')) {
        modules = await service.modules().catchError(
          (_) => const <HarnessModule>[],
        );
      }
      if (service.can('insights/projects')) {
        projects = await service.projects().catchError((_) => const <String>[]);
      }
      if (service.can('provider/list')) {
        providers = await service.providers().catchError(
          (_) => const <ProviderInfo>[],
        );
      }
      if (service.can('provider/models') && providers.isNotEmpty) {
        models = await service.models().catchError((_) => const <ModelInfo>[]);
      }
      if (service.can('usage/budgets')) {
        budgets = await service.budgets().catchError((_) => const <JsonMap>[]);
      }
    } finally {
      if (models.isNotEmpty) {
        providers = [
          for (final provider in providers)
            ProviderInfo(
              id: provider.id,
              label: provider.label,
              doc: provider.doc,
              models: [
                for (final model in models)
                  if (model.provider == null ||
                      model.provider == provider.id ||
                      model.id.startsWith('${provider.id}:'))
                    model,
              ],
            ),
        ];
      }
      server = ServerOverview(
        version: version,
        modules: modules,
        providers: providers,
        projects: projects,
        budgets: budgets,
      );
      serverLoading = false;
      _notify();
    }
  }

  Future<void> disconnect() async {
    ++_connectionGeneration;
    await _teardown();
    phase = ConnectionPhase.disconnected;
    error = null;
    _notify();
  }

  Future<void> _teardown({bool keepPhase = false}) async {
    _sessionRefresh?.cancel();
    _sessionRefresh = null;
    await _subscription?.cancel();
    _subscription = null;
    await _degradedSubscription?.cancel();
    _degradedSubscription = null;
    final client = _client;
    _client = null;
    api = null;
    capabilities = null;
    for (final controller in _sessions.values) {
      controller.dispose();
    }
    _sessions.clear();
    _sessionSignatures.clear();
    sessions = const [];
    projects = const [];
    selectedProject = null;
    tasks = null;
    usage = null;
    server = null;
    activeSessionId = null;
    serverLoading = false;
    if (!keepPhase) {
      address = null;
    }
    if (client != null) {
      try {
        await client.close().timeout(const Duration(seconds: 2));
      } catch (_) {}
    }
  }

  String _cleanError(Object failure) {
    if (failure is AcpException) return failure.message;
    final text = '$failure';
    return text.replaceFirst(RegExp(r'^Exception: '), '');
  }

  void clearActionError() {
    lastActionError = null;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _sessionRefresh?.cancel();
    _subscription?.cancel();
    _degradedSubscription?.cancel();
    for (final controller in _sessions.values) {
      controller.dispose();
    }
    _sessions.clear();
    unawaited(_client?.close());
    super.dispose();
  }
}
