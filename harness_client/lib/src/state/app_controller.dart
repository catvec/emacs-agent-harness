import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

import '../acp/acp_client.dart';
import '../acp/acp_message.dart';
import '../acp/capabilities.dart';
import '../acp/acp_transport.dart';
import '../acp/connection_target.dart';
import '../models/project_roots.dart';
import '../models/quota.dart';
import '../models/server_info.dart';
import '../models/session.dart';
import '../models/task.dart';
import '../services/harness_api.dart';
import '../services/device_name.dart';
import '../state/drafts.dart';
import '../state/quota_controller.dart';
import '../state/session_controller.dart';
import '../state/settings_controller.dart';
import '../state/task_controller.dart';
import '../state/usage_controller.dart';

enum ConnectionPhase {
  disconnected,
  connecting,
  authenticating,
  connected,

  /// The connection was lost and the app is getting it back by itself.  The
  /// screens stay as they were, with what was typed on them: the app is
  /// still in its session, only out of touch for now.
  reconnecting,
  needsAuth,
  failed,
}

typedef AcpConnector = Future<AcpTransport> Function(
  ConnectionTarget target,
  String token,
);

/// Opens [url] for the user, in their browser.  Whether it could be opened.
typedef UrlOpener = Future<bool> Function(Uri url);

Future<bool> _launchInBrowser(Uri url) =>
    launchUrl(url, mode: LaunchMode.externalApplication);

/// How long the app waits between attempts to connect again, once a connection
/// is lost: the first attempt is made at once, and then after each that
/// fails it waits this long, the last for as long as it takes.  A harness
/// that restarted is back in seconds; one that is not should not be asked a
/// hundred times a minute.
const List<Duration> defaultReconnectDelays = <Duration>[
  Duration(seconds: 1),
  Duration(seconds: 2),
  Duration(seconds: 4),
  Duration(seconds: 8),
  Duration(seconds: 15),
];

/// How an attempt to connect again ended.
enum _Attempt {
  /// The connection is back.
  connected,

  /// The harness did not accept this device's session secret: it needs to
  /// sign in again, which only a person can do.
  refused,

  /// It did not work this time (the harness cannot be reached, or it did
  /// not answer); try again later.
  failed,

  /// Something else happened meanwhile (the person disconnected, or
  /// connected to another address): this attempt is no longer wanted.
  superseded,
}

class AppController extends ChangeNotifier {
  AppController({
    required this.settings,
    AcpConnector? connector,
    UrlOpener? urlOpener,
    this.reconnectDelays = defaultReconnectDelays,
    this.handshakeTimeout = const Duration(seconds: 12),
    this.probeTimeout = const Duration(seconds: 5),
  }) : _connector = connector,
       _openUrl = urlOpener ?? _launchInBrowser;

  final SettingsController settings;
  final AcpConnector? _connector;
  final UrlOpener _openUrl;

  /// The waits between attempts to connect again: see
  /// [defaultReconnectDelays].
  final List<Duration> reconnectDelays;

  /// How long a harness has to answer `initialize` on a connection that was
  /// just opened, when the app is connecting again.
  final Duration handshakeTimeout;

  /// How long a connection that looks open has to answer a probe, when the
  /// app returns to the foreground.
  final Duration probeTimeout;

  /// What was typed and not sent yet, which outlives the screens: see
  /// [DraftStore].
  final DraftStore drafts = DraftStore();
  AcpClient? _client;
  HarnessApi? api;
  HarnessCapabilities? capabilities;
  ConnectionPhase phase = ConnectionPhase.disconnected;
  String? error;
  String? address;

  /// Why the connection was lost, in words for a person, while the app is
  /// getting it back ([ConnectionPhase.reconnecting]).
  String? lostReason;

  /// How many attempts to connect again this outage has taken so far.
  int reconnectAttempt = 0;

  /// What the last attempt to connect again said, when it failed.
  String? reconnectError;

  /// What the last attempt to go back into the harness this device remembers
  /// said, when it did not work (see [resume]), in words for a person.  It
  /// stays while the attempts go on, so what the screen says does not blink
  /// with each one.
  String? resumeError;

  /// The session secret this device is signed in with, to present on the
  /// next connection: the harness replaces it every so often, and the
  /// one in use is the one to keep.
  String _secret = '';
  Timer? _reconnectTimer;
  Completer<void>? _reconnectWake;
  bool _foreground = true;
  Completer<void>? _foregroundWake;
  bool _resumeStarted = false;
  bool _resuming = false;

  /// The way to sign in the user chose, while the harness waits for them
  /// to finish it (an approval in Emacs, a login in the browser).
  AuthMethod? signingInWith;
  List<SessionSummary> sessions = const [];

  /// The projects of the harness: main checkouts, which the git worktrees
  /// of their tasks belong to rather than being projects themselves, and
  /// the scratch directories of its agents are no project's at all.
  List<String> projects = const [];

  /// The project the Usage view is narrowed to, and the one a new session or
  /// task starts in: null for every project.  The app opens on the project
  /// of the latest work, and a choice, every project included, stays until
  /// another is made ([selectProject]).  The task board is not narrowed by
  /// it: it opens on every project and has its own scope
  /// ([TaskController.project]), so that the work of the projects a person
  /// did not open the app on is not out of sight.
  String? selectedProject;
  bool _projectChosen = false;
  TaskController? tasks;
  UsageController? usage;

  /// Each provider's billing and plan quota, for the providers that report
  /// them; null on a harness that does not offer `provider/quota`.
  QuotaController? quota;
  ServerOverview? server;
  bool serverLoading = false;
  String? activeSessionId;
  String? lastActionError;
  final Map<String, SessionController> _sessions =
      <String, SessionController>{};
  final Map<String, String> _sessionSignatures = <String, String>{};

