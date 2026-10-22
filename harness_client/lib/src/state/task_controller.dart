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
    final present = {for (final task in tasks) task.columnName};
    return [
      for (final column in order)
        if (present.contains(column)) column,
    ];
  }

  List<HarnessTask> forColumn(String column) => [
    for (final task in tasks)
      if (task.columnName == column) task,
  ]..sort((a, b) => b.priorityRank.compareTo(a.priorityRank));

  int countFor(String column) =>
      tasks.where((task) => task.columnName == column).length;

  int get needsAttention => tasks.where((task) => task.needsInput).length;

  /// Read the board of [project], every project's when it is null, and
  /// keep the board narrowed to it from now on.
  Future<void> load({String? project, bool showSpinner = true}) async {
    this.project = project;
    final mine = ++_loads;
    bool overtaken() => mine != _loads;
    if (showSpinner) {
      loading = true;
      notifyListeners();
    }
    error = null;
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
      return null;
    } catch (failure) {
      error = '$failure';
      notifyListeners();
      return null;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<HarnessTask?> start(String id) => _run(() => api.startTask(id));
  Future<HarnessTask?> queue(String id) => _run(() => api.queueTask(id));
  Future<HarnessTask?> verify(String id) => _run(() => api.verifyTask(id));
  Future<HarnessTask?> reject(String id, String feedback) =>
      _run(() => api.rejectTask(id, feedback));
  Future<HarnessTask?> prompt(String id, String text) =>
      _run(() => api.promptTask(id, text));
  Future<HarnessTask?> retry(String id) => _run(() => api.retryTask(id));
  Future<HarnessTask?> cancelTask(String id) => _run(() => api.cancelTask(id));
  Future<HarnessTask?> complete(String id) => _run(() => api.completeTask(id));
  Future<HarnessTask?> archive(String id) => _run(() => api.archiveTask(id));

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

  Future<void> toggleQueue() async {
    await _run(() async {
      await api.toggleTaskQueue(cwd: project);
      return null;
    });
  }

  Future<void> toggleBacklog() async {
    await _run(() async {
      await api.toggleBacklogMode(cwd: project);
      return null;
    });
  }
}

extension on HarnessTask {
  int get priorityRank => switch (priority) {
    'high' => 2,
    'low' => 0,
    _ => 1,
  };
}
