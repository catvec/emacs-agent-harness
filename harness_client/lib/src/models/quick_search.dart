import '../acp/acp_message.dart';
import 'session.dart' show parseTime;

/// What a quick search favours: the kind of thing it lists first, which the
/// place it was opened from suggests (`harness-quick-search-bias` in the
/// harness's Emacs).  It only favours: the model reads the rest too.
enum SearchBias {
  tasks,
  sessions,
  commands;

  /// The word the harness knows it by (`:bias`).
  String get wire => name;

  /// What the line under the search box says it favours.
  String get favours => switch (this) {
    SearchBias.tasks => 'tasks',
    SearchBias.sessions => 'sessions, then actions',
    SearchBias.commands => 'actions, then sessions',
  };

  /// The kinds of things found, as this bias lists them, first first.
  List<SearchKind> get order => switch (this) {
    SearchBias.tasks => const [
      SearchKind.tasks,
      SearchKind.sessions,
      SearchKind.commands,
    ],
    SearchBias.sessions => const [
      SearchKind.sessions,
      SearchKind.commands,
      SearchKind.tasks,
    ],
    SearchBias.commands => const [
      SearchKind.commands,
      SearchKind.sessions,
      SearchKind.tasks,
    ],
  };

  static SearchBias? fromWire(Object? value) {
    final name = asString(value)?.trim().toLowerCase();
    for (final bias in values) {
      if (bias.name == name) return bias;
    }
    return null;
  }
}

/// A kind of thing a search finds.  What the harness's Emacs calls commands
/// are the app's own actions here.
enum SearchKind {
  commands('Actions'),
  sessions('Sessions'),
  tasks('Tasks');

  const SearchKind(this.heading);
  final String heading;
}

/// A session a search found, as the harness names it (`search/ask`'s
/// `:sessions`): any session of any project, found by its name or by what was
/// said in it.
class FoundSession {
  const FoundSession({
    required this.id,
    this.name,
    this.kind,
    this.status,
    this.project,
    this.cwd,
    this.updated,
    this.snippet,
    this.node,
    this.ranges = const [],
    this.task,
  });

  factory FoundSession.fromWire(JsonMap wire) {
    return FoundSession(
      id: asStringOr(wire['id'], ''),
      name: _text(wire['name']),
      kind: _text(wire['kind']),
      status: _text(wire['status']),
      project: _text(wire['project']),
      cwd: _text(wire['cwd']),
      updated: parseTime(wire['updated']),
      snippet: _text(wire['snippet']),
      node: _text(wire['node']),
      ranges: [
        for (final range in asList(wire['ranges']))
          if (range is List &&
              range.length >= 2 &&
              asInt(range[0]) != null &&
              asInt(range[1]) != null)
            (asInt(range[0])!, asInt(range[1])!),
      ],
      task: _text(wire['task']),
    );
  }

  final String id;
  final String? name;
  final String? kind;
  final String? status;

  /// The name of the session's project.
  final String? project;
  final String? cwd;
  final DateTime? updated;

  /// The passage around the words the search found in the session, on one
  /// line, and where they are in it (`ranges`, each start and end).  Null for
  /// a session found by its name only.
  final String? snippet;
  final String? node;
  final List<(int, int)> ranges;

  /// The id of the task of the board this session works on.
  final String? task;

  String get title =>
      name ?? 'Session ${id.length > 8 ? id.substring(0, 8) : id}';
}

/// A task a search found (`:tasks`): enough to name it and say where it
/// stands, as the harness read it.
class FoundTask {
  const FoundTask({required this.id, this.title, this.status, this.sessionId});

  factory FoundTask.fromWire(JsonMap wire) => FoundTask(
    id: asStringOr(wire['id'], ''),
    title: _text(wire['title']),
    status: _text(wire['status']),
    sessionId: _text(wire['session']),
  );

  final String id;
  final String? title;

  /// Where it stands, in the harness's words: "review: finished, waits for
  /// your review".
  final String? status;
  final String? sessionId;
}

/// A command of the app's catalogue the search named (`:commands`): the entry
/// the app sent, back.
class FoundCommand {
  const FoundCommand({
    required this.command,
    this.keys,
    this.where,
    this.label,
    this.doc,
  });

  factory FoundCommand.fromWire(JsonMap wire) => FoundCommand(
    command: asStringOr(wire['command'], ''),
    keys: _text(wire['keys']),
    where: _text(wire['where']),
    label: _text(wire['label']),
    doc: _text(wire['doc']),
  );

  final String command;

  /// The taps that reach it, where an Emacs command has keys.
  final String? keys;
  final String? where;
  final String? label;
  final String? doc;
}

/// What a search proposes to do to a task (`:actions`): an order the line
/// gave ("stop the docs task").  The quick search only proposes it: a person
/// says yes.
class ProposedAction {
  const ProposedAction({
    required this.task,
    required this.action,
    this.text,
    this.title,
    this.confirm = false,
  });

  factory ProposedAction.fromWire(JsonMap wire) => ProposedAction(
    task: asStringOr(wire['task'], ''),
    action: asStringOr(wire['action'], ''),
    text: _text(wire['text']),
    title: _text(wire['title']),
    confirm: asBool(wire['confirm']),
  );

  final String task;

  /// `archive`, `restore`, `stop`, `retry`, `start`, `verify`, `complete`,
  /// `message`, `reject` or `priority`.
  final String action;

  /// The words a message or a send-back carries, or the priority.
  final String? text;
  final String? title;

  /// Whether it interrupts work, merges it or sends words to an agent: the
  /// board asks about those and runs the rest, and the quick search asks about
  /// all.
  final bool confirm;

