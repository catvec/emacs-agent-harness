import 'package:flutter/material.dart';

import '../../models/task.dart';
import '../../models/task_actions.dart';
import '../../state/app_controller.dart';
import '../../state/task_controller.dart';
import '../adaptive/adaptive_widgets.dart';
import '../adaptive/layout_widgets.dart';
import '../theme/harness_theme.dart';

/// What can be done with [task] now: the actions that apply to it where it
/// stands, which this harness has.  Its session says whether it waits for an
/// answer (see [TaskActions.of]).
TaskActions taskActionsOf(
  AppController app,
  TaskController controller,
  HarnessTask task,
) {
  final session = task.sessionId == null
      ? null
      : app.summaryFor(task.sessionId!);
  return TaskActions.of(
    task,
    pendingRequest: session?.pending.isNotEmpty ?? false,
    supports: controller.api.can,
  );
}

/// What a line about [task] says that its column does not, as parts of
/// a [HarnessMetaLine]: that the person paused it, that it waits for quota or
/// money, that it was put away (archived).
List<Object> taskStateParts(HarnessTask task) {
  final hold = task.hold;
  return [
    if (hold != null)
      HarnessMetaPart(
        hold.kind == 'paused' ? 'Paused' : 'Waiting for ${hold.kind}',
        color: HarnessColors.amber,
        weight: FontWeight.w700,
      ),
    if (task.archived) 'Archived',
  ];
}

/// The icon of [action], on a button or in a menu.
IconData taskActionIcon(TaskAction action) => switch (action) {
  TaskAction.openSession => Icons.open_in_new_rounded,
  TaskAction.answer => Icons.front_hand_outlined,
  TaskAction.start => Icons.play_arrow_rounded,
  TaskAction.queue => Icons.playlist_add_rounded,
  TaskAction.retry => Icons.replay_rounded,
  TaskAction.retryMerge => Icons.call_merge_rounded,
  TaskAction.pause => Icons.pause_rounded,
  TaskAction.resume => Icons.play_circle_outline_rounded,
  TaskAction.returnToPending => Icons.undo_rounded,
  TaskAction.message => Icons.chat_bubble_outline_rounded,
  TaskAction.verify => Icons.check_rounded,
  TaskAction.sendBack => Icons.reply_rounded,
  TaskAction.stop => Icons.stop_rounded,
  TaskAction.drop => Icons.delete_outline_rounded,
  TaskAction.complete => Icons.done_all_rounded,
  TaskAction.archive => Icons.archive_outlined,
  TaskAction.unarchive => Icons.unarchive_outlined,
  TaskAction.setPriority => Icons.flag_outlined,
  TaskAction.delete => Icons.delete_forever_outlined,
};

/// What a menu says for [action] on [task].  Priority says where the task
/// stands now, and delete that it asks first.
String taskActionMenuLabel(TaskAction action, HarnessTask task) =>
    switch (action) {
      TaskAction.setPriority => 'Priority · ${task.priorityLabel}',
      TaskAction.delete => 'Delete task…',
      _ => action.labelFor(task),
    };

/// Does what a person chose to do with a task: asks first where the action
/// stops work or throws it away, or needs words, then has the board's
/// [TaskController] do it.  The card's menu and the task's sheet both go
/// through here, so a task is handled the same way wherever it is touched.
///
/// A failure is the controller's to say ([TaskController.error], which the
/// board and the sheet show): the harness checks every action against the
/// task as it is now, and its words are the explanation.
class TaskActionRunner {
  const TaskActionRunner({
    required this.controller,
    required this.onOpenSession,
  });

  final TaskController controller;

  /// Open the conversation of a task's session.
  final ValueChanged<String> onOpenSession;

