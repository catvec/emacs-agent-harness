import 'dart:async';
import 'dart:convert';

import 'package:harness_client/src/acp/acp_message.dart';
import 'package:harness_client/src/acp/acp_transport.dart';
import 'package:harness_client/src/acp/connection_target.dart';

import 'harness_tools.dart';
import 'tool_showcase.dart';

/// In-memory ACP transport: the client's writes go to [onSend], the harness's
/// messages arrive on [messages].
class FakeTransport implements AcpTransport {
  FakeTransport();

  final _incoming = StreamController<String>.broadcast();
  final _done = Completer<void>();
  void Function(String message)? onSend;
  bool _open = true;

  @override
  Stream<String> get messages => _incoming.stream;

  @override
  Future<void> get done => _done.future;

  @override
  bool get isOpen => _open;

  @override
  String get description => 'memory://fake-harness';

  String? _closeReason;

  @override
  String? get closeReason => _closeReason;

  @override
  void send(String message) {
    if (!_open) throw StateError('closed');
    onSend?.call(message);
  }

  void harnessSend(String message) {
    if (_open) _incoming.add(message);
  }

  /// The harness's end of the connection goes away: it closed it, or the
  /// network did.  The client finds out, as it would from a socket.
  Future<void> dropConnection([
    String reason = 'The connection dropped.',
  ]) async {
    if (!_open) return;
    _closeReason = reason;
    await close();
  }

  @override
  Future<void> close([String? reason]) async {
    if (!_open) return;
    _open = false;
    await _incoming.close();
    if (!_done.isCompleted) _done.complete();
  }
}

/// A small, scripted harness that speaks real ACP JSON-RPC over [FakeTransport].
/// It mirrors the shapes of the emacs-agent-harness closely enough to exercise
/// every client flow, and can pretend to be a plain ACP agent with
/// [enhanced] false.
class FakeHarness {
  FakeHarness({
    this.enhanced = true,
    this.token,
    this.failAuthOnce = false,
    this.reducedBeforeAuth = false,
    this.rotateTo,
    this.signIn = false,
    this.oidcUrl,
    this.issueSecret,
    this.projectMains = true,
    this.tidyProjects = true,
    this.taskPictures = true,
    this.quota = true,
    this.toolCatalogue = true,
    Set<String>? knownSecrets,
  }) : knownSecrets = knownSecrets ?? <String>{} {
    if (enhanced) {
      methods.addAll({
        'session/list',
        'session/get',
        'session/nodes',
        'session/update',
        'session/fork',
        'session/delete',
        'agent/activity',
        'agent/prompt',
        'priority/set',
        'permission/pending',
        'permission/answer',
        'permission/deny',
        'question/pending',
        'question/answer',
        'question/image',
        'question/cancel',
        'task/list',
        'task/get',
        'task/submit',
        'task/start',
        'task/queue',
        'task/verify',
        'task/reject',
        'task/prompt',
        'task/retry',
        'task/cancel',
        'task/complete',
        'task/archive',
        'task/slots',
        'task/settings',
        'task/toggle-queue',
        'task/toggle-backlog-mode',
        'usage/totals',
        'usage/summary',
        'usage/live-all',
        'usage/rates',
        'usage/budgets',
        'insights/projects',
        if (projectMains) 'project/mains',
        'provider/list',
        'provider/models',
        if (quota) 'provider/quota',
        'harness/version',
        'harness/modules',
        'config/describe',
        if (toolCatalogue) 'tools/list',
      });
      events.addAll({
        'session/created',
        'session/node-added',
        'session/node-updated',
        'agent/turn-started',
        'agent/turn-ended',
        'agent/activity-changed',
        'agent/stream',
        'question/asked',
        'task/changed',
        'task/review',
        'task/done',
        'usage/live-updated',
        'usage/rates-updated',
        'usage/budgets-changed',
        'session/status',
        'permission/requested',
        if (quota) 'provider/quota-updated',
      });
    }
    _seed();
  }

  final bool enhanced;
  final String? token;
  final bool failAuthOnce;

  /// Whether the harness offers `project/mains`, which says what checkout a
  /// directory is a git worktree of.  An older harness does not.
  final bool projectMains;

  /// Whether the harness lists only checkouts as its projects, and knows that
  /// a scratch directory (one in the temporary directory of a session, such
  /// as an agent gives a sub-agent to work in) is no project's: it says the
  /// project of the session whose directory it is, and none when that
  /// session is gone.  An older one lists the directories its sessions and
  /// tasks work in, worktrees and scratch directories among them, and takes
  /// a scratch directory for a checkout of its own.
  final bool tidyProjects;

  /// Whether the harness takes pictures sent as data with a task, which its
  /// `task/settings` say (`inlineAttachments`).  An older harness does not
  /// say, and would lose them.
  final bool taskPictures;

  /// Whether the harness offers `provider/quota`: the billing and plan quota
  /// of the providers that report one.  An older harness does not.
  final bool quota;

  /// What each provider that reports its quota last said, as
  /// `provider/quota` answers: Claude on a Max plan, Copilot on a Pro one.
  /// A provider that says nothing is not in the map.
  final Map<String, Map<String, Object?>> quotas = {};

  /// How many times a client asked `provider/quota` to ask its source again.
  int quotaRefreshes = 0;

  /// Make `provider/quota` fail, as a provider whose probe goes wrong does.
  bool failQuota = false;

  /// Whether the harness offers `tools/list`: its tools, what people call
  /// them, and the allow list of the calls a chat folds into runs.  An older
  /// harness does not, and the app then folds nothing.
  final bool toolCatalogue;

  /// What `tools/list` answers: the harness's real tools (see
  /// `harness_tools.dart`), which a test may change to see what the app does
  /// with other ones.
  final List<Map<String, Object?>> toolSpecs = harnessToolSpecs();

  /// Make `tools/list` fail, as a harness that goes wrong does.
  bool failToolList = false;

  /// Where git worktrees that are not in the `.worktrees` of their checkout
  /// are, as a repository's `.git` says it: worktree -> checkout.  An older
  /// harness made them beside the repository.
  final Map<String, String> worktreeOf = {
    '/Users/noah/Code/emacs-agent-harness-worktrees/task-old-layout/':
        '/Users/noah/Code/emacs-agent-harness/',
  };

  /// Like a remote listener serving plain TCP: before `authenticate`,
  /// `initialize` gives only the reduced result, with no `_harness` object.
  final bool reducedBeforeAuth;

  /// Like a harness whose session secret for this device is due to be
  /// replaced: a client that says it can keep a new one (`_harness.
  /// sessionRefresh` in its `initialize`) is given this one.
  final String? rotateTo;

  /// Whether a client said it can keep a replacement secret.
  bool sessionRefreshAsked = false;

  /// Like the harness's listener for other devices: a connection that
  /// brought no session secret it knows may `initialize` and `authenticate`
  /// and nothing else.  `initialize` lists "Approve in Emacs" (and, with
  /// [oidcUrl], a login in the browser), and `authenticate` waits for the
  /// test to [approve] or [deny] it.
  final bool signIn;

  /// Where the login at the identity provider is, for a harness that
  /// offers one.
  final String? oidcUrl;

  /// The session secret a harness hands a client that said it can keep
  /// one, in the answer to `authenticate`.
  final String? issueSecret;

  /// Session secrets this harness already knows: a connection that opens
  /// with one is signed in.
  final Set<String> knownSecrets;

  /// The code the person at Emacs compares.
  String signInCode = '4719';

  /// What the last client said of itself in `initialize`.
  Map<String, Object?> lastClientInfo = const {};

  /// The methods `authenticate` was called with, in order.
  final List<String> signInAttempts = [];

  Completer<bool>? _waiting;

  /// The person at Emacs approves the device that waits.
  void approve() => _waiting?.complete(true);

  /// The person at Emacs refuses it.
  void deny() => _waiting?.complete(false);

  /// Whether `authenticate` waits for somebody.
  bool get waitingForApproval => _waiting != null && !_waiting!.isCompleted;

  /// What `insights/projects` answers, when a test wants a harness with other
  /// projects than the two it has.
  List<String>? projectList;

  /// Make `session/list` fail, as a harness that goes wrong after it let the
  /// client in does.
  bool failSessionList = false;

  /// How many of the next connections are refused, as a harness that is
  /// down (or a network that is) refuses them.
  int refuseConnects = 0;

  /// How many connections were opened to this harness, the refused ones
  /// not counted.
  int connects = 0;

  /// A harness that stopped answering without closing the connection, as
  /// one on a network that died without a word does: what the client sends
  /// goes nowhere.
  bool silent = false;

  /// How many of the next connections are silent from the start: the
  /// harness takes the connection and never answers on it.
  int silentConnects = 0;
  final methods = <String>{};
  final events = <String>{};
  bool authenticated = false;
  bool authFailed = false;
  FakeTransport? transport;
  final Map<String, Map<String, Object?>> sessions = {};
  final Map<String, List<Map<String, Object?>>> nodes = {};
  final Map<String, Map<String, Object?>> tasks = {};
  final List<Map<String, Object?>> permissionAnswers = [];
  final List<Map<String, Object?>> questionAnswers = [];

  /// The pending ids of the questions the client dismissed.
  final List<String> questionCancels = [];

  /// Make `question/answer` fail, as a harness that goes wrong does.
  bool failQuestionAnswers = false;
  final List<String> prompts = [];
  final List<String> requestsByClient = [];

  /// Every request the client made, with its params, in order.
  final List<(String, JsonMap)> requests = [];
  final Map<String, Completer<Map<String, Object?>>> _serverRequests = {};
  final Map<String, Map<String, Object?>> _serverRequestParams = {};
  void Function(String message)? writer;
  int _nextServerRequest = 1;
  int _generated = 0;