  /// As `task/search-apply` takes it: what the search proposed, without what
  /// it left out.
  JsonMap toWire() => {
    'task': task,
    'action': action,
    if (text != null) 'text': text,
    if (title != null) 'title': title,
    'confirm': confirm,
  };

  /// What doing it means, in words after "Do": "stop “Fix the docs”".
  String get sentence {
    final name = title == null ? task : '“$title”';
    return switch (action) {
      'complete' => 'mark $name done',
      'message' => 'send “${text ?? ''}” to $name',
      'reject' => text == null ? 'send $name back' : 'send $name back: “$text”',
      'priority' =>
        text == null
            ? 'change the priority of $name'
            : 'make $name $text priority',
      _ => '$action $name',
    };
  }
}

/// How one proposed action went (`task/search-apply`).
class ActionResult {
  const ActionResult({
    required this.task,
    required this.action,
    required this.ok,
    this.title,
    this.text,
    this.error,
  });

  factory ActionResult.fromWire(JsonMap wire) => ActionResult(
    task: asStringOr(wire['task'], ''),
    action: asStringOr(wire['action'], ''),
    ok: asBool(wire['ok']),
    title: _text(wire['title']),
    text: _text(wire['text']),
    error: _text(wire['error']),
  );

  /// A failure the app has to make up: the harness did not answer.
  factory ActionResult.failed(ProposedAction action, String error) =>
      ActionResult(
        task: action.task,
        action: action.action,
        ok: false,
        title: action.title,
        text: action.text,
        error: error,
      );

  final String task;
  final String action;
  final bool ok;
  final String? title;
  final String? text;
  final String? error;

  static const _done = {
    'archive': ('Archived', 'archive'),
    'restore': ('Restored', 'restore'),
    'stop': ('Stopped', 'stop'),
    'retry': ('Retried', 'retry'),
    'start': ('Started', 'start'),
    'verify': ('Verified', 'verify'),
    'complete': ('Marked done', 'mark done'),
    'message': ('Sent a message to', 'message'),
    'reject': ('Sent back', 'send back'),
    'priority': ('Changed the priority of', 'change the priority of'),
  };

  /// "Archived “Fix the docs”" or "Could not stop “Fix the docs”: it is not
  /// working".
  String get sentence {
    final name = title == null ? task : '“$title”';
    final words = _done[action];
    if (ok) return '${words?.$1 ?? action} $name';
    return 'Could not ${words?.$2 ?? action} $name: '
        '${error ?? 'it failed'}';
  }
}

/// What `search/ask` answers: the plan of a search.  Nothing has changed yet;
/// the lists are what the model says the line is about, best first.
class QuickSearchPlan {
  const QuickSearchPlan({
    this.query = '',
    this.model,
    this.bias,
    this.looked,
    this.sessionQuery,
    this.answer,
    this.note,
    this.widened = false,
    this.tasks = const [],
    this.sessions = const [],
    this.commands = const [],
    this.actions = const [],
  });

  factory QuickSearchPlan.fromWire(JsonMap wire) => QuickSearchPlan(
    query: asStringOr(wire['query'], ''),
    model: _text(wire['model']),
    bias: SearchBias.fromWire(wire['bias']),
    looked: _text(wire['looked']),
    sessionQuery: _text(wire['session-query'] ?? wire['sessionQuery']),
    answer: _text(wire['answer']),
    note: _text(wire['note']),
    widened: asBool(wire['widened']),
    // Whatever has no name to be found by is no result: there would be
    // nothing to open.
    tasks: [
      for (final item in asMapList(wire['tasks']))
        if (FoundTask.fromWire(item) case final task when task.id.isNotEmpty)
          task,
    ],
    sessions: [
      for (final item in asMapList(wire['sessions']))
        if (FoundSession.fromWire(item) case final session
            when session.id.isNotEmpty)
          session,
    ],
    commands: [
      for (final item in asMapList(wire['commands']))
        if (FoundCommand.fromWire(item) case final command
            when command.command.isNotEmpty)
          command,
    ],
    actions: [
      for (final item in asMapList(wire['actions']))
        if (ProposedAction.fromWire(item) case final action
            when action.task.isNotEmpty && action.action.isNotEmpty)
          action,
    ],
  );

  final String query;
  final String? model;
  final SearchBias? bias;

  /// What the model looked at besides what it was given ("searched the
  /// sessions for “merge queue”"), when it did.
  final String? looked;
  final String? sessionQuery;

  /// The answer in words, Markdown and whole, for a line words answer
  /// ("how do I attach an image?"); null when the lists are the answer.
  final String? answer;

  /// The model's word on its lists ("No task matched; these sessions mention
  /// it.").
  final String? note;

  /// The model found nothing, and the search added what comes nearest
  /// itself; [note] says so.
  final bool widened;
  final List<FoundTask> tasks;
  final List<FoundSession> sessions;
  final List<FoundCommand> commands;
  final List<ProposedAction> actions;

  /// Whether the search found and proposes nothing, and has nothing to say.
  bool get isEmpty =>
      answer == null &&
      tasks.isEmpty &&
      sessions.isEmpty &&
      commands.isEmpty &&
      actions.isEmpty;

  int countOf(SearchKind kind) => switch (kind) {
    SearchKind.commands => commands.length,
    SearchKind.sessions => sessions.length,
    SearchKind.tasks => tasks.length,
  };
}

String? _text(Object? value) {
  if (value == null || value == false) return null;
  final text = asString(value)?.trim();
  return text == null || text.isEmpty ? null : text;
}
