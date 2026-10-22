import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../models/activity.dart';
import '../../models/session.dart';
import '../../models/task.dart';
import '../../models/transcript.dart';
import '../../models/usage.dart';
import '../../state/app_controller.dart';
import '../../state/drafts.dart';
import '../../state/session_controller.dart';
import '../adaptive/adaptive_widgets.dart';
import '../adaptive/layout_widgets.dart';
import '../adaptive/platform_style.dart';
import '../app_scope.dart';
import '../format.dart';
import '../navigation.dart';
import '../theme/harness_theme.dart';
import '../widgets/connection_banner.dart';
import '../widgets/interaction_card.dart';
import '../widgets/message_composer.dart';
import '../widgets/quota_widgets.dart';
import '../widgets/transcript_view.dart';

class SessionScreen extends StatefulWidget {
  const SessionScreen({
    super.key,
    required this.sessionId,
    this.embedded = false,
  });

  final String sessionId;
  final bool embedded;

  @override
  State<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends State<SessionScreen> {
  late AppController _app;
  late SessionController _controller;
  bool _bound = false;
  int _scrollTick = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_bound) {
      _app = HarnessScope.appOf(context);
      _controller = _app.sessionController(widget.sessionId);
      _bound = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _app.openSession(widget.sessionId);
      });
    }
  }

  @override
  void didUpdateWidget(SessionScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessionId != widget.sessionId) {
      _controller = _app.sessionController(widget.sessionId);
      _scrollTick++;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _app.openSession(widget.sessionId);
      });
    }
  }

  @override
  void dispose() {
    if (!widget.embedded && _bound) {
      _app.closeSession();
    }
    super.dispose();
  }

  Future<void> _rename() async {
    final current = _controller.summary?.displayTitle ?? '';
    final name = await showHarnessTextPrompt(
      context: context,
      title: 'Rename session',
      initial: current,
      hint: 'A short title',
      confirmLabel: 'Rename',
    );
    if (name != null && name.trim().isNotEmpty) {
      await _controller.rename(name.trim());
    }
  }

  Future<void> _fork() async {
    final id = await _controller.fork();
    if (id == null || !mounted) return;
    if (widget.embedded) {
      _app.openSession(id);
    } else {
      await Navigator.of(context).pushReplacement(
        harnessRoute(context, (context) => SessionScreen(sessionId: id)),
      );
    }
  }

  Future<void> _delete() async {
    final confirmed = await showHarnessDialog<bool>(
      context: context,
      title: 'Delete this session?',
      message:
          'The transcript and its temporary files are removed from the harness. '
          'This cannot be undone.',
      confirmLabel: 'Delete',
      cancelLabel: 'Cancel',
      destructive: true,
    );
    if (confirmed != true) return;
    final removed = await _controller.deleteSession();
    if (removed && mounted) {
      if (widget.embedded) {
        _app.closeSession();
      } else {
        Navigator.of(context).pop();
      }
    }
  }

  Future<void> _chooseModel() async {
    final models = [
      for (final provider in _app.server?.providers ?? const [])
        for (final model in provider.models) model,
    ];
    if (models.isEmpty) {
      final value = await showHarnessTextPrompt(
        context: context,
        title: 'Change model',
        message: 'The harness takes provider:model.',
        initial: _controller.summary?.model ?? '',
        hint: 'provider:model',
        confirmLabel: 'Use model',
      );
      if (value != null && value.trim().isNotEmpty) {
        await _controller.setModel(value.trim());
      }
      return;
    }
    final chosen = await showHarnessMenu<String>(
      context: context,
      title: 'Model',
      items: [
        for (final model in models)
          HarnessMenuItem(
            value: model.id,
            label: model.name == model.id
                ? model.id
                : '${model.name} · ${model.id}',
            icon: Icons.memory_rounded,
          ),
      ],
    );
    if (chosen != null) await _controller.setModel(chosen);
  }

  Future<void> _chooseMode() async {
    final chosen = await showHarnessMenu<String>(
      context: context,
      title: 'Permission mode',
      items: const [
        HarnessMenuItem(
          value: 'ask',
          label: 'Ask · reads allowed, the rest asks',
          icon: Icons.help_outline_rounded,
        ),
        HarnessMenuItem(
          value: 'accept-edits',
          label: 'Accept edits · reads and writes allowed',
          icon: Icons.edit_outlined,
        ),
        HarnessMenuItem(
          value: 'auto',
          label: 'Auto · a judge decides each call',
          icon: Icons.auto_awesome_rounded,
        ),
        HarnessMenuItem(
          value: 'yolo',
          label: 'YOLO · everything inside the project',
          icon: Icons.bolt_rounded,
        ),
      ],
    );
    if (chosen != null) await _controller.setMode(chosen);
  }

  Future<void> _choosePriority() async {
    final chosen = await showHarnessMenu<String>(
      context: context,
      title: 'Session priority',
      items: const [
        HarnessMenuItem(
          value: 'high',
          label: 'High',
          icon: Icons.keyboard_double_arrow_up_rounded,
        ),
        HarnessMenuItem(
          value: 'medium',
          label: 'Medium',
          icon: Icons.drag_handle_rounded,
        ),
        HarnessMenuItem(
          value: 'low',
          label: 'Low',
          icon: Icons.keyboard_double_arrow_down_rounded,
        ),
      ],
    );
    if (chosen != null) await _controller.setPriority(chosen);
  }

  List<Widget> _actions(BuildContext context) {
    final caps = _app.capability;
    return [
      HarnessIconButton(
        icon: adaptiveIcon(
          context,
          Icons.refresh_rounded,
          CupertinoIcons.arrow_clockwise,
        ),
        label: 'Reload transcript',
        onPressed: () => _controller.open(force: true),
      ),
      HarnessIconButton(
        icon: adaptiveIcon(
          context,
          Icons.more_horiz_rounded,
          CupertinoIcons.ellipsis_circle,
        ),
        label: 'Session menu',
        onPressed: () async {
          final action = await showHarnessMenu<String>(
            context: context,
            title: _controller.summary?.displayTitle ?? 'Session',
            items: [
              if (caps?.renameSession == true)
                const HarnessMenuItem(
                  value: 'rename',
                  label: 'Rename',
                  icon: Icons.edit_outlined,
                ),
              if (caps?.fork == true)
                const HarnessMenuItem(
                  value: 'fork',
                  label: 'Fork conversation',
                  icon: Icons.call_split_rounded,
                ),
              if (caps?.priority == true)
                const HarnessMenuItem(
                  value: 'priority',
                  label: 'Priority',
                  icon: Icons.sort_rounded,
                ),
              const HarnessMenuItem(
                value: 'model',
                label: 'Change model',
                icon: Icons.memory_rounded,
              ),
              if (caps?.setMode == true)
                const HarnessMenuItem(
                  value: 'mode',
                  label: 'Permission mode',
                  icon: Icons.shield_outlined,
                ),
              if (caps?.deleteSession == true)
                const HarnessMenuItem(
                  value: 'delete',
                  label: 'Delete session',
                  icon: Icons.delete_outline_rounded,
                  destructive: true,
                ),
            ],
          );
          if (!mounted) return;
          switch (action) {
            case 'rename':
              await _rename();
            case 'fork':
              await _fork();
            case 'priority':
              await _choosePriority();
            case 'model':
              await _chooseModel();
            case 'mode':
              await _chooseMode();
            case 'delete':
              await _delete();
          }
        },
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    if (!_bound) {
      return const SizedBox.shrink();
    }
    return AnimatedBuilder(
      animation: Listenable.merge([_controller, _app.settings, _app]),
      builder: (context, _) {
        final summary =
            _controller.summary ?? _app.summaryFor(widget.sessionId);
        final title = summary?.displayTitle ?? 'Session';
        final body = _buildBody(context, summary);
        // Where the conversation is and what it is doing, under its title.
        final context_ = summary == null
            ? null
            : _SessionContext(
                app: _app,
                controller: _controller,
                summary: summary,
              );
        if (widget.embedded) {
          return Material(
            type: MaterialType.transparency,
            child: Column(
              children: [
                _EmbeddedHeader(
                  title: title,
                  subtitle: context_,
                  actions: _actions(context),
                  onClose: _app.closeSession,
                ),
                Expanded(child: body),
              ],
            ),
          );
        }
        return HarnessPage(
          title: title,
          subtitle: context_,
          actions: _actions(context),
          body: body,
        );
      },
    );
  }

  Widget _buildBody(BuildContext context, SessionSummary? summary) {
    final theme = Theme.of(context);
    final controller = _controller;
    if (_controller.deleted) {
      return Column(
        children: [
          Expanded(
            child: HarnessEmptyState(
              icon: Icons.delete_outline_rounded,
              title: 'Session deleted',
              message: 'This conversation is gone from the harness.',
              action: HarnessPrimaryButton(
                label: 'Back to sessions',
                onPressed: () {
                  if (widget.embedded) {
                    _app.closeSession();
                  } else {
                    Navigator.of(context).maybePop();
                  }
                },
              ),
            ),
          ),
        ],
      );
    }
    final plan = controller.transcript.plan;
    return Column(
      children: [
        // A conversation opened as a page of its own covers the home
        // screens, and with them their banner.
        if (!widget.embedded) ConnectionBanner(app: _app),
        if (controller.error != null)
          HarnessErrorBanner(
            message: controller.error!,
            onDismiss: controller.clearError,
            actionLabel: 'Retry',
            onAction: () => controller.open(force: true),
          ),
        Expanded(
          child: controller.loading && controller.transcript.items.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      HarnessActivity(radius: 11),
                      const SizedBox(height: 14),
                      Text(
                        'Loading the conversation…',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                )
              : TranscriptView(
                  items: controller.transcript.items,
                  showThinking: _app.settings.showThinking,
                  streaming: controller.promptInFlight,
                  scrollTick: _scrollTick,
                ),
        ),
        if (plan.isNotEmpty && controller.currentInteraction == null)
          _PlanStrip(plan: plan),
        if (controller.promptInFlight ||
            controller.activity != null ||
            controller.currentInteraction != null)
          _ActivityBar(
            activity: controller.activity,
            waiting: controller.currentInteraction != null,
            running: controller.promptInFlight,
          ),
        if (controller.currentInteraction != null)
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight:
                  MediaQuery.sizeOf(context).height *
                  (controller.currentInteraction!.isQuestion ? 0.64 : 0.46),
            ),
            child: InteractionCard(controller: controller),
          ),
        MessageComposer(
          running: controller.promptInFlight,
          cancelling: controller.cancelling,
          canAttach: _app.capability?.promptImages == true,
          awaitingAnswer: controller.currentInteraction != null,
          // Typing goes on while the connection is out; sending waits for it.
          offline: !controller.canSend,
          enabled: controller.currentInteraction == null && controller.canSend,
          onStop: controller.cancel,
          // How the next message is handled: the model, the permission mode,
          // how full the context is and what the conversation has cost.
          footer: _SessionFooter(
            app: _app,
            summary: summary,
            onModel: _chooseModel,
            onMode: _chooseMode,
          ),
          // What is typed outlives this screen: see DraftStore.
          drafts: _app.drafts,
          draftKey: DraftStore.composerKey(widget.sessionId),
          onSend: (text, attachments) {
            // No connection to take it: the composer keeps the message.
            if (!controller.canSend) return false;
            setState(() => _scrollTick++);
            unawaited(controller.send(text, attachments: attachments));
            return true;
          },
        ),
      ],
    );
  }
}