  Future<AcpTransport> Function(ConnectionTarget target, String token)
  get connector => (ConnectionTarget target, String token) async {
    if (refuseConnects > 0) {
      refuseConnects--;
      throw Exception('Connection refused');
    }
    connects++;
    silent = silentConnects > 0;
    if (silentConnects > 0) silentConnects--;
    // A listener that lets a device sign in, as it opens: a secret it knows
    // signs the connection in, any other is as none.
    if (signIn) {
      authenticated = token.isNotEmpty && knownSecrets.contains(token);
    } else if (this.token != null && !target.isTcp) {
      // A WebSocket that presented the secret as it opened was let in; plain
      // TCP signs in with `authenticate`.
      authenticated = token == this.token;
    }
    return attach();
  };

  FakeTransport attach() {
    final fake = FakeTransport();
    transport = fake;
    fake.onSend = _receive;
    return fake;
  }

  /// The connection goes away from the harness's side.
  Future<void> dropConnection([String? reason]) async {
    final fake = transport;
    if (fake == null) return;
    await (reason == null
        ? fake.dropConnection()
        : fake.dropConnection(reason));
  }

  /// For a server wrapper: hand a client's raw message to the harness.
  void handleMessage(String message) => _receive(message);

  Future<AcpTransport> open(ConnectionTarget target, String token) =>
      connector(target, token);

  void _seed() {
    final now = DateTime.now();
    sessions['s1'] = {
      'id': 's1',
      'name': 'Design the merge queue',
      'kind': 'main',
      'project': '/Users/noah/Code/emacs-agent-harness/',
      'cwd': '/Users/noah/Code/emacs-agent-harness/',
      'model': 'claude:claude-fable-5-1',
      'permissionMode': 'ask',
      'status': 'idle',
      'created':
          now.subtract(const Duration(days: 2)).millisecondsSinceEpoch / 1000,
      'updated':
          now.subtract(const Duration(minutes: 12)).millisecondsSinceEpoch /
          1000,
      'lastMessage':
          now.subtract(const Duration(minutes: 12)).millisecondsSinceEpoch /
          1000,
      // A Max plan pays for the calls: nothing billed per token, what they
      // come to at API prices as the value the plan covered.
      'usage': {
        'input': 42000,
        'output': 8100,
        'cacheRead': 31000,
        'cacheWrite': 1200,
        'cost': 0.0,
        'listCost': 3.25,
        'billing': 'subscription',
        'plan': 'max',
        'context': 52300,
        'lastOutput': 900,
        'turns': 14,
      },
      'contextWindow': 200000,
      'todos': [
        {
          'id': 't1',
          'text': 'Read the merge queue and its tests',
          'status': 'done',
        },
        {
          'id': 't2',
          'text': 'Sketch the queue states on a card',
          'status': 'done',
        },
        {
          'id': 't3',
          'text': 'Implement the Flutter board view',
          'status': 'in-progress',
        },
        {
          'id': 't4',
          'text': 'Drive the flows in an emulator',
          'status': 'pending',
        },
      ],
      'plan': 'Ship a native client for the harness.',
      'pending': [],
      'queue': [],
    };
    sessions['s2'] = {
      'id': 's2',
      'name': 'Fix duplicate task titles',
      'kind': 'main',
      'project': '/Users/noah/Code/emacs-agent-harness/',
      'cwd': '/Users/noah/Code/emacs-agent-harness/.worktrees/task-fix-titles/',
      'model': 'claude:claude-fable-5-1',
      'permissionMode': 'accept-edits',
      'status': 'blocked',
      'created':
          now.subtract(const Duration(hours: 1)).millisecondsSinceEpoch / 1000,
      'updated':
          now.subtract(const Duration(minutes: 3)).millisecondsSinceEpoch /
          1000,
      'lastMessage':
          now.subtract(const Duration(minutes: 3)).millisecondsSinceEpoch /
          1000,
      // Past the plan's window: billed as extra usage at API prices.
      'usage': {
        'input': 8800,
        'output': 2100,
        'cacheRead': 6000,
        'cost': 0.12,
        'listCost': 1.12,
        'billing': 'extra-usage',
        'plan': 'max',
        'context': 11800,
        'lastOutput': 300,
        'turns': 3,
      },
      'contextWindow': 200000,
      'todos': [],
      'pending': [
        {
          'id': 'p-s2',
          'kind': 'permission',
          'created':
              now.subtract(const Duration(minutes: 3)).millisecondsSinceEpoch /
              1000,
          'payload': {
            'tool': 'bash',
            'kind': 'exec',
            'title': 'Run the test suite',
            'call-id': 'call-fix-1',
            'input': {'command': 'flutter test test/sessions_test.dart'},
            'cwd': '/Users/noah/Code/emacs-agent-harness/.worktrees/task-fix-titles/',
            'paths': [
              '/Users/noah/Code/emacs-agent-harness/.worktrees/task-fix-titles/',
            ],
          },
        },
      ],
      'queue': [],
    };
    sessions['s3'] = {
      'id': 's3',
      'name': 'Polish the iOS sheet',
      'kind': 'fork',
      'project': '/Users/noah/Code/emacs-agent-harness/',
      'cwd': '/Users/noah/Code/emacs-agent-harness/',
      'model': 'claude:claude-haiku-4-5',
      'permissionMode': 'auto',
      'status': 'running',
      'created':
          now.subtract(const Duration(minutes: 40)).millisecondsSinceEpoch /
          1000,
      'updated':
          now.subtract(const Duration(seconds: 40)).millisecondsSinceEpoch /
          1000,
      'lastMessage':
          now.subtract(const Duration(minutes: 1)).millisecondsSinceEpoch /
          1000,
      'usage': {
        'input': 12000,
        'output': 4300,
        'cacheRead': 9000,
        'cost': 0.0,
        'listCost': 0.18,
        'billing': 'subscription',
        'plan': 'max',
        'context': 21000,
        'lastOutput': 500,
        'turns': 5,
      },
      'contextWindow': 128000,
      'todos': [
        {
          'id': 'p1',
          'text': 'Match the iOS sheet motion',
          'status': 'in-progress',
        },
        {'id': 'p2', 'text': 'Check the dark palette', 'status': 'pending'},
      ],
      'pending': [],
      'queue': [],
    };
    sessions['s4'] = {
      'id': 's4',
      'name': 'Investigate cache misses',
      'kind': 'btw',
      'project': '/Users/noah/Code/other-project/',
      'cwd': '/Users/noah/Code/other-project/',
      'model': 'deepseek:deepseek-chat',
      'permissionMode': 'ask',
      'status': 'inactive',
      'created':
          now.subtract(const Duration(days: 4)).millisecondsSinceEpoch / 1000,
      'updated':
          now.subtract(const Duration(days: 1)).millisecondsSinceEpoch / 1000,
      'lastMessage':
          now.subtract(const Duration(days: 1)).millisecondsSinceEpoch / 1000,
      'usage': {
        'input': 22000,
        'output': 5100,
        'cacheRead': 900,
        'cost': 0.21,
        'listCost': 0.21,
        'context': 27300,
        'lastOutput': 400,
        'turns': 8,
      },
      'contextWindow': 128000,
      'todos': [],
      'pending': [],
      'queue': [],
    };
    nodes['s1'] = [
      _node('n1', 'user', 'Give me the tour of the merge queue.'),
      _node(
        'n2',
        'assistant',
        'The merge queue has three moving parts:\n\n1. **Queued** branches wait for a slot.\n2. **Merging** runs one at a time.\n3. **Conflicts** go back to the task’s own session.\n\n```dart\nfinal queue = MergeQueue();\n```\n\nWant me to open a task for the board view?',
        meta: {'model': 'claude:claude-fable-5-1'},
      ),
      _node(
        'n3',
        'tool-call',
        '',
        tool: 'read_file',
        callId: 'call-1',
        title: 'Read file: docs/modules/merge.md',
        input: {'path': 'docs/modules/merge.md'},
      ),
      _node(
        'n4',
        'tool-result',
        '',
        callId: 'call-1',
        output: 'The merge queue merges one branch at a time…',
      ),
      _node(
        'n5',
        'assistant',
        'The module is clear: the UI only needs to show states, never drive the merge.',
        meta: {'model': 'claude:claude-fable-5-1'},
      ),
      _node('n6', 'hint', 'Context compacted from 214k tokens to 52k.'),
    ];
    nodes['s2'] = [
      _node(
        'm1',
        'user',
        'Run the session tests before we rename the duplicate titles.',
      ),
      _node(
        'm2',
        'tool-call',
        '',
        tool: 'bash',
        callId: 'call-fix-1',
        title: 'Run the test suite',
        input: {'command': 'flutter test test/sessions_test.dart'},
      ),
    ];
    nodes['s3'] = [
      _node('p1', 'user', 'Make the bottom sheet feel native on iOS.'),
      _node(
        'p2',
        'thinking',
        'The sheet needs the large radius, a grabber and spring motion.',
      ),
      _node(
        'p3',
        'assistant',
        'I’m matching the sheet to the system motion and checking the dark palette now.',
      ),
      _node(
        'p4',
        'tool-call',
        '',
        tool: 'edit_file',
        callId: 'call-ios-1',
        title: 'Edit file: lib/sheet.dart',
        input: {'path': 'lib/sheet.dart'},
      ),
    ];
    nodes['s4'] = [
      _node('c1', 'user', 'Why did the prompt cache miss twice?'),
      _node(
        'c2',
        'assistant',
        'The cache lapsed between the two calls: the first was 11 minutes after the last write.',
      ),
    ];

    tasks['task-1'] = {
      'id': 'task-1',
      'name': 'Build the Flutter ACP client',
      'prompt': 'Create a Flutter client that speaks ACP and uses the harness extensions.',
      'state': 'active',
      'column': 'active',
      'priority': 'high',
      'project': '/Users/noah/Code/emacs-agent-harness/',
      'cwd': '/Users/noah/Code/emacs-agent-harness/.worktrees/task-flutter/',
      'session': 's3',
      'branch': 'task/flutter-acp-client',
      'worktree':
          '/Users/noah/Code/emacs-agent-harness/.worktrees/task-flutter/',
      'created':
          now.subtract(const Duration(hours: 3)).millisecondsSinceEpoch / 1000,
      'updated':
          now.subtract(const Duration(minutes: 2)).millisecondsSinceEpoch /
          1000,
    };
    tasks['task-2'] = {
      'id': 'task-2',
      'name': 'Review the emulator screenshots',
      'prompt': 'Check every flow and screenshot on both device sizes.',
      'state': 'review',
      'column': 'review',
      'priority': 'medium',
      'project': '/Users/noah/Code/emacs-agent-harness/',
      'cwd': '/Users/noah/Code/emacs-agent-harness/.worktrees/task-screens/',
      'branch': 'task/screenshots',
      'created':
          now.subtract(const Duration(hours: 2)).millisecondsSinceEpoch / 1000,
      'updated':
          now.subtract(const Duration(minutes: 9)).millisecondsSinceEpoch /
          1000,
      'report': {
        'summary': 'All flows pass at 390×844 and 412×915; screenshots are in screenshots/.',
        'evidence': [
          {
            'image': 'screenshots/android-chat.png',
            'caption': 'Chat with a tool card',
          },
          {'note': 'flutter test: 38 passing'},
        ],
        'reproduction': 'Open the app, connect to the preview harness, and walk Sessions → Tasks.',
      },
    };
    tasks['task-3'] = {
      'id': 'task-3',
      'name': 'Cache the model catalogue',
      'prompt': 'Remember provider/model results for a minute.',
      'state': 'pending',
      'column': 'pending',
      'priority': 'low',
      'project': '/Users/noah/Code/emacs-agent-harness/',
      'cwd': '/Users/noah/Code/emacs-agent-harness/',
      'created':
          now.subtract(const Duration(minutes: 50)).millisecondsSinceEpoch /
          1000,
      'updated':
          now.subtract(const Duration(minutes: 40)).millisecondsSinceEpoch /
          1000,
    };
    tasks['task-4'] = {
      'id': 'task-4',
      'name': 'Answer the permission',
      'prompt': 'The test suite needs to run.',
      'state': 'active',
      'column': 'needs-input',
      'priority': 'high',
      'project': '/Users/noah/Code/emacs-agent-harness/',
      'cwd': '/Users/noah/Code/emacs-agent-harness/.worktrees/task-fix-titles/',
      'session': 's2',
      'branch': 'task/fix-titles',
      'created':
          now.subtract(const Duration(minutes: 30)).millisecondsSinceEpoch /
          1000,
      'updated':
          now.subtract(const Duration(minutes: 3)).millisecondsSinceEpoch /
          1000,
    };
    tasks['task-5'] = {
      'id': 'task-5',
      'name': 'Write the migration notes',
      'prompt': 'Write up what moved in the protocol.',
      'state': 'pending',
      'column': 'backlog',
      'priority': 'medium',
      'backlog': true,
      'project': '/Users/noah/Code/emacs-agent-harness/',
      'cwd': '/Users/noah/Code/emacs-agent-harness/',
      'created':
          now.subtract(const Duration(hours: 5)).millisecondsSinceEpoch / 1000,
      'updated':
          now.subtract(const Duration(hours: 4)).millisecondsSinceEpoch / 1000,
    };
    tasks['task-6'] = {
      'id': 'task-6',
      'name': 'Ship the session list',
      'prompt': 'A native session list.',
      'state': 'done',
      'column': 'done',
      'priority': 'medium',
      'project': '/Users/noah/Code/emacs-agent-harness/',
      'cwd': '/Users/noah/Code/emacs-agent-harness/',
      'created':
          now.subtract(const Duration(days: 1)).millisecondsSinceEpoch / 1000,
      'updated':
          now.subtract(const Duration(hours: 20)).millisecondsSinceEpoch / 1000,
      'verified': true,
    };
    if (quota) _seedQuotas(now);
  }

