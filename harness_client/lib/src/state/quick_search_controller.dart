import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/quick_search.dart';
import '../services/quick_search_api.dart';
import 'app_controller.dart';
import 'quick_search_catalogue.dart';

enum QuickSearchStatus { idle, searching, done, failed }

/// Whether a search can be asked now, and if not why: what the search says
/// instead of an answer.
enum QuickSearchAvailability {
  ready,

  /// The connection was lost and the app is getting it back: a search waits
  /// for that, as everything does.
  reconnecting,

  /// The app is not in a harness.
  disconnected,

  /// The harness it is in cannot answer a search (an older one, or one
  /// without its search module).
  unsupported,
}

/// One quick search, from the screen it was opened on to the answer and what
/// is done with it: the harness's Emacs keeps the same in the state of its
/// popout (`harness-quick-search--state`).
///
/// The line goes to the harness (`search/ask`), with where it was typed and
/// what the app can do, and the harness's model answers with a plan: what it
/// says in words, and the actions, sessions and tasks the line is about.  An
/// answer is the answer to the line asked last: one that arrives after the
/// person asked something else, stopped waiting or left, is dropped.
class QuickSearchController extends ChangeNotifier {
  QuickSearchController({
    required this.app,
    required this.place,
    String? project,
  }) : project = project ?? defaultProject(app, place);

  final AppController app;
  final QuickSearchPlace place;

  /// The project the search is about: where the tasks it reads are, and what
  /// a new session starts in.
  String project;

  QuickSearchStatus _status = QuickSearchStatus.idle;
  String _query = '';
  SearchBias? _bias;
  QuickSearchPlan? _plan;
  String? _error;
  String? _model;
  List<ProposedAction> _proposed = const [];
  List<ProposedAction> _running = const [];
  List<ActionResult> _results = const [];
  Map<String, QuickCommand> _catalogue = const {};
  int _seq = 0;
  bool _disposed = false;

  QuickSearchStatus get status => _status;

  /// The line asked last.
  String get query => _query;

  /// What the last search favoured.
  SearchBias get bias => _bias ?? place.bias;

  /// What the harness answered, once the search is done.
  QuickSearchPlan? get plan => _plan;

  /// Why the search failed, in words for a person.
  String? get error => _error;

  /// The model that answers, as the harness said (`search/warm`) or the
  /// plan did; null until either has.
  String? get model => _model;

  /// What the search proposes to do to tasks, waiting for a yes.
  List<ProposedAction> get proposed => _proposed;

  /// The actions being done now.
  List<ProposedAction> get running => _running;

  /// How the actions went.
  List<ActionResult> get results => _results;

  bool get searching => _status == QuickSearchStatus.searching;

  /// The lines searched before, newest first.
  List<String> get history => app.quickSearchHistory.lines;

  /// The project a search opened on [place] is about: the one the screen is
  /// narrowed to, else the one the app is on, else the first the harness
  /// knows; '/' when it knows none, which only finds what is not a
  /// project's.
  static String defaultProject(AppController app, QuickSearchPlace place) {
    String? chosen;
    switch (place.origin) {
      case SearchOrigin.tasks:
        chosen = app.tasks?.project ?? app.selectedProject;
      case SearchOrigin.chat:
        final id = place.sessionId;
        final session = id == null ? null : app.summaryFor(id);
        chosen =
            (session == null ? null : app.projectOfSession(session)) ??
            app.selectedProject;
      default:
        chosen = app.selectedProject;
    }
    return chosen ?? app.projects.firstOrNull ?? '/';
  }

  QuickSearchApi? get _service {
    final api = app.api;
    return api == null ? null : QuickSearchApi(api);
  }

  QuickSearchAvailability get availability {
    final service = _service;
    if (service == null || !app.hasSession) {
      return QuickSearchAvailability.disconnected;
    }
    if (!service.canSearch) return QuickSearchAvailability.unsupported;
    if (app.isReconnecting) return QuickSearchAvailability.reconnecting;
    return QuickSearchAvailability.ready;
  }

  /// What the app can do, as it was when the last search was asked: the
  /// command the search named is done as it was offered.
  List<QuickCommand> get catalogue => _catalogue.values.toList();