  /// Do [action] to [task].  [context] is where a question is asked.
  Future<void> run(
    BuildContext context,
    TaskAction action,
    HarnessTask task,
  ) async {
    final id = task.id;
    switch (action) {
      case TaskAction.openSession:
      case TaskAction.answer:
        final session = task.sessionId;
        if (session != null && session.isNotEmpty) onOpenSession(session);
      case TaskAction.start:
        await controller.start(id);
      case TaskAction.queue:
        await controller.queue(id);
      case TaskAction.retry:
        await controller.retry(id);
      case TaskAction.retryMerge:
        await controller.retryMerge(id);
      case TaskAction.pause:
        await controller.pause(id);
      case TaskAction.resume:
        await controller.resume(id);
      case TaskAction.returnToPending:
        await controller.returnToPending(id);
      case TaskAction.verify:
        await controller.verify(id);
      case TaskAction.archive:
        await controller.archive(id);
      case TaskAction.unarchive:
        await controller.unarchive(id);
      case TaskAction.message:
        final text = await _askMessage(context, task);
        if (text != null) await controller.prompt(id, text);
      case TaskAction.sendBack:
        final feedback = await showHarnessTextPrompt(
          context: context,
          title: 'Send it back',
          message: 'What should change? It goes to the task’s own session.',
          hint: 'Feedback',
          multiline: true,
          confirmLabel: 'Send back',
        );
        if (feedback != null && feedback.trim().isNotEmpty) {
          await controller.reject(id, feedback.trim());
        }
      case TaskAction.stop:
        if (await _confirm(
          context,
          title: 'Stop this task?',
          message:
              'Its session stops what it is doing. The task stays on the '
              'board, where it can be retried or marked done.',
          confirm: 'Stop task',
          cancel: 'Keep going',
        )) {
          await controller.cancelTask(id);
        }
      case TaskAction.drop:
        if (await _confirm(
          context,
          title: 'Drop this task?',
          message:
              'It has not started. It comes off the board, and its session '
              'goes with it.',
          confirm: 'Drop task',
          cancel: 'Keep it',
        )) {
          await controller.cancelTask(id);
        }
      case TaskAction.complete:
        if (await _confirm(
          context,
          title: 'Mark this task complete?',
          message: 'That accepts the work without waiting for a merge.',
          confirm: 'Complete',
          cancel: 'Cancel',
          destructive: false,
        )) {
          await controller.complete(id);
        }
      case TaskAction.setPriority:
        final chosen = await _askPriority(context, task);
        if (chosen != null) await controller.setPriority(task, chosen);
      case TaskAction.delete:
        final result = await _askDelete(context, task);
        if (result != null) {
          await controller.delete(id, deleteSession: result);
        }
    }
  }

  /// The words of a message to [task]'s session, or null when none are
  /// written.  What the message does depends on where the task is, which the
  /// question says.
  Future<String?> _askMessage(BuildContext context, HarnessTask task) async {
    final (title, help) = switch (task.columnName) {
      'active' => (
        'Steer the task',
        'It goes to the task’s session, which reads it as it works.',
      ),
      'backlog' => (
        'Feedback on the write-up',
        'The task is written up again with it.',
      ),
      'done' => (
        'Follow up',
        'The task’s session takes it up again, and the task goes back to '
            'work.',
      ),
      'pending' => (
        'Message the task',
        'The task starts again with it, or keeps it for when it starts.',
      ),
      _ => ('Message the task', 'It goes to the task’s own session.'),
    };
    final text = await showHarnessTextPrompt(
      context: context,
      title: title,
      message: help,
      hint: 'Message',
      multiline: true,
      confirmLabel: 'Send',
    );
    final trimmed = text?.trim() ?? '';
    return trimmed.isEmpty ? null : trimmed;
  }

  /// The priority a person picks for [task]: one of the levels it does not
  /// have, or null.
  Future<String?> _askPriority(BuildContext context, HarnessTask task) {
    final current = task.priority ?? 'medium';
    const levels = [
      ('high', 'High', Icons.keyboard_double_arrow_up_rounded),
      ('medium', 'Medium', Icons.drag_handle_rounded),
      ('low', 'Low', Icons.keyboard_double_arrow_down_rounded),
    ];
    return showHarnessMenu<String>(
      context: context,
      title: 'Priority is ${task.priorityLabel.toLowerCase()}',
      items: [
        for (final (value, label, icon) in levels)
          if (value != current)
            HarnessMenuItem(value: value, label: '$label priority', icon: icon),
      ],
    );
  }

  /// Whether to also delete [task]'s session, once the person confirms that
  /// the task is to be deleted; null when they do not.
  Future<bool?> _askDelete(BuildContext context, HarnessTask task) async {
    // A task that never started takes its session along either way; one with
    // a session of its own to keep (a write-up, the work) asks.
    final asks = (task.sessionId ?? '').isNotEmpty && !task.isPending;
    var alsoSession = false;
    final confirmed = await showHarnessDialog<bool>(
      context: context,
      title: 'Delete this task?',
      content: StatefulBuilder(
        builder: (context, setState) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'The harness forgets the task. Its worktree and branch stay, in '
              'case they hold work nobody merged.',
              style: HarnessText.body(context),
            ),
            if (asks) ...[
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Also delete its session',
                      style: HarnessText.rowTitle(context),
                    ),
                  ),
                  HarnessSwitch(
                    value: alsoSession,
                    onChanged: (value) => setState(() => alsoSession = value),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
      confirmLabel: 'Delete',
      cancelLabel: 'Cancel',
      destructive: true,
    );
    return confirmed == true ? alsoSession : null;
  }

  Future<bool> _confirm(
    BuildContext context, {
    required String title,
    required String message,
    required String confirm,
    required String cancel,
    bool destructive = true,
  }) async =>
      await showHarnessDialog<bool>(
        context: context,
        title: title,
        message: message,
        confirmLabel: confirm,
        cancelLabel: cancel,
        destructive: destructive,
      ) ==
      true;
}
