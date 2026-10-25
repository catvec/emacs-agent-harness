import 'package:flutter/material.dart' show ThemeMode;

import '../acp/acp_message.dart';
import '../models/project_roots.dart';
import '../models/quick_search.dart';
import 'app_controller.dart';
import 'task_controller.dart';

/// What a quick search may make the app do, which the home shell, that holds
/// the screens, says how.  A command that only goes somewhere asks it to.
abstract interface class QuickSearchHost {
  /// Show one of the home screens: `sessions`, `tasks`, `usage`, `server` or
  /// `settings`.  Whatever is open on top of them is closed.
  void openTab(String tab);

  /// Open the conversation of a session.
  void openSession(String sessionId);

  /// Open the first session that waits for an answer; false when none does.
  bool openNeedsYou();
}

/// What a person chose in the quick search, which the home shell does once
/// the search has closed.
typedef QuickSearchChoice = Future<void> Function(QuickSearchHost host);

/// Which screen of the app a quick search was opened from.
enum SearchOrigin {
  sessions('Sessions'),
  tasks('Tasks'),
  usage('Usage'),
  server('Server'),
  settings('Settings'),
  chat('Conversation');

  const SearchOrigin(this.title);
  final String title;

  /// The screen of the home tab [id], `sessions` if it is none.
  static SearchOrigin ofTab(String id) {
    for (final origin in values) {
      if (origin.name == id && origin != chat) return origin;
    }
    return sessions;
  }
}

/// Where a quick search was opened: the app's screen, and in a conversation
/// which.  It sets what the search favours -- tasks on the task board,
/// sessions in the list of them, actions anywhere else -- and is told to the
/// model, which the harness's Emacs does with the buffer it was opened from
/// (`harness-quick-search-context`).
class QuickSearchPlace {
  const QuickSearchPlace(this.origin, {this.sessionId, this.sessionTitle});

  /// A search opened from the conversation [sessionId], which a search leaves
  /// out of what it finds: the person is in it.
  const QuickSearchPlace.chat(String sessionId, {String? title})
    : this(SearchOrigin.chat, sessionId: sessionId, sessionTitle: title);

  final SearchOrigin origin;
  final String? sessionId;
  final String? sessionTitle;

  /// What the search favours here: tasks on the task board, sessions in the
  /// session list, actions anywhere else.
  SearchBias get bias => switch (origin) {
    SearchOrigin.tasks => SearchBias.tasks,
    SearchOrigin.sessions => SearchBias.sessions,
    _ => SearchBias.commands,
  };

  /// The kind of place, as the harness's search knows it (`:view`): the task
  /// board, a chat, the session list; any other is a screen of its own.
  String get view => switch (origin) {
    SearchOrigin.tasks => 'board',
    SearchOrigin.sessions => 'sessions',
    SearchOrigin.chat => 'chat',
    SearchOrigin.settings => 'settings',
    _ => 'buffer',
  };

  /// What the place shows: the screen's name, or the conversation's.
  String get title => origin == SearchOrigin.chat
      ? (sessionTitle ?? origin.title)
      : origin.title;

  /// As `search/ask` takes it (`:context`), with the project searched.
  /// `client` is what tells the model the person is on the phone app, not in
  /// Emacs, and that the commands it is given are the app's own.
  JsonMap toContext(String project) => {
    'view': view,
    'title': title,
    'client': 'phone app',
    'project': project,
    if (sessionId != null) 'session': sessionId,
  };
}

/// What kind of thing a command of the app is, which says how it is drawn
/// and what its button is called.
enum QuickCommandKind {
  /// Goes to a screen, or to where something is done.
  screen('Open'),

  /// Does something at once.
  action('Run'),

  /// Changes a setting at once.
  setting('Set'),

  /// Narrows the app to a project.
  project('Open');

  const QuickCommandKind(this.verb);
  final String verb;
}

/// One thing the app can do for a quick search: what the model may name,
/// and, once a person taps it, what is done.
///
/// What the harness's Emacs sends its search for each command (its keys, what
/// the menu calls it, the first line of its documentation) the app sends too:
/// [keys] are the taps that reach it, [label] what it is called, [doc] what it
/// does, in a line, as the model reads at most 120 characters of it.  A
/// "how do I ...?" is answered from them, so they say where things are.
class QuickCommand {
  const QuickCommand({
    required this.name,
    required this.label,
    required this.doc,
    required this.run,
    this.keys,
    this.where = 'app',
    this.kind = QuickCommandKind.screen,
  });