  /// What the providers that report a plan's quota say: Claude on a Max plan
  /// with its 5-hour and weekly windows, Copilot on a Pro one with a
  /// month's premium requests.  DeepSeek bills per token and says nothing.
  void _seedQuotas(DateTime now) {
    double at(Duration after) => now.add(after).millisecondsSinceEpoch / 1000;
    quotas['claude'] = {
      'billing': 'subscription',
      'plan': 'max',
      'plan-label': 'Claude Max',
      'auth': 'claude.ai',
      'account': {'email': 'noah@example.com'},
      'available': true,
      'windows': [
        {
          'name': '5h',
          'label': 'Current session (5 hours)',
          'used': 0.23,
          'resets': at(const Duration(hours: 3, minutes: 12)),
        },
        {
          'name': '7d',
          'label': 'This week, all models',
          'used': 0.41,
          'resets': at(const Duration(days: 3, hours: 5)),
        },
        {
          'name': '7d Fable',
          'label': 'This week, Fable',
          'used': 0.18,
          'resets': at(const Duration(days: 3, hours: 5)),
        },
      ],
      'extra': {
        'enabled': false,
        'used': 0.0,
        'limit': 50.0,
        'currency': 'USD',
        'disabled-reason': 'out_of_credits',
      },
      'limit-status': 'allowed',
      'using-extra': false,
      'updated': at(const Duration(minutes: -4)),
    };
    quotas['copilot'] = {
      'billing': 'subscription',
      'plan': 'pro',
      'plan-label': 'GitHub Copilot Pro',
      'auth': 'github',
      'available': true,
      'windows': [
        {
          'name': 'premium',
          'label': 'Premium requests this month (93 of 300)',
          'used': 0.31,
          'resets': at(const Duration(days: 9, hours: 2)),
        },
      ],
      'updated': at(const Duration(minutes: -12)),
    };
  }

  /// A provider tells a new quota, as it does when a turn used some of its
  /// plan: it is kept for `provider/quota` and announced to the client.
  void updateQuota(String provider, Map<String, Object?> next) {
    quotas[provider] = next;
    _event('provider/quota-updated', [provider, next]);
  }

  /// The checkout the git worktree at [directory] was made from, or
  /// [directory] itself when it is no worktree: what its `.git` file says.
  /// For a scratch directory of a [tidyProjects] harness the checkout of the
  /// project of the session whose directory it is, or '' for none.
  String mainCheckoutOf(String directory) {
    final known = worktreeOf[directory];
    if (known != null) return known;
    final at = directory.indexOf('/.worktrees/');
    if (at > 0) return directory.substring(0, at + 1);
    if (tidyProjects) {
      final owner = _scratchOwner.firstMatch(directory)?.group(1);
      if (owner != null) {
        final project = sessions[owner]?['project'];
        return project is String ? mainCheckoutOf(project) : '';
      }
    }
    return directory;
  }

  static final _scratchOwner = RegExp(
    r'/harness-[0-9]+/'
    r'([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/',
  );

  /// What `insights/projects` lists: the checkouts, and for an older harness
  /// the directories its tasks and its sessions in scratch directories work
  /// in besides.
  List<String> listedProjects() => <String>{
    ...?projectList,
    if (projectList == null) ...[
      '/Users/noah/Code/emacs-agent-harness/',
      '/Users/noah/Code/other-project/',
    ],
    if (!tidyProjects) ..._untidyProjects(),
  }.toList()..sort();

  Set<String> _untidyProjects() => {
    for (final task in tasks.values)
      if (task['project'] case final String project) project,
    for (final session in sessions.values)
      if (session['project'] case final String project)
        if (_scratchOwner.hasMatch(project)) project,
  };

  /// Sessions as a harness whose agents work in scratch directories has
  /// them: [scratchOwner], a session of the checkout, started sub-agents in
  /// directories of its own temporary directory, which is where
  /// `/tmp/harness-UID/ID/` is; another's, [goneOwner], is not a session any
  /// more.  And a task that was made from inside an old worktree, which
  /// therefore has the worktree for its project.
  static const scratchOwner = '6f2c1a90-1111-4222-8333-444444444444';
  static const goneOwner = '6f2c1a90-2222-4222-8333-555555555555';

  void seedScratchSessions() {
    final now = DateTime.now();
    void add(String id, String name, String kind, String directory) {
      sessions[id] = {
        'id': id,
        'name': name,
        'kind': kind,
        'project': directory,
        'cwd': directory,
        'model': 'claude:claude-fable-5-1',
        'permissionMode': 'auto',
        'status': 'inactive',
        'created':
            now.subtract(const Duration(hours: 3)).millisecondsSinceEpoch /
            1000,
        'updated':
            now.subtract(const Duration(hours: 2)).millisecondsSinceEpoch /
            1000,
        'lastMessage':
            now.subtract(const Duration(hours: 2)).millisecondsSinceEpoch /
            1000,
        'contextWindow': 200000,
        'todos': [],
        'pending': [],
        'queue': [],
      };
      nodes[id] = [];
    }

    add(
      scratchOwner,
      'Compare the client libraries',
      'main',
      '/Users/noah/Code/emacs-agent-harness/',
    );
    add(
      'scratch-1',
      'Try the first client',
      'subagent',
      '/tmp/harness-1000/$scratchOwner/client-1/',
    );
    add(
      'scratch-2',
      'Try the second client',
      'subagent',
      '/tmp/harness-1000/$scratchOwner/client-2/',
    );
    add(
      'scratch-3',
      'Check the supervisor',
      'subagent',
      '/tmp/harness-1000/$goneOwner/wt/core/',
    );
    tasks['task-old'] = {
      'id': 'task-old',
      'name': 'Explain the concurrency limit',
      'prompt': 'Why does it say 3?',
      'state': 'done',
      'column': 'done',
      'priority': 'medium',
      'project':
          '/Users/noah/Code/emacs-agent-harness-worktrees/task-old-layout/',
      'cwd': '/Users/noah/Code/emacs-agent-harness-worktrees/task-old-layout/',
      'created':
          now.subtract(const Duration(days: 9)).millisecondsSinceEpoch / 1000,
      'updated':
          now.subtract(const Duration(days: 9)).millisecondsSinceEpoch / 1000,
      'verified': true,
    };
  }