/// The header of a conversation that is a pane of a wide screen: the title
/// over where it is and what it is doing, and the actions.
class _EmbeddedHeader extends StatelessWidget {
  const _EmbeddedHeader({
    required this.title,
    required this.subtitle,
    required this.actions,
    required this.onClose,
  });

  final String title;
  final Widget? subtitle;
  final List<Widget> actions;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(
        HarnessSpace.gutter,
        HarnessSpace.md,
        HarnessSpace.sm,
        HarnessSpace.md,
      ),
      decoration: BoxDecoration(
        color: HarnessStyle.isCupertino(context)
            ? CupertinoTheme.of(context).barBackgroundColor
            : theme.colorScheme.surface,
        border: Border(
          bottom: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: HarnessText.pageTitle(context),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  DefaultTextStyle(
                    style: HarnessText.subtitle(context),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    child: subtitle!,
                  ),
                ],
              ],
            ),
          ),
          ...actions,
          HarnessIconButton(
            icon: Icons.close_rounded,
            label: 'Close conversation',
            size: 19,
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}

/// The line under the title of a conversation: its state (a dot and a
/// word), the project it works on, and the task it belongs to, if any.
class _SessionContext extends StatelessWidget {
  const _SessionContext({
    required this.app,
    required this.controller,
    required this.summary,
  });

