import 'dart:async';

import 'package:flutter/foundation.dart';

import '../acp/acp_client.dart';
import '../models/workspace.dart';
import '../services/harness_api.dart';

/// The workspace chat on the client: the workspace, its threads, its timeline
/// and its computer.  One controller serves every screen size; the screens
/// decide how much of it to show.
class WorkspaceController extends ChangeNotifier {
  WorkspaceController(this._api);

  /// A controller with data and no harness behind it, for the widget tests
  /// and the screenshot cases.
  WorkspaceController.preview({
    required WorkspaceSummary workspace,
    List<WorkspaceEntry> entries = const [],
    WorkspaceMemoryStatus? memory,
    WorkspaceComputerStatus computer = const WorkspaceComputerStatus(),
  }) : _api = null,
       workspaces = [workspace],
       current = workspace,
       threads = workspace.threads,
       entries = entries,
       memory = memory,
       computer = computer,
       selectedThread = workspace.active?.id;

  final HarnessApi? _api;

  List<WorkspaceSummary> workspaces = const [];
  WorkspaceSummary? current;
  List<WorkspaceThread> threads = const [];
  List<WorkspaceEntry> entries = const [];
  WorkspaceMemoryStatus? memory;
  WorkspaceComputerStatus computer = const WorkspaceComputerStatus();

  String? selectedThread;
  String? selectedTag;
  String? error;
  bool loading = false;
  bool sending = false;

  int _loads = 0;
  Timer? _reloadTimer;

  bool get _preview => _api == null;

  bool get canSend =>
      current != null && (_preview || _api!.can('workspace/prompt'));

  WorkspaceThread? get activeThread {
    for (final thread in threads) {
      if (thread.id == selectedThread) return thread;
    }
    for (final thread in threads) {
      if (thread.id == current?.lastThread) return thread;
    }
    return threads.isEmpty ? null : threads.first;
  }

  /// The threads the rail shows: all of them, or those sharing [selectedTag].
  List<WorkspaceThread> get shownThreads {
    final tag = selectedTag;
    if (tag == null) return threads;
    return [
      for (final thread in threads)
        if (thread.tags.any((item) => item.toLowerCase() == tag.toLowerCase()))
          thread,
    ];
  }

  /// The timeline narrowed to the threads the selected concept names.
  List<WorkspaceEntry> get visibleEntries {
    final tag = selectedTag;
    if (tag == null) return entries;
    final ids = {
      for (final thread in shownThreads) thread.id,
    };
    return [
      for (final entry in entries)
        if (ids.contains(entry.thread)) entry,
    ];
  }

  /// The concepts the prototype's periphery draws, most shared first.
  ///
  /// A concept is a tag a thread carries; the useful level is the few themes
  /// that cross threads, not a node for every page.  The Logseq taxonomy the
  /// dream maintains will feed the same list.
  List<ConceptTag> get concepts {
    final byName = <String, List<WorkspaceThread>>{};
    for (final thread in threads) {
      for (final tag in thread.tags) {
        final key = tag.trim();
        if (key.isEmpty) continue;
        byName.putIfAbsent(key, () => <WorkspaceThread>[]).add(thread);
      }
    }
    final list = [
      for (final entry in byName.entries)
        ConceptTag(
          name: entry.key,
          threads: entry.value,
          shared: entry.value.length > 1,
        ),
    ];
    list.sort((a, b) {
      final byCount = b.threads.length.compareTo(a.threads.length);
      return byCount != 0 ? byCount : a.name.compareTo(b.name);
    });
    return list;
  }

  void selectThread(String? id) {
    if (selectedThread == id) return;
    selectedThread = id;
    selectedTag = null;
    notifyListeners();
  }

  /// Narrow the rail to a concept.  Selecting the one that is on clears it,
  /// so a tap on a node is both a way in and a way back.
  void selectTag(String? tag) {
    final same = selectedTag != null &&
        tag != null &&
        selectedTag!.toLowerCase() == tag.toLowerCase();
    selectedTag = same ? null : tag;
    notifyListeners();
  }

