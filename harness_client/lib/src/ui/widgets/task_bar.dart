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

  @override
  void didUpdateWidget(SessionTaskBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessionId != widget.sessionId) _error = null;
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
        return Container(
          key: const Key('task-bar'),
          decoration: BoxDecoration(
            color: color.withValues(alpha: dark ? 0.14 : 0.07),
            border: Border(
              top: BorderSide(color: color.withValues(alpha: 0.4)),
            ),
          ),
          padding: const EdgeInsets.fromLTRB(
            HarnessSpace.gutter,
            HarnessSpace.sm,
            HarnessSpace.xs,
            HarnessSpace.sm,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  HarnessStatusLabel(
                    label: line.heading,
                    color: color,
                    style: HarnessText.subtitle(context),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: HarnessMetaLine(
                      parts: _facts(task),
                      style: HarnessText.caption(context),
                    ),
                  ),
                  if (layout.menu.isNotEmpty)
                    HarnessIconButton(
                      icon: Icons.more_horiz_rounded,
                      label: 'Task actions',
                      size: 20,
                      onPressed: busy ? null : () => _more(task, layout),
                    )
                  else
                    const SizedBox(height: 40, width: HarnessSpace.sm),
                ],
              ),
              if (!widget.compact) ...[
                Padding(
                  padding: const EdgeInsets.only(right: HarnessSpace.md),
                  child: _Words(task: task, line: line),
                ),
                if (task.report case final HandInReport report)
                  _ReportRow(report: report, sessionId: task.sessionId),
                if (_error != null)
                  HarnessErrorBanner(
                    message: _error!,
                    margin: const EdgeInsets.only(
                      top: HarnessSpace.sm,
                      right: HarnessSpace.md,
                    ),
                    onDismiss: () => setState(() => _error = null),
                  ),
                if (layout.primary != null || layout.buttons.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(
                      top: HarnessSpace.md,
                      bottom: HarnessSpace.xs,
                      right: HarnessSpace.md,
                    ),
                    child: Row(
                      children: [
                        if (layout.primary case final primary?)
                          Expanded(
                            flex: 3,
                            child: HarnessPrimaryButton(
                              label: primary.labelFor(task),
                              icon: taskActionIcon(primary),
                              expand: true,
                              busy: _running == primary,
                              onPressed: busy ? null : () => _perform(primary),
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
                              onPressed: busy ? null : () => _perform(action),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
              ],
            ],
          ),
        );
      },
    );
  }

  /// The facts about the task that the heading does not say.
  List<Object?> _facts(HarnessTask task) => [
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
        'Cannot continue',
        color: HarnessColors.amber,
        weight: FontWeight.w700,
      ),
  ];
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
    return Padding(
      padding: const EdgeInsets.only(right: HarnessSpace.xs),
      child: Row(
        children: [
          Expanded(
            child: HarnessMetaLine(
              maxLines: 2,
              style: HarnessText.caption(context),
              parts: [
                if (report.missing)
                  const HarnessMetaPart(
                    'No report was handed in',
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
      ),
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
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(line.message!, style: HarnessText.subtitle(context)),
          ),
        if (error != null && error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              truncate(error, 200),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: HarnessText.caption(
                context,
              ).copyWith(color: theme.colorScheme.error),
            ),
          ),
      ],
    );
  }
}
