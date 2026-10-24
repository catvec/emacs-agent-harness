import 'dart:async';

import 'package:flutter/foundation.dart';

import '../acp/acp_client.dart';
import '../acp/acp_message.dart';
import '../models/project_roots.dart';
import '../models/task.dart';
import '../services/harness_api.dart';
import 'prompt_attachment.dart';

class TaskController extends ChangeNotifier {
  TaskController(this.api);

  final HarnessApi api;
  List<HarnessTask> tasks = const [];
  TaskSlots? slots;
  TaskSettingsInfo? settings;

  /// The project the board is narrowed to, as a main checkout, or null for
  /// every project, which is how the board opens: a board that starts on one
  /// project hides the work of all the others, and a person looking for what
  /// is running in a project they did not pick first sees nothing of it.
  /// [load] sets it, [reload] keeps it.
  String? project;
  String? error;
  bool loading = false;
  bool busy = false;

  /// Whether the board shows the tasks that were put away (archived).  They
  /// are kept out of sight, as they are in Emacs, until a person asks for
  /// them: that is also where they are brought back from.
  bool showArchived = false;

  /// Which [load] is the latest, so that the answer of one that something
  /// newer overtook (the board was narrowed to another project meanwhile)
  /// is not shown as the board.
  int _loads = 0;

  List<String> get columns {
    const order = [
      'needs-input',
      'active',
      'review',
      'pending',
      'merging',
      'backlog',
      'done',
    ];
    final present = {
      for (final task in tasks)
        if (_shown(task)) task.columnName,
    };
    return [
      for (final column in order)
        if (present.contains(column)) column,
    ];
  }

  List<HarnessTask> forColumn(String column) => [
    for (final task in tasks)
      if (task.columnName == column && _shown(task)) task,
  ]..sort((a, b) => b.priorityRank.compareTo(a.priorityRank));

  int countFor(String column) =>
      tasks.where((task) => task.columnName == column && _shown(task)).length;

  bool _shown(HarnessTask task) => showArchived || !task.archived;

  /// How many of the board's tasks are put away.
  int get archivedCount => tasks.where((task) => task.archived).length;

  /// Show or hide the tasks that were put away.
  void setShowArchived(bool shown) {
    if (showArchived == shown) return;
    showArchived = shown;
    notifyListeners();
  }

  int get needsAttention => tasks.where((task) => task.needsInput).length;

  /// Read the board of [project], every project's when it is null, and
  /// keep the board narrowed to it from now on.  [keepError] keeps what was
  /// said of the last failure on show: the board is read again after an
  /// action that was refused, to show what the harness has now, and the
  /// words of the refusal are still the person's to read.
  Future<void> load({
    String? project,
    bool showSpinner = true,
    bool keepError = false,
  }) async {
    this.project = project;
    final mine = ++_loads;
    bool overtaken() => mine != _loads;
    if (showSpinner) {
      loading = true;
      notifyListeners();
    }
    if (!keepError) error = null;
    try {
      final loaded = await api.tasks(cwd: project);
      if (overtaken()) return;
      tasks = loaded;
      // The queue and the settings are a project's: with the board on every
      // project they are those of the first one, which is what a task
      // sheet's defaults come from, not what the board shows.
      final slotProject = project ?? _firstProject(loaded);
      if (slotProject != null &&
          slotProject.isNotEmpty &&
          api.can('task/slots')) {
        final found = await api
            .taskSlots(cwd: slotProject)
            .catchError((_) => const TaskSlots());
        if (overtaken()) return;
        slots = found;
      }
      if (slotProject != null &&
          slotProject.isNotEmpty &&
          api.can('task/settings')) {
        final found = await api
            .taskSettings(cwd: slotProject)
            .catchError((_) => const TaskSettingsInfo());
        if (overtaken()) return;
        settings = found;
      }
    } on AcpException catch (failure) {
      if (!overtaken()) error = failure.message;
    } catch (failure) {
      if (!overtaken()) error = '$failure';
    } finally {
      if (!overtaken()) {
        loading = false;
        notifyListeners();
      }
    }
  }

  /// Read the board again, narrowed as it is.
  Future<void> reload({bool showSpinner = true}) =>
      load(project: project, showSpinner: showSpinner);

  String? _firstProject(List<HarnessTask> tasks) {
    for (final task in tasks) {
      if (task.project != null && task.project!.isNotEmpty) return task.project;
      if (task.cwd != null && task.cwd!.isNotEmpty) return task.cwd;
    }
    return project;
  }