  /// The sessions the harness keeps as records of its own model calls (the
  /// permission judge, a recap, a name): they come and go with every call it
  /// makes, a few a minute, and are no conversation, so what is said of them
  /// is no reason to read all the sessions again (see [_onNotification]).
  final Set<String> _internalSessions = <String>{};
  StreamSubscription<AcpNotification>? _subscription;
  StreamSubscription<String>? _degradedSubscription;
  Timer? _sessionRefresh;

  /// How directories fold into projects, as far as this harness has said
  /// (see [refreshProjects]).
  ProjectRoots _roots = const ProjectRoots.empty();
  final Map<String, String> _resolvedMains = <String, String>{};
  final Set<String> _askedMains = <String>{};
  int _connectionGeneration = 0;
  bool _disposed = false;

  bool get isConnected => phase == ConnectionPhase.connected;

  /// The connection was lost and is being got back.
  bool get isReconnecting => phase == ConnectionPhase.reconnecting;

  /// Whether the app is in its session, with the home screens up: connected,
  /// or only out of touch for a while ([isReconnecting]).
  bool get hasSession => isConnected || isReconnecting;

  /// Whether the app is going back into the harness this device remembers,
  /// by itself, and has not needed anything from the person yet ([resume]).
  /// The connection screen then says so instead of asking for an address and
  /// a secret, which the device already holds.
  bool get resuming =>
      _resuming &&
      phase != ConnectionPhase.needsAuth &&
      phase != ConnectionPhase.connected;

  /// Whether the next attempt to connect again waits for its turn, which
  /// [retryNow] brings forward.
  bool get waitingToRetry =>
      (isReconnecting || resuming) &&
      _reconnectWake != null &&
      !_reconnectWake!.isCompleted;
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

  /// What [session] cost and who pays for it: the price when its calls are
  /// billed per token, its plan with the plan's quota when a subscription
  /// pays (see [SpendStatus]).
  SpendStatus spendOf(SessionSummary? session) => SpendStatus.of(
    usage: session?.usage,
    quota: quota?.forModel(session?.model),
  );

  /// The same for the sessions of [tasks] taken together.  [model], the one
  /// new tasks use, names the provider whose account stands for them all;
  /// else the first session's does.
  SpendStatus spendOfTasks(Iterable<HarnessTask> tasks, {String? model}) {
    final sessions = <SessionSummary>[
      for (final task in tasks)
        if (task.sessionId case final id?)
          if (summaryFor(id) case final session?) session,
    ];
    return SpendStatus.of(
      usage: combineUsage(sessions),
      quota: quota?.forModel(model ?? sessions.firstOrNull?.model),
      subject: 'These tasks',
    );
  }

  /// The name of the provider whose account [spend] reads, as people read
  /// it ("Claude"); null when no provider's quota applies.
  String? providerLabelOf(SpendStatus spend) {
    final provider = spend.quota?.provider;
    return provider == null ? null : quota?.labelOf(provider);
  }

  /// How many of the listed sessions wait for the person, among those the
  /// app holds a conversation of.  A session the harness no longer lists
  /// (it was deleted while the app was out of reach) waits for nobody.
  int get attentionCount =>
      sessions.where((session) => needsAttention(session.id)).length;

  bool get hasTasks => capabilities?.tasks == true && tasks != null;
  bool get hasUsage => capabilities?.usage == true && usage != null;
  bool get hasQuota => capabilities?.quota == true && quota != null;

  /// The ways the harness lets this device sign in (ACP's `authMethods`),
  /// but for the session secret, which has a field of its own.
  List<AuthMethod> get signInMethods => [
    for (final method in capabilities?.authMethods ?? const <AuthMethod>[])
      if (!method.isToken) method,
  ];

  /// Whether a session secret can be given instead of choosing a method.
  bool get canUseToken =>
      (capabilities?.authMethods ?? const <AuthMethod>[]).any(
        (method) => method.isToken,
      );

  /// Connect to [address]: a `ws://` or `wss://` address (an `https://` one
  /// is its `wss://`), a `tcp://` address, or the connection link the
  /// harness gives a device that is given a token (a `ws://` address with
  /// a `?token=`).  [token] is a session secret typed beside the address,
  /// and wins over one in it.
  ///
  /// A device that has no session yet, or whose secret was refused, stops
  /// at [ConnectionPhase.needsAuth], where [signInMethods] are shown to
  /// the user, who picks one for [signIn]: that is how ACP lets a client
  /// sign in.  Once signed in, the secret the harness hands this device is
  /// kept, and the next connection needs no sign-in at all: the app goes
  /// back in by itself when it opens (see [resume]).
  Future<void> connect(String address, {String token = ''}) {
    // A person who connects by hand takes over from the app's own attempts.
    _stopResuming();
    return _connect(address, token: token);
  }

