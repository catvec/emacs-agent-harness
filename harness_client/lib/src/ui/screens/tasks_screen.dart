import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../models/task.dart';
import '../../state/app_controller.dart';
import '../../state/drafts.dart';
import '../../state/prompt_attachment.dart';
import '../../state/task_controller.dart';
import '../adaptive/adaptive_widgets.dart';
import '../adaptive/layout_widgets.dart';
import '../format.dart';
import '../theme/harness_theme.dart';
import '../widgets/connection_banner.dart';
import '../widgets/image_attachments.dart';
import '../widgets/quota_widgets.dart';

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

  static const _columns = [
    'needs-input',
    'active',
    'review',
    'pending',
    'merging',
    'backlog',
    'done',
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
                    onOpen: (task) => _showTask(context, task),
                    onOpenSession: widget.onOpenSession,
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

  Future<void> _showTask(BuildContext context, HarnessTask task) async {
    final controller = widget.app.tasks;
    if (controller == null) return;
    await showHarnessSheet<void>(
      context: context,
      builder: (sheetContext) => _TaskDetail(
        app: widget.app,
        controller: controller,
        taskId: task.id,
        onOpenSession: widget.onOpenSession,
      ),
    );
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
                        controller.load(project: chosen.isEmpty ? null : chosen),
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
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'The tasks of every project. Pick a project to pause its '
                'queue or change how its backlog starts.',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
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
      onPressed: controller.toggleQueue,
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
              onPressed: controller.toggleQueue,
            ),
          HarnessTextButton(
            label: autoQueue ? 'Backlog: auto' : 'Backlog: manual',
            icon: autoQueue
                ? Icons.auto_mode_rounded
                : Icons.pan_tool_alt_outlined,
            onPressed: controller.toggleBacklog,
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
/// and whether finished work waits for a review.
class _QueueSheet extends StatelessWidget {
  const _QueueSheet({required this.controller});

  final TaskController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final queued = controller.slots?.queue.length ?? 0;
        final suspended = controller.slots?.suspended ?? false;
        final autoQueue = controller.settings?.backlogMode == 'auto';
        final review = controller.settings?.requireVerification == true;
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
                  onChanged: (_) => controller.toggleQueue(),
                ),
                _ToggleRow(
                  icon: Icons.auto_mode_rounded,
                  title: 'Queue the backlog automatically',
                  subtitle:
                      'A task that is written up joins the queue by itself, '
                      'instead of waiting to be started.',
                  value: autoQueue,
                  onChanged: (_) => controller.toggleBacklog(),
                ),
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

class _TaskBoard extends StatelessWidget {
  const _TaskBoard({
    required this.app,
    required this.controller,
    required this.selectedColumn,
    required this.columns,
    required this.onSelectColumn,
    required this.onOpen,
    required this.onOpenSession,
  });

  final AppController app;
  final TaskController controller;
  final String selectedColumn;
  final List<String> columns;
  final ValueChanged<String> onSelectColumn;
  final ValueChanged<HarnessTask> onOpen;
  final ValueChanged<String> onOpenSession;

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
              controller: controller,
              onOpen: onOpen,
              onOpenSession: onOpenSession,
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
                            controller: controller,
                            onTap: () => onOpen(task),
                            onOpenSession: onOpenSession,
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
    required this.controller,
    required this.onOpen,
    required this.onOpenSession,
  });

  final String column;
  final List<HarnessTask> tasks;
  final AppController app;
  final TaskController controller;
  final ValueChanged<HarnessTask> onOpen;
  final ValueChanged<String> onOpenSession;

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
                      controller: controller,
                      onTap: () => onOpen(task),
                      onOpenSession: onOpenSession,
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

class TaskCard extends StatelessWidget {
  const TaskCard({
    super.key,
    required this.task,
    required this.app,
    required this.controller,
    required this.onTap,
    required this.onOpenSession,
  });

  final HarnessTask task;
  final AppController app;
  final TaskController controller;
  final VoidCallback onTap;
  final ValueChanged<String> onOpenSession;

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
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
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
                            if (report != null &&
                                report.summary.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Text(
                                truncate(report.summary, 140),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: HarnessText.subtitle(context),
                              ),
                            ],
                            if (task.error != null &&
                                task.error!.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Text(
                                truncate(task.error!, 100),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: HarnessText.caption(context)
                                    .copyWith(color: theme.colorScheme.error),
                              ),
                            ],
                          ],
                        ),
                      ),
                      // The buttons are a little further out than the text
                      // above: their icon, not their padding, lines up.
                      Padding(
                        padding: const EdgeInsets.fromLTRB(4, 2, 4, 4),
                        child: _TaskActions(
                          task: task,
                          controller: controller,
                          onOpenSession: onOpenSession,
                          onReview: onTap,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TaskActions extends StatelessWidget {
  const _TaskActions({
    required this.task,
    required this.controller,
    required this.onOpenSession,
    required this.onReview,
  });

  final HarnessTask task;
  final TaskController controller;
  final ValueChanged<String> onOpenSession;
  final VoidCallback onReview;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget? primary;
    if (task.isReview) {
      primary = HarnessTextButton(
        label: 'Review',
        icon: Icons.rate_review_outlined,
        dense: true,
        onPressed: onReview,
      );
    } else if (task.needsInput) {
      primary = HarnessTextButton(
        label: 'Answer',
        icon: Icons.front_hand_outlined,
        dense: true,
        onPressed: onReview,
      );
    } else if (task.isPending) {
      primary = HarnessTextButton(
        label: 'Start now',
        icon: Icons.play_arrow_rounded,
        dense: true,
        onPressed: () => controller.start(task.id),
      );
    } else if (task.isBacklog) {
      primary = HarnessTextButton(
        label: 'Start',
        icon: Icons.play_arrow_rounded,
        dense: true,
        onPressed: () => controller.start(task.id),
      );
    } else if (task.sessionId != null) {
      primary = HarnessTextButton(
        label: 'Open',
        icon: Icons.open_in_new_rounded,
        dense: true,
        onPressed: () => onOpenSession(task.sessionId!),
      );
    }
    return Row(
      children: [
        if (primary != null) primary,
        const Spacer(),
        if (task.isReview)
          HarnessIconButton(
            icon: Icons.check_circle_outline_rounded,
            label: 'Verify task',
            size: 18,
            color: HarnessColors.moss,
            onPressed: () => controller.verify(task.id),
          ),
        if (task.isPending || task.isBacklog)
          HarnessIconButton(
            icon: Icons.delete_outline_rounded,
            label: 'Cancel task',
            size: 18,
            color: theme.colorScheme.onSurfaceVariant,
            onPressed: () => controller.cancelTask(task.id),
          ),
        if (task.isActive && task.sessionId != null)
          HarnessIconButton(
            icon: Icons.stop_circle_outlined,
            label: 'Stop task',
            size: 18,
            color: theme.colorScheme.onSurfaceVariant,
            onPressed: () => controller.cancelTask(task.id),
          ),
        HarnessIconButton(
          icon: Icons.more_horiz_rounded,
          label: 'Task actions',
          size: 18,
          onPressed: () => _showActions(context),
        ),
      ],
    );
  }

  Future<void> _showActions(BuildContext context) async {
    final action = await showHarnessMenu<String>(
      context: context,
      title: task.title,
      items: [
        if (task.sessionId != null)
          const HarnessMenuItem(
            value: 'session',
            label: 'Open session',
            icon: Icons.open_in_new_rounded,
          ),
        if (task.isReview) ...[
          const HarnessMenuItem(
            value: 'verify',
            label: 'Verify and merge',
            icon: Icons.check_rounded,
          ),
          const HarnessMenuItem(
            value: 'reject',
            label: 'Send back with feedback',
            icon: Icons.reply_rounded,
          ),
        ],
        if (task.isBacklog)
          const HarnessMenuItem(
            value: 'queue',
            label: 'Queue it',
            icon: Icons.playlist_add_rounded,
          ),
        if (task.isPending)
          const HarnessMenuItem(
            value: 'start',
            label: 'Start now',
            icon: Icons.play_arrow_rounded,
          ),
        if (task.isStopped && !task.isReview)
          const HarnessMenuItem(
            value: 'retry',
            label: 'Retry',
            icon: Icons.replay_rounded,
          ),
        if (task.isActive)
          const HarnessMenuItem(
            value: 'cancel',
            label: 'Stop',
            icon: Icons.stop_rounded,
            destructive: true,
          ),
        if (!task.isDone)
          const HarnessMenuItem(
            value: 'complete',
            label: 'Mark complete',
            icon: Icons.done_all_rounded,
          ),
        if (task.isDone)
          const HarnessMenuItem(
            value: 'archive',
            label: 'Archive',
            icon: Icons.archive_outlined,
          ),
      ],
    );
    if (action == null) return;
    switch (action) {
      case 'session':
        if (task.sessionId != null) onOpenSession(task.sessionId!);
      case 'verify':
        await controller.verify(task.id);
      case 'reject':
        if (!context.mounted) return;
        final feedback = await showHarnessTextPrompt(
          context: context,
          title: 'Send it back',
          message: 'What should change? It goes to the task’s own session.',
          hint: 'Feedback',
          multiline: true,
          confirmLabel: 'Send back',
        );
        if (feedback != null && feedback.trim().isNotEmpty) {
          await controller.reject(task.id, feedback.trim());
        }
      case 'queue':
        await controller.queue(task.id);
      case 'start':
        await controller.start(task.id);
      case 'retry':
        await controller.retry(task.id);
      case 'cancel':
        await controller.cancelTask(task.id);
      case 'complete':
        if (!context.mounted) return;
        final confirmed = await showHarnessDialog<bool>(
          context: context,
          title: 'Mark this task complete?',
          message: 'That accepts the work without waiting for a merge.',
          confirmLabel: 'Complete',
          destructive: true,
        );
        if (confirmed == true) await controller.complete(task.id);
      case 'archive':
        await controller.archive(task.id);
    }
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
  String _priority = 'medium';
  bool _refine = false;
  bool _plan = false;
  bool _mainTree = false;
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
    if (resumed) {
      _priority = draft.priority;
      _refine = draft.refine;
      _plan = draft.plan;
      _mainTree = draft.mainTree;
      _attachments.addAll(draft.attachments);
    }
    _prompt.addListener(_keepDraft);
    _cwd.addListener(_keepDraft);
  }

  void _keepDraft() {
    _draft
      ..prompt = _prompt.text
      ..cwd = _cwd.text
      ..project = _project
      ..priority = _priority
      ..refine = _refine
      ..plan = _plan
      ..mainTree = _mainTree
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
              options: const [
                ('low', 'Low'),
                ('medium', 'Medium'),
                ('high', 'High'),
              ],
              value: _priority,
              onChanged: (value) => _choose(() => _priority = value),
            ),
            const SizedBox(height: 14),
            _ToggleRow(
              icon: Icons.edit_note_rounded,
              title: 'Write it up first',
              subtitle:
                  'Wait in the backlog; refines the prompt before it starts.',
              value: _refine,
              onChanged: (value) => _choose(() => _refine = value),
            ),
            _ToggleRow(
              icon: Icons.map_outlined,
              title: 'Plan first',
              subtitle: 'A strong model plans; a medium model carries it out.',
              value: _plan,
              onChanged: (value) => _choose(() => _plan = value),
            ),
            _ToggleRow(
              icon: Icons.account_tree_outlined,
              title: 'Work in the main tree',
              subtitle:
                  'No worktree or branch; changes land in the checkout itself.',
              value: _mainTree,
              onChanged: (value) => _choose(() => _mainTree = value),
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
  final ValueChanged<bool> onChanged;

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

class _TaskDetail extends StatelessWidget {
  const _TaskDetail({
    required this.app,
    required this.controller,
    required this.taskId,
    required this.onOpenSession,
  });

  final AppController app;
  final TaskController controller;
  final String taskId;
  final ValueChanged<String> onOpenSession;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        HarnessTask? task;
        for (final item in controller.tasks) {
          if (item.id == taskId) task = item;
        }
        if (task == null) {
          return const Padding(
            padding: EdgeInsets.all(30),
            child: Center(child: Text('This task is no longer on the board.')),
          );
        }
        final theme = Theme.of(context);
        final muted = theme.colorScheme.onSurfaceVariant;
        final color = HarnessColors.column(task.columnName, theme.brightness);
        final session = task.sessionId == null
            ? null
            : app.summaryFor(task.sessionId!);
        return Padding(
          padding: EdgeInsets.only(
            left: HarnessSpace.sheetGutter,
            right: HarnessSpace.sheetGutter,
            top: 2,
            bottom: MediaQuery.viewInsetsOf(context).bottom + 22,
          ),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Where the task stands: its column and its priority, then
                // its name, then where it lives.
                Row(
                  children: [
                    HarnessStatusLabel(
                      label: _columnLabel(task.columnName),
                      color: color,
                      style: HarnessText.subtitle(context),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: HarnessMetaLine(
                        parts: [
                          if (task.priority == 'high')
                            const HarnessMetaPart(
                              'High priority',
                              color: HarnessColors.oxide,
                              weight: FontWeight.w700,
                            )
                          else
                            '${task.priorityLabel} priority',
                        ],
                      ),
                    ),
                    HarnessIconButton(
                      icon: Icons.close_rounded,
                      label: 'Close',
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  task.title,
                  style: HarnessText.sheetTitle(context)
                      .copyWith(fontSize: 24, letterSpacing: -0.5),
                ),
                const SizedBox(height: 6),
                HarnessMetaLine(
                  maxLines: 3,
                  parts: [
                    projectName(app.projectOfTask(task)),
                    task.branch,
                    if (session != null)
                      'Session ${statusLabel(session.status)}',
                    if (task.verified)
                      const HarnessMetaPart(
                        'Verified',
                        color: HarnessColors.moss,
                        weight: FontWeight.w700,
                      ),
                    if (task.noMerge) 'No merge',
                    if (task.cannotContinue)
                      const HarnessMetaPart(
                        'Cannot continue',
                        color: HarnessColors.amber,
                        weight: FontWeight.w700,
                      ),
                  ],
                ),
                if (task.sessionId != null) ...[
                  const SizedBox(height: HarnessSpace.lg),
                  HarnessSecondaryButton(
                    label: 'Open the task’s session',
                    icon: Icons.open_in_new_rounded,
                    expand: true,
                    onPressed: () {
                      Navigator.of(context).maybePop();
                      onOpenSession(task!.sessionId!);
                    },
                  ),
                ],
                if (task.error != null && task.error!.isNotEmpty) ...[
                  const SizedBox(height: HarnessSpace.md),
                  HarnessErrorBanner(
                    message: task.error!,
                    margin: EdgeInsets.zero,
                  ),
                ],
                const SizedBox(height: HarnessSpace.lg),
                _DetailSection(
                  title: 'Prompt',
                  child: Text(
                    task.prompt.trim().isEmpty
                        ? 'No prompt recorded.'
                        : task.prompt,
                    style: HarnessText.body(context).copyWith(height: 1.5),
                  ),
                ),
                if (task.attachments.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  _DetailSection(
                    title: 'Attachments',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final name in task.attachments)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Row(
                              children: [
                                const Icon(Icons.image_outlined, size: 14),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    name,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      fontSize: 12.5,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
                if (task.report != null) ...[
                  const SizedBox(height: HarnessSpace.md),
                  _DetailSection(
                    title: 'Report',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (task.report!.missing)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: Text(
                              'No report was handed in; this is the last '
                              'message.',
                              style: HarnessText.caption(context)
                                  .copyWith(color: HarnessColors.amber),
                            ),
                          ),
                        if (task.report!.summary.isNotEmpty)
                          Text(
                            task.report!.summary,
                            style: HarnessText.body(context)
                                .copyWith(height: 1.5),
                          ),
                        if (task.report!.reproduction != null &&
                            task.report!.reproduction!.isNotEmpty) ...[
                          const SizedBox(height: HarnessSpace.md),
                          Text(
                            'TO REPRODUCE',
                            style: HarnessText.label(context),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            task.report!.reproduction!,
                            style: HarnessText.body(context)
                                .copyWith(height: 1.5),
                          ),
                        ],
                        for (final line in task.report!.evidenceLines) ...[
                          const SizedBox(height: 6),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Icon(
                                  Icons.check_circle_outline_rounded,
                                  size: 15,
                                  color: muted,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  line,
                                  style: HarnessText.subtitle(context).copyWith(
                                    color: theme.colorScheme.onSurface,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
                if (task.feedback.isNotEmpty) ...[
                  const SizedBox(height: HarnessSpace.md),
                  _DetailSection(
                    title: 'Feedback rounds',
                    child: Column(
                      children: [
                        for (final round in task.feedback)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Padding(
                                  padding: const EdgeInsets.only(top: 2),
                                  child: Icon(
                                    Icons.reply_rounded,
                                    size: 15,
                                    color: muted,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    round.text,
                                    style: HarnessText.subtitle(context)
                                        .copyWith(
                                          color: theme.colorScheme.onSurface,
                                        ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
                if (task.conflicts.isNotEmpty) ...[
                  const SizedBox(height: HarnessSpace.md),
                  _DetailSection(
                    title: 'Merge conflicts',
                    child: Text(
                      task.conflicts.join('\n'),
                      style: HarnessText.mono(context),
                    ),
                  ),
                ],
                const SizedBox(height: HarnessSpace.xl),
                _DetailActions(
                  task: task,
                  controller: controller,
                  onOpenSession: onOpenSession,
                  onReject: () async {
                    final feedback = await showHarnessTextPrompt(
                      context: context,
                      title: 'Send it back',
                      message: 'What should change?',
                      hint: 'Feedback',
                      multiline: true,
                      confirmLabel: 'Send back',
                    );
                    if (feedback != null && feedback.trim().isNotEmpty) {
                      await controller.reject(task!.id, feedback.trim());
                    }
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// What can be done with the task.  The one action to take is full width;
/// the others share a row, in equal parts: no ragged edge, and a thumb can
/// find them in the same place every time.
class _DetailActions extends StatelessWidget {
  const _DetailActions({
    required this.task,
    required this.controller,
    required this.onOpenSession,
    required this.onReject,
  });

  final HarnessTask task;
  final TaskController controller;
  final ValueChanged<String> onOpenSession;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    final primary = <Widget>[
      if (task.isReview)
        HarnessPrimaryButton(
          label: 'Verify and merge',
          icon: Icons.check_rounded,
          expand: true,
          onPressed: () => controller.verify(task.id),
        ),
      if (task.isPending)
        HarnessPrimaryButton(
          label: 'Start now',
          icon: Icons.play_arrow_rounded,
          expand: true,
          onPressed: () => controller.start(task.id),
        ),
      if (task.isBacklog)
        HarnessPrimaryButton(
          label: 'Start',
          icon: Icons.play_arrow_rounded,
          expand: true,
          onPressed: () => controller.start(task.id),
        ),
    ];
    final secondary = <Widget>[
      if (task.isReview)
        HarnessSecondaryButton(
          label: 'Send back',
          icon: Icons.reply_rounded,
          expand: true,
          onPressed: onReject,
        ),
      if (task.isBacklog)
        HarnessSecondaryButton(
          label: 'Queue it',
          icon: Icons.playlist_add_rounded,
          expand: true,
          onPressed: () => controller.queue(task.id),
        ),
      if (task.isStopped && !task.isReview)
        HarnessSecondaryButton(
          label: 'Retry',
          icon: Icons.replay_rounded,
          expand: true,
          onPressed: () => controller.retry(task.id),
        ),
      if (!task.isDone)
        HarnessSecondaryButton(
          label: 'Mark complete',
          icon: Icons.done_all_rounded,
          expand: true,
          onPressed: () async {
            final confirmed = await showHarnessDialog<bool>(
              context: context,
              title: 'Mark this task complete?',
              message: 'That accepts the work without waiting for a merge.',
              confirmLabel: 'Complete',
              destructive: true,
            );
            if (confirmed == true) await controller.complete(task.id);
          },
        ),
      if (task.isDone)
        HarnessSecondaryButton(
          label: 'Archive',
          icon: Icons.archive_outlined,
          expand: true,
          onPressed: () => controller.archive(task.id),
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final button in primary) ...[
          button,
          const SizedBox(height: HarnessSpace.sm),
        ],
        if (secondary.isNotEmpty)
          Row(
            children: [
              for (var index = 0; index < secondary.length; index++) ...[
                if (index > 0) const SizedBox(width: HarnessSpace.sm),
                Expanded(child: secondary[index]),
              ],
            ],
          ),
      ],
    );
  }
}

class _DetailSection extends StatelessWidget {
  const _DetailSection({required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return HarnessCard(
      padding: const EdgeInsets.all(HarnessSpace.lg),
      radius: 14,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title.toUpperCase(), style: HarnessText.label(context)),
          const SizedBox(height: HarnessSpace.sm),
          child,
        ],
      ),
    );
  }
}

String _columnLabel(String column) => switch (column) {
  'needs-input' => 'Needs input',
  'active' => 'Active',
  'review' => 'Review',
  'pending' => 'Pending',
  'merging' => 'Merging',
  'backlog' => 'Backlog',
  'done' => 'Done',
  _ => column,
};

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