  /// Its name, which the answer names it by: one word of lower case letters
  /// and hyphens, the same on every run.
  final String name;
  final String label;
  final String doc;
  final String? keys;

  /// What the harness's search calls where a command applies.  The commands
  /// the model is shown whatever the line says are those `menu` lists.
  final String where;
  final QuickCommandKind kind;

  /// Do it.  The search has closed by then.
  final Future<void> Function(QuickSearchHost host) run;

  /// As `search/ask` takes it (`:commands`).  Every one runs where the
  /// search was opened: the app is the same on every screen.
  JsonMap toWire() => {
    'command': name,
    if (keys != null) 'keys': keys,
    'where': where,
    'label': label,
    'doc': doc,
    'here': true,
  };
}

/// The most projects the catalogue names: a person with more has asked for
/// one of them by name, which the model finds in the list it is sent.
const _maxProjects = 40;

/// The commands of the app, as they are now: the screens it has, the
/// settings it can change, how to do what it does, and every project.  What
/// this harness cannot do (no task board, no usage) is left out, as are the
/// commands that would change nothing (the theme already in use).
///
/// [project] is where a new session starts: the project of the screen the
/// search was opened from.
List<QuickCommand> quickCommands(AppController app, {String? project}) {
  final settings = app.settings;
  final tasks = app.hasTasks ? app.tasks : null;
  final waiting = app.attentionCount;
  final projectLabel = project == null ? null : _projectLabel(project);
  QuickCommand screen(
    String name,
    String tab,
    String keys,
    String label,
    String doc, {
    String where = 'menu',
  }) => QuickCommand(
    name: name,
    keys: keys,
    where: where,
    label: label,
    doc: doc,
    run: (host) async => host.openTab(tab),
  );

  return [
    // The screens.
    screen(
      'open-sessions',
      'sessions',
      'Sessions tab',
      'Open the sessions list',
      'Every conversation, newest first, those that need you on top; '
          'search it, filter by project, tap one to open it.',
    ),
    if (tasks != null)
      screen(
        'open-tasks',
        'tasks',
        'Tasks tab',
        'Open the task board',
        'Tasks by column: needs you, working, review, queued, backlog, '
            'done; narrow it to one project.',
      ),
    if (app.hasUsage)
      screen(
        'open-usage',
        'usage',
        'Usage tab',
        'Open usage, spend and plan quota',
        'What the work cost: spend and tokens by project, model and day, '
            'budgets, and how much of the plan is left.',
      ),
    screen(
      'open-server',
      'server',
      'Server tab',
      'Open the server page',
      'The harness this app talks to: its version, its modules and the '
          'extensions it offers.',
    ),
    screen(
      'open-settings',
      'settings',
      'Settings tab',
      'Open settings',
      'Connection, theme, platform style, thinking, remembering the '
          'harness, non-interactive mode, sign out.',
    ),

    // What can be done.
    QuickCommand(
      name: 'new-session',
      keys: 'Sessions tab › +',
      where: 'menu',
      kind: QuickCommandKind.action,
      label: 'Start a new session',
      doc: projectLabel == null
          ? 'Begins a conversation with an agent; the + also lets you name '
                'it and pick the model.'
          : 'Begins a conversation with an agent in $projectLabel; the + '
                'also lets you name it and pick the project and model.',
      run: (host) async {
        // Where the new session shows up, while the harness makes it.
        host.openTab('sessions');
        final cwd = project ?? app.selectedProject ?? app.projects.firstOrNull;
        if (cwd == null) return;
        final id = await app.createSession(cwd: cwd);
        if (id != null) host.openSession(id);
      },
    ),
    if (app.capability?.taskSubmit == true)
      screen(
        'new-task',
        'tasks',
        'Tasks tab › +',
        'Submit a new task',
        'Describe the work, pick project and priority, attach images, '
            'write it up or plan it first, and send it.',
      ),
    QuickCommand(
      name: 'attach-images',
      keys: 'Tasks tab › + › Attach images; in a conversation › image button',
      where: 'menu',
      label: 'Attach images to a task or a message',
      doc:
          'The image button of the new-task sheet and of a conversation’s '
          'message box sends pictures along with the text.',
      run: (host) async => host.openTab(tasks != null ? 'tasks' : 'sessions'),
    ),
    QuickCommand(
      name: 'answer-waiting',
      keys: 'Sessions tab › Needs you › the session',
      where: 'menu',
      kind: waiting > 0 ? QuickCommandKind.action : QuickCommandKind.screen,
      label: waiting > 0
          ? 'Answer the session that needs you'
          : 'Answer an agent’s question or permission request',
      doc: waiting > 0
          ? '${waiting == 1 ? 'A question or permission request waits' : '$waiting sessions wait'} '
                'for you; this opens the first.'
          : 'A session that needs you says so; open it and answer its card: '
                'allow or deny a tool call, or pick an answer.',
      run: (host) async {
        if (!host.openNeedsYou()) host.openTab('sessions');
      },
    ),
    QuickCommand(
      name: 'refresh-sessions',
      keys: 'Sessions tab › refresh',
      label: 'Refresh the sessions',
      doc: 'Reads the list of sessions from the harness again.',
      kind: QuickCommandKind.action,
      run: (host) async {
        host.openTab('sessions');
        await app.refreshSessions();
      },
    ),
    if (tasks != null) ...[
      screen(
        'task-actions',
        'tasks',
        'Tasks tab › a task',
        'Verify, send back, stop, retry, pause, archive or message a task',
        'A task offers what applies to it: Verify and merge, Send back, '
            'Stop, Retry, Pause, Mark complete, Archive, Message.',
        where: 'tasks',
      ),
      screen(
        'queue-controls',
        'tasks',
        'Tasks tab › the queue line under the title',
        'Pause or resume the task queue',
        'Tap the line that says how the queue is doing to pause or resume '
            'it and to set how the backlog joins it.',
        where: 'tasks',
      ),
      QuickCommand(
        name: 'refresh-tasks',
        keys: 'Tasks tab › refresh',
        where: 'tasks',
        kind: QuickCommandKind.action,
        label: 'Refresh the task board',
        doc: 'Reads the tasks from the harness again.',
        run: (host) async {
          host.openTab('tasks');
          await tasks.reload();
        },
      ),
      if (tasks.archivedCount > 0 || tasks.showArchived)
        QuickCommand(
          name: tasks.showArchived
              ? 'hide-archived-tasks'
              : 'show-archived-tasks',
          keys: 'Tasks tab › archive icon',
          where: 'tasks',
          kind: QuickCommandKind.action,
          label: tasks.showArchived
              ? 'Hide archived tasks'
              : 'Show archived tasks',
          doc: tasks.showArchived
              ? 'Puts the tasks that were archived out of sight again.'
              : 'The archived tasks are kept out of sight; this shows them, '
                    'to bring one back.',
          run: (host) async {
            tasks.setShowArchived(!tasks.showArchived);
            host.openTab('tasks');
          },
        ),
      if (tasks.project != null)
        QuickCommand(
          name: 'all-projects',
          keys: 'Tasks tab › the project line',
          where: 'project',
          kind: QuickCommandKind.project,
          label: 'Show the tasks of every project',
          doc: 'Widens the task board from one project to all of them.',
          run: (host) async {
            host.openTab('tasks');
            await tasks.load();
          },
        ),
    ],

    // The projects.
    ..._projectCommands(app, tasks),

    // The settings.
    for (final mode in ThemeMode.values)
      if (mode != settings.themeMode)
        QuickCommand(
          name: switch (mode) {
            ThemeMode.light => 'theme-light',
            ThemeMode.dark => 'theme-dark',
            ThemeMode.system => 'theme-system',
          },
          keys: 'Settings tab › Appearance › Theme',
          where: 'settings',
          kind: QuickCommandKind.setting,
          label: switch (mode) {
            ThemeMode.light => 'Use the light theme',
            ThemeMode.dark => 'Use the dark theme',
            ThemeMode.system => 'Follow the system theme',
          },
          doc: switch (mode) {
            ThemeMode.light => 'Light colours, whatever the system uses.',
            ThemeMode.dark => 'Dark colours, whatever the system uses.',
            ThemeMode.system => 'Light or dark as the system is.',
          },
          run: (host) async => settings.setThemeMode(mode),
        ),
    QuickCommand(
      name: settings.showThinking ? 'hide-thinking' : 'show-thinking',
      keys: 'Settings tab › Chat › Show thinking',
      where: 'settings',
      kind: QuickCommandKind.setting,
      label: settings.showThinking
          ? 'Hide the agent’s thoughts in conversations'
          : 'Show the agent’s thoughts in conversations',
      doc: settings.showThinking
          ? 'Leaves out the streamed thinking of the agent.'
          : 'Shows the streamed thinking of the agent, collapsed.',
      run: (host) async => settings.setShowThinking(!settings.showThinking),
    ),
    if (app.canSetNonInteractiveEverywhere)
      screen(
        'non-interactive',
        'settings',
        'Settings tab › Conversations › Non-interactive',
        'Turn non-interactive mode on or off',
        'Every conversation and task runs without waiting for you, and new '
            'ones start that way; each can be switched on its own.',
        where: 'settings',
      ),
    QuickCommand(
      name: 'reconnect',
      keys: 'Settings tab › Reconnect',
      where: 'settings',
      kind: QuickCommandKind.action,
      label: 'Reconnect to the harness',
      doc: 'Opens the connection again; the screens and what you typed stay.',
      run: (host) async => app.reconnect(),
    ),
    screen(
      'disconnect',
      'settings',
      'Settings tab › Disconnect',
      'Disconnect from the harness',
      'Leaves this harness; the app does not go back in until you connect '
          'again. Conversations stay on the harness.',
      where: 'settings',
    ),
    if (app.canSignOut)
      screen(
        'sign-out',
        'settings',
        'Settings tab › Sign out of this harness',
        'Sign out of this harness',
        'Ends this device’s session on the harness and forgets its secret '
            'here; signing in again reconnects.',
        where: 'settings',
      ),
    screen(
      'remember-connection',
      'settings',
      'Settings tab › Chat › Remember',
      'Stay signed in on this device',
      'Keeps the harness’s address and this device’s session here, so the '
          'app goes back in by itself when it opens.',
      where: 'settings',
    ),
    screen(
      'platform-feel',
      'settings',
      'Settings tab › Appearance › Platform feel',
      'Switch between Android and Apple styling',
      'Material 3 controls or Cupertino ones; follows the system by default.',
      where: 'settings',
    ),
  ];
}

