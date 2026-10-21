import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../models/task.dart';
import '../../state/app_controller.dart';
import '../../state/drafts.dart';
import '../../state/task_controller.dart';
import '../adaptive/adaptive_widgets.dart';
import '../format.dart';
import '../theme/harness_theme.dart';
import '../widgets/connection_banner.dart';

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
              onPressed: () =>
                  controller.load(project: widget.app.selectedProject),
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
                  onDismiss: () =>
                      controller.load(project: widget.app.selectedProject),
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
      controller.load(project: widget.app.selectedProject);
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
    final theme = Theme.of(context);
    final slots = controller.slots;
    final limit = slots?.limit;
    final holders = slots?.holders.length ?? 0;
    final queued = slots?.queue.length ?? 0;
    final suspended = slots?.suspended ?? false;
    final settings = controller.settings;
    final autoQueue = settings?.backlogMode == 'auto';
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.7),
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              HarnessPill(
                label: projectName(app.selectedProject),
                icon: Icons.folder_outlined,
                selected: app.selectedProject != null,
                onTap: () async {
                  final chosen = await showHarnessMenu<String>(
                    context: context,
                    title: 'Task project',
                    items: [
                      for (final project in app.projects)
                        HarnessMenuItem(
                          value: project,
                          label: projectName(project),
                          icon: Icons.folder_outlined,
                        ),
                    ],
                  );
                  if (chosen != null) app.selectProject(chosen);
                },
              ),
              HarnessPill(
                label: limit == null
                    ? '$holders working'
                    : '$holders / $limit working',
                icon: Icons.people_outline_rounded,
                color: HarnessColors.moss,
                onTap: null,
              ),
              if (queued > 0)
                HarnessPill(
                  label: '$queued queued',
                  icon: Icons.schedule_rounded,
                  color: theme.colorScheme.primary,
                  onTap: null,
                ),
              if (settings?.requireVerification == true)
                const HarnessPill(
                  label: 'Review required',
                  icon: Icons.visibility_outlined,
                  color: Color(0xFF6B7FD1),
                  onTap: null,
                ),
              HarnessPill(
                label: suspended ? 'Resume queue' : 'Pause queue',
                icon: suspended
                    ? Icons.play_arrow_rounded
                    : Icons.pause_rounded,
                color: suspended ? HarnessColors.amber : null,
                selected: suspended,
                onTap: () => controller.toggleQueue(),
              ),
              HarnessPill(
                label: autoQueue ? 'Auto queue' : 'Manual queue',
                icon: autoQueue
                    ? Icons.auto_mode_rounded
                    : Icons.pan_tool_alt_outlined,
                color: const Color(0xFFB08956),
                selected: autoQueue,
                onTap: () => controller.toggleBacklog(),
              ),
            ],
          ),
          if (queued > 0 || suspended)
            Padding(
              padding: const EdgeInsets.only(top: 7),
              child: Text(
                suspended
                    ? 'Waiting tasks do not start on their own until the queue resumes.'
                    : 'Queued tasks start by priority as slots free.',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontSize: 10.5,
                ),
              ),
            ),
        ],
      ),
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
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 4, 14, 4),
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final column in present)
                HarnessPill(
                  label: _columnLabel(column),
                  count: controller.countFor(column),
                  color: HarnessColors.column(
                    column,
                    Theme.of(context).brightness,
                  ),
                  selected: selected == column,
                  onTap: () => onSelectColumn(column),
                ),
            ],
          ),
        ),
        Expanded(
          child: selected == null
              ? const SizedBox.shrink()
              : RefreshIndicator(
                  onRefresh: () =>
                      controller.load(project: app.selectedProject),
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(14, 6, 14, 20),
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
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
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
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 7),
              Text(
                _columnLabel(column),
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.1,
                ),
              ),
              const SizedBox(width: 5),
              Text(
                '${tasks.length}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
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
                      child: Text(
                        'Empty',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant.withValues(
                            alpha: 0.6,
                          ),
                        ),
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
    final session = task.sessionId == null
        ? null
        : app.summaryFor(task.sessionId!);
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
                    padding: const EdgeInsets.fromLTRB(11, 10, 10, 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            _PriorityDot(priority: task.priority),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                task.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13.5,
                                  height: 1.25,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 5),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                [
                                      task.projectName,
                                      if (task.branch != null) task.branch,
                                      if (session != null)
                                        statusLabel(session.status),
                                    ]
                                    .where(
                                      (part) => part != null && part.isNotEmpty,
                                    )
                                    .join(' · '),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                  fontSize: 10.5,
                                ),
                              ),
                            ),
                            if (task.priority == 'high')
                              const HarnessStatusPill(
                                label: 'High',
                                color: HarnessColors.oxide,
                                icon: Icons.flag_rounded,
                              ),
                          ],
                        ),
                        if (report != null && report.summary.isNotEmpty) ...[
                          const SizedBox(height: 7),
                          Text(
                            truncate(report.summary, 120),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontSize: 11.5,
                              color: theme.colorScheme.onSurfaceVariant,
                              height: 1.35,
                            ),
                          ),
                        ],
                        if (task.error != null && task.error!.isNotEmpty) ...[
                          const SizedBox(height: 7),
                          Text(
                            truncate(task.error!, 100),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.error,
                              fontSize: 10.5,
                            ),
                          ),
                        ],
                        const SizedBox(height: 8),
                        _TaskActions(
                          task: task,
                          controller: controller,
                          onOpenSession: onOpenSession,
                          onReview: onTap,
                        ),
                      ],
                    ),
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
        onPressed: onReview,
      );
    } else if (task.needsInput) {
      primary = HarnessTextButton(
        label: 'Answer',
        icon: Icons.front_hand_outlined,
        onPressed: onReview,
      );
    } else if (task.isPending) {
      primary = HarnessTextButton(
        label: 'Start now',
        icon: Icons.play_arrow_rounded,
        onPressed: () => controller.start(task.id),
      );
    } else if (task.isBacklog) {
      primary = HarnessTextButton(
        label: 'Start',
        icon: Icons.play_arrow_rounded,
        onPressed: () => controller.start(task.id),
      );
    } else if (task.sessionId != null) {
      primary = HarnessTextButton(
        label: 'Open',
        icon: Icons.open_in_new_rounded,
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
    _cwd = TextEditingController(
      text: resumed ? draft.cwd : widget.app.selectedProject ?? '',
    );
    _project = resumed ? draft.project : widget.app.selectedProject;
    if (resumed) {
      _priority = draft.priority;
      _refine = draft.refine;
      _plan = draft.plan;
      _mainTree = draft.mainTree;
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
      ..mainTree = _mainTree;
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
    final theme = Theme.of(context);
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
            Text(
              'New task',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'The harness gives it a session, a worktree and a place in the queue.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            // The sheet covers the banner of the screens under it. What is
            // written here is kept, and goes when the connection is back.
            ConnectionBanner(app: app, padding: const EdgeInsets.only(top: 12)),
            const SizedBox(height: 16),
            if (app.projects.isNotEmpty) ...[
              Text('PROJECT', style: _label(theme)),
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
            Text('WHAT SHOULD IT DO?', style: _label(theme)),
            const SizedBox(height: 7),
            HarnessTextField(
              controller: _prompt,
              hint: 'Describe the change, the bug, or the question…',
              maxLines: 6,
              minLines: 4,
              textInputAction: TextInputAction.newline,
            ),
            const SizedBox(height: 14),
            Text('PRIORITY', style: _label(theme)),
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
              HarnessErrorBanner(message: _error!),
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

  TextStyle? _label(ThemeData theme) => theme.textTheme.labelSmall?.copyWith(
    letterSpacing: 1.1,
    fontWeight: FontWeight.w700,
    color: theme.colorScheme.onSurfaceVariant,
  );
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
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  subtitle,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontSize: 10.5,
                  ),
                ),
              ],
            ),
          ),
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
        final color = HarnessColors.column(task.columnName, theme.brightness);
        final session = task.sessionId == null
            ? null
            : app.summaryFor(task.sessionId!);
        return Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 2,
            bottom: MediaQuery.viewInsetsOf(context).bottom + 22,
          ),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Container(
                      width: 9,
                      height: 9,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    HarnessStatusPill(
                      label: _columnLabel(task.columnName),
                      color: color,
                    ),
                    const SizedBox(width: 6),
                    HarnessStatusPill(
                      label: task.priorityLabel,
                      color: task.priority == 'high'
                          ? HarnessColors.oxide
                          : theme.colorScheme.onSurfaceVariant,
                      icon: Icons.flag_outlined,
                    ),
                    const Spacer(),
                    HarnessIconButton(
                      icon: Icons.close_rounded,
                      label: 'Close',
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  task.title,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.6,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    HarnessStatusPill(
                      label: projectName(task.project ?? task.cwd),
                      color: theme.colorScheme.onSurfaceVariant,
                      icon: Icons.folder_outlined,
                    ),
                    if (task.branch != null)
                      HarnessStatusPill(
                        label: task.branch!,
                        color: theme.colorScheme.onSurfaceVariant,
                        icon: Icons.call_split_rounded,
                      ),
                    if (session != null)
                      HarnessStatusPill(
                        label: 'Session ${statusLabel(session.status)}',
                        color: HarnessColors.status(
                          session.status,
                          theme.brightness,
                        ),
                      ),
                    if (task.verified)
                      const HarnessStatusPill(
                        label: 'Verified',
                        color: HarnessColors.moss,
                        icon: Icons.verified_outlined,
                      ),
                    if (task.noMerge)
                      const HarnessStatusPill(
                        label: 'No merge',
                        color: HarnessColors.slate,
                        icon: Icons.call_merge_rounded,
                      ),
                    if (task.cannotContinue)
                      const HarnessStatusPill(
                        label: 'Cannot continue',
                        color: HarnessColors.amber,
                      ),
                  ],
                ),
                if (task.sessionId != null) ...[
                  const SizedBox(height: 14),
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
                  const SizedBox(height: 12),
                  HarnessErrorBanner(message: task.error!),
                ],
                const SizedBox(height: 18),
                _DetailSection(
                  title: 'Prompt',
                  child: Text(
                    task.prompt.trim().isEmpty
                        ? 'No prompt recorded.'
                        : task.prompt,
                    style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
                  ),
                ),
                if (task.report != null) ...[
                  const SizedBox(height: 16),
                  _DetailSection(
                    title: 'Report',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (task.report!.missing)
                          Text(
                            'No report was handed in; this is the last message.',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: HarnessColors.amber,
                            ),
                          ),
                        if (task.report!.summary.isNotEmpty)
                          Text(
                            task.report!.summary,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              height: 1.5,
                            ),
                          ),
                        if (task.report!.reproduction != null &&
                            task.report!.reproduction!.isNotEmpty) ...[
                          const SizedBox(height: 10),
                          Text(
                            'TO REPRODUCE',
                            style: theme.textTheme.labelSmall?.copyWith(
                              letterSpacing: 1,
                              fontWeight: FontWeight.w700,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(task.report!.reproduction!),
                        ],
                        for (final line in task.report!.evidenceLines) ...[
                          const SizedBox(height: 5),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Icon(
                                Icons.check_circle_outline_rounded,
                                size: 14,
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  line,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    fontSize: 12,
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
                  const SizedBox(height: 16),
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
                                const Icon(Icons.reply_rounded, size: 14),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    round.text,
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
                if (task.conflicts.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  _DetailSection(
                    title: 'Merge conflicts',
                    child: Text(task.conflicts.join('\n')),
                  ),
                ],
                const SizedBox(height: 20),
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
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        if (task.isReview) ...[
          HarnessPrimaryButton(
            label: 'Verify and merge',
            icon: Icons.check_rounded,
            onPressed: () => controller.verify(task.id),
          ),
          HarnessSecondaryButton(
            label: 'Send back',
            icon: Icons.reply_rounded,
            onPressed: onReject,
          ),
        ],
        if (task.isPending)
          HarnessPrimaryButton(
            label: 'Start now',
            icon: Icons.play_arrow_rounded,
            onPressed: () => controller.start(task.id),
          ),
        if (task.isBacklog) ...[
          HarnessPrimaryButton(
            label: 'Start',
            icon: Icons.play_arrow_rounded,
            onPressed: () => controller.start(task.id),
          ),
          HarnessSecondaryButton(
            label: 'Queue it',
            icon: Icons.playlist_add_rounded,
            onPressed: () => controller.queue(task.id),
          ),
        ],
        if (task.isStopped && !task.isReview)
          HarnessSecondaryButton(
            label: 'Retry',
            icon: Icons.replay_rounded,
            onPressed: () => controller.retry(task.id),
          ),
        if (!task.isDone)
          HarnessSecondaryButton(
            label: 'Mark complete',
            icon: Icons.done_all_rounded,
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
            onPressed: () => controller.archive(task.id),
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
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title.toUpperCase(),
            style: theme.textTheme.labelSmall?.copyWith(
              letterSpacing: 1.1,
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}

class _PriorityDot extends StatelessWidget {
  const _PriorityDot({required this.priority});
  final String? priority;

  @override
  Widget build(BuildContext context) {
    final color = switch (priority) {
      'high' => HarnessColors.oxide,
      'low' => Theme.of(
        context,
      ).colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
      _ => HarnessColors.amber,
    };
    return Tooltip(
      message: '${priority ?? 'medium'} priority',
      child: Container(
        width: 6,
        height: 6,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
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