  void applyEvent(String event, List<Object?> args) {
    switch (event) {
      case 'task/changed':
      case 'task/review':
      case 'task/done':
        final wire = args.isEmpty ? null : args.first;
        if (wire is Map) {
          final task = HarnessTask.fromWire(asMap(wire));
          // The harness tells of every project's tasks; a board narrowed to
          // one has no place for the others'.
          if (_onBoard(task)) _upsert(task);
        }
      case 'task/deleted':
        final id = args.isEmpty ? null : asString(args.first);
        if (id != null) {
          tasks = tasks.where((task) => task.id != id).toList();
          notifyListeners();
        }
      case 'task/queue':
      case 'task/backlog-mode':
        // The queue of a project was suspended or resumed, or its backlog
        // changed mode: in Emacs, or by an agent's task_control.  The event
        // names the project by its checkout and says the new state, but the
        // board that is narrowed to it reads both again, which cannot go
        // wrong whichever way the project is written.
        unawaited(_refreshQueue());
    }
  }

  /// Read the queue and the settings of the board's project again, quietly:
  /// what the person sees follows what Emacs or an agent did.
  Future<void> _refreshQueue() async {
    final mine = _loads;
    final slotProject = project ?? _firstProject(tasks);
    if (slotProject == null || slotProject.isEmpty) return;
    try {
      if (api.can('task/slots')) {
        final found = await api.taskSlots(cwd: slotProject);
        if (mine != _loads) return;
        slots = found;
      }
      if (api.can('task/settings')) {
        final found = await api.taskSettings(cwd: slotProject);
        if (mine != _loads) return;
        settings = found;
      }
      notifyListeners();
    } on AcpException {
      // The next read of the board says what is wrong, if anything is.
    }
  }

  /// Whether [task] is one the board shows: any, with the board on every
  /// project, else one of its project (what `task/list` filters by).
  bool _onBoard(HarnessTask task) {
    final scope = projectDirectory(project);
    final home = projectDirectory(task.project);
    return scope.isEmpty || home.isEmpty || home == scope;
  }

  void _upsert(HarnessTask task) {
    final index = tasks.indexWhere((existing) => existing.id == task.id);
    if (index < 0) {
      tasks = [...tasks, task];
    } else {
      final copy = [...tasks];
      copy[index] = copy[index].merge(task);
      tasks = copy;
    }
    notifyListeners();
  }