  final AppController app;
  final SessionController controller;
  final SessionSummary summary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final waiting = controller.currentInteraction != null;
    final status = waiting ? 'blocked' : summary.status;
    final color = HarnessColors.status(status, theme.brightness);
    final task = _taskForSession(app, summary.id);
    final project = app.projectOfSession(summary) ?? summary.project;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        HarnessDot(color: color, size: 6),
        const SizedBox(width: 6),
        Flexible(
          child: HarnessMetaLine(
            dropWhatDoesNotFit: true,
            parts: [
              HarnessMetaPart(
                waiting ? 'Needs you' : statusLabel(status),
                color: color,
                weight: FontWeight.w600,
              ),
              // The project, where there is more than one to tell apart.
              if (app.projects.length != 1) projectName(project ?? summary.cwd),
              if (task != null) 'Task: ${task.title}',
            ],
          ),
        ),
      ],
    );
  }

  HarnessTask? _taskForSession(AppController app, String? id) {
    if (id == null) return null;
    for (final task in app.tasks?.tasks ?? const <HarnessTask>[]) {
      if (task.sessionId == id) return task;
    }
    return null;
  }
}

/// The row under the message field.  On the left what decides how the next
/// message is handled, and can be changed (the model, the permission mode);
/// on the right how full the context is and what the conversation has cost.
class _SessionFooter extends StatelessWidget {
  const _SessionFooter({
    required this.app,
    required this.summary,
    required this.onModel,
    required this.onMode,
  });