  /// The board of a project other than the one the harness is mostly used
  /// for: a task at work and one to review, in `other-project`, whose
  /// sessions are not in the seed.  A harness has the work of every project
  /// it is used for, and a client that shows one project's must not hide
  /// the rest.
  void seedOtherProjectTasks() {
    final now = DateTime.now();
    tasks['task-7'] = {
      'id': 'task-7',
      'name': 'Deploy the docs site',
      'prompt': 'Publish the docs to the cluster.',
      'state': 'active',
      'column': 'active',
      'priority': 'medium',
      'project': '/Users/noah/Code/other-project/',
      'cwd': '/Users/noah/Code/other-project/.worktrees/task-docs-site/',
      'branch': 'task/docs-site',
      'worktree': '/Users/noah/Code/other-project/.worktrees/task-docs-site/',
      'created':
          now.subtract(const Duration(minutes: 45)).millisecondsSinceEpoch /
          1000,
      'updated':
          now.subtract(const Duration(minutes: 1)).millisecondsSinceEpoch /
          1000,
    };
    tasks['task-8'] = {
      'id': 'task-8',
      'name': 'Trim the cluster alerts',
      'prompt': 'Silence the alerts nobody acts on.',
      'state': 'review',
      'column': 'review',
      'priority': 'low',
      'project': '/Users/noah/Code/other-project/',
      'cwd': '/Users/noah/Code/other-project/.worktrees/task-alerts/',
      'branch': 'task/alerts',
      'created':
          now.subtract(const Duration(hours: 2)).millisecondsSinceEpoch / 1000,
      'updated':
          now.subtract(const Duration(minutes: 20)).millisecondsSinceEpoch /
          1000,
    };
  }

  /// Sessions as a harness that works in git worktrees has them.  A task's
  /// own session is filed under the checkout (see `s2`), but a sub-agent, or
  /// a session started to resolve a merge, that works in a worktree is
  /// filed under the worktree, a directory of its own to the session.  One
  /// worktree is in the `.worktrees` of its checkout, one beside the
  /// repository, as an older harness made them.
  void seedWorktreeSessions() {
    final now = DateTime.now();
    void add(String id, String name, String kind, String directory) {
      sessions[id] = {
        'id': id,
        'name': name,
        'kind': kind,
        'project': directory,
        'cwd': directory,
        'model': 'claude:claude-fable-5-1',
        'permissionMode': 'auto',
        'status': 'idle',
        'created':
            now.subtract(const Duration(hours: 2)).millisecondsSinceEpoch /
            1000,
        'updated':
            now.subtract(const Duration(minutes: 20)).millisecondsSinceEpoch /
            1000,
        'lastMessage':
            now.subtract(const Duration(minutes: 20)).millisecondsSinceEpoch /
            1000,
        'contextWindow': 200000,
        'todos': [],
        'pending': [],
        'queue': [],
      };
      nodes[id] = [];
    }

    add(
      'w1',
      'Review the title change',
      'subagent',
      '/Users/noah/Code/emacs-agent-harness/.worktrees/task-fix-titles/',
    );
    add(
      'w2',
      'Resolve the merge conflict',
      'main',
      '/Users/noah/Code/emacs-agent-harness/.worktrees/task-screens/',
    );
    add(
      'w3',
      'Port the old board',
      'main',
      '/Users/noah/Code/emacs-agent-harness-worktrees/task-old-layout/',
    );
    add(
      'w4',
      'Profile the model cache',
      'subagent',
      '/Users/noah/Code/other-project/.worktrees/task-cache/',
    );
  }

  /// A session that has done some work, as a task's does: tool calls of
  /// the kinds an agent makes, one that failed, one the permission system
  /// refused, and the `hand_in` call that ended it, with the report it
  /// handed in (see `tool_showcase.dart`).  It is not seeded by default, so
  /// the lists the other tests count stay as they are.
  void seedToolShowcase() {
    sessions[toolShowcaseId] = toolShowcaseSession();
    nodes[toolShowcaseId] = toolShowcaseNodes();
  }

  /// The agent adds [node] to session [sid]'s transcript while a client is
  /// open on it, and the client is sent it as the harness sends a live node:
  /// the ACP update, and the whole node beside it.
  void stream(String sid, Map<String, Object?> node) {
    (nodes[sid] ??= []).add(node);
    for (final update in _updatesForNode(node, replay: false)) {
      _send('session/update', {'sessionId': sid, 'update': update});
    }
  }

  /// Session [sid] asks the person to allow the call [callId], as the harness
  /// does before it runs a command it has no leave for.  The answer comes
  /// when the person gives it, and is kept in [permissionAnswers].
  Future<Map<String, Object?>> askPermission(
    String sid, {
    required String callId,
    String tool = 'bash',
    String title = 'Run the command',
  }) async {
    final response = await _requestClient('session/request_permission', {
      'sessionId': sid,
      'toolCall': {
        'toolCallId': callId,
        'title': title,
        'kind': 'execute',
        'rawInput': {'command': title},
      },
      'options': _permissionOptions,
      '_harness': {'pendingId': 'perm-$callId', 'tool': tool},
    });
    final answer = asMap(response['result']);
    permissionAnswers.add(answer);
    return answer;
  }

  static const _permissionOptions = <Map<String, Object?>>[
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
    {'optionId': 'deny-always', 'name': 'Always deny', 'kind': 'reject_always'},
  ];

  Map<String, Object?> _node(
    String id,
    String kind,
    String content, {
    String? tool,
    String? title,
    String? callId,
    Map<String, Object?>? input,
    String? output,
    bool isError = false,
    Map<String, Object?>? meta,
  }) {
    final map = <String, Object?>{
      'id': id,
      'kind': kind,
      'content': content,
      'ts': DateTime.now().millisecondsSinceEpoch / 1000,
      if (tool != null) 'tool': tool,
      if (title != null) 'title': title,
      if (callId != null) 'callId': callId,
      if (input != null) 'input': input,
      if (output != null) 'output': output,
      if (isError) 'isError': true,
      if (meta != null) 'meta': meta,
    };
    return map;
  }

  void _receive(String raw) {
    if (silent) return;
    final message = asMap(jsonDecode(raw));
    final method = asString(message['method']);
    final id = message['id'];
    if (method != null) {
      if (id == null) {
        _notification(method, asMap(message['params']));
      } else {
        requestsByClient.add(method);
        requests.add((method, asMap(message['params'])));
        unawaited(_request(method, asMap(message['params']), id));
      }
      return;
    }
    if (id != null) {
      final key = '$id';
      final completer = _serverRequests.remove(key);
      if (completer != null && !completer.isCompleted) {
        completer.complete({
          'result': message['result'],
          'error': message['error'],
        });
      }
    }
  }

  void _notification(String method, JsonMap params) {
    if (method == 'session/cancel') {
      final sid = asString(params['sessionId']);
      if (sid != null) _setStatus(sid, 'idle');
    }
  }

