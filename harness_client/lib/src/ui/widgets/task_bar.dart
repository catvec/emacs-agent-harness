import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/task.dart';
import '../../models/task_actions.dart';
import '../../models/task_chat.dart';
import '../../models/tool_display.dart';
import '../../state/app_controller.dart';
import '../adaptive/adaptive_widgets.dart';
import '../adaptive/layout_widgets.dart';
import '../format.dart';
import '../screens/hand_in_report_screen.dart';
import '../screens/review_screen.dart';
import '../theme/harness_theme.dart';
import 'task_action_runner.dart';

/// Where a task is handled: the bar above the message box of the
/// conversation of a task's session.
///
/// Tapping a task on the board opens its conversation, and this is what the
/// conversation says about the task and offers to do with it: where it
/// stands (its column, how urgent it is, what holds it back, what went
/// wrong), and the actions of that state, the ones the board of Emacs offers
/// on a card ([TaskActions]), done as the board's menu did them
/// ([TaskActionRunner]).  A task in review is verified here, or sent back by
/// typing what should change in the box below (the harness takes a message
/// to its session for that feedback); a task in the backlog is started or
/// queued; one that stopped is tried again; the priority, the pause and the
/// rest are in the menu.  Nothing needs the board.  See [TaskBarActions] for
/// what is a button and what is in the menu.  A task that was handed in with
/// a report has a line for it, with *View report*, which opens the page the
/// `hand_in` call's full view opens ([HandInReportScreen]).
///
/// The bar is one line until it is opened, so that the conversation above it
/// keeps the height of the page: the state, the facts that matter and the one
/// action of the state, with the rest behind the chevron.  The line is the
/// bar's own control ([bar-toggle]): a tap on it opens the bar to what it has
/// to say -- the line about the state, the report, the way into the review,
/// what went wrong and every action -- and a tap on the chevron closes it
/// again.  The open state is the person's, not the screen's: it outlives a
/// rebuild of the bar and another session's.
///
/// It shows nothing for a session that is no task's, and while the harness
/// is being asked which task it is.
class SessionTaskBar extends StatefulWidget {
  const SessionTaskBar({
    super.key,
    required this.app,
    required this.sessionId,
    required this.onSendBack,
    this.compact = false,
  });

  final AppController app;
  final String sessionId;

  /// Puts the cursor in the message box: *Send back* is feedback, typed there.
  final VoidCallback onSendBack;

  /// One line, for the room that is left while the keyboard is up.
  final bool compact;

  @override
  State<SessionTaskBar> createState() => _SessionTaskBarState();
}

class _SessionTaskBarState extends State<SessionTaskBar> {
  /// Why the last action failed, in the harness's words.
  String? _error;

  /// The action being done, for its button to say so.
  TaskAction? _running;

  /// The (task board, session) the harness was asked about.
  Object? _asked;

  /// Whether the bar is open to what it has to say.  It starts as the
  /// keyboard leaves it: shut, which is the line the conversation is written
  /// under, and it stays shut across a rebuild.
  bool _open = false;