  final AppController app;
  final SessionSummary? summary;
  final VoidCallback onModel;
  final VoidCallback onMode;

  @override
  Widget build(BuildContext context) {
    final s = summary;
    final usage = s?.usage;
    final window = s?.contextWindow;
    final used = usage?.contextInUse ?? 0;
    final spend = app.spendOf(s);
    return LayoutBuilder(
      builder: (context, constraints) {
        // On a narrow screen the figures give way to the pickers: the rule
        // goes, then the cost.  The context's figures stay.
        final narrow = constraints.maxWidth < 340;
        final ruled = constraints.maxWidth >= 400;
        return Row(
          children: [
            // The pickers take what the figures at the other end leave, the
            // model first: its name gives way after the mode's.
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    flex: 4,
                    child: HarnessPicker(
                      icon: Icons.memory_rounded,
                      label: modelName(s?.model),
                      onTap: onModel,
                    ),
                  ),
                  Flexible(
                    flex: 2,
                    child: HarnessPicker(
                      icon: Icons.shield_outlined,
                      label: permissionLabel(s?.permissionMode),
                      onTap: app.capability?.setMode == true ? onMode : null,
                    ),
                  ),
                ],
              ),
            ),
            // The figures are never more than half the row: where they do
            // not fit in that, they shrink rather than crowd the pickers.
            if ((window != null && window > 0) || (spend.worthShowing && !narrow))
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: constraints.maxWidth * (narrow ? 0.4 : 0.5),
                ),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (window != null && window > 0)
                        _ContextMeter(used: used, window: window, rule: ruled),
                      // What it cost, or the plan that pays for it with the
                      // plan's quota.
                      if (spend.worthShowing && !narrow) ...[
                        const SizedBox(width: HarnessSpace.md),
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: SpendChip(
                            key: const Key('session-spend'),
                            status: spend,
                            onTap: () => showPlanSheet(
                              context,
                              status: spend,
                              providerLabel: app.providerLabelOf(spend),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// How much of the context window is used: the figures, and a rule that
/// turns amber as it fills.
class _ContextMeter extends StatelessWidget {
  const _ContextMeter({
    required this.used,
    required this.window,
    this.rule = true,
  });

  final int used;
  final int window;

  /// Whether the rule is drawn, or only the figures.
  final bool rule;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fraction = (used / window).clamp(0.0, 1.0);
    return Semantics(
      label: 'Context ${formatTokens(used)} of ${formatTokens(window)}',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (rule) ...[
            SizedBox(
              width: 30,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: fraction,
                  minHeight: 3,
                  backgroundColor: theme.colorScheme.surfaceContainerHigh,
                  color: fraction > 0.8
                      ? HarnessColors.amber
                      : theme.colorScheme.primary,
                ),
              ),
            ),
            const SizedBox(width: 6),
          ],
          Text(
            '${formatTokens(used)} / ${formatTokens(window)}',
            style: HarnessText.meta(context),
          ),
        ],
      ),
    );
  }
}