  Future<void> _request(String method, JsonMap params, Object? id) async {
    try {
      if (method == 'initialize') {
        final reduced = reducedBeforeAuth && token != null && !authenticated;
        final asked =
            asMap(
              asMap(params['clientCapabilities'])['_harness'],
            )['sessionRefresh'] ==
            true;
        if (asked) sessionRefreshAsked = true;
        lastClientInfo = asMap(params['clientInfo']);
        _respond(
          id,
          signIn && !authenticated
              ? _signInInitializeResult()
              : reduced
              ? _reducedInitializeResult()
              : _initializeResult(rotate: asked && rotateTo != null),
        );
        return;
      }
      if (signIn && method == 'authenticate') {
        await _signIn(id, params);
        return;
      }
      if (signIn && !authenticated) {
        _respondError(
          id,
          -32000,
          'Authentication required: call authenticate first',
          {'authMethods': _signInMethods()},
        );
        return;
      }
      if (method == 'authenticate') {
        if (token != null && asString(params['token']) != token) {
          _respondError(id, -32000, 'Invalid token');
          return;
        }
        authenticated = true;
        _respond(id, const <String, Object?>{});
        return;
      }
      if (token != null && !authenticated) {
        _respondError(id, -32000, 'Authentication required');
        return;
      }
      if (!enhanced && method.startsWith('_harness/')) {
        _respondError(id, -32601, 'Method not found: $method');
        return;
      }
      if (method == 'session/list') {
        if (failSessionList) {
          _respondError(id, -32603, 'The harness could not list sessions');
          return;
        }
        final cwd = asString(params['cwd']);
        final list = sessions.values
            .where(
              (session) => cwd == null || cwd.isEmpty || session['cwd'] == cwd,
            )
            .map(
              (session) =>
                  enhanced ? _sessionInfo(session) : _plainSessionInfo(session),
            )
            .toList();
        _respond(id, {
          'sessions': list,
          if (enhanced && list.length > 2) 'nextCursor': 'page-2',
        });
        return;
      }
      if (method == 'session/load') {
        final sid = asString(params['sessionId']);
        if (sid == null || !sessions.containsKey(sid)) {
          _respondError(id, -32603, 'No session $sid');
          return;
        }
        _replay(sid);
        _respond(id, const <String, Object?>{});
        return;
      }
      if (method == 'session/new') {
        final sid = 's${sessions.length + 1}';
        final cwd = asString(params['cwd']) ?? '/tmp';
        final harness = asMap(params['_harness']);
        sessions[sid] = {
          'id': sid,
          'name': asString(harness['name']) ?? 'New session',
          'kind': 'main',
          'project': cwd,
          'cwd': cwd,
          'model': asString(harness['model']) ?? 'claude:claude-fable-5-1',
          'permissionMode': 'ask',
          'status': 'idle',
          'created': DateTime.now().millisecondsSinceEpoch / 1000,
          'updated': DateTime.now().millisecondsSinceEpoch / 1000,
          'contextWindow': 200000,
          'todos': [],
          'pending': [],
          'queue': [],
        };
        nodes[sid] = [];
        _respond(id, {
          'sessionId': sid,
          'modes': {
            'currentModeId': 'ask',
            'availableModes': [
              {'id': 'ask', 'name': 'Ask'},
              {'id': 'accept-edits', 'name': 'Accept edits'},
              {'id': 'auto', 'name': 'Auto'},
              {'id': 'yolo', 'name': 'YOLO'},
            ],
          },
        });
        return;
      }
      if (method == 'session/prompt') {
        final sid = asString(params['sessionId']);
        if (sid == null) {
          _respondError(id, -32602, 'sessionId required');
          return;
        }
        prompts.add(_promptText(params['prompt']));
        _streamTurn(sid, _promptText(params['prompt']), id);
        return;
      }
      if (method == 'session/cancel') {
        _respond(id, const <String, Object?>{});
        return;
      }
      if (method == 'session/set_mode') {
        final sid = asString(params['sessionId']);
        final mode = asString(params['modeId']);
        if (sid != null && sessions[sid] != null && mode != null) {
          sessions[sid]!['permissionMode'] = mode;
          _pushSession(sid);
        }
        _respond(id, const <String, Object?>{});
        return;
      }
      if (method == 'session/set_model') {
        final sid = asString(params['sessionId']);
        final model = asString(params['modelId']);
        if (sid != null && sessions[sid] != null && model != null) {
          sessions[sid]!['model'] = model;
          _pushSession(sid);
        }
        _respond(id, const <String, Object?>{});
        return;
      }
      if (method == '_harness/session/list' && failSessionList) {
        _respondError(id, -32603, 'The harness could not list sessions');
        return;
      }
      if (method == '_harness/session/list') {
        _respond(id, enhanced ? sessions.values.toList() : const <Object?>[]);
        return;
      }
      if (method == '_harness/session/get') {
        final sid = asString(params['id']);
        _respond(id, sessions[sid] ?? const <String, Object?>{});
        return;
      }
      if (method == '_harness/session/nodes') {
        final sid = asString(params['id']);
        _respond(id, nodes[sid] ?? const <Object?>[]);
        return;
      }
      if (method == '_harness/session/update') {
        final sid = asString(params['id']);
        final name = asString(params['name']);
        if (sid != null && sessions[sid] != null && name != null) {
          sessions[sid]!['name'] = name;
          _pushSession(sid);
        }
        _respond(id, sessions[sid] ?? const <String, Object?>{});
        return;
      }
      if (method == '_harness/session/fork') {
        final parent = asString(params['id']);
        final sid = 'fork-${++_generated}';
        final copy = Map<String, Object?>.from(sessions[parent] ?? {});
        copy['id'] = sid;
        copy['name'] = 'Fork: ${copy['name']}';
        copy['kind'] = 'fork';
        copy['status'] = 'idle';
        sessions[sid] = copy;
        nodes[sid] = List<Map<String, Object?>>.from(nodes[parent] ?? const []);
        _respond(id, copy);
        return;
      }
      if (method == '_harness/session/delete') {
        final sid = asString(params['id']);
        if (sid != null) {
          sessions.remove(sid);
          nodes.remove(sid);
        }
        _respond(id, const <String, Object?>{});
        return;
      }
      if (method == '_harness/agent/activity') {
        _respond(id, const <String, Object?>{});
        return;
      }
      if (method == '_harness/priority/set') {
        _respond(id, const <String, Object?>{});
        return;
      }
      if (method == '_harness/permission/pending') {
        // As the harness answers it: the permission requests only.
        final sid = asString(params['session-id']);
        _respond(id, enhanced ? _pendingKind(sid, 'permission') : const []);
        return;
      }
      if (method == '_harness/question/pending') {
        final sid = asString(params['session-id']);
        _respond(id, enhanced ? _pendingKind(sid, 'question') : const []);
        return;
      }
      if (method == '_harness/permission/answer') {
        permissionAnswers.add(asMap(params['answer']));
        _respond(id, const <String, Object?>{});
        return;
      }
      if (method == '_harness/question/answer' && failQuestionAnswers) {
        _respondError(id, -32603, 'The harness could not take the answer');
        return;
      }
      if (method == '_harness/question/answer') {
        final answer = asMap(params['answer']);
        questionAnswers.add(answer);
        final sid = asString(params['session-id']);
        final pid = asString(params['pid']);
        if (sid != null && pid != null && sessions[sid] != null) {
          _resolve(sid, pid, asString(answer['answer']));
        }
        _respond(id, true);
        return;
      }
      if (method == '_harness/question/cancel') {
        final sid = asString(params['session-id']);
        final pid = asString(params['pid']);
        questionCancels.add(pid ?? '');
        if (sid != null && pid != null && sessions[sid] != null) {
          _resolve(sid, pid, null);
        }
        _respond(id, true);
        return;
      }
      if (method == '_harness/question/image') {
        _respond(id, {
          'mime': 'image/svg+xml',
          'data': base64Encode(utf8.encode(_sampleSvg)),
        });
        return;
      }
      if (method == '_harness/task/list') {
        // As the harness answers it: the tasks of one project when it is
        // given a `cwd`, every task of every project without.
        final cwd = asString(params['cwd']);
        final listed = tasks.values.where(
          (task) => cwd == null || cwd.isEmpty || task['project'] == cwd,
        );
        _respond(id, enhanced ? listed.toList() : const <Object?>[]);
        return;
      }
      if (method == '_harness/task/get') {
        _respond(
          id,
          tasks[asString(params['id'])] ?? const <String, Object?>{},
        );
        return;
      }
      if (method == '_harness/task/slots') {
        _respond(id, {
          'project':
              asString(params['cwd']) ??
              '/Users/noah/Code/emacs-agent-harness/',
          'limit': 3,
          'suspended': false,
          'holders': [
            {
              'id': 'task-1',
              'title': 'Build the Flutter ACP client',
              'priority': 'high',
            },
            {
              'id': 'task-4',
              'title': 'Answer the permission',
              'priority': 'high',
            },
          ],
          'queue': [
            {
              'id': 'task-3',
              'title': 'Cache the model catalogue',
              'priority': 'low',
              'reason': '',
            },
          ],
          'waits': [],
        });
        return;
      }
      if (method == '_harness/task/settings') {
        _respond(id, {
          'maxRunning': 3,
          'queueSuspended': false,
          'backlogMode': 'manual',
          'requireVerification': true,
          'model': 'claude:claude-fable-5-1',
          'permissionMode': 'auto',
          if (taskPictures)
            'inlineAttachments': [
              'image/png',
              'image/jpeg',
              'image/gif',
              'image/webp',
            ],
        });
        return;
      }
      if (method == '_harness/task/submit') {
        final taskId = 'task-${tasks.length + 1}';
        final opts = asMap(params['opts']);
        // The harness keeps each picture sent as data as a file of the
        // task's own, and the task names the file.
        final attachments = [
          for (final item in asMapList(opts['attachments']))
            {
              'name': item['name'],
              'mime': item['mime'],
              'path': '/state/attachments/$taskId/${item['name']}',
            },
        ];
        final task = {
          'id': taskId,
          'name': _firstLine(asString(params['prompt']) ?? 'New task'),
          'prompt': params['prompt'],
          'state': 'pending',
          'column': opts['refine'] == true ? 'backlog' : 'pending',
          'priority': asString(opts['priority']) ?? 'medium',
          'project':
              asString(params['cwd']) ??
              '/Users/noah/Code/emacs-agent-harness/',
          'cwd': asString(params['cwd']),
          'created': DateTime.now().millisecondsSinceEpoch / 1000,
          'updated': DateTime.now().millisecondsSinceEpoch / 1000,
          if (opts['refine'] == true) 'backlog': true,
          if (attachments.isNotEmpty) 'attachments': attachments,
        };
        tasks[taskId] = task;
        _event('task/changed', [task]);
        _respond(id, task);
        return;
      }
      if (method.startsWith('_harness/task/')) {
        final action = method.substring('_harness/task/'.length);
        final taskId = asString(params['id']);
        final task = tasks[taskId];
        if (task != null) {
          if (action == 'start') {
            task['state'] = 'active';
            task['column'] = 'active';
          } else if (action == 'queue') {
            task['state'] = 'pending';
            task['column'] = 'pending';
            task['backlog'] = false;
          } else if (action == 'verify') {
            task['state'] = 'done';
            task['column'] = 'done';
            task['verified'] = true;
          } else if (action == 'reject') {
            task['state'] = 'active';
            task['column'] = 'active';
            task['feedback'] = [
              ...(task['feedback'] as List? ?? const []),
              {
                'text': params['feedback'],
                'at': DateTime.now().millisecondsSinceEpoch / 1000,
              },
            ];
          } else if (action == 'complete') {
            task['state'] = 'done';
            task['column'] = 'done';
          } else if (action == 'cancel') {
            tasks.remove(taskId);
            _event('task/deleted', [taskId]);
            _respond(id, task);
            return;
          } else if (action == 'archive') {
            task['archived'] = true;
            tasks.remove(taskId);
            _event('task/deleted', [taskId]);
            _respond(id, task);
            return;
          } else if (action == 'retry') {
            task['state'] = 'active';
            task['column'] = 'active';
          }
          _event('task/changed', [task]);
        }
        _respond(id, task ?? const <String, Object?>{});
        return;
      }
      if (method == '_harness/usage/totals') {
        _respond(id, {
          'input': 84800,
          'output': 19600,
          'cache-read': 46000,
          'cache-write': 2100,
          'cost': 1.24,
          'list-cost': 1.51,
          'calls': 30,
        });
        return;
      }
      if (method == '_harness/usage/summary') {
        final groupBy = asString(params['group-by']) ?? 'project';
        final rows = switch (groupBy) {
          'model' => [
            {
              'key': 'claude:claude-fable-5-1',
              'input': 62000,
              'output': 14100,
              'cache-read': 31000,
              'cache-write': 1200,
              'cost': 0.91,
              'list-cost': 1.07,
              'calls': 18,
            },
            {
              'key': 'copilot:gpt-5.2-codex',
              'input': 12000,
              'output': 4300,
              'cache-read': 9000,
              'cost': 0.18,
              'list-cost': 0.18,
              'calls': 6,
            },
            {
              'key': 'deepseek:deepseek-chat',
              'input': 10800,
              'output': 1200,
              'cache-read': 6000,
              'cache-write': 900,
              'cost': 0.15,
              'list-cost': 0.26,
              'calls': 6,
            },
          ],
          // Spend is recorded under the directory a session worked in: a
          // task's work under its worktree, which says its checkout as `main`.
          'project' => [
            {
              'key': '/Users/noah/Code/emacs-agent-harness/',
              'main': '/Users/noah/Code/emacs-agent-harness/',
              'input': 40000,
              'output': 10000,
              'cache-read': 20000,
              'cache-write': 1200,
              'cost': 0.49,
              'list-cost': 0.6,
              'calls': 12,
            },
            {
              'key': '/Users/noah/Code/emacs-agent-harness/.worktrees/task-flutter/',
              'main': '/Users/noah/Code/emacs-agent-harness/',
              'input': 24000,
              'output': 6300,
              'cache-read': 14000,
              'cache-write': 900,
              'cost': 0.48,
              'list-cost': 0.61,
              'calls': 9,
            },
            {
              'key': '/Users/noah/Code/emacs-agent-harness/.worktrees/task-fix-titles/',
              'main': '/Users/noah/Code/emacs-agent-harness/',
              'input': 8800,
              'output': 2100,
              'cache-read': 6000,
              'cost': 0.12,
              'list-cost': 0.12,
              'calls': 3,
            },
            {
              'key': '/Users/noah/Code/other-project/',
              'main': '/Users/noah/Code/other-project/',
              'input': 12000,
              'output': 1200,
              'cache-read': 6000,
              'cost': 0.15,
              'list-cost': 0.18,
              'calls': 6,
            },
          ],
          _ => _days(),
        };
        _respond(id, rows);
        return;
      }
      if (method == '_harness/usage/live-all') {
        _respond(id, [
          {
            'session': 's1',
            'context': 52300,
            'output': 900,
            'estimated': false,
          },
          {'session': 's3', 'context': 21000, 'output': 500, 'estimated': true},
        ]);
        return;
      }
      if (method == '_harness/usage/rates') {
        _respond(id, [
          {
            'session': 's1',
            'rate': 42.0,
            'output': 900,
            'seconds': 21.4,
            'calls': 2,
            'model': 'claude:claude-fable-5-1',
          },
        ]);
        return;
      }
      if (method == '_harness/usage/budgets') {
        _respond(id, [
          {
            'id': 'b1',
            'scope': 'project',
            'target': '/Users/noah/Code/emacs-agent-harness/',
            'amount': 25,
            'hard': true,
          },
          {
            'id': 'b2',
            'scope': 'period',
            'period': 'month',
            'amount': 80,
            'hard': false,
          },
        ]);
        return;
      }
      if (method == '_harness/project/mains') {
        _respond(id, [
          for (final root in asList(params['roots']))
            if (asString(root) case final directory?)
              {'root': directory, 'main': mainCheckoutOf(directory)},
        ]);
        return;
      }
      if (method == '_harness/insights/projects') {
        _respond(id, listedProjects());
        return;
      }
      if (method == '_harness/provider/list') {
        _respond(id, [
          {
            'id': 'claude',
            'label': 'Claude',
            'doc': 'Anthropic',
            'capabilities': {'quota': quota, 'billing': quota},
          },
          {
            'id': 'copilot',
            'label': 'GitHub Copilot',
            'doc': 'Copilot CLI',
            'capabilities': {'quota': quota, 'billing': quota},
          },
          {
            'id': 'deepseek',
            'label': 'DeepSeek',
            'doc': 'DeepSeek API',
            'capabilities': {'quota': false},
          },
        ]);
        return;
      }
      if (method == '_harness/provider/quota') {
        if (asBool(params['refresh'])) quotaRefreshes++;
        if (failQuota) {
          _respondError(id, -32603, 'The quota probe failed.');
          return;
        }
        // A provider that has nothing to say answers nothing.
        _respond(id, quotas[asString(params['providerId'])]);
        return;
      }
      if (method == '_harness/provider/models') {
        _respond(id, [
          {
            'id': 'claude:claude-fable-5-1',
            'name': 'Claude Fable 5.1',
            'provider': 'claude',
            'context-window': 200000,
          },
          {
            'id': 'claude:claude-haiku-4-5',
            'name': 'Claude Haiku 4.5',
            'provider': 'claude',
            'context-window': 200000,
          },
          {
            'id': 'copilot:gpt-5.2-codex',
            'name': 'GPT-5.2 Codex',
            'provider': 'copilot',
            'context-window': 128000,
          },
          {
            'id': 'deepseek:deepseek-chat',
            'name': 'DeepSeek Chat',
            'provider': 'deepseek',
            'context-window': 128000,
          },
        ]);
        return;
      }
      if (method == '_harness/harness/version') {
        _respond(id, {
          'version': '0.9.4',
          'emacs': '31.1',
          'protocolVersion': 1,
        });
        return;
      }
      if (method == '_harness/harness/modules') {
        _respond(id, [
          {
            'name': 'session',
            'description': 'Conversations',
            'optional': false,
          },
          {'name': 'agent', 'description': 'The turn loop', 'optional': false},
          {'name': 'tasks', 'description': 'Task mode', 'optional': true},
          {
            'name': 'usage',
            'description': 'Cost accounting',
            'optional': false,
          },
          {
            'name': 'acp-remote',
            'description': 'Phone pairing',
            'optional': true,
          },
        ]);
        return;
      }
      if (method == '_harness/config/describe') {
        _respond(id, {
          'cwd': '/Users/noah/Code/emacs-agent-harness/',
          'inProject': true,
        });
        return;
      }
      if (method == '_harness/tools/list' && toolCatalogue) {
        if (failToolList) {
          _respondError(id, -32603, 'The harness could not list its tools.');
          return;
        }
        // The specs of every tool, as the harness gives them without a
        // session: what a transcript's calls are labelled by.
        _respond(id, toolSpecs);
        return;
      }
      if (method == '_harness/session/test-hang') {
        // Deliberately never answers; the client's close must reject it.
        return;
      }
      _respondError(id, -32601, 'Method not found: $method');
    } catch (error) {
      _respondError(id, -32603, '$error');
    }
  }