/// A command for each project: it narrows the app to it.  The task board when
/// there is one (with the new session of the next search, which starts in the
/// project the board is narrowed to), else the project the usage and the new
/// sessions are about.
List<QuickCommand> _projectCommands(AppController app, TaskController? tasks) {
  final taken = <String>{};
  final out = <QuickCommand>[];
  for (final project in app.projects.take(_maxProjects)) {
    final label = _projectLabel(project);
    var slug = _slug(label);
    if (slug.isEmpty) slug = 'project';
    var name = 'project-$slug';
    for (var n = 2; !taken.add(name); n++) {
      name = 'project-$slug-$n';
    }
    final where = _shorten(project, 60);
    out.add(
      QuickCommand(
        name: name,
        keys: tasks != null ? 'Tasks tab › the project line' : null,
        where: 'project',
        kind: QuickCommandKind.project,
        label: tasks != null
            ? 'Show the $label project’s tasks'
            : 'Switch to the $label project',
        doc: tasks != null
            ? 'Narrows the task board, usage and new sessions to $label '
                  '($where).'
            : 'Narrows usage and new sessions to $label ($where).',
        run: (host) async {
          app.selectProject(project);
          if (tasks != null) {
            host.openTab('tasks');
            await tasks.load(project: project);
          } else {
            host.openTab('sessions');
          }
        },
      ),
    );
  }
  return out;
}

/// The name of the project at [path]: its directory's.
String _projectLabel(String path) {
  final dir = worktreeOwner(path) ?? path;
  final parts = dir.split('/').where((part) => part.isNotEmpty).toList();
  return parts.isEmpty ? dir : parts.last;
}

String _slug(String text) => text
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
    .replaceAll(RegExp(r'^-+|-+$'), '');

String _shorten(String text, int max) =>
    text.length <= max ? text : '…${text.substring(text.length - max + 1)}';