class _PlanStrip extends StatelessWidget {
  const _PlanStrip({required this.plan});
  final List<PlanEntry> plan;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final done = plan.where((entry) => entry.isDone).length;
    final active = plan.where((entry) => entry.isActive).firstOrNull;
    final progress = plan.isEmpty ? 0.0 : done / plan.length;
    // One line: the plan and how far it is, then the step being worked on.
    // How far is also a hairline along the top edge.
    return Semantics(
      button: true,
      label: 'Plan, $done of ${plan.length} done',
      child: HarnessTap(
        onTap: () => _showPlan(context),
        child: Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.primary.withValues(alpha: 0.04),
            border: Border(
              top: BorderSide(
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
              ),
            ),
          ),
          child: Stack(
            children: [
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 2,
                  backgroundColor: Colors.transparent,
                  color: theme.colorScheme.primary,
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  HarnessSpace.gutter,
                  10,
                  HarnessSpace.md,
                  10,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.map_outlined,
                      size: 16,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Plan',
                      style: HarnessText.meta(context).copyWith(
                        fontWeight: FontWeight.w700,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '$done / ${plan.length}',
                      style: HarnessText.meta(context),
                    ),
                    if (active != null) ...[
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          active.content,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: HarnessText.subtitle(context),
                        ),
                      ),
                    ] else
                      const Spacer(),
                    const SizedBox(width: 6),
                    Icon(
                      Icons.expand_less_rounded,
                      size: 18,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showPlan(BuildContext context) {
    showHarnessSheet<void>(
      context: context,
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Plan', style: HarnessText.sheetTitle(sheetContext)),
            const SizedBox(height: 14),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.65,
              ),
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    for (final entry in plan)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              entry.isDone
                                  ? Icons.check_circle_rounded
                                  : entry.isActive
                                  ? Icons.radio_button_checked_rounded
                                  : Icons.radio_button_unchecked_rounded,
                              size: 19,
                              color: entry.isDone
                                  ? HarnessColors.moss
                                  : entry.isActive
                                  ? Theme.of(sheetContext).colorScheme.primary
                                  : Theme.of(sheetContext)
                                        .colorScheme
                                        .onSurfaceVariant,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                entry.content,
                                style: TextStyle(
                                  fontSize: 14,
                                  height: 1.4,
                                  decoration: entry.isDone
                                      ? TextDecoration.lineThrough
                                      : null,
                                  color: entry.isDone
                                      ? Theme.of(sheetContext)
                                            .colorScheme
                                            .onSurfaceVariant
                                      : null,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActivityBar extends StatefulWidget {
  const _ActivityBar({
    required this.activity,
    required this.waiting,
    required this.running,
  });

  final TurnActivity? activity;
  final bool waiting;
  final bool running;

  @override
  State<_ActivityBar> createState() => _ActivityBarState();
}

class _ActivityBarState extends State<_ActivityBar> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final activity = widget.activity;
    final label =
        widget.waiting && (activity == null || activity.phase == 'checking')
        ? 'Waiting for your answer'
        : activity?.label ?? (widget.running ? 'Working' : '');
    if (label.isEmpty) return const SizedBox.shrink();
    final since = activity?.since;
    final elapsed = since == null ? null : DateTime.now().difference(since);
    final color = widget.waiting
        ? HarnessColors.amber
        : theme.colorScheme.primary;
    return Container(
      padding: const EdgeInsets.fromLTRB(
        HarnessSpace.gutter,
        8,
        HarnessSpace.gutter,
        8,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.04),
        border: Border(
          top: BorderSide(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 16,
            child: Center(
              child: widget.waiting
                  ? Icon(Icons.front_hand_rounded, size: 15, color: color)
                  : HarnessActivity(radius: 7, color: color),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: HarnessText.meta(context)
                  .copyWith(color: color, fontWeight: FontWeight.w600),
            ),
          ),
          if (elapsed != null)
            Text(_formatElapsed(elapsed), style: HarnessText.meta(context)),
        ],
      ),
    );
  }

  String _formatElapsed(Duration duration) {
    if (duration.inSeconds < 60) return '${duration.inSeconds}s';
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds % 60;
    return '${minutes}m ${seconds.toString().padLeft(2, '0')}s';
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