  Map<String, Object?> _initializeResult({bool rotate = false}) => {
    'protocolVersion': 1,
    'agentInfo': {
      'name': enhanced ? 'emacs-agent-harness' : 'Plain ACP agent',
      'version': enhanced ? '0.9.4' : '2.0.0',
    },
    'agentCapabilities': {
      'loadSession': true,
      'promptCapabilities': {
        'image': true,
        'audio': false,
        'embeddedContext': true,
      },
      'sessionCapabilities': {'list': <String, Object?>{}},
    },
    if (enhanced)
      '_harness': {
        'methods': methods.toList()..sort(),
        'events': events.toList()..sort(),
        if (rotate) 'session': {'token': rotateTo, 'deviceId': 'dev1'},
      },
    'authMethods': [
      if (token != null && !authenticated)
        {
          'id': 'token',
          'name': 'Shared secret',
          'description': 'Call authenticate with the token',
        },
    ],
  };

  List<Map<String, Object?>> _signInMethods() => [
    {
      'id': 'emacs-approval',
      'name': 'Approve in Emacs',
      'description':
          'Asks the person at this harness\'s Emacs to approve this device. '
          'Check that Emacs shows the code $signInCode, and press Approve '
          'there. It waits 50 seconds.',
    },
    if (oidcUrl != null)
      {
        'id': 'oidc',
        'name': 'Sign in with auth.example.com',
        'description':
            'Open $oidcUrl in a browser, sign in, and confirm the code '
            '$signInCode. This connection signs in once you have.',
        '_meta': {
          'harness': {'url': oidcUrl},
        },
      },
    if (sessionRefreshAsked)
      {
        'id': 'token',
        'name': 'Session secret',
        'description': 'Call authenticate with a session secret.',
      },
  ];