  Future<void> load({String? id, bool showSpinner = true}) async {
    if (_preview) return;
    final api = _api!;
    final mine = ++_loads;
    bool overtaken() => mine != _loads;
    if (showSpinner) {
      loading = true;
      notifyListeners();
    }
    error = null;
    try {
      final all = await api.workspaces();
      if (overtaken()) return;
      workspaces = all;
      WorkspaceSummary? chosen;
      for (final workspace in all) {
        if (id != null && workspace.id == id) chosen = workspace;
      }
      if (chosen == null && current != null) {
        for (final workspace in all) {
          if (workspace.id == current!.id) chosen = workspace;
        }
      }
      chosen ??= all.isEmpty ? null : all.first;
      if (chosen == null) {
        current = null;
        threads = const [];
        entries = const [];
        selectedThread = null;
        notifyListeners();
        return;
      }
      final detail = await api.workspace(chosen.id);
      if (overtaken()) return;
      final timeline = await api.workspaceTimeline(chosen.id);
      if (overtaken()) return;
      final notes = await api.workspaceMemory(chosen.id);
      if (overtaken()) return;
      final box = await api.workspaceComputer(chosen.id);
      if (overtaken()) return;
      current = detail;
      threads = detail.threads;
      entries = timeline;
      memory = notes;
      computer = box ?? const WorkspaceComputerStatus();
      final wanted = selectedThread;
      selectedThread = _hasThread(wanted) ? wanted : detail.active?.id;
      if (selectedTag != null &&
          !concepts.any((concept) => concept.name == selectedTag)) {
        selectedTag = null;
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

  bool _hasThread(String? id) {
    if (id == null) return false;
    return threads.any((thread) => thread.id == id);
  }

  Future<void> reload({bool showSpinner = false}) =>
      load(showSpinner: showSpinner);

  /// Send [text] to the active thread.  The server records the user message
  /// and the brief, then the turn; the timeline events keep the screen live.
  Future<void> send(String text) async {
    final workspace = current;
    if (workspace == null || text.trim().isEmpty) return;
    final thread = activeThread?.id;
    if (_preview) {
      _appendPreview(text);
      return;
    }
    sending = true;
    error = null;
    notifyListeners();
    try {
      await _api!.promptWorkspace(workspace.id, text, thread: thread);
      await load(showSpinner: false);
    } on AcpException catch (failure) {
      error = failure.message;
    } catch (failure) {
      error = '$failure';
    } finally {
      sending = false;
      notifyListeners();
    }
  }

  void _appendPreview(String text) {
    entries = [
      ...entries,
      WorkspaceEntry(kind: 'message', role: 'user', text: text, at: DateTime.now()),
      WorkspaceEntry(
        kind: 'message',
        role: 'assistant',
        text: 'The preview keeps this answer local.',
        at: DateTime.now(),
      ),
    ];
    notifyListeners();
  }

  Future<void> cancel() async {
    final workspace = current;
    if (workspace == null || _preview) return;
    try {
      await _api!.cancelWorkspace(workspace.id, thread: activeThread?.id);
      await reload();
    } on AcpException catch (failure) {
      error = failure.message;
      notifyListeners();
    }
  }

  Future<void> create(String name) async {
    final api = _api;
    if (_preview || api == null) return;
    try {
      final workspace = await api.createWorkspace(name);
      await load(id: workspace.id, showSpinner: false);
    } on AcpException catch (failure) {
      error = failure.message;
      notifyListeners();
    }
  }

  Future<void> newThread(String title) async {
    final workspace = current;
    if (workspace == null) return;
    if (_preview) {
      final thread = WorkspaceThread(
        id: 'preview-${threads.length + 1}',
        title: title,
        tags: conceptTags(title),
      );
      threads = [...threads, thread];
      selectedThread = thread.id;
      selectedTag = null;
      notifyListeners();
      return;
    }
    final api = _api;
    if (api == null) return;
    try {
      final thread = await api.createWorkspaceThread(workspace.id, title);
      selectedThread = thread.id;
      selectedTag = null;
      await load(showSpinner: false);
    } on AcpException catch (failure) {
      error = failure.message;
      notifyListeners();
    }
  }

  /// Take the computer over, or give it back.  A harness without the box
  /// methods still animates the panel as a preview, so the interaction can
  /// be judged before the sandbox lands.
  Future<void> takeOver() async {
    if (!computer.userControl) {
      final api = _api;
      if (api != null && !_preview && computer.available &&
          api.can('workspace/box/take-over')) {
        try {
          await api.workspaceTakeOver(current!.id);
        } on AcpException {
          // The panel still changes; the next /status corrects it.
        }
      }
      computer = computer.copyWith(control: 'user');
      notifyListeners();
    }
  }

  Future<void> returnControl() async {
    if (computer.userControl) {
      final api = _api;
      if (api != null && !_preview && computer.available &&
          api.can('workspace/box/return-control')) {
        try {
          await api.workspaceReturnControl(current!.id);
        } on AcpException {
          // As above.
        }
      }
      computer = computer.copyWith(control: 'agent');
      notifyListeners();
    }
  }

  /// Follow the harness's workspace events, quietly.  A burst of entries
  /// arriving from one turn is one read of the timeline, not one per node.
  void applyEvent(String event, List<Object?> args) {
    if (!event.startsWith('workspace/')) return;
    final id = args.isEmpty ? null : args.first;
    if (id is String && current != null && id != current!.id) return;
    _reloadTimer?.cancel();
    _reloadTimer = Timer(const Duration(milliseconds: 140), () {
      if (!_preview) unawaited(load(showSpinner: false));
    });
  }

  @override
  void dispose() {
    _reloadTimer?.cancel();
    super.dispose();
  }
}

/// A tag at the level the prototype shows: a concept, the threads that share
/// it, and whether it is a bridge between more than one.
class ConceptTag {
  const ConceptTag({
    required this.name,
    required this.threads,
    required this.shared,
  });

  final String name;
  final List<WorkspaceThread> threads;
  final bool shared;
}