  @override
  void didUpdateWidget(SessionTaskBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessionId != widget.sessionId) {
      _error = null;
      _open = false;
    }
  }

  /// A session opened from the list of sessions may be of a task the board
  /// does not list (it is narrowed to another project): ask once.
  void _lookUp() {
    final controller = widget.app.tasks;
    if (controller == null) return;
    final key = (identityHashCode(controller), widget.sessionId);
    if (_asked == key) return;
    _asked = key;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(controller.lookUp(widget.sessionId));
    });
  }

  Future<void> _perform(TaskAction action) async {
    final controller = widget.app.tasks;
    final task = controller?.forSession(widget.sessionId);
    if (controller == null || task == null) return;
    // Feedback is written in the message box under the bar.
    if (action == TaskAction.sendBack) {
      widget.onSendBack();
      return;
    }
    setState(() {
      _error = null;
      _running = action;
    });
    // What the action does is the board's: it asks first where it stops work
    // or throws the task away, then has the controller do it, which says why
    // when the harness refuses (the harness checks the task as it is now).
    controller.error = null;
    await TaskActionRunner(
      controller: controller,
      onOpenSession: (_) {},
    ).run(context, action, task);
    if (!mounted) return;
    setState(() {
      _running = null;
      _error = controller.error;
    });
  }

  Future<void> _more(HarnessTask task, TaskBarActions layout) async {
    final action = await showHarnessMenu<TaskAction>(
      context: context,
      title: task.title,
      items: [
        for (final action in layout.menu)
          HarnessMenuItem(
            value: action,
            label: taskActionMenuLabel(action, task),
            icon: taskActionIcon(action),
            destructive: action.destructive,
          ),
      ],
    );
    if (action != null) await _perform(action);
  }

  void _toggle() => setState(() => _open = !_open);

  @override
  Widget build(BuildContext context) {
    final controller = widget.app.tasks;
    if (controller == null) return const SizedBox.shrink();
    _lookUp();
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final task = controller.forSession(widget.sessionId);
        if (task == null) return const SizedBox.shrink();
        final line = TaskStateLine.of(task);
        final layout = TaskBarActions.of(
          task,
          taskActionsOf(widget.app, controller, task),
        );
        final theme = Theme.of(context);
        final dark = theme.brightness == Brightness.dark;
        final color = HarnessColors.column(task.columnName, theme.brightness);
        final busy = controller.busy;
        // The keyboard leaves a strip of the page: the bar says where the
        // task stands, and every action waits for the keyboard to go.
        final compact = widget.compact;
        final open = _open && !compact;
        return Container(
          key: const Key('task-bar'),
          decoration: BoxDecoration(
            color: color.withValues(alpha: dark ? 0.14 : 0.07),
            border: Border(
              top: BorderSide(color: color.withValues(alpha: 0.4)),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Line(
                task: task,
                line: line,
                layout: layout,
                color: color,
                busy: busy,
                open: open,
                compact: compact,
                onToggle: _toggle,
                onPerform: _perform,
                onMore: () => _more(task, layout),
                onReview:
                    (widget.app.capabilities?.review ?? false) && _reviews(task)
                    ? () => ReviewScreen.show(
                        context,
                        app: widget.app,
                        task: task,
                      )
                    : null,
              ),
              // What the line does not say, for a person who asked to see it.
              AnimatedSize(
                duration: HarnessMotion.of(
                  context,
                  const Duration(milliseconds: 160),
                ),
                curve: Curves.easeOutCubic,
                alignment: Alignment.topCenter,
                child: open
                    ? _Details(
                        task: task,
                        line: line,
                        layout: layout,
                        color: color,
                        busy: busy,
                        running: _running,
                        error: _error,
                        app: widget.app,
                        onPerform: _perform,
                        onReview:
                            (widget.app.capabilities?.review ?? false) &&
                                _reviews(task)
                            ? () => ReviewScreen.show(
                                context,
                                app: widget.app,
                                task: task,
                              )
                            : null,
                        onDismissError: () => setState(() => _error = null),
                      )
                    : const SizedBox(width: double.infinity),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Whether there is work of this task's to review: a branch of its own,
  /// or a review that was already made of it.
  bool _reviews(HarnessTask task) =>
      !task.isBacklog &&
      (task.branch != null ||
          task.columnName == 'review' ||
          task.report != null);
}

/// The bar's one line: where the task stands, the facts that matter and the
/// one action of the state, and the chevron that opens the rest.
///
/// The line is a control of its own: a tap anywhere on it that is not a
/// button opens or closes the bar.
class _Line extends StatelessWidget {
  const _Line({
    required this.task,
    required this.line,
    required this.layout,
    required this.color,
    required this.busy,
    required this.open,
    required this.compact,
    required this.onToggle,
    required this.onPerform,
    required this.onMore,
    required this.onReview,
  });

  final HarnessTask task;
  final TaskStateLine line;
  final TaskBarActions layout;
  final Color color;
  final bool busy;
  final bool open;
  final bool compact;
  final VoidCallback onToggle;
  final ValueChanged<TaskAction> onPerform;
  final VoidCallback onMore;
  final VoidCallback? onReview;

  @override
  Widget build(BuildContext context) {
    final primary = layout.primary;
    return Semantics(
      expanded: open,
      child: GestureDetector(
        key: const Key('task-bar-toggle'),
        behavior: HitTestBehavior.opaque,
        onTap: compact ? null : onToggle,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            HarnessSpace.gutter,
            HarnessSpace.xs,
            HarnessSpace.xs,
            HarnessSpace.xs,
          ),
          child: Row(
            children: [
              HarnessDot(color: color, size: 7),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  line.heading,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: HarnessText.subtitle(context)
                      .copyWith(color: color, fontWeight: FontWeight.w700),
                ),
              ),
              // The facts, on the line and never in the details under it: a
              // fact said twice is a fact the height was paid for twice.
              // Shut, the line keeps what fits, the first facts first; open,
              // it has the room the one action left, and wraps the rest.
              if (taskFacts(task).isNotEmpty) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: HarnessMetaLine(
                    dropWhatDoesNotFit: !open,
                    maxLines: open ? 2 : 1,
                    parts: taskFacts(task),
                    style: HarnessText.caption(context),
                  ),
                ),
              ] else
                const Spacer(),
              // The one action of the state, where the line has room for it:
              // the open bar says it in words under the line.
              if (!open && primary != null && !compact) ...[
                const SizedBox(width: 6),
                _QuickAction(
                  action: primary,
                  task: task,
                  color: color,
                  busy: busy,
                  onPressed: () => onPerform(primary),
                ),
              ],
              // With the keyboard up the bar is the line alone: the way
              // into the review is its icon there.  Otherwise it is in the
              // open bar, in words.
              if (compact && onReview != null) ...[
                const SizedBox(width: 2),
                HarnessIconButton(
                  key: const Key('task-review-compact'),
                  icon: Icons.rate_review_outlined,
                  label: 'Review',
                  size: 19,
                  dense: true,
                  onPressed: onReview,
                ),
              ],
              if (layout.menu.isNotEmpty)
                HarnessIconButton(
                  icon: Icons.more_horiz_rounded,
                  label: 'Task actions',
                  size: 19,
                  dense: true,
                  onPressed: busy ? null : onMore,
                ),
              if (!compact)
                HarnessIconButton(
                  key: const Key('task-bar-chevron'),
                  icon: open
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  label: open ? 'Hide details' : 'Show details',
                  size: 19,
                  dense: true,
                  onPressed: onToggle,
                ),
            ],
          ),
        ),
      ),
    );
  }

}