  /// What a listener for other devices answers a connection that has not
  /// signed in: what any ACP agent says of itself, and how to sign in.
  Map<String, Object?> _signInInitializeResult() => {
    'protocolVersion': 1,
    'agentInfo': {'name': 'emacs-agent-harness'},
    'agentCapabilities': {
      'loadSession': true,
      'promptCapabilities': {
        'image': true,
        'audio': false,
        'embeddedContext': true,
      },
    },
    'authMethods': _signInMethods(),
  };

  Future<void> _signIn(Object? id, JsonMap params) async {
    final methodId = asString(params['methodId']) ?? '';
    signInAttempts.add(methodId);
    if (methodId == 'token') {
      final secret = asString(params['token']) ?? '';
      if (knownSecrets.contains(secret)) {
        authenticated = true;
        _respond(id, const <String, Object?>{});
      } else {
        _respondError(id, -32000, 'Invalid session secret');
      }
      return;
    }
    if (methodId != 'emacs-approval' && methodId != 'oidc') {
      _respondError(id, -32000, 'Unknown authentication method');
      return;
    }
    final waiting = Completer<bool>();
    _waiting = waiting;
    final approved = await waiting.future;
    _waiting = null;
    if (!approved) {
      _respondError(
        id,
        -32000,
        'The person at the harness\'s Emacs refused this device',
      );
      return;
    }
    authenticated = true;
    _respond(id, {
      if (sessionRefreshAsked && issueSecret != null)
        '_meta': {
          'harness': {
            'session': {'token': issueSecret, 'deviceId': 'dev1'},
          },
        },
    });
  }

  Map<String, Object?> _reducedInitializeResult() => {
    'protocolVersion': 1,
    'agentInfo': {'name': 'emacs-agent-harness'},
    'agentCapabilities': <String, Object?>{},
    'authMethods': [
      {
        'id': 'token',
        'name': 'Session secret',
        'description': 'Call authenticate with the session secret',
      },
    ],
  };

  Map<String, Object?> _sessionInfo(Map<String, Object?> session) => {
    'sessionId': session['id'],
    'cwd': session['cwd'],
    'title': session['name'],
    'updatedAt': DateTime.fromMillisecondsSinceEpoch(
      ((session['updated'] as num) * 1000).round(),
    ).toUtc().toIso8601String(),
    '_meta': {
      'status': session['status'],
      'kind': session['kind'],
      'model': session['model'],
      'project': session['project'],
    },
  };

  Map<String, Object?> _plainSessionInfo(Map<String, Object?> session) => {
    'sessionId': session['id'],
    'cwd': session['cwd'],
    'title': session['name'],
    'updatedAt': DateTime.fromMillisecondsSinceEpoch(
      ((session['updated'] as num) * 1000).round(),
    ).toUtc().toIso8601String(),
  };

  void _replay(String sid) {
    final session = sessions[sid];
    if (session == null) return;
    _send('session/update', {
      'sessionId': sid,
      'update': _sessionUpdate(session),
    });
    for (final node in nodes[sid] ?? const <Map<String, Object?>>[]) {
      for (final update in _updatesForNode(node, replay: true)) {
        _send('session/update', {'sessionId': sid, 'update': update});
      }
    }
    if (enhanced) {
      _send('session/update', {
        'sessionId': sid,
        'update': {'sessionUpdate': '_harness/session', 'session': session},
      });
    }
  }

  List<Map<String, Object?>> _updatesForNode(
    Map<String, Object?> node, {
    bool replay = true,
  }) {
    final kind = asString(node['kind']);
    final id = asString(node['id']);
    final list = <Map<String, Object?>>[];
    final harness = {'nodeId': id};
    switch (kind) {
      case 'user':
        list.add({
          'sessionUpdate': 'user_message_chunk',
          'content': {'type': 'text', 'text': node['content']},
          '_harness': harness,
        });
      case 'assistant':
        list.add({
          'sessionUpdate': 'agent_message_chunk',
          'content': {'type': 'text', 'text': node['content']},
          '_harness': harness,
        });
      case 'thinking':
        list.add({
          'sessionUpdate': 'agent_thought_chunk',
          'content': {'type': 'text', 'text': node['content']},
          '_harness': harness,
        });
      case 'tool-call':
        list.add({
          'sessionUpdate': 'tool_call',
          'toolCallId': node['callId'] ?? node['call-id'],
          'title': node['title'],
          'kind': 'read',
          'status': 'in_progress',
          'rawInput': node['input'],
          '_harness': {...harness, 'tool': node['tool']},
        });
      case 'tool-result':
        list.add({
          'sessionUpdate': 'tool_call_update',
          'toolCallId': node['callId'] ?? node['call-id'],
          'status': asBool(node['isError'] ?? node['is-error'])
              ? 'failed'
              : 'completed',
          'rawOutput': node['output'],
          '_harness': harness,
        });
      case 'hint':
        list.add({
          'sessionUpdate': 'agent_message_chunk',
          'content': {'type': 'text', 'text': node['content']},
          '_harness': harness,
        });
    }
    if (enhanced) list.add({'sessionUpdate': '_harness/node', 'node': node});
    return list;
  }

  void _streamTurn(String sid, String text, Object? requestId) async {
    final session = sessions[sid];
    if (session == null) {
      _respondError(requestId, -32603, 'No session');
      return;
    }
    final slow = text.toLowerCase().contains('slowly');
    final pace = slow ? 900 : 25;
    _setStatus(sid, 'running', event: 'agent/turn-started');
    final userNode = _node('u-${++_generated}', 'user', text);
    (nodes[sid] ??= []).add(userNode);
    for (final update in _updatesForNode(userNode)) {
      _send('session/update', {'sessionId': sid, 'update': update});
    }
    await _delay(slow ? 800 : 30);
    _activity(sid, {'phase': 'thinking', 'since': _now()});
    await _delay(slow ? 700 : 0);
    final thought = _node(
      't-${++_generated}',
      'thinking',
      'The request asks me to work through the harness. I’ll check the relevant state first.',
    );
    (nodes[sid] ??= []).add(thought);
    _send('session/update', {
      'sessionId': sid,
      'update': {
        'sessionUpdate': 'agent_thought_chunk',
        'content': {'type': 'text', 'text': thought['content']},
        '_harness': {'nodeId': thought['id']},
      },
    });
    await _delay(pace);
    _activity(sid, {'phase': 'writing', 'since': _now()});
    final answerId = 'a-${++_generated}';
    const first =
        'I’m on it. The **sessions** view can stay live while you work: ';
    const second = 'streams, tool calls and requests all arrive over ACP.\n\n';
    for (final chunk in [first, second]) {
      _send('session/update', {
        'sessionId': sid,
        'update': {
          'sessionUpdate': 'agent_message_chunk',
          'content': {'type': 'text', 'text': chunk},
          '_harness': {'nodeId': answerId},
        },
      });
      await _delay(pace);
    }
    if (text.toLowerCase().contains('permission')) {
      await _delay(30);
      final response = await _requestClient('session/request_permission', {
        'sessionId': sid,
        'toolCall': {
          'toolCallId': 'call-perm-1',
          'title': 'Run the full test suite',
          'kind': 'execute',
          'rawInput': {'command': 'flutter test'},
        },
        'options': _permissionOptions,
        '_harness': {
          'pendingId': 'perm-1',
          'tool': 'bash',
          'cwd': session['cwd'],
          'paths': [session['cwd']],
        },
      });
      permissionAnswers.add(asMap(response['result']));
      final outcome = asMap(asMap(response['result'])['outcome']);
      final allowed =
          asString(outcome['optionId'])?.startsWith('allow') == true;
      final callId = 'call-perm-1';
      final call = _node(
        'c-${++_generated}',
        'tool-call',
        '',
        tool: 'bash',
        callId: callId,
        title: 'Run the full test suite',
        input: {'command': 'flutter test'},
      );
      (nodes[sid] ??= []).add(call);
      _send('session/update', {
        'sessionId': sid,
        'update': {
          'sessionUpdate': 'tool_call',
          'toolCallId': callId,
          'title': call['title'],
          'kind': 'execute',
          'status': 'in_progress',
          'rawInput': call['input'],
          '_harness': {'nodeId': call['id'], 'tool': 'bash'},
        },
      });
      _activity(sid, {
        'phase': 'tool',
        'since': _now(),
        'tool': 'bash',
        'title': 'Run the full test suite',
        'count': 1,
      });
      await _delay(400);
      final result = _node(
        'r-${++_generated}',
        'tool-result',
        '',
        callId: callId,
        output: allowed
            ? 'All 38 tests passed in 41.2s.'
            : 'Permission denied: the command did not run.',
        isError: !allowed,
      );
      (nodes[sid] ??= []).add(result);
      _send('session/update', {
        'sessionId': sid,
        'update': {
          'sessionUpdate': 'tool_call_update',
          'toolCallId': callId,
          'status': allowed ? 'completed' : 'failed',
          'rawOutput': result['output'],
          '_harness': {'nodeId': result['id']},
        },
      });
    }
    if (text.toLowerCase().contains('question')) {
      await _delay(40);
      final response = await _requestClient('_harness/ask_user', {
        'sessionId': sid,
        'requestId': 'q-1',
        'question': 'Which layout should the tablet session view use?',
        'options': [
          'Split: list and transcript',
          'Tabs: sessions and tasks',
          'Focus: one conversation',
        ],
        'diagrams': [
          {
            'type': 'ascii',
            'text': '┌────────┬──────────────┐\n│ list   │ transcript   │\n│        │              │\n└────────┴──────────────┘',
          },
          {
            'type': 'ascii',
            'text': '┌───────┬───────┐\n│ 1     │ 2     │\n│       │       │\n└───────┴───────┘',
          },
          {
            'type': 'ascii',
            'text': '┌──────────────────────┐\n│    conversation      │\n│                      │\n└──────────────────────┘',
          },
        ],
        'cowboy': {
          'preview': 'The prompt cache is cold. Compacting costs less than carrying on.',
          'choices': [
            {'label': 'Compact the summary', 'cost-text': '~\$0.04'},
            {'label': 'Use the transcript', 'cost-text': '~\$0.11'},
            {'label': 'Carry on uncached', 'cost-text': '~\$0.42'},
          ],
        },
      });
      questionAnswers.add(asMap(response['result']));
    }
    await _delay(slow ? 900 : 30);
    _send('session/update', {
      'sessionId': sid,
      'update': {
        'sessionUpdate': 'plan',
        'entries': [
          {
            'content': 'Read the state layer',
            'status': 'completed',
            'priority': 'medium',
          },
          {
            'content': 'Wire the ACP view',
            'status': 'in_progress',
            'priority': 'medium',
          },
          {
            'content': 'Check it in an emulator',
            'status': 'pending',
            'priority': 'medium',
          },
        ],
      },
    });
    final finalNode = _node(
      answerId,
      'assistant',
      'I’m done with this step. The transcript is live and the task board is one tap away.',
      meta: {'model': session['model']},
    );
    (nodes[sid] ??= []).add(finalNode);
    if (enhanced) {
      _send('session/update', {
        'sessionId': sid,
        'update': {'sessionUpdate': '_harness/node', 'node': finalNode},
      });
    }
    _setStatus(sid, 'idle', event: 'agent/turn-ended');
    _respond(requestId, {
      'stopReason': 'end_turn',
      '_harness': {'reason': 'end-turn', 'duration': 1.2},
    });
  }

