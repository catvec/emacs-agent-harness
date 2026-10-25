import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../models/task.dart';
import '../../models/task_chat.dart';
import '../../state/app_controller.dart';
import '../../state/drafts.dart';
import '../../state/prompt_attachment.dart';
import '../../state/settings_controller.dart';
import '../../state/task_controller.dart';
import '../adaptive/adaptive_widgets.dart';
import '../adaptive/layout_widgets.dart';
import '../format.dart';
import '../theme/harness_theme.dart';
import '../widgets/connection_banner.dart';
import '../widgets/image_attachments.dart';
import '../widgets/quota_widgets.dart';
import '../widgets/task_action_runner.dart';

class TasksScreen extends StatefulWidget {
  const TasksScreen({
    super.key,
    required this.app,
    required this.onOpenSession,
  });

  final AppController app;
  final ValueChanged<String> onOpenSession;

  @override
  State<TasksScreen> createState() => _TasksScreenState();
}

class _TasksScreenState extends State<TasksScreen> {
  String? _column;

  /// Why a tap on a task opened nothing, until it is dismissed.
  String? _notice;

  static const _columns = [
    'needs-input',
    'active',
    'review',
    'pending',
    'merging',
    'backlog',
    'done',
    'cancelled',
  ];

  @override
  Widget build(BuildContext context) {
    final controller = widget.app.tasks;
    if (controller == null) {
      return const Center(child: HarnessActivity(radius: 10));
    }
    return AnimatedBuilder(
      animation: Listenable.merge([controller, widget.app]),
      builder: (context, _) {
        final selected = _selectedColumn(controller);
        return HarnessPage(
          title: 'Tasks',
          actions: [
            // The tasks that were put away are kept out of sight; this is
            // where they are looked for, and brought back from.
            if (controller.archivedCount > 0 || controller.showArchived)
              HarnessIconButton(
                icon: controller.showArchived
                    ? Icons.archive_rounded
                    : Icons.archive_outlined,
                label: controller.showArchived
                    ? 'Hide archived tasks'
                    : 'Show archived tasks',
                onPressed: () =>
                    controller.setShowArchived(!controller.showArchived),
              ),
            HarnessIconButton(
              icon: adaptiveIcon(
                context,
                Icons.refresh_rounded,
                CupertinoIcons.arrow_clockwise,
              ),
              label: 'Refresh tasks',
              onPressed: () => controller.reload(),
            ),
            HarnessIconButton(
              icon: adaptiveIcon(
                context,
                Icons.add_rounded,
                CupertinoIcons.add,
              ),
              label: 'New task',
              onPressed: () => _newTask(context),
            ),
          ],
          body: Column(
            children: [
              _TaskHeader(
                app: widget.app,
                controller: controller,
                onNew: () => _newTask(context),
              ),
              if (controller.error != null)
                HarnessErrorBanner(
                  message: controller.error!,
                  onDismiss: () => controller.reload(),
                ),
              if (_notice != null)
                HarnessErrorBanner(
                  message: _notice!,
                  onDismiss: () => setState(() => _notice = null),
                ),
              if (controller.loading && controller.tasks.isEmpty)
                const Expanded(
                  child: Center(child: HarnessActivity(radius: 10)),
                )
              else if (controller.tasks.isEmpty)
                Expanded(
                  child: HarnessEmptyState(
                    icon: Icons.checklist_rtl_rounded,
                    title: 'The board is clear',
                    message:
                        'Submit a task and the harness gives it a session, a '
                        'worktree and a place in the merge queue.',
                    action: HarnessPrimaryButton(
                      label: 'New task',
                      icon: Icons.add_rounded,
                      onPressed: () => _newTask(context),
                    ),
                  ),
                )
              else
                Expanded(
                  child: _TaskBoard(
                    app: widget.app,
                    controller: controller,
                    selectedColumn: selected,
                    columns: _columns,
                    onSelectColumn: (column) =>
                        setState(() => _column = column),
                    onOpen: _openTask,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  String _selectedColumn(TaskController controller) {
    if (_column != null && controller.countFor(_column!) > 0) return _column!;
    for (final column in [
      'needs-input',
      'active',
      'review',
      'pending',
      'backlog',
      'merging',
      'done',
      'cancelled',
    ]) {
      if (controller.countFor(column) > 0) return column;
    }
    return 'pending';
  }

  Future<void> _newTask(BuildContext context) async {
    final controller = widget.app.tasks;
    if (controller == null) return;
    final created = await showHarnessSheet<HarnessTask>(
      context: context,
      builder: (sheetContext) => _NewTaskSheet(app: widget.app),
    );
    if (created != null && mounted) {
      setState(() => _column = created.columnName);
      // A task made for another project than the one the board is narrowed
      // to is not on that board: the board shows every project, where it is.
      final narrowed = controller.project;
      if (narrowed != null && widget.app.projectOfTask(created) != narrowed) {
        controller.load();
      } else {
        controller.reload();
      }
    }
  }

  /// A task is handled in its conversation: the board only leads there.
  /// Where it is verified, sent back, started or tried again is the
  /// conversation's bar (`SessionTaskBar`), not a sheet or buttons here.
  void _openTask(HarnessTask task) {
    final session = task.sessionId;
    if (session == null || session.isEmpty) {
      setState(() => _notice = '“${task.title}” has no conversation to open.');
      return;
    }
    if (_notice != null) setState(() => _notice = null);
    widget.onOpenSession(session);
  }
}

/// What the board is about (the project) and how the queue is doing, in two
/// lines.  The settings of the queue (pause it, how the backlog joins it)
/// are real controls, and are kept where controls are: inline on a wide
/// screen, in a sheet that the line opens on a phone.
class _TaskHeader extends StatelessWidget {
  const _TaskHeader({
    required this.app,
    required this.controller,
    required this.onNew,
  });

  final AppController app;
  final TaskController controller;
  final VoidCallback onNew;

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 920;
    final choose = app.projects.length > 1;
    // The board opens on every project; a project narrows it.  A queue is a
    // project's, so its line is the narrowed board's.
    final scoped = controller.project != null;
    // What the board's tasks cost, or the plan that pays for them with its
    // quota.  The model new tasks use names the provider whose account
    // stands for them all.
    final spend = app.spendOfTasks(
      controller.tasks,
      model: controller.settings?.model,
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        border: wide
            ? Border(
                bottom: BorderSide(
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
              )
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          HarnessScopeBar(
            label: scoped ? projectName(controller.project) : 'All projects',
            onTap: choose
                ? () async {
                    final chosen = await showHarnessMenu<String>(
                      context: context,
                      title: 'Task project',
                      items: [
                        const HarnessMenuItem(value: '', label: 'All projects'),
                        for (final project in app.projects)
                          HarnessMenuItem(
                            value: project,
                            label: projectName(project),
                            icon: Icons.folder_outlined,
                          ),
                      ],
                    );
                    if (chosen != null) {
                      unawaited(
                        controller.load(
                          project: chosen.isEmpty ? null : chosen,
                        ),
                      );
                    }
                  }
                : null,
            trailing: spend.worthShowing
                ? SpendChip(
                    key: const Key('tasks-spend'),
                    status: spend,
                    onTap: () => showPlanSheet(
                      context,
                      status: spend,
                      providerLabel: app.providerLabelOf(spend),
                    ),
                  )
                : null,
          ),
          if (scoped)
            _QueueLine(controller: controller, wide: wide)
          else
            Padding(
              padding: const EdgeInsets.fromLTRB(
                HarnessSpace.gutter,
                0,
                HarnessSpace.gutter,
                0,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        'The tasks of every project. Pick a project to pause '
                        'its queue or change how its backlog starts.',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                  if (_hasAllQueues(controller))
                    HarnessTextButton(
                      label: 'All queues',
                      icon: Icons.tune_rounded,
                      dense: true,
                      onPressed: () => showHarnessSheet<void>(
                        context: context,
                        builder: (sheetContext) =>
                            _AllQueuesSheet(controller: controller),
                      ),
                    ),
                ],
              ),
            ),
          const SizedBox(height: HarnessSpace.sm),
        ],
      ),
    );
  }
}

String _slotsText(TaskController controller) {
  final slots = controller.slots;
  final holders = slots?.holders.length ?? 0;
  final limit = slots?.limit;
  return limit == null ? '$holders working' : '$holders of $limit working';
}

/// How the queue is doing: who is working, who waits, and whether it is
/// paused (which is said first, and can be undone from the line).
class _QueueLine extends StatelessWidget {
  const _QueueLine({required this.controller, required this.wide});

  final TaskController controller;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final queued = controller.slots?.queue.length ?? 0;
    final suspended = controller.slots?.suspended ?? false;
    final autoQueue = controller.settings?.backlogMode == 'auto';
    final summary = HarnessMetaLine(
      parts: [
        if (suspended)
          const HarnessMetaPart(
            'Queue paused',
            color: HarnessColors.amber,
            weight: FontWeight.w700,
          ),
        _slotsText(controller),
        if (queued > 0) '$queued queued',
      ],
    );
    final resume = HarnessTextButton(
      label: 'Resume',
      icon: Icons.play_arrow_rounded,
      onPressed: () => controller.setQueueSuspended(false),
    );
    final Widget line;
    if (wide) {
      line = Row(
        children: [
          Expanded(child: summary),
          if (suspended)
            resume
          else
            HarnessTextButton(
              label: 'Pause queue',
              icon: Icons.pause_rounded,
              onPressed: () => controller.setQueueSuspended(true),
            ),
          HarnessTextButton(
            label: autoQueue ? 'Backlog: auto' : 'Backlog: manual',
            icon: autoQueue
                ? Icons.auto_mode_rounded
                : Icons.pan_tool_alt_outlined,
            onPressed: () => controller.setAutoQueue(!autoQueue),
          ),
        ],
      );
    } else {
      line = Row(
        children: [
          Expanded(
            child: Semantics(
              button: true,
              label: 'Queue settings',
              child: HarnessTap(
                onTap: () => _showQueue(context, controller),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: [
                      Expanded(child: summary),
                      if (!suspended) adaptiveChevron(context),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (suspended) resume,
        ],
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        HarnessSpace.gutter,
        0,
        HarnessSpace.gutter,
        0,
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 36),
        child: line,
      ),
    );
  }
}

Future<void> _showQueue(BuildContext context, TaskController controller) {
  return showHarnessSheet<void>(
    context: context,
    builder: (sheetContext) => _QueueSheet(controller: controller),
  );
}

/// The queue's settings: what pausing it does, how the backlog joins it,
/// and whether finished work waits for a review.  And the tasks themselves:
/// all of the project's can be paused at once, and let go again.
class _QueueSheet extends StatefulWidget {
  const _QueueSheet({required this.controller});

  final TaskController controller;

  @override
  State<_QueueSheet> createState() => _QueueSheetState();
}

class _QueueSheetState extends State<_QueueSheet> {
  /// What the last "all tasks" button did, in words.
  String? _note;

  TaskController get controller => widget.controller;

  Future<void> _all({required bool pause}) async {
    final count = await (pause
        ? controller.pauseAll()
        : controller.resumeAll());
    if (!mounted || count == null) return;
    setState(() => _note = _countNote(count, pause: pause));
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final queued = controller.slots?.queue.length ?? 0;
        final suspended = controller.slots?.suspended ?? false;
        final autoQueue = controller.settings?.backlogMode == 'auto';
        final review = controller.settings?.requireVerification == true;
        final busy = controller.busy;
        return Padding(
          padding: EdgeInsets.fromLTRB(
            HarnessSpace.sheetGutter,
            4,
            HarnessSpace.sheetGutter,
            MediaQuery.viewInsetsOf(context).bottom + 22,
          ),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Queue', style: HarnessText.sheetTitle(context)),
                const SizedBox(height: 4),
                HarnessMetaLine(
                  parts: [
                    _slotsText(controller),
                    if (queued > 0) '$queued queued',
                  ],
                ),
                const SizedBox(height: HarnessSpace.lg),
                _ToggleRow(
                  icon: Icons.pause_rounded,
                  title: 'Pause the queue',
                  subtitle:
                      'Waiting tasks do not start on their own until it '
                      'resumes.',
                  value: suspended,
                  onChanged: busy ? null : controller.setQueueSuspended,
                ),
                _ToggleRow(
                  icon: Icons.auto_mode_rounded,
                  title: 'Queue the backlog automatically',
                  subtitle:
                      'A task that is written up joins the queue by itself, '
                      'instead of waiting to be started.',
                  value: autoQueue,
                  onChanged: busy ? null : controller.setAutoQueue,
                ),
                if (_hasPauseAll(controller)) ...[
                  const SizedBox(height: HarnessSpace.sm),
                  Divider(color: Theme.of(context).colorScheme.outlineVariant),
                  const SizedBox(height: HarnessSpace.sm),
                  _AllTasksRow(
                    busy: busy,
                    note: _note,
                    onPause: () => _all(pause: true),
                    onResume: () => _all(pause: false),
                  ),
                ],
                const SizedBox(height: HarnessSpace.sm),
                Divider(color: Theme.of(context).colorScheme.outlineVariant),
                HarnessInfoRow(
                  label: 'Review',
                  value: review
                      ? 'Required: finished work waits for you to verify it.'
                      : 'Not required: finished work merges on its own.',
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Whether there is something to do to every project's queue at once.
bool _hasAllQueues(TaskController controller) =>
    _hasPauseAll(controller) ||
    (controller.api.can('task/suspend-all-queues') &&
        controller.api.can('task/resume-all-queues'));

/// Whether the harness can pause and resume every task of a project at once.
bool _hasPauseAll(TaskController controller) =>
    controller.api.can('task/pause-all') &&
    controller.api.can('task/resume-all');

/// What pausing or resuming [count] tasks did, as the board in Emacs says it.
String _countNote(int count, {required bool pause}) {
  if (count == 0) return pause ? 'No task to pause.' : 'No paused task.';
  final tasks = count == 1 ? '1 task' : '$count tasks';
  return pause ? 'Paused $tasks.' : 'Resumed $tasks.';
}

/// The same for [count] queues.
String _queuesNote(int count, {required bool pause}) {
  if (count == 0) return pause ? 'No queue to pause.' : 'No paused queue.';
  final queues = count == 1 ? '1 queue' : '$count queues';
  return pause ? 'Paused $queues.' : 'Resumed $queues.';
}

/// The two buttons that pause every task and let them go again, with what
/// the last one did.
class _AllTasksRow extends StatelessWidget {
  const _AllTasksRow({
    required this.busy,
    required this.note,
    required this.onPause,
    required this.onResume,
  });

  final bool busy;
  final String? note;
  final VoidCallback onPause;
  final VoidCallback onResume;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('TASKS', style: HarnessText.label(context)),
        const SizedBox(height: 4),
        Text(
          'Pausing a task puts it back in the queue and holds it there; the '
          'ones at work stop first.',
          style: HarnessText.caption(context),
        ),
        const SizedBox(height: HarnessSpace.sm),
        Row(
          children: [
            Expanded(
              child: HarnessSecondaryButton(
                label: 'Pause all',
                icon: Icons.pause_rounded,
                expand: true,
                onPressed: busy ? null : onPause,
              ),
            ),
            const SizedBox(width: HarnessSpace.sm),
            Expanded(
              child: HarnessSecondaryButton(
                label: 'Resume all',
                icon: Icons.play_arrow_rounded,
                expand: true,
                onPressed: busy ? null : onResume,
              ),
            ),
          ],
        ),
        if (note != null) ...[
          const SizedBox(height: 6),
          Text(note!, style: HarnessText.caption(context)),
        ],
      ],
    );
  }
}

/// The queues of every project at once, for a board that shows them all.
class _AllQueuesSheet extends StatefulWidget {
  const _AllQueuesSheet({required this.controller});

  final TaskController controller;

  @override
  State<_AllQueuesSheet> createState() => _AllQueuesSheetState();
}

class _AllQueuesSheetState extends State<_AllQueuesSheet> {
  String? _note;

  TaskController get controller => widget.controller;

  Future<void> _queues({required bool suspend}) async {
    final count = await controller.setAllQueuesSuspended(suspend);
    if (!mounted || count == null) return;
    setState(() => _note = _queuesNote(count, pause: suspend));
  }

  Future<void> _tasks({required bool pause}) async {
    final count = await (pause
        ? controller.pauseAll()
        : controller.resumeAll());
    if (!mounted || count == null) return;
    setState(() => _note = _countNote(count, pause: pause));
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final busy = controller.busy;
        final api = controller.api;
        return Padding(
          padding: EdgeInsets.fromLTRB(
            HarnessSpace.sheetGutter,
            4,
            HarnessSpace.sheetGutter,
            MediaQuery.viewInsetsOf(context).bottom + 22,
          ),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Every project', style: HarnessText.sheetTitle(context)),
                const SizedBox(height: 4),
                Text(
                  'Pick a project to pause its queue or change how its '
                  'backlog starts. These act on all of them.',
                  style: HarnessText.subtitle(context),
                ),
                if (api.can('task/suspend-all-queues') &&
                    api.can('task/resume-all-queues')) ...[
                  const SizedBox(height: HarnessSpace.lg),
                  Text('QUEUES', style: HarnessText.label(context)),
                  const SizedBox(height: HarnessSpace.sm),
                  Row(
                    children: [
                      Expanded(
                        child: HarnessSecondaryButton(
                          label: 'Pause every queue',
                          icon: Icons.pause_rounded,
                          expand: true,
                          onPressed: busy ? null : () => _queues(suspend: true),
                        ),
                      ),
                      const SizedBox(width: HarnessSpace.sm),
                      Expanded(
                        child: HarnessSecondaryButton(
                          label: 'Resume every queue',
                          icon: Icons.play_arrow_rounded,
                          expand: true,
                          onPressed: busy
                              ? null
                              : () => _queues(suspend: false),
                        ),
                      ),
                    ],
                  ),
                ],
                if (_hasPauseAll(controller)) ...[
                  const SizedBox(height: HarnessSpace.lg),
                  _AllTasksRow(
                    busy: busy,
                    note: null,
                    onPause: () => _tasks(pause: true),
                    onResume: () => _tasks(pause: false),
                  ),
                ],
                if (_note != null) ...[
                  const SizedBox(height: HarnessSpace.md),
                  Text(_note!, style: HarnessText.caption(context)),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class _TaskBoard extends StatelessWidget {
  const _TaskBoard({
    required this.app,
    required this.controller,
    required this.selectedColumn,
    required this.columns,
    required this.onSelectColumn,
    required this.onOpen,
  });

  final AppController app;
  final TaskController controller;
  final String selectedColumn;
  final List<String> columns;
  final ValueChanged<String> onSelectColumn;
  final ValueChanged<HarnessTask> onOpen;

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 920;
    if (wide) {
      return ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 16),
        itemCount: columns.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, index) {
          final column = columns[index];
          return SizedBox(
            width: 300,
            child: _TaskColumn(
              column: column,
              tasks: controller.forColumn(column),
              app: app,
              onOpen: onOpen,
            ),
          );
        },
      );
    }
    final present = [
      for (final column in columns)
        if (controller.countFor(column) > 0) column,
    ];
    final selected = present.contains(selectedColumn)
        ? selectedColumn
        : present.firstOrNull;
    final brightness = Theme.of(context).brightness;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The columns of the board, as tabs: one row, from the gutter.
        HarnessTabStrip<String>(
          value: selected ?? '',
          onChanged: onSelectColumn,
          tabs: [
            for (final column in present)
              HarnessTab(
                value: column,
                label: _columnLabel(column),
                count: controller.countFor(column),
                color: HarnessColors.column(column, brightness),
              ),
          ],
        ),
        Expanded(
          child: selected == null
              ? const SizedBox.shrink()
              : RefreshIndicator(
                  onRefresh: () => controller.reload(),
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(
                      HarnessSpace.gutter,
                      HarnessSpace.md,
                      HarnessSpace.gutter,
                      20,
                    ),
                    children: [
                      for (final task in controller.forColumn(selected))
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: TaskCard(
                            task: task,
                            app: app,
                            onTap: () => onOpen(task),
                          ),
                        ),
                      if (controller.countFor(selected) == 0)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 40),
                          child: Center(
                            child: Text(
                              'Nothing in ${_columnLabel(selected).toLowerCase()}.',
                              style: HarnessText.subtitle(context),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }
}

class _TaskColumn extends StatelessWidget {
  const _TaskColumn({
    required this.column,
    required this.tasks,
    required this.app,
    required this.onOpen,
  });

  final String column;
  final List<HarnessTask> tasks;
  final AppController app;
  final ValueChanged<HarnessTask> onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = HarnessColors.column(column, theme.brightness);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 2, 4, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              HarnessDot(color: color),
              const SizedBox(width: 8),
              Text(
                _columnLabel(column),
                style: HarnessText.rowTitle(context).copyWith(fontSize: 14),
              ),
              const SizedBox(width: 6),
              Text('${tasks.length}', style: HarnessText.meta(context)),
            ],
          ),
        ),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLow.withValues(
                alpha: 0.5,
              ),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
              ),
            ),
            child: ListView(
              padding: const EdgeInsets.all(8),
              children: [
                for (final task in tasks)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: TaskCard(
                      task: task,
                      app: app,
                      onTap: () => onOpen(task),
                    ),
                  ),
                if (tasks.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 28),
                    child: Center(
                      child: Text('Empty', style: HarnessText.caption(context)),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// A task on the board: what it is, where it stands, and a way in.  Tapping
/// it opens its conversation, where it is handled (see `SessionTaskBar`):
/// the board is a list to choose from, with nothing to push on a card.
class TaskCard extends StatelessWidget {
  const TaskCard({
    super.key,
    required this.task,
    required this.app,
    required this.onTap,
  });

  final HarnessTask task;
  final AppController app;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = HarnessColors.column(task.columnName, theme.brightness);
    final report = task.report;
    // Where the work is, and anything out of the ordinary about it.  The
    // project is the board's own scope, and the column says the state: a
    // card does not repeat either.
    final meta = HarnessMetaLine(
      parts: [
        // What the column does not say: a pause, a wait, a task put away.
        ...taskStateParts(task),
        if (app.selectedProject == null) projectName(app.projectOfTask(task)),
        task.branch,
        if (task.priority == 'high')
          const HarnessMetaPart(
            'High priority',
            color: HarnessColors.oxide,
            weight: FontWeight.w700,
          )
        else if (task.priority == 'low')
          'Low priority',
      ],
      style: HarnessText.caption(context),
    );
    return Semantics(
      button: true,
      label: 'Task ${task.title}',
      child: HarnessTap(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerLowest,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: theme.colorScheme.outlineVariant),
          ),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  width: 4,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: const BorderRadius.horizontal(
                      left: Radius.circular(14),
                    ),
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 4, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          task.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: HarnessText.rowTitle(context),
                        ),
                        const SizedBox(height: 3),
                        meta,
                        if (report != null && report.summary.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          // The words of the summary, which is Markdown: a
                          // card has no room for its syntax.
                          Text(
                            markdownPreview(report.summary),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: HarnessText.subtitle(context),
                          ),
                        ],
                        if (task.error != null && task.error!.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Text(
                            truncate(task.error!, 100),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: HarnessText.caption(
                              context,
                            ).copyWith(color: theme.colorScheme.error),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                // The way in: the conversation of the task.
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Center(child: adaptiveChevron(context)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NewTaskSheet extends StatefulWidget {
  const _NewTaskSheet({required this.app});
  final AppController app;

  @override
  State<_NewTaskSheet> createState() => _NewTaskSheetState();
}

class _NewTaskSheetState extends State<_NewTaskSheet> {
  late final TextEditingController _prompt;
  late final TextEditingController _cwd;
  String? _project;

  /// The four choices below the description.  The sheet starts them as they
  /// were left, which the settings keep (see [_setChoice]).
  late String _priority;
  late bool _refine;
  late bool _plan;
  late bool _mainTree;
  bool _busy = false;
  String? _error;

  /// The pictures attached to the task, as the draft keeps them.
  final _attachments = <PromptAttachment>[];
  String? _attachmentError;
  bool _picking = false;

  /// What was written of the task, kept where it outlives this sheet: a
  /// sheet that is closed by accident, or thrown away with the screens when
  /// the connection is lost, must not take the description with it.
  TaskDraft get _draft => widget.app.drafts.task;

  @override
  void initState() {
    super.initState();
    final draft = _draft;
    final resumed = !draft.isEmpty;
    _prompt = TextEditingController(text: draft.prompt);
    // It starts in the project the board is narrowed to, else the one of the
    // latest work.
    final start = widget.app.tasks?.project ?? widget.app.selectedProject;
    _cwd = TextEditingController(text: resumed ? draft.cwd : start ?? '');
    _project = resumed ? draft.project : start;
    if (resumed) _attachments.addAll(draft.attachments);
    // How the last task was set, not the defaults: whoever files high
    // priority tasks for the main tree does not pick them again each time.
    final choices = widget.app.settings.newTaskChoices;
    _priority = choices.priority;
    _refine = choices.refine;
    _plan = choices.plan;
    _mainTree = choices.mainTree;
    _prompt.addListener(_keepDraft);
    _cwd.addListener(_keepDraft);
  }

  void _keepDraft() {
    _draft
      ..prompt = _prompt.text
      ..cwd = _cwd.text
      ..project = _project
      ..attachments = List.of(_attachments);
  }

  /// Whether the harness takes pictures sent with a task.  One that does not
  /// say would lose them, so none is offered: a harness without the setting
  /// is an older one.
  bool get _canAttach => widget.app.tasks?.settings?.takesImages ?? false;

  /// Pick pictures to attach.  The harness takes only what its settings
  /// name, up to a size, and refuses the whole task for one it does not, so
  /// what it would refuse is kept off, and said.
  Future<void> _pickImages() async {
    if (_picking || _busy) return;
    final accepted = widget.app.tasks?.settings?.inlineAttachments ?? const [];
    setState(() {
      _picking = true;
      _attachmentError = null;
    });
    try {
      final picked = await pickImageAttachments(
        room: maxImageAttachments - _attachments.length,
      );
      if (!mounted) return;
      final problems = <String>[];
      final kept = <PromptAttachment>[];
      for (final image in picked) {
        // What the bytes are, not what the file is called.
        final type = sniffImageMime(image.bytes);
        if (type == null || !accepted.contains(type)) {
          final types = [
            for (final mime in accepted) mime.split('/').last.toUpperCase(),
          ];
          problems.add(
            '${image.name} is not a picture a task takes (${types.join(', ')}).',
          );
        } else if (image.bytes.length > maxTaskImageBytes) {
          problems.add(
            '${image.name} is larger than ${maxTaskImageBytes ~/ (1024 * 1024)} MB.',
          );
        } else {
          kept.add(image);
        }
      }
      setState(() {
        _attachments.addAll(kept);
        _attachmentError = problems.isEmpty ? null : problems.join('\n');
      });
      _keepDraft();
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _attachmentError =
            'This platform cannot open the photo picker: ${error.toString().split('\n').first}',
      );
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  void _removeAttachment(int index) {
    setState(() {
      _attachments.removeAt(index);
      _attachmentError = null;
    });
    _keepDraft();
  }

  /// Change a choice on the sheet, and keep it with the rest of the draft.
  void _choose(VoidCallback change) {
    setState(change);
    _keepDraft();
  }

  /// Change the priority, or one of the three switches, and keep how they
  /// are set, where the next sheet and the next run of the app start from
  /// them.  They are kept as they change, not only when a task is sent: a
  /// sheet that is closed after a switch was turned opens with it turned.  A
  /// write that fails is for the settings to say
  /// (`SettingsController.persistenceProblem`), not for the sheet to stop on.
  void _setChoice(VoidCallback change) {
    setState(change);
    unawaited(
      widget.app.settings.setNewTaskChoices(
        NewTaskChoices(
          priority: _priority,
          refine: _refine,
          plan: _plan,
          mainTree: _mainTree,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _prompt.removeListener(_keepDraft);
    _cwd.removeListener(_keepDraft);
    _prompt.dispose();
    _cwd.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final controller = widget.app.tasks;
    if (controller == null || _prompt.text.trim().isEmpty) return;
    final cwd = (_project ?? _cwd.text).trim();
    if (cwd.isEmpty) {
      setState(() => _error = 'Choose a project or type an absolute path.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final task = await controller.submit(
      cwd: cwd,
      prompt: _prompt.text.trim(),
      priority: _priority,
      refine: _refine,
      plan: _plan,
      mainTree: _mainTree,
      attachments: _canAttach ? List.of(_attachments) : const [],
    );
    if (!mounted) return;
    if (task == null) {
      setState(() {
        _busy = false;
        _error = controller.error ?? 'The harness could not submit the task.';
      });
      return;
    }
    // Sent: only now is the description no longer worth keeping.
    _draft.clear();
    Navigator.of(context).pop(task);
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 4,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 22,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('New task', style: HarnessText.sheetTitle(context)),
            const SizedBox(height: 4),
            Text(
              'The harness gives it a session, a worktree and a place in the '
              'queue.',
              style: HarnessText.subtitle(context),
            ),
            // The sheet covers the banner of the screens under it. What is
            // written here is kept, and goes when the connection is back.
            ConnectionBanner(app: app, padding: const EdgeInsets.only(top: 12)),
            const SizedBox(height: 16),
            if (app.projects.isNotEmpty) ...[
              Text('PROJECT', style: HarnessText.label(context)),
              const SizedBox(height: 7),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final project in app.projects)
                    HarnessPill(
                      label: projectName(project),
                      icon: Icons.folder_outlined,
                      selected: _project == project,
                      onTap: () => _choose(() {
                        _project = project;
                        _cwd.text = project;
                      }),
                    ),
                ],
              ),
              const SizedBox(height: 8),
            ],
            HarnessTextField(
              controller: _cwd,
              hint: '/absolute/path/to/project',
              prefix: const Icon(Icons.folder_open_rounded, size: 18),
              onChanged: (_) {
                if (_project != null) _choose(() => _project = null);
              },
            ),
            const SizedBox(height: 14),
            Text('WHAT SHOULD IT DO?', style: HarnessText.label(context)),
            const SizedBox(height: 7),
            HarnessTextField(
              controller: _prompt,
              hint: 'Describe the change, the bug, or the question…',
              maxLines: 6,
              minLines: 4,
              textInputAction: TextInputAction.newline,
            ),
            _attachmentsRow(),
            const SizedBox(height: 14),
            Text('PRIORITY', style: HarnessText.label(context)),
            const SizedBox(height: 7),
            HarnessSegmented<String>(
              key: const Key('task-priority'),
              options: const [
                ('low', 'Low'),
                ('medium', 'Medium'),
                ('high', 'High'),
              ],
              value: _priority,
              onChanged: (value) => _setChoice(() => _priority = value),
            ),
            const SizedBox(height: 14),
            _ToggleRow(
              key: const Key('task-refine'),
              icon: Icons.edit_note_rounded,
              title: 'Write it up first',
              subtitle:
                  'Wait in the backlog; refines the prompt before it starts.',
              value: _refine,
              onChanged: (value) => _setChoice(() => _refine = value),
            ),
            _ToggleRow(
              key: const Key('task-plan'),
              icon: Icons.map_outlined,
              title: 'Plan first',
              subtitle: 'A strong model plans; a medium model carries it out.',
              value: _plan,
              onChanged: (value) => _setChoice(() => _plan = value),
            ),
            _ToggleRow(
              key: const Key('task-main-tree'),
              icon: Icons.account_tree_outlined,
              title: 'Work in the main tree',
              subtitle:
                  'No worktree or branch; changes land in the checkout itself.',
              value: _mainTree,
              onChanged: (value) => _setChoice(() => _mainTree = value),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              HarnessErrorBanner(message: _error!, margin: EdgeInsets.zero),
            ],
            const SizedBox(height: 18),
            HarnessPrimaryButton(
              label: _busy
                  ? 'Submitting…'
                  : _refine
                  ? 'Add to backlog'
                  : 'Submit task',
              icon: _busy ? null : Icons.arrow_forward_rounded,
              busy: _busy,
              expand: true,
              onPressed: _busy ? null : _submit,
            ),
          ],
        ),
      ),
    );
  }

  /// The pictures attached to the task, and the button that attaches more:
  /// only when the harness takes them, which its settings say once they are
  /// read, so the row comes up when they are.
  Widget _attachmentsRow() {
    final controller = widget.app.tasks;
    if (controller == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (!_canAttach) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  for (var i = 0; i < _attachments.length; i++)
                    ImageAttachmentThumbnail(
                      // Not by name: two files of one name can be picked.
                      key: ObjectKey(_attachments[i]),
                      attachment: _attachments[i],
                      size: 64,
                      onRemove: () => _removeAttachment(i),
                    ),
                  if (_attachments.length < maxImageAttachments)
                    HarnessPill(
                      key: const Key('task-attach'),
                      label: _picking
                          ? 'Opening photos…'
                          : _attachments.isEmpty
                          ? 'Attach images'
                          : 'Add more',
                      icon: Icons.add_photo_alternate_outlined,
                      onTap: _picking || _busy ? null : _pickImages,
                    ),
                ],
              ),
              if (_attachmentError != null) ...[
                const SizedBox(height: 6),
                Text(
                  _attachmentError!,
                  key: const Key('task-attachment-error'),
                  style: HarnessText.caption(context)
                      .copyWith(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _ToggleRow extends StatelessWidget {
  const _ToggleRow({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;

  /// Null while the row cannot be changed, as when the harness is busy with
  /// the last change.
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: HarnessText.rowTitle(context)),
                const SizedBox(height: 1),
                Text(subtitle, style: HarnessText.caption(context)),
              ],
            ),
          ),
          const SizedBox(width: 12),
          HarnessSwitch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

String _columnLabel(String column) => taskColumnLabel(column);

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