/// The facts about [task] that its column's heading does not say: what holds
/// it back, how urgent it is, where its work is, and what is out of the
/// ordinary about it.  The bar's line says what fits of them, and has more
/// room for them once its one action has gone to the open bar.
List<Object?> taskFacts(HarnessTask task) => [
  // What the column does not say: a pause, a wait, a task put away.
  ...taskStateParts(task),
  if (task.priority == 'high')
    const HarnessMetaPart(
      'High priority',
      color: HarnessColors.oxide,
      weight: FontWeight.w700,
    )
  else if (task.priority == 'low')
    'Low priority',
  task.branch,
  if (task.verified)
    const HarnessMetaPart(
      'Verified',
      color: HarnessColors.moss,
      weight: FontWeight.w700,
    ),
  if (task.attachments.isNotEmpty)
    '${task.attachments.length} '
        '${task.attachments.length == 1 ? 'attachment' : 'attachments'}',
  if (task.noMerge) 'No merge',
  if (task.cannotContinue)
    const HarnessMetaPart(
      'Blocked',
      color: HarnessColors.amber,
      weight: FontWeight.w700,
    ),
];

/// The one action of the state, as the line shows it: the same label its
/// button has, in the colour of the state, without the height of a button.
class _QuickAction extends StatelessWidget {
  const _QuickAction({
    required this.action,
    required this.task,
    required this.color,
    required this.busy,
    required this.onPressed,
  });

