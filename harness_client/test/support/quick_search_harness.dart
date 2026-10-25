import 'dart:async';
import 'dart:convert';

import 'package:harness_client/src/acp/acp_message.dart';
import 'package:harness_client/src/acp/acp_transport.dart';
import 'package:harness_client/src/acp/connection_target.dart';

import 'fake_harness.dart';

/// A harness that fails a search the way the real one does: with an error
/// whose message is the harness's own ("The model took longer than 45s").
class SearchFailure implements Exception {
  const SearchFailure(this.message, [this.code = -32603]);
  final String message;
  final int code;
}

/// A [FakeHarness] that also answers the quick search: `search/ask`,
/// `search/warm` and `task/search-apply`, the methods of the harness's
/// `tasks-search` module, with plans a test scripts.
///
/// It stands between the client and the fake harness (the way a server
/// wrapper does, see `FakeHarness.handleMessage`): the three methods are
/// answered here, everything else goes through, so the fake's sessions and
/// tasks are the ones the app shows.  Every request is kept, as the fake
/// keeps its own, so `harness.calls('_harness/search/ask')` has them too.
class SearchingHarness {
  SearchingHarness({FakeHarness? harness, this.offersSearch = true})
    : harness = harness ?? FakeHarness() {
    if (offersSearch && this.harness.enhanced) {
      this.harness.methods.addAll(searchMethods);
    }
  }

  /// The methods of the harness's search.
  static const searchMethods = {
    'search/ask',
    'search/warm',
    'task/search-apply',
  };

  final FakeHarness harness;

  /// Whether the harness has the search module at all.
  final bool offersSearch;

  /// The params of each `search/ask`, `search/warm` and `task/search-apply`
  /// the app made, in order.
  final List<JsonMap> asks = [];
  final List<JsonMap> warms = [];
  final List<JsonMap> applies = [];

  /// What `search/ask` answers: the plan (see [plan]), now or later; throw a
  /// [SearchFailure] for a harness whose search fails.  Called with the
  /// params of the request.
  FutureOr<Object?> Function(JsonMap params) onAsk = (params) => plan();

  /// What `search/warm` answers: the model, and whether its process is ready.
  FutureOr<Object?> Function(JsonMap params) onWarm = (params) => {
    'model': 'claude:claude-haiku-4-5',
    'warm': true,
  };

  /// What `task/search-apply` answers: one result for each action.
  FutureOr<Object?> Function(JsonMap params) onApply = (params) => [
    for (final action in asMapList(params['actions']))
      {
        'task': action['task'],
        'action': action['action'],
        'title': action['title'],
        'ok': true,
      },
  ];

  /// The line of the query of the latest `search/ask`, or null.
  String? get lastQuery => asks.isEmpty ? null : asString(asks.last['query']);

  /// The `opts` of the latest `search/ask`.
  JsonMap get lastOpts => asMap(asks.last['opts']);

  /// The `context` of the latest `search/ask`.
  JsonMap get lastContext => asMap(lastOpts['context']);

  /// The names of the commands the latest `search/ask` sent.
  List<String> get lastCommandNames => [
    for (final command in asMapList(lastOpts['commands']))
      asStringOr(command['command'], ''),
  ];

  /// Connect through this, instead of [FakeHarness.connector].
  Future<AcpTransport> connector(ConnectionTarget target, String token) async {
    final transport = await harness.connector(target, token);
    if (transport is FakeTransport) {
      final onward = transport.onSend;
      transport.onSend = (raw) {
        if (!_answer(transport, raw)) onward?.call(raw);
      };
    }
    return transport;
  }

  /// Whether [raw] was one of the search's requests, which was answered here.
  bool _answer(FakeTransport transport, String raw) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return false;
    }
    if (decoded is! Map || decoded['id'] == null) return false;
    final message = asMap(decoded);
    final method = asString(message['method']);
    final id = message['id'];
    final params = asMap(message['params']);
    final script = switch (method) {
      '_harness/search/ask' => (asks, onAsk),
      '_harness/search/warm' => (warms, onWarm),
      '_harness/task/search-apply' => (applies, onApply),
      _ => null,
    };
    if (script == null) return false;
    harness.requests.add((method!, params));
    harness.requestsByClient.add(method);
    if (!offersSearch) {
      transport.harnessSend(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': id,
          'error': {'code': -32601, 'message': 'Method not found: $method'},
        }),
      );
      return true;
    }
    script.$1.add(params);
    unawaited(_reply(transport, id, () async => await script.$2(params)));
    return true;
  }

  Future<void> _reply(
    FakeTransport transport,
    Object? id,
    Future<Object?> Function() produce,
  ) async {
    Map<String, Object?> message;
    try {
      message = {'jsonrpc': '2.0', 'id': id, 'result': await produce()};
    } on SearchFailure catch (failure) {
      message = {
        'jsonrpc': '2.0',
        'id': id,
        'error': {'code': failure.code, 'message': failure.message},
      };
    }
    transport.harnessSend(jsonEncode(message));
  }
}

/// The wire form of a session a search found, as `search/ask` has them
/// (`:sessions`).
JsonMap foundSession(
  String id, {
  String? name,
  String kind = 'main',
  String status = 'idle',
  String? project = 'emacs-agent-harness',
  String? snippet,
  String? node,
  List<List<int>>? ranges,
  String? task,
  double? updated,
}) => {
  'id': id,
  'name': name,
  'kind': kind,
  'status': status,
  'project': project,
  'cwd': '/Users/noah/Code/emacs-agent-harness/',
  'updated':
      updated ??
      DateTime.now()
              .subtract(const Duration(minutes: 12))
              .millisecondsSinceEpoch /
          1000,
  'snippet': snippet,
  'node': node,
  'ranges': ranges,
  'task': task,
};

/// The wire form of a task a search found (`:tasks`).
JsonMap foundTask(String id, String title, String status, {String? session}) =>
    {'id': id, 'title': title, 'status': status, 'session': session};

/// The wire form of a command of the app a search named: the entry the app
/// sent, back.
JsonMap foundCommand(
  String name, {
  String? keys,
  String where = 'menu',
  String? label,
  String? doc,
}) => {
  'command': name,
  'keys': keys,
  'where': where,
  'label': label,
  'doc': doc,
  'here': true,
};

/// The wire form of an action a search proposes to do to a task.
JsonMap proposedAction(
  String task,
  String action, {
  String? title,
  String? text,
  bool confirm = false,
}) => {
  'task': task,
  'action': action,
  'title': title,
  'text': text,
  'confirm': confirm,
};

/// The wire form of a plan, as `search/ask` answers it.
JsonMap plan({
  String query = '',
  String model = 'claude:claude-haiku-4-5',
  String bias = 'commands',
  String? answer,
  String? note,
  String? looked,
  bool widened = false,
  List<JsonMap> commands = const [],
  List<JsonMap> sessions = const [],
  List<JsonMap> tasks = const [],
  List<JsonMap> actions = const [],
}) => {
  'query': query,
  'model': model,
  'bias': bias,
  'looked': looked,
  'session-query': null,
  'answer': answer,
  'note': note,
  'widened': widened,
  'ids': [for (final task in tasks) task['id']],
  'actions': actions,
  'tasks': tasks,
  'sessions': sessions,
  'commands': commands,
};