  /// [connect], which [resume] also uses.  [handshake] is how long the harness
  /// has to answer `initialize`, where waiting for ever is no good (the app
  /// is going back in by itself, and the person has no button to press).
  ///
  /// The first thing it does, before it waits for anything, is take the
  /// next [_connectionGeneration]: [resume] reads it right after the call to
  /// know which attempt is its own.
  Future<void> _connect(
    String address, {
    String token = '',
    Duration? handshake,
  }) async {
    final generation = ++_connectionGeneration;
    await _teardown(keepPhase: true);
    phase = ConnectionPhase.connecting;
    this.address = address;
    error = null;
    lastActionError = null;
    signingInWith = null;
    _secret = token.trim();
    _notify();
    var secret = token.trim();
    try {
      final target = ConnectionTarget.parse(address, web: kIsWeb);
      if (secret.isEmpty && target.token != null) secret = target.token!;
      // What is shown and remembered never carries the secret in its URL.
      final shown = target.isTcp ? address : target.webSocketUri.toString();
      this.address = shown;
      final transport =
          await (_connector?.call(target, secret) ??
              target.connect(token: secret));
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
      final initialized = await client.initialize(
        clientTitle: deviceName(),
        timeout: handshake,
      );
      if (generation != _connectionGeneration) {
        // Something else took over while the harness thought about it.
        await client.close();
        return;
      }
      _adopt(client, initialized);
      // The secret the connection was opened with is the one to sign in
      // with, even where the harness replaced it just now.
      final presented = secret;
      secret = _keepReplacement(shown, secret, _replacementSecret(initialized));
      if (capabilities!.authMethods.isNotEmpty) {
        // The harness wants this device to sign in.  A secret on a
        // WebSocket was offered as the connection opened, and a harness
        // that listed methods did not take it; over plain TCP it is the
        // first thing to try.
        if (target.isTcp && presented.isNotEmpty && canUseToken) {
          try {
            final answer = await client.authenticate(
              methodId: 'token',
              token: presented,
            );
            secret = await _signedIn(client, shown, secret, answer);
          } on AcpException catch (failure) {
            if (generation != _connectionGeneration) return;
            if (failure.isAuthRequired) {
              phase = ConnectionPhase.needsAuth;
              error = _notAccepted;
              _notify();
              return;
            }
            rethrow;
          }
        } else {
          phase = ConnectionPhase.needsAuth;
          error = presented.isNotEmpty ? _notAccepted : null;
          _notify();
          return;
        }
      }
      await _enter(generation, shown, secret);
    } on AcpException catch (failure) {
      // An attempt that something else took over from, and that ends in
      // failure now (its connection was closed under it), must not undo
      // what the other has done since.
      if (generation != _connectionGeneration) return;
      if (failure.isAuthRequired) {
        phase = ConnectionPhase.needsAuth;
        error = failure.message;
      } else {
        phase = ConnectionPhase.failed;
        error = failure.message;
        if (_resuming) resumeError = failure.message;
        await _teardown(keepPhase: true);
      }
      _notify();
    } catch (failure) {
      if (generation != _connectionGeneration) return;
      phase = ConnectionPhase.failed;
      error = _cleanError(failure, hadSecret: secret.isNotEmpty);
      if (_resuming) resumeError = _describeFailure(failure);
      await _teardown(keepPhase: true);
      _notify();
    }
  }

  /// Take [initialized], what `initialize` answered, as what the harness
  /// can do, and wire the client to it.
  void _adopt(AcpClient client, JsonMap initialized) {
    capabilities = HarnessCapabilities.fromInitialize(initialized);
    api = HarnessApi(client, capabilities!);
    _degradedSubscription?.cancel();
    _degradedSubscription = api!.degraded.listen(_onDegraded);
    client.requestHandler = _onAgentRequest;
  }

  /// Start using the connection: the first loads, then the app opens.
  Future<void> _enter(int generation, String shown, String secret) async {
    await _loadInitial(throwOnAuth: true);
    if (generation != _connectionGeneration) return;
    signingInWith = null;
    phase = ConnectionPhase.connected;
    error = null;
    _secret = secret;
    final client = _client;
    if (client != null) _watch(client, generation);
    _notify();
    // Remembering is a convenience; a slow preference store must not stop
    // the initial loads after a successful connection.
    unawaited(settings.rememberConnectionDetails(shown, secret));
    _scheduleInitialLoads();
  }

  /// What a harness that signed this device in handed back: the secret to
  /// sign in with next time, in the `_meta` of the answer to `authenticate`.
  String? _handedSecret(JsonMap answer) {
    final token = asString(
      asMap(asMap(asMap(answer['_meta'])['harness'])['session'])['token'],
    );
    return token == null || token.isEmpty ? null : token;
  }

  /// A harness that listed methods before it signed this device in answers
  /// `initialize` again, now with everything it can do.  Returns the secret
  /// to keep: the one it handed over, else the one the device had, and the
  /// one that replaces either, when the full answer brings one.
  Future<String> _signedIn(
    AcpClient client,
    String shown,
    String secret,
    JsonMap answer,
  ) async {
    var kept = _handedSecret(answer) ?? secret;
    if (kept != secret) _keepReplacement(shown, secret, kept);
    final full = await client.initialize(clientTitle: deviceName());
    _adopt(client, full);
    kept = _keepReplacement(shown, kept, _replacementSecret(full));
    return kept;
  }

  /// Sign in with [method], one of [signInMethods]: ACP's `authenticate`,
  /// which the harness answers once the user did what the method asks.
  /// An approval waits for them in Emacs, a login for them in the browser,
  /// which this opens.
  Future<void> signIn(AuthMethod method) async {
    final client = _client;
    final shown = address;
    if (client == null || shown == null || signingInWith != null) return;
    final generation = _connectionGeneration;
    signingInWith = method;
    phase = ConnectionPhase.authenticating;
    error = null;
    _notify();
    try {
      final url = method.isOidc ? method.url : null;
      if (url != null) {
        final opened = await _openUrl(Uri.parse(url)).catchError((_) => false);
        if (!opened) {
          lastActionError =
              'Open $url in a browser, sign in, and confirm the code '
              '${method.code ?? ''}.';
          _notify();
        }
      }
      final answer = await client.authenticate(methodId: method.id);
      if (generation != _connectionGeneration) return;
      final secret = await _signedIn(client, shown, '', answer);
      await _enter(generation, shown, secret);
    } on AcpException catch (failure) {
      if (generation != _connectionGeneration) return;
      signingInWith = null;
      phase = failure.isTransport
          ? ConnectionPhase.failed
          : ConnectionPhase.needsAuth;
      error = failure.message;
      _notify();
    } catch (failure) {
      if (generation != _connectionGeneration) return;
      signingInWith = null;
      phase = ConnectionPhase.failed;
      error = _cleanError(failure);
      _notify();
    }
  }

  /// Give up on the sign-in that waits: the connection closes, and with it
  /// what the harness waits to approve.
  Future<void> cancelSignIn() async {
    if (signingInWith == null) return;
    await disconnect();
  }