  /// The command of the app that [found], which the search named, is.
  QuickCommand? commandFor(FoundCommand found) => _catalogue[found.command];

  /// Whether the harness can do what a plan proposes.
  bool get canApply => _service?.canApply ?? false;

  /// Search another project from now on.
  void setProject(String next) {
    if (_disposed || next == project) return;
    project = next;
    _model = null;
    notifyListeners();
    unawaited(warm());
  }

  /// Have the harness start the model of the next search, as the box opens
  /// (`search/warm`): its process is up by the time the line is typed.  It
  /// says which model answers.  A failure is nobody's concern: the search
  /// finds out for itself.
  Future<void> warm() async {
    final service = _service;
    if (service == null || availability != QuickSearchAvailability.ready) {
      return;
    }
    final asked = project;
    try {
      final model = await service.warm(asked);
      if (_disposed || asked != project || model == null) return;
      _model = model.id;
      notifyListeners();
    } catch (_) {
      // A search does not need it.
    }
  }

  /// Ask the harness about [line], favouring [bias] (what the place suggests
  /// by default).  An empty line asks nothing.  The line goes in the history.
  Future<void> search(String line, {SearchBias? bias}) async {
    final text = line.trim();
    final service = _service;
    if (_disposed || text.isEmpty || service == null) return;
    if (availability != QuickSearchAvailability.ready) return;
    app.quickSearchHistory.add(text);
    final seq = ++_seq;
    final favoured = bias ?? place.bias;
    final catalogue = quickCommands(app, project: project);
    _catalogue = {for (final command in catalogue) command.name: command};
    _query = text;
    _bias = favoured;
    _status = QuickSearchStatus.searching;
    _plan = null;
    _error = null;
    _proposed = const [];
    _running = const [];
    _results = const [];
    notifyListeners();
    try {
      final found = await service.ask(
        cwd: project,
        query: text,
        bias: favoured,
        context: place.toContext(project),
        commands: [for (final command in catalogue) command.toWire()],
      );
      if (_stale(seq)) return;
      _plan = found;
      _model = found.model ?? _model;
      // Every order is proposed, whether the board would run it at once or
      // not: a line typed on the phone does nothing to a task unasked.
      _proposed = found.actions;
      _status = QuickSearchStatus.done;
    } catch (error) {
      if (_stale(seq)) return;
      _error = QuickSearchApi.describe(error);
      _status = QuickSearchStatus.failed;
    }
    notifyListeners();
  }

  /// Ask the line asked last again.
  Future<void> retry() => search(_query, bias: _bias);

  /// Ask the line asked last again, favouring [bias].
  Future<void> reask(SearchBias bias) => search(_query, bias: bias);

  /// Stop waiting for the answer.  The harness's model finishes by itself;
  /// what it says is dropped when it comes.  The line stays where it was
  /// typed, to be refined.
  void cancel() {
    if (_disposed || !searching) return;
    _seq++;
    _status = QuickSearchStatus.idle;
    notifyListeners();
  }

  /// Leave what the search proposes undone.
  void skip() {
    if (_disposed || _proposed.isEmpty) return;
    _proposed = const [];
    notifyListeners();
  }

  /// Do what the search proposes, and say how it went.
  Future<void> doIt() async {
    final service = _service;
    final actions = _proposed;
    if (_disposed ||
        service == null ||
        actions.isEmpty ||
        _running.isNotEmpty) {
      return;
    }
    final seq = _seq;
    _proposed = const [];
    _running = actions;
    _results = const [];
    notifyListeners();
    List<ActionResult> done;
    try {
      done = await service.apply(actions);
      if (done.isEmpty) {
        done = [
          for (final action in actions)
            ActionResult.failed(action, 'the harness did not say how it went'),
        ];
      }
    } catch (error) {
      done = [
        for (final action in actions)
          ActionResult.failed(action, QuickSearchApi.describe(error)),
      ];
    }
    // The board follows what was done to it.
    final tasks = app.tasks;
    if (tasks != null) unawaited(tasks.reload(showSpinner: false));
    if (_disposed || seq != _seq) return;
    _running = const [];
    _results = done;
    notifyListeners();
  }

  bool _stale(int seq) => _disposed || seq != _seq;

  @override
  void dispose() {
    _disposed = true;
    _seq++;
    super.dispose();
  }
}