  final TaskAction action;
  final HarnessTask task;
  final Color color;
  final bool busy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: action.labelFor(task),
      child: Semantics(
        button: true,
        label: action.labelFor(task),
        child: HarnessTap(
          onTap: busy ? null : onPressed,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (busy)
                  Padding(
                    padding: const EdgeInsets.only(right: 5),
                    child: SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.6,
                        color: color,
                      ),
                    ),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.only(right: 5),
                    child: Icon(taskActionIcon(action), size: 15, color: color),
                  ),
                Text(
                  action.shortLabel,
                  style: HarnessText.meta(context)
                      .copyWith(color: color, fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The open bar: the line about the state, the report, the way into the
/// review, what went wrong, and every action the state offers.
class _Details extends StatelessWidget {
  const _Details({
    required this.task,
    required this.line,
    required this.layout,
    required this.color,
    required this.busy,
    required this.running,
    required this.error,
    required this.app,
    required this.onPerform,
    required this.onReview,
    required this.onDismissError,
  });

  final HarnessTask task;
  final TaskStateLine line;
  final TaskBarActions layout;
  final Color color;
  final bool busy;
  final TaskAction? running;
  final String? error;
  final AppController app;
  final ValueChanged<TaskAction> onPerform;
  final VoidCallback? onReview;
  final VoidCallback onDismissError;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        HarnessSpace.gutter,
        0,
        HarnessSpace.md,
        HarnessSpace.xs,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (line.message != null || (task.error ?? '').isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: _Words(task: task, line: line),
            ),
          if (task.report case final HandInReport report)
            _ReportRow(report: report, sessionId: task.sessionId),
          if (onReview != null) _ReviewRow(task: task, onReview: onReview!),
          if (error != null)
            HarnessErrorBanner(
              message: error!,
              margin: const EdgeInsets.only(top: HarnessSpace.sm),
              onDismiss: onDismissError,
            ),
          if (layout.primary != null || layout.buttons.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: HarnessSpace.sm),
              child: Row(
                children: [
                  if (layout.primary case final primary?)
                    Expanded(
                      flex: 3,
                      child: HarnessPrimaryButton(
                        label: primary.labelFor(task),
                        icon: taskActionIcon(primary),
                        expand: true,
                        busy: running == primary,
                        onPressed: busy ? null : () => onPerform(primary),
                      ),
                    ),
                  for (final action in layout.buttons) ...[
                    if (layout.primary != null)
                      const SizedBox(width: HarnessSpace.sm),
                    Expanded(
                      flex: 2,
                      child: HarnessSecondaryButton(
                        label: action.labelFor(task),
                        icon: taskActionIcon(action),
                        expand: true,
                        onPressed: busy ? null : () => onPerform(action),
                      ),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// What there is to say of the report the task's work was handed in with, and
/// the way to read it: when it was handed in, how many pieces of evidence came
/// with it, and *View report*.
///
/// The report is not drawn here.  It is the card of the `hand_in` call in the
/// conversation above, which opens to the same page; this is the way to that
/// page from the place the task is handled, and the only one for the report of
/// a round of work that handed none in, which has no call (the page shows the
/// last message of the session, as what it is).
class _ReportRow extends StatelessWidget {
  const _ReportRow({required this.report, this.sessionId});

  final HandInReport report;

  /// The task's session, whose harness gives the pictures of the evidence
  /// (the page draws them).
  final String? sessionId;

  @override
  Widget build(BuildContext context) {
    final when = report.at;
    final pieces = report.evidence.length;
    return Row(
      children: [
        Expanded(
          child: HarnessMetaLine(
            maxLines: 1,
            style: HarnessText.caption(context),
            parts: [
              if (report.missing)
                const HarnessMetaPart(
                  'Report missing',
                  color: HarnessColors.amber,
                  weight: FontWeight.w700,
                )
              else
                when == null
                    ? 'Handed in'
                    : 'Handed in ${HandInReportScreen.whenLabel(when)}',
              if (pieces > 0)
                pieces == 1
                    ? '1 piece of evidence'
                    : '$pieces pieces of evidence',
            ],
          ),
        ),
        HarnessTextButton(
          label: 'View report',
          icon: Icons.assignment_turned_in_outlined,
          dense: true,
          onPressed: () =>
              HandInReportScreen.show(context, report, sessionId: sessionId),
        ),
      ],
    );
  }
}

/// The way into the change review of the task: its files, their diffs, the
/// threads on them and the feedback written on them.
///
/// The review is the harness's, not this page's: a comment made there is an
/// operation of the task's review, read by Emacs and by the agent as any
/// other, and the page says nothing of its own about the task.
class _ReviewRow extends StatelessWidget {
  const _ReviewRow({required this.task, required this.onReview});

  final HarnessTask task;
  final VoidCallback onReview;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: HarnessMetaLine(
            maxLines: 1,
            style: HarnessText.caption(context),
            parts: [
              'Changes, threads and feedback',
              if (task.branch != null) task.branch!,
            ],
          ),
        ),
        HarnessTextButton(
          key: const Key('task-review'),
          label: 'Review',
          icon: Icons.rate_review_outlined,
          dense: true,
          onPressed: onReview,
        ),
      ],
    );
  }
}

/// What is said of the state, and what the task itself says went wrong.
class _Words extends StatelessWidget {
  const _Words({required this.task, required this.line});

  final HarnessTask task;
  final TaskStateLine line;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final error = task.error;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (line.message != null)
          Text(line.message!, style: HarnessText.caption(context)),
        if (error != null && error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              truncate(error, 200),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: HarnessText.caption(context)
                  .copyWith(color: theme.colorScheme.error),
            ),
          ),
      ],
    );
  }
}