  /// The new session secret a harness put in an `initialize` answer, if any.
  /// A harness replaces the secret of a device that said it can keep one
  /// (see [AcpClient.initialize]) every so often, so a secret that leaks is
  /// of no use for long.
  String? _replacementSecret(JsonMap initialized) {
    final token = asString(
      asMap(asMap(initialized['_harness'])['session'])['token'],
    );
    return token == null || token.isEmpty ? null : token;
  }

  /// Keep [replacement] in place of [secret] at once: the old secret stops
  /// working soon, so it must not wait for the rest of the connection to go
  /// well.  Returns the secret to go on with.
  String _keepReplacement(String address, String secret, String? replacement) {
    if (replacement == null || replacement == secret) return secret;
    unawaited(settings.rememberConnectionDetails(address, replacement));
    return replacement;
  }

  /// Sign in with a session secret, or the harness's shared secret, typed
  /// by the user.
  Future<void> submitToken(String token) async {
    final client = _client;
    final shown = address;
    if (client == null || shown == null) return;
    final generation = _connectionGeneration;
    phase = ConnectionPhase.authenticating;
    error = null;
    _notify();
    try {
      final answer = await client.authenticate(methodId: 'token', token: token);
      final secret = await _signedIn(client, shown, token, answer);
      await _enter(generation, shown, secret);
    } on AcpException catch (failure) {
      phase = failure.isAuthRequired
          ? ConnectionPhase.needsAuth
          : ConnectionPhase.failed;
      error = failure.isAuthRequired ? _notAccepted : failure.message;
      _notify();
    }
  }

  /// Whether the harness offers `logout`: ending this device's session.
  bool get canSignOut {
    final caps = asMap(asMap(capabilities?.raw['agentCapabilities'])['auth']);
    return caps.containsKey('logout');
  }

  /// End this device's session on the harness (it must be paired again to
  /// connect), forget the saved secret and disconnect.
  Future<void> signOut() async {
    final client = _client;
    if (client != null && canSignOut) {
      try {
        await client.request('logout', <String, Object?>{});
      } catch (_) {
        // The session may be gone already; either way we leave.
      }
    }
    _secret = '';
    await settings.clearConnection();
    await disconnect();
  }

  Future<void> _loadInitial({bool throwOnAuth = false}) async {
    await refreshSessions(throwOnAuth: throwOnAuth);
    await refreshProjects();
  }

  void _scheduleInitialLoads() {
    if (capabilities?.tasks == true) {
      tasks = TaskController(api!);
      unawaited(tasks!.load(showSpinner: false));
    }
    if (capabilities?.usage == true) {
      usage = UsageController(api!, roots: () => _roots);
      unawaited(usage!.load(project: selectedProject, showSpinner: false));
    }
    if (capabilities?.quota == true) {
      _startQuota(api!);
      unawaited(quota!.load());
    }
    unawaited(refreshServer());
  }

  /// Keep the plan quota of the providers, and show it wherever a screen
  /// shows what a session costs: a change of it is a change of the app.
  void _startQuota(HarnessApi service) {
    quota = QuotaController(service)..addListener(_notify);
  }

  void _stopQuota() {
    quota
      ?..removeListener(_notify)
      ..dispose();
    quota = null;
  }

  /// Whether new conversations start non-interactive; null until known.
  bool? defaultNonInteractive;
  bool updatingNonInteractive = false;

  bool get canSetNonInteractiveEverywhere =>
      capabilities?.setAllNonInteractive == true;

  /// Reads the harness's default for non-interactive mode, if it tells.
  Future<void> loadNonInteractiveDefault() async {
    final service = api;
    if (service == null) return;
    final cwd = sessions.isNotEmpty ? sessions.first.cwd : null;
    try {
      final value = await service.defaultNonInteractive(cwd ?? '/');
      if (value != null && value != defaultNonInteractive) {
        defaultNonInteractive = value;
        _notify();
      }
    } catch (_) {
      // The switch is then shown from the conversations themselves.
    }
  }