  Future<T?> _run<T>(Future<T> Function() action) async {
    if (busy) return null;
    busy = true;
    error = null;
    notifyListeners();
    try {
      final result = await action();
      await load(project: project, showSpinner: false);
      return result;
    } on AcpException catch (failure) {
      error = failure.message;
      notifyListeners();
      await _readAfterFailure();
      return null;
    } catch (failure) {
      error = '$failure';
      notifyListeners();
      await _readAfterFailure();
      return null;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// A refusal usually means the board was behind the harness (the task was
  /// verified in Emacs while the sheet was open, say): read it again, so the
  /// board shows what is so, with the harness's words still on it.
  Future<void> _readAfterFailure() =>
      load(project: project, showSpinner: false, keepError: true);

  // The actions on a task.  Each asks the harness, which checks that it
  // applies to the task as it is now, reads the board again, and answers
  // with the task, or null when it failed: [error] then says why, in the
  // harness's words.

  Future<HarnessTask?> start(String id) => _run(() => api.startTask(id));
  Future<HarnessTask?> queue(String id) => _run(() => api.queueTask(id));
  Future<HarnessTask?> verify(String id) => _run(() => api.verifyTask(id));
  Future<HarnessTask?> reject(String id, String feedback) =>
      _run(() => api.rejectTask(id, feedback));
  Future<HarnessTask?> retry(String id) => _run(() => api.retryTask(id));
  Future<HarnessTask?> complete(String id) => _run(() => api.completeTask(id));
  Future<HarnessTask?> archive(String id) => _run(() => api.archiveTask(id));
  Future<HarnessTask?> unarchive(String id) =>
      _run(() => api.archiveTask(id, restore: true));
  Future<HarnessTask?> pause(String id) => _run(() => api.pauseTask(id));
  Future<HarnessTask?> resume(String id) => _run(() => api.resumeTask(id));
  Future<HarnessTask?> returnToPending(String id) =>
      _run(() => api.returnTaskToPending(id));

  /// Send the branch of [id] through the merge queue again, after a merge
  /// that failed.
  Future<HarnessTask?> retryMerge(String id) => _run(() => api.mergeTask(id));

  /// Write [text] to the session of [id]: steer it, answer it, give feedback
  /// on its write-up, reopen it.  Whether the harness took it.
  Future<bool> prompt(String id, String text) =>
      _done(() => api.promptTask(id, text));

  /// Stop [id], or drop it when it never started.  Whether it worked.
  Future<bool> cancelTask(String id) => _done(() => api.cancelTask(id));

  /// Forget [id], and its session too when [deleteSession] is set.  Whether
  /// it worked.
  Future<bool> delete(String id, {bool deleteSession = false}) =>
      _done(() => api.deleteTask(id, deleteSession: deleteSession));

  /// Give [task] [priority], which is its session's.  The board shows it at
  /// once and reads it back from the harness; where the harness refuses, the
  /// board goes back to what it said.  Whether it worked.
  Future<bool> setPriority(HarnessTask task, String priority) async {
    final session = task.sessionId;
    if (session == null || session.isEmpty) {
      error = 'This task has no session to hold its priority.';
      notifyListeners();
      return false;
    }
    final before = tasks;
    tasks = [
      for (final other in tasks)
        other.id == task.id ? other.withPriority(priority) : other,
    ];
    notifyListeners();
    final worked = await _done(() => api.setPriority(session, priority));
    if (!worked) {
      tasks = before;
      notifyListeners();
    }
    return worked;
  }

  /// Run [action] like [_run], for one that answers nothing of its own:
  /// whether it worked.
  Future<bool> _done(Future<void> Function() action) async =>
      await _run(() async {
        await action();
        return true;
      }) ??
      false;

  // The queue of the board's project, and what it does with the backlog.
  // They are set, not toggled: a toggle done from a screen that is a moment
  // behind the harness would put the queue the other way from the one asked
  // for.  Without a project the board has none to act on (it shows every
  // project's tasks), and nothing is sent.

  /// Suspend the board's queue ([suspended]) or resume it: no waiting task
  /// starts on its own while it is suspended; a task already at work goes on.
  Future<bool> setQueueSuspended(bool suspended) {
    final scope = project;
    if (scope == null) return Future.value(false);
    if (!api.can('task/suspend-queue') && api.can('task/toggle-queue')) {
      // A harness that can only switch it: not when it is as asked already.
      if ((slots?.suspended ?? false) == suspended) return Future.value(true);
      return _done(() => api.toggleTaskQueue(cwd: scope));
    }
    return _done(
      () => suspended
          ? api.suspendQueue(cwd: scope)
          : api.resumeQueue(cwd: scope),
    );
  }

  /// Let the backlog of the board's project queue the tasks that are written
  /// up by themselves ([auto]), or leave them for a person to queue.
  Future<bool> setAutoQueue(bool auto) {
    final scope = project;
    if (scope == null) return Future.value(false);
    if (!api.can('task/set-backlog-mode') &&
        api.can('task/toggle-backlog-mode')) {
      if ((settings?.backlogMode == 'auto') == auto) return Future.value(true);
      return _done(() => api.toggleBacklogMode(cwd: scope));
    }
    return _done(
      () => api.setBacklogMode(auto ? 'auto' : 'manual', cwd: scope),
    );
  }

  /// Pause every task of the board's project (every project's, with the
  /// board on all of them): those at work and those waiting for a slot.
  /// How many were paused, or null when it failed.
  Future<int?> pauseAll() => _countIds(() => api.pauseAllTasks(cwd: project));

  /// End the pause of every paused task of the board's project (every
  /// project's, with the board on all of them).  How many, or null.
  Future<int?> resumeAll() => _countIds(() => api.resumeAllTasks(cwd: project));

  /// Suspend or resume the queue of every project at once.  How many queues
  /// it was for, or null when it failed.
  Future<int?> setAllQueuesSuspended(bool suspended) =>
      _run(() => suspended ? api.suspendAllQueues() : api.resumeAllQueues());

  Future<int?> _countIds(Future<List<String>> Function() action) async {
    final ids = await _run(action);
    return ids?.length;
  }

  Future<HarnessTask?> submit({
    required String cwd,
    required String prompt,
    String? priority,
    bool refine = false,
    bool plan = false,
    bool mainTree = false,
    List<PromptAttachment> attachments = const [],
  }) => _run(
    () => api.submitTask(
      cwd: cwd,
      prompt: prompt,
      priority: priority,
      refine: refine,
      plan: plan,
      mainTree: mainTree,
      attachments: [for (final image in attachments) image.toTaskAttachment()],
    ),
  );
}

extension on HarnessTask {
  int get priorityRank => switch (priority) {
    'high' => 2,
    'low' => 0,
    _ => 1,
  };
}