  Future<Map<String, Object?>> _requestClient(
    String method,
    Map<String, Object?> params,
  ) {
    final id = 'srv-${++_nextServerRequest}';
    final completer = Completer<Map<String, Object?>>();
    _serverRequests[id] = completer;
    _serverRequestParams[id] = params;
    _send(method, params, id: id);
    return completer.future;
  }

  void _activity(String sid, Map<String, Object?> activity) {
    if (!enhanced) return;
    _send('session/update', {
      'sessionId': sid,
      'update': {'sessionUpdate': '_harness/activity', 'activity': activity},
    });
  }

  void _setStatus(String sid, String status, {String? event}) {
    final session = sessions[sid];
    if (session == null) return;
    session['status'] = status;
    session['updated'] = _now();
    _pushSession(sid);
    if (event != null) {
      _event(event, [sid, status == 'idle' ? 'end-turn' : null]);
    }
  }

  void _pushSession(String sid) {
    final session = sessions[sid];
    if (session == null || !enhanced) return;
    _send('session/update', {
      'sessionId': sid,
      'update': {'sessionUpdate': '_harness/session', 'session': session},
    });
  }

  /// The agent of session [sid] calls `ask_user`: the harness holds the
  /// question as pending on the session, which is blocked on it, tells the
  /// clients what the session waits on, and asks them the question, as
  /// `_harness/ask_user`.  The answer comes back with the future (the
  /// `result` of the client's reply).
  Future<Map<String, Object?>> askUser(
    String sid, {
    required String question,
    List<Object?> options = const [],
    List<Object?>? diagrams,
    String requestId = 'q-ask',
  }) async {
    final payload = <String, Object?>{
      'question': question,
      'options': options,
      if (diagrams != null) 'diagrams': diagrams,
    };
    _hold(sid, requestId, payload);
    final response = await _requestClient('_harness/ask_user', {
      'sessionId': sid,
      'requestId': requestId,
      ...payload,
    });
    final result = asMap(response['result']);
    // Another client may have answered it first, as the harness takes the
    // first answer; what is still waiting is answered with this one.
    if (isPending(sid, requestId)) {
      questionAnswers.add(result);
      _resolve(sid, requestId, asString(result['answer']));
    }
    return result;
  }

  /// A question the agent of session [sid] asked that no client heard: the
  /// harness holds it as pending on the session, and tells the clients so
  /// ([announce]), but asks none of them.  A client finds it with
  /// `question/pending`.
  void leavePendingQuestion(
    String sid, {
    required String question,
    List<Object?> options = const [],
    List<Object?>? diagrams,
    String requestId = 'q-left',
    bool announce = false,
  }) {
    _hold(
      sid,
      requestId,
      {
        'question': question,
        'options': options,
        if (diagrams != null) 'diagrams': diagrams,
      },
      announce: announce,
    );
  }

  /// The question [id] of session [sid] was answered somewhere else (in
  /// Emacs, on another device): the harness tells its clients.
  void answerElsewhere(String sid, String id, String answer) {
    questionAnswers.add({'answer': answer, 'from': 'elsewhere'});
    _resolve(sid, id, answer);
  }

  /// Whether a request of session [sid] still waits for an answer.
  bool isPending(String sid, String id) =>
      _pendingOf(sid).any((item) => item['id'] == id);

  /// The harness holds a question as pending on [sid], and says so.
  void _hold(
    String sid,
    String id,
    Map<String, Object?> payload, {
    bool announce = true,
  }) {
    final pending = _pendingOf(sid);
    pending.removeWhere((item) => item['id'] == id);
    pending.add({
      'id': id,
      'kind': 'question',
      'created': DateTime.now().millisecondsSinceEpoch / 1000,
      'payload': payload,
    });
    sessions[sid]!['status'] = 'blocked';
    if (announce) {
      _setStatus(sid, 'blocked');
      _event('session/pending-changed', [sid, List.of(pending)]);
    }
  }

  /// The question [id] of session [sid] was answered, by whoever: it is no
  /// longer pending, the clients are told, and the session goes on when
  /// nothing else holds it.
  void _resolve(String sid, String id, String? answer) {
    final pending = _pendingOf(sid);
    pending.removeWhere((item) => item['id'] == id);
    if (pending.isEmpty) _setStatus(sid, 'running');
    _event('question/answered', [sid, id, answer]);
    _event('session/pending-changed', [sid, List.of(pending)]);
  }

  /// The pending requests of [sid] of one [kind], as the harness lists them.
  List<Object?> _pendingKind(String? sid, String kind) {
    final session = sessions[sid];
    if (session == null) return const [];
    return [
      for (final item in _pendingOf(sid!))
        if (item['kind'] == kind) item,
    ];
  }

  /// The pending requests of session [sid], the list the harness keeps.
  List<Map<String, Object?>> _pendingOf(String sid) {
    final session = sessions[sid]!;
    final list = session['pending'];
    // The seeded lists are literals of a narrower type than this adds to.
    if (_pendingLists.contains(list)) return list! as List<Map<String, Object?>>;
    final copy = <Map<String, Object?>>[
      for (final item in (list as List? ?? const []))
        Map<String, Object?>.from(item as Map),
    ];
    _pendingLists.add(copy);
    session['pending'] = copy;
    return copy;
  }

  /// The lists [_pendingOf] made, which it can add to.
  final Set<Object> _pendingLists = Set<Object>.identity();

  /// The harness announces [event], as it does when something happens in
  /// it: a client that listens refreshes what it shows.
  void announce(String event, [List<Object?> args = const []]) =>
      _event(event, args);

  void _event(String event, List<Object?> args) {
    if (!enhanced) return;
    _send('_harness/event', {'event': event, 'args': args});
  }

  void _write(String message) {
    final sink = writer;
    if (sink != null) {
      sink(message);
    } else {
      transport?.harnessSend(message);
    }
  }

  void _respond(Object? id, Object? result) {
    _write(jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result}));
  }

  void _respondError(Object? id, int code, String message, [Object? data]) {
    _write(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'error': {
          'code': code,
          'message': message,
          if (data != null) 'data': data,
        },
      }),
    );
  }

  void _send(String method, Map<String, Object?> params, {String? id}) {
    _write(
      jsonEncode({
        'jsonrpc': '2.0',
        if (id != null) 'id': id,
        'method': method,
        'params': params,
      }),
    );
  }

  double _now() => DateTime.now().millisecondsSinceEpoch / 1000;

  Future<void> _delay(int ms) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  List<Map<String, Object?>> _days() {
    final now = DateTime.now();
    return [
      for (var offset = 6; offset >= 0; offset--)
        {
          'key': _date(now.subtract(Duration(days: offset))),
          'cost': [0.12, 0.3, 0.08, 0.44, 0.21, 0.05, 0.04][6 - offset],
          'list-cost': [0.14, 0.33, 0.09, 0.5, 0.24, 0.06, 0.05][6 - offset],
          'input': 8000 + offset * 1000,
          'output': 2000 + offset * 100,
          'cache-read': 4000,
          'cache-write': 200,
          'calls': 3 + offset,
        },
    ];
  }

  String _date(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

  String _promptText(Object? prompt) =>
      asList(prompt)
          .map((block) => asString(asMap(block)['text']) ?? '')
          .join(' ');

  String _firstLine(String text) {
    final line = text.split('\n').first.trim();
    return line.length <= 60 ? line : '${line.substring(0, 59)}…';
  }

  Map<String, Object?> _sessionUpdate(Map<String, Object?> session) => {
    'sessionUpdate': '_harness/session',
    'session': session,
  };
}

const _sampleSvg = '''
<svg xmlns="http://www.w3.org/2000/svg" width="320" height="180" viewBox="0 0 320 180">
  <rect x="8" y="8" width="140" height="164" rx="12" fill="#eef0f4"/>
  <rect x="160" y="8" width="152" height="164" rx="12" fill="#e6f4ec"/>
  <text x="78" y="94" font-family="sans-serif" font-size="14" text-anchor="middle" fill="#444">sessions</text>
  <text x="236" y="94" font-family="sans-serif" font-size="14" text-anchor="middle" fill="#2f7d5b">transcript</text>
</svg>
''';