  /// Switches every conversation, and the default for new ones.
  Future<void> setNonInteractiveEverywhere(bool on) async {
    final service = api;
    if (service == null || updatingNonInteractive) return;
    updatingNonInteractive = true;
    _notify();
    try {
      await service.setNonInteractiveEverywhere(on);
      defaultNonInteractive = on;
      for (final controller in _sessions.values) {
        unawaited(controller.refreshInfo());
      }
    } on AcpException catch (failure) {
      error = failure.message;
    } finally {
      updatingNonInteractive = false;
      _notify();
    }
    await refreshSessions();
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
      _internalSessions
        ..clear()
        ..addAll([
          for (final session in loaded)
            if (session.kind == 'internal') session.id,
        ]);
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
      // What was read is the harness's word on every session, the ones the
      // app holds a conversation of included: their own records are only as
      // new as the last event each heard, and a connection that was out
      // heard none.
      if (service.can('session/list')) _adoptIntoConversations(loaded);
      _keepSelectedProject();
      _notify();
      if (defaultNonInteractive == null && canSetNonInteractiveEverywhere) {
        unawaited(loadNonInteractiveDefault());
      }
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

  /// Hand each of [records], the harness's records of its sessions, to the
  /// conversation the app holds of that session, if it holds one: what the
  /// conversation knows of the session, and the requests it recovered from
  /// the harness, are then what the harness says now (see
  /// [SessionController.adopt]).  A conversation that is open, which reads
  /// its own record when the connection is back, is no different: this is
  /// the same word.
  void _adoptIntoConversations(List<SessionSummary> records) {
    for (final record in records) {
      _sessions[record.id]?.adopt(record, unlessOlder: true);
    }
  }

  int _sortByTouched(SessionSummary a, SessionSummary b) {
    final at = a.touchedAt?.millisecondsSinceEpoch ?? 0;
    final bt = b.touchedAt?.millisecondsSinceEpoch ?? 0;
    return bt.compareTo(at);
  }

  /// The project (main checkout) a session works for, null for none.
  String? projectOfSession(SessionSummary session) =>
      _roots.of(session.project ?? session.cwd);

  /// The project (main checkout) a task belongs to, null for none.
  String? projectOfTask(HarnessTask task) =>
      _roots.of(task.project ?? task.cwd);

  /// The directories the sessions and tasks work in.
  Set<String> _workingDirectories() => {
    for (final session in sessions)
      if (projectDirectory(session.project ?? session.cwd).isNotEmpty)
        projectDirectory(session.project ?? session.cwd),
    for (final task in tasks?.tasks ?? const <HarnessTask>[])
      if (projectDirectory(task.project ?? task.cwd).isNotEmpty)
        projectDirectory(task.project ?? task.cwd),
  };

  /// Work out the projects: the ones the harness lists and the ones the
  /// work of its sessions and tasks is in.
  ///
  /// A session or a task names the directory it works in, which for a task,
  /// and for the sub-agents and forks started in its worktree, is a git
  /// worktree of the project, and for a sub-agent an agent gave a scratch
  /// directory to, one in the temporary directory of a session.  Those are
  /// no projects of their own, so each directory, the ones the harness lists
  /// too, is folded into the project it belongs to: the harness says which,
  /// once per directory, when it offers `project/mains`; else the directory
  /// itself tells, in the layouts the harness makes worktrees in and the
  /// place it makes scratch directories (see [ProjectRoots]).
  Future<void> refreshProjects() async {
    final service = api;
    if (service == null) return;
    var listed = const <String>[];
    if (service.can('insights/projects')) {
      try {
        listed = await service.projects();
      } catch (_) {}
    }
    final directories = {
      for (final directory in listed)
        if (projectDirectory(directory).isNotEmpty) projectDirectory(directory),
      ..._workingDirectories(),
    };
    final unasked = [
      for (final directory in directories)
        if (!_askedMains.contains(directory)) directory,
    ]..sort();
    Map<String, String>? answers;
    if (unasked.isNotEmpty && service.can('project/mains')) {
      try {
        answers = await service.mainProjects(unasked);
      } catch (_) {
        // Asked again with the next refresh; the paths say what they can.
      }
    }
    // The connection may have gone, or been replaced, meanwhile.
    if (api != service) return;
    if (answers != null) {
      _resolvedMains.addAll(answers);
      _askedMains.addAll(unasked);
    }
    _roots = ProjectRoots(resolved: _resolvedMains);
    projects = _roots.projectsOf(directories);
    _keepSelectedProject();
    _notify();
  }

  /// Open on the project of the latest work, until a person chooses.  What
  /// they chose stays, every project included, as long as it is listed: a
  /// refresh, which the harness's events bring every few seconds, must not
  /// turn it back into the project of the latest work.
  void _keepSelectedProject() {
    final chosen = selectedProject;
    final gone = chosen != null && !projects.contains(chosen);
    if (gone || (chosen == null && !_projectChosen)) {
      selectedProject = _defaultProject();
    }
  }

  String? _defaultProject() {
    for (final session in sessions) {
      final project = projectOfSession(session);
      if (project != null && (projects.isEmpty || projects.contains(project))) {
        return project;
      }
    }
    return projects.isEmpty ? null : projects.first;
  }

  void selectProject(String? project) {
    selectedProject = project;
    _projectChosen = true;
    _notify();
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
      drafts: drafts,
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
      // What is known of it, brought up to date by what was just heard.
      copy[index] = copy[index].merge(summary);
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
      // That a session waits for the person is not said once, in a banner
      // that stays until it is closed by hand: the sessions say it
      // themselves, for as long as it is so (the list of sessions, and the
      // notice of the shell, see [attentionCount]).
      return sessionController(sid).handleAgentRequest(method, params);
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
    quota?.applyEvent(event, args);
    switch (event) {
      case 'session/created':
      case 'session/deleted':
      case 'session/status':
      case 'agent/turn-started':
      case 'agent/turn-ended':
        // The sessions are a few megabytes: not read again for a record of
        // a model call, which the harness makes and ends every few seconds.
        if (!_isInternalSessionEvent(event, args)) _scheduleSessionRefresh();
      case 'task/changed':
      case 'task/review':
      case 'task/done':
        if (tasks != null) _scheduleSessionRefresh();
      case 'harness/reloaded':
      case 'config/changed':
      case 'provider/models-updated':
        unawaited(refreshServer());
        // A reloaded harness may have other providers to ask.
        if (event == 'harness/reloaded') unawaited(quota?.load());
      case 'usage/budgets-changed':
        unawaited(
          usage?.load(project: selectedProject, showSpinner: false) ??
              Future.value(),
        );
    }
  }

  /// Whether [event], a session event with [args] (its session's id, and for
  /// `session/created` and `session/deleted` the session), is about an
  /// internal session.  A session nothing is known of is not taken for one:
  /// only what is certain is skipped.
  bool _isInternalSessionEvent(String event, List<Object?> args) {
    final id = args.isEmpty ? null : asString(args.first);
    if (id == null || id.isEmpty) return false;
    final session = args.length > 1
        ? asMap(args[1])
        : const <String, Object?>{};
    final internal =
        asString(session['kind']) == 'internal' ||
        _internalSessions.contains(id);
    if (!internal) return false;
    if (event == 'session/deleted') {
      _internalSessions.remove(id);
    } else {
      _internalSessions.add(id);
    }
    return true;
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

  /// Leave the harness, as the person asked to.  The device keeps its
  /// address and secret, so connecting again is a tap, but the app no longer
  /// goes back in by itself when it opens until it is connected again: they
  /// chose to be out.
  Future<void> disconnect() async {
    ++_connectionGeneration;
    _stopResuming();
    unawaited(settings.setReconnectOnLaunch(false));
    await _teardown();
    phase = ConnectionPhase.disconnected;
    error = null;
    _notify();
  }

  // ---------------------------------------------------------------------
  // A device that remembers its harness.
  //
  // A device that signed in keeps the address of its harness and the session
  // secret the harness gave it (see [SettingsController]).  When the app
  // opens it goes back in with them by itself, as it does after a lost
  // connection, and the person is not asked for anything: the harness is the
  // only one that can ask again, by turning the device away (its session was
  // ended, or ran out).  Only a device that has nothing remembered, or that
  // the harness will not take back, is shown the connection form.
  // ---------------------------------------------------------------------

  /// Go back into the harness this device remembers, as the app opens.
  /// Where it ends depends on what the harness says:
  ///
  ///  * it takes the secret: the app is in ([ConnectionPhase.connected]);
  ///  * it asks the device to sign in ([ConnectionPhase.needsAuth]): the
  ///    secret was revoked or ran out, or there is none.  That is a question
  ///    for the person, so the app stops there (and does not try the secret
  ///    again until the next launch);
  ///  * it cannot be reached (the network is not up, the harness is
  ///    restarting): the app tries again by itself, as it does after a lost
  ///    connection, until the harness answers or the person takes over
  ///    ([cancelResume]).  A phone that is put away waits.
  ///
  /// Does nothing unless [SettingsController.canResume], and only once per
  /// run of the app.
  Future<void> resume() async {
    if (_disposed ||
        _resumeStarted ||
        phase != ConnectionPhase.disconnected ||
        !settings.canResume) {
      return;
    }
    final remembered = settings.address;
    final secret = settings.token;
    try {
      ConnectionTarget.parse(remembered, web: kIsWeb);
    } on FormatException {
      // Not an address (it was damaged, or another build wrote it): there
      // is nothing to go back to, and the form shows what is kept.
      return;
    }
    _resumeStarted = true;
    _resuming = true;
    resumeError = null;
    _notify();
    try {
      var failures = 0;
      while (true) {
        final attempt = _connect(
          remembered,
          token: secret,
          handshake: handshakeTimeout,
        );
        // The attempt took its generation before it waited for anything.
        final generation = _connectionGeneration;
        await attempt;
        if (!_resumeWanted(generation) || phase != ConnectionPhase.failed) {
          break;
        }
        // Out of reach for now: wait, and try again.
        failures++;
        await _untilForeground(() => _resumeWanted(generation));
        if (!_resumeWanted(generation)) break;
        await _waitToRetry(failures);
        if (!_resumeWanted(generation)) break;
      }
    } finally {
      _stopResuming();
      _notify();
    }
  }

  bool _resumeWanted(int generation) =>
      !_disposed && _resuming && generation == _connectionGeneration;

  void _stopResuming() {
    _resuming = false;
    resumeError = null;
  }

  /// The person does not want the app to go back into the harness it
  /// remembers (it is the wrong address, or they want to sign in another
  /// way): stop trying and show the connection form, with what is kept in it.
  Future<void> cancelResume() async {
    if (!_resuming) return;
    ++_connectionGeneration;
    _stopResuming();
    await _teardown();
    phase = ConnectionPhase.disconnected;
    error = null;
    _notify();
  }

  // ---------------------------------------------------------------------
  // A connection that is lost.
  //
  // A phone loses its connection all the time: it sleeps, it changes
  // network, a VPN restarts, the harness reloads.  None of that is a reason
  // to throw the screens away, and with them the message being written: the
  // app notices, says so quietly, and connects again by itself, with the
  // secret it already holds.  What it shows is read again from the harness
  // once the connection is back; only a harness that no longer accepts the
  // device's session needs the person (see [_Attempt.refused]).
  // ---------------------------------------------------------------------

  /// Learn when [client] ends, whoever ends it.
  void _watch(AcpClient client, int generation) {
    unawaited(
      client.closed.then((_) {
        if (_disposed ||
            generation != _connectionGeneration ||
            !identical(client, _client)) {
          return;
        }
        _lose(client.closeReason ?? 'The connection was closed.');
      }),
    );
  }

  /// The connection is gone, for [reason]: start getting it back.
  void _lose(String reason) {
    if (_disposed || phase != ConnectionPhase.connected) return;
    final generation = _connectionGeneration;
    // End what is left of the connection before anything else happens: the
    // answers to the agent's requests that the sessions give up on below
    // must not go out on it, as a refusal nobody gave.
    final old = _client;
    if (old != null && !old.isClosed) unawaited(old.close());
    lostReason = reason;
    reconnectAttempt = 0;
    reconnectError = null;
    phase = ConnectionPhase.reconnecting;
    api?.reconnecting = true;
    for (final controller in _sessions.values) {
      controller.connectionLost();
    }
    _notify();
    unawaited(_reconnect(generation));
  }

  bool _reconnecting(int generation) =>
      !_disposed &&
      generation == _connectionGeneration &&
      phase == ConnectionPhase.reconnecting;

  /// Connect again until it works, or the harness turns this device away, or
  /// the person disconnects.
  Future<void> _reconnect(int generation) async {
    var failures = 0;
    while (_reconnecting(generation)) {
      // A phone that is put away has no network to try: the attempts wait
      // for it to come back, which is when the person needs the connection.
      await _untilForeground(() => _reconnecting(generation));
      if (!_reconnecting(generation)) return;
      reconnectAttempt++;
      _notify();
      final outcome = await _reconnectOnce(generation);
      if (outcome == _Attempt.connected) {
        // The connection works.  Reading what the screens show over it may
        // still fail, which is no reason to doubt the connection.
        try {
          await _refreshAfterReconnect(generation);
        } catch (failure) {
          debugPrint('Harness: could not refresh after reconnecting: $failure');
        }
        return;
      }
      if (outcome != _Attempt.failed || !_reconnecting(generation)) return;
      await _waitToRetry(++failures);
    }
  }

  Future<_Attempt> _reconnectOnce(int generation) async {
    final shown = address;
    if (shown == null) return _Attempt.superseded;
    AcpClient? client;
    try {
      final target = ConnectionTarget.parse(shown, web: kIsWeb);
      final presented = _secret;
      final transport =
          await (_connector?.call(target, presented) ??
              target.connect(token: presented));
      if (!_reconnecting(generation)) {
        await transport.close();
        return _Attempt.superseded;
      }
      client = AcpClient(
        transport,
        logger: kDebugMode ? (message) => debugPrint('ACP $message') : null,
      );
      var initialized = await client.initialize(
        clientTitle: deviceName(),
        timeout: handshakeTimeout,
      );
      var secret = _keepReplacement(
        shown,
        presented,
        _replacementSecret(initialized),
      );
      var caps = HarnessCapabilities.fromInitialize(initialized);
      if (caps.authMethods.isNotEmpty && _reconnecting(generation)) {
        // The harness wants this device to sign in: it did not take the
        // secret that was offered as the connection opened.  Over plain TCP
        // the secret is the first thing to try; where it is no good, or
        // there is none, only a person can sign the device in again.
        var signedIn = false;
        if (target.isTcp &&
            presented.isNotEmpty &&
            caps.authMethods.any((method) => method.isToken)) {
          try {
            final answer = await client.authenticate(
              methodId: 'token',
              token: presented,
            );
            secret = _keepReplacement(
              shown,
              secret,
              _handedSecret(answer) ?? secret,
            );
            initialized = await client.initialize(
              clientTitle: deviceName(),
              timeout: handshakeTimeout,
            );
            secret = _keepReplacement(
              shown,
              secret,
              _replacementSecret(initialized),
            );
            caps = HarnessCapabilities.fromInitialize(initialized);
            signedIn = true;
          } on AcpException catch (failure) {
            if (!failure.isAuthRequired) rethrow;
          }
        }
        if (!signedIn && _reconnecting(generation)) {
          await _turnedAway(client, initialized, presented.isNotEmpty);
          return _Attempt.refused;
        }
      }
      if (!_reconnecting(generation)) {
        await client.close();
        return _Attempt.superseded;
      }
      _resume(client, caps, secret, generation);
      return _Attempt.connected;
    } on AcpException catch (failure) {
      await client?.close();
      if (failure.isAuthRequired && _reconnecting(generation)) {
        await _forgetScreens();
        phase = ConnectionPhase.needsAuth;
        error = _notAccepted;
        _notify();
        return _Attempt.refused;
      }
      reconnectError = failure.message;
      return _Attempt.failed;
    } catch (failure) {
      await client?.close();
      reconnectError = _describeFailure(failure);
      return _Attempt.failed;
    }
  }

  /// What an attempt to connect again that failed says, for the banner: the
  /// few things that go wrong, in words, and anything else as it is.
  String _describeFailure(Object failure) {
    final text = '$failure';
    final lower = text.toLowerCase();
    if (lower.contains('connection refused')) {
      return 'The harness refused the connection: is it running?';
    }
    if (lower.contains('network is unreachable') ||
        lower.contains('no route to host') ||
        lower.contains('failed host lookup')) {
      return 'The network cannot reach the harness.';
    }
    if (failure is TimeoutException || lower.contains('timed out')) {
      return 'The harness did not answer in time.';
    }
    return _cleanError(failure, hadSecret: _secret.isNotEmpty);
  }

  /// The harness would not take this device back: leave the session the way
  /// a connection that needs a sign-in is left, with the harness's own list
  /// of the ways to do it at hand.
  Future<void> _turnedAway(
    AcpClient client,
    JsonMap initialized,
    bool hadSecret,
  ) async {
    await _forgetScreens();
    _client = client;
    _subscription = client.notifications.listen(_onNotification);
    _adopt(client, initialized);
    phase = ConnectionPhase.needsAuth;
    error = hadSecret ? _notAccepted : null;
    _notify();
  }

  /// Let go of everything the screens were showing, which belonged to a
  /// connection that will not come back.  What was typed stays ([drafts]).
  Future<void> _forgetScreens() => _teardown(keepPhase: true);

  /// Use [client], the new connection, in place of the lost one: the api
  /// and everything built on it carry on over it, and what they show is read
  /// again.
  void _resume(
    AcpClient client,
    HarnessCapabilities caps,
    String secret,
    int generation,
  ) {
    capabilities = caps;
    api!.rebind(client, caps);
    client.requestHandler = _onAgentRequest;
    final previous = _subscription;
    _client = client;
    _subscription = client.notifications.listen(_onNotification);
    unawaited(previous?.cancel());
    _secret = secret;
    lostReason = null;
    reconnectError = null;
    reconnectAttempt = 0;
    error = null;
    phase = ConnectionPhase.connected;
    _watch(client, generation);
    _notify();
  }

  /// Read again what the screens show, which may have changed while the
  /// connection was out.
  Future<void> _refreshAfterReconnect(int generation) async {
    _ensureControllers();
    await refreshSessions();
    if (generation != _connectionGeneration || !isConnected) return;
    await refreshProjects();
    if (tasks != null) {
      unawaited(tasks!.reload(showSpinner: false));
    }
    if (usage != null) {
      unawaited(usage!.load(project: selectedProject, showSpinner: false));
    }
    if (quota != null) unawaited(quota!.load());
    unawaited(refreshServer());
    // The open conversation: its transcript, and the requests that were
    // waiting for an answer when the connection went.  The others read
    // themselves again when they are opened.
    final open = activeSession;
    if (open != null) unawaited(open.open());
  }

  /// A harness that came back with more to offer than it had.
  void _ensureControllers() {
    final service = api;
    if (service == null) return;
    if (capabilities?.tasks == true && tasks == null) {
      tasks = TaskController(service);
    }
    if (capabilities?.usage == true && usage == null) {
      usage = UsageController(service);
    }
    if (capabilities?.quota == true && quota == null) _startQuota(service);
  }

  Future<void> _waitToRetry(int failures) {
    final index = failures - 1 < reconnectDelays.length
        ? failures - 1
        : reconnectDelays.length - 1;
    final delay = reconnectDelays.isEmpty
        ? const Duration(seconds: 15)
        : reconnectDelays[index];
    final wake = Completer<void>();
    _reconnectWake = wake;
    _reconnectTimer = Timer(delay, () {
      if (!wake.isCompleted) wake.complete();
    });
    _notify();
    return wake.future;
  }

  /// End the wait between two attempts, whether it ran out or not.
  void _wakeReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final wake = _reconnectWake;
    _reconnectWake = null;
    if (wake != null && !wake.isCompleted) wake.complete();
    // And the wait for the app to come back, which re-checks that it has.
    final away = _foregroundWake;
    _foregroundWake = null;
    if (away != null && !away.isCompleted) away.complete();
  }

  /// Wait for the app to be on screen; stop waiting when the attempts it
  /// waits for are no longer [wanted] (the connection is back, or the person
  /// took over).
  Future<void> _untilForeground(bool Function() wanted) async {
    while (!_foreground && wanted()) {
      final wake = _foregroundWake ??= Completer<void>();
      await wake.future;
    }
  }

  /// Whether the app is on screen.  While it is not, it does not try to
  /// connect again (see [_reconnect]): the network of a phone that is put
  /// away is asleep, and the harness would only be asked in vain.  It
  /// starts again the moment the app is back ([resumed]).
  void setForeground(bool value) {
    if (_foreground == value) return;
    _foreground = value;
    if (value) {
      final away = _foregroundWake;
      _foregroundWake = null;
      if (away != null && !away.isCompleted) away.complete();
    }
  }

  /// Try to connect again now, instead of when the next attempt is due.
  void retryNow() {
    if (waitingToRetry) _wakeReconnect();
  }

  /// Connect again now, in place: the screens stay as they are, and so does
  /// what was typed on them.  With a connection, it is dropped for a new
  /// one; while one is being got back, the next attempt is made at once;
  /// with none, it is made from the address and secret this device holds.
  Future<void> reconnect() async {
    switch (phase) {
      case ConnectionPhase.connected:
        _lose('You asked to reconnect.');
      case ConnectionPhase.reconnecting:
        retryNow();
      case ConnectionPhase.disconnected:
      case ConnectionPhase.failed:
      case ConnectionPhase.needsAuth:
        final target = address ?? settings.address;
        if (target.isNotEmpty) {
          await connect(
            target,
            token: _secret.isNotEmpty ? _secret : settings.token,
          );
        }
      case ConnectionPhase.connecting:
      case ConnectionPhase.authenticating:
        break;
    }
  }

  /// Whether the connection that looks open still is, and if not, get it back
  /// at once.  A phone puts a connection to sleep without a word while the
  /// app is away, and a request for something real only finds out after
  /// minutes.
  Future<void> checkConnection() async {
    if (isReconnecting || resuming) {
      retryNow();
      return;
    }
    final client = _client;
    if (!isConnected || client == null) return;
    if (client.isClosed) {
      _lose(client.closeReason ?? 'The connection was closed.');
      return;
    }
    final alive = await client.probe(timeout: probeTimeout);
    if (!alive && identical(client, _client) && isConnected) {
      _lose(client.closeReason ?? 'The harness did not answer.');
    }
  }

  /// The app came back to the foreground.
  Future<void> resumed() {
    setForeground(true);
    return checkConnection();
  }

  Future<void> _teardown({bool keepPhase = false}) async {
    _sessionRefresh?.cancel();
    _sessionRefresh = null;
    _wakeReconnect();
    lostReason = null;
    reconnectError = null;
    reconnectAttempt = 0;
    // Cancelled now; the future that says it is done is not waited for, as
    // nothing here depends on it.
    unawaited(_subscription?.cancel());
    _subscription = null;
    unawaited(_degradedSubscription?.cancel());
    _degradedSubscription = null;
    final client = _client;
    _client = null;
    api?.dispose();
    api = null;
    capabilities = null;
    signingInWith = null;
    for (final controller in _sessions.values) {
      controller.dispose();
    }
    _sessions.clear();
    _sessionSignatures.clear();
    _internalSessions.clear();
    sessions = const [];
    projects = const [];
    selectedProject = null;
    _projectChosen = false;
    _roots = const ProjectRoots.empty();
    _resolvedMains.clear();
    _askedMains.clear();
    tasks = null;
    usage = null;
    _stopQuota();
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

  static const _notAccepted =
      'The harness did not accept this device\'s session: it may have been '
      'revoked, or have expired. Sign in again below.';

  String _cleanError(Object failure, {bool hadSecret = false}) {
    if (failure is AcpException) return failure.message;
    final text = '$failure';
    // dart:io reports a refused upgrade as "not upgraded to websocket"
    // (some SDKs add the status).  A harness lets a connection in so that
    // it can sign in; it refuses one only when its address has been refused
    // too often (HTTP 429), or its listener has too many connections.
    if (text.contains('status code: 429') ||
        text.contains('was not upgraded to websocket')) {
      return hadSecret
          ? 'The harness refused this connection: too many devices are '
                'signing in at once, or this address was refused too often '
                'lately. Wait a minute and try again.'
          : 'The harness refused this connection: too many devices are '
                'signing in at once. Wait a minute and try again.';
    }
    // A browser reports no reason at all for a refused upgrade.
    if (kIsWeb && text.contains('WebSocket connection failed')) {
      return 'Could not open the connection. A browser cannot say why: the '
          'harness may be unreachable, or its address may be refused for '
          'now.';
    }
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
    ++_connectionGeneration;
    _sessionRefresh?.cancel();
    _wakeReconnect();
    _subscription?.cancel();
    _degradedSubscription?.cancel();
    for (final controller in _sessions.values) {
      controller.dispose();
    }
    _sessions.clear();
    api?.dispose();
    unawaited(_client?.close());
    drafts.dispose();
    super.dispose();
  }
}
