/// What can be done with a task on the board, and when.
///
/// The harness decides whether an action may happen: every `task/*` method
/// checks the state of the task it is given and answers with an error the app
/// shows as it is.  What this file decides is which of the actions to *offer*
/// for a task, so that a person is shown what the harness will take and not a
/// row of buttons that mostly fail.  The sets are the ones the task board of
/// Emacs offers on a card (`harness-ui-tasks--actions`), column by column, and
/// the checks behind them are the harness's own (see `docs/modules/tasks.md`
/// for the states and columns), so a task has the same buttons in Emacs and on
/// the phone.
library;

import 'task.dart';

/// One thing a person can do with a task.
enum TaskAction {
  /// Look at the conversation of the task's session.
  openSession('Open session'),

  /// Answer what the task's session asked or wants allowed: the request is
  /// answered in the session.
  answer('Answer'),

  /// Start a task that waits, whatever the limit of tasks at once, the queue
  /// being suspended or not (`task/start`).
  start('Start now'),

  /// Put a backlog task in the pending queue, where it starts by itself as a
  /// slot frees (`task/queue`).
  queue('Queue it'),

  /// Have a task that stopped part way carry on (`task/retry`).
  retry('Retry'),

  /// Send the branch of a task whose merge failed through the merge queue
  /// again (`task/merge`).
  retryMerge('Retry merge'),

  /// Put a task back in the pending queue and hold it there until it is
  /// resumed (`task/pause`).
  pause('Pause'),

  /// End a task's pause (`task/resume`).
  resume('Resume'),

  /// Stop a task at work and put it back in the pending queue, where it
  /// carries on when it starts again (`task/return-to-pending`).
  returnToPending('Return to queue'),

  /// Write to the task's session: steer it, answer it, give feedback on its
  /// write-up, or reopen it (`task/prompt`).
  message('Message'),

  /// Accept the work of a task in review; its branch goes through the merge
  /// queue (`task/verify`).
  verify('Verify and merge'),

  /// Send a task in review back to its session with feedback
  /// (`task/reject`).
  sendBack('Send back'),

  /// Stop a task that works, or waits for the merge (`task/cancel`).
  stop('Stop'),

  /// Drop a task that never started (`task/cancel`): it is taken off the
  /// board, and its session with it.
  drop('Drop'),

  /// Mark a task done by hand, merged or not (`task/complete`).
  complete('Mark complete'),

  /// Hide a task in review or done (`task/archive`).
  archive('Archive'),

  /// Bring an archived task back (`task/archive` with `restore`).
  unarchive('Unarchive'),

  /// Change the priority of the task, which is its session's
  /// (`priority/set`): low, medium or high.
  setPriority('Priority'),

  /// Forget the task (`task/delete`).
  delete('Delete');

  const TaskAction(this.label);

  /// What the button says, for a task of no kind in particular; see
  /// [labelFor].
  final String label;

  /// The harness method that does it, or null for an action that is the
  /// app's own: looking at a session.  A harness older than the method does
  /// not have it, and the action is not offered (see [TaskActions.of]).
  String? get method => switch (this) {
    openSession || answer => null,
    start => 'task/start',
    queue => 'task/queue',
    retry => 'task/retry',
    retryMerge => 'task/merge',
    pause => 'task/pause',
    resume => 'task/resume',
    returnToPending => 'task/return-to-pending',
    message => 'task/prompt',
    verify => 'task/verify',
    sendBack => 'task/reject',
    stop || drop => 'task/cancel',
    complete => 'task/complete',
    archive || unarchive => 'task/archive',
    setPriority => 'priority/set',
    delete => 'task/delete',
  };

  /// Whether the action throws work away or stops it, so that a person is
  /// asked before it happens, and its button is not the colour of the others.
  bool get destructive => switch (this) {
    stop || drop || delete => true,
    _ => false,
  };

  /// Whether a person is asked before the action happens.  Marking a task
  /// complete accepts work without the merge, which cannot be undone.
  bool get confirms => destructive || this == complete;

  /// Whether the action needs words from the person: the message, the
  /// feedback.
  bool get needsText => this == message || this == sendBack;

  /// What the button for this action says for [task].
  String labelFor(HarnessTask task) => switch (this) {
    verify when task.noMerge => 'Verify',
    retry when task.isDuplicate => 'Write it up anyway',
    retry when task.isRefining => 'Retry write-up',
    _ => label,
  };
}

/// The actions to offer for one task.
class TaskActions {
  const TaskActions._(this.all);

  /// The actions that apply to [task], in the order its card offers them:
  /// the session first, then those of its column with the main one before the
  /// others, then the priority and delete.
  ///
  /// [pendingRequest] is whether the task's session waits for an answer to a
  /// question or a permission request.  The session knows; the task's own
  /// record says only that it needs the person.  A task that needs the
  /// person and stopped for no reason of its own (`outcome` is empty) waits
  /// for such an answer all the same.
  ///
  /// [supports] says whether the harness has a method, when the app knows
  /// what it has: an action whose method it lacks is not offered.
  factory TaskActions.of(
    HarnessTask task, {
    bool pendingRequest = false,
    bool Function(String method)? supports,
  }) {
    final column = task.columnName;
    final hasSession = (task.sessionId ?? '').isNotEmpty;
    // Pausing, and returning to pending, are for a task at work or stopped
    // part way, which the harness keeps in the state `active`: a task that is
    // done, say, and on its way to work again is none of them yet.
    final working = task.state == 'active';
    final actions = <TaskAction>[];

    if (task.archived) {
      // A task that was put away is brought back first.  One in review can
      // still be verified; a done one has nothing else to do.
      actions.add(TaskAction.unarchive);
      if (column == 'review') actions.add(TaskAction.verify);
    } else {
      switch (column) {
        case 'pending':
          // A paused task is resumed first and started second; one that
          // waits for a slot can be paused, last.  One that was put back in
          // the queue after it worked is the message's: its session has the
          // work, and a message starts it again (or is kept for the start).
          // One that never started has nothing to say yet, and a message to
          // it is refused.
          if (task.isPaused) actions.add(TaskAction.resume);
          actions.add(TaskAction.start);
          if (task.returned) actions.add(TaskAction.message);
          actions.add(TaskAction.drop);
          if (!task.isPaused) actions.add(TaskAction.pause);
        case 'backlog':
          if (task.isRefining) {
            // Being written up (the agent can be steered or stopped); a
            // write-up that stopped part way needs the person instead (its
            // column is needs-input).
            actions.addAll([TaskAction.message, TaskAction.stop]);
          } else {
            // The way out of the backlog is the queue, which starts the task
            // as a slot frees; starting it by hand ignores the limit.
            actions.addAll([
              TaskAction.start,
              TaskAction.queue,
              TaskAction.message,
              TaskAction.drop,
            ]);
          }
        case 'needs-input':
          if (pendingRequest || task.outcome == null) {
            // It asks something, and the session is where it is answered.
            actions.addAll([TaskAction.answer, TaskAction.stop]);
          } else if (task.isDuplicate) {
            // The agent found the board has it already: the person decides.
            actions.addAll([
              TaskAction.start,
              TaskAction.retry,
              TaskAction.message,
              TaskAction.drop,
            ]);
          } else if (task.isRefining) {
            actions.addAll([
              TaskAction.retry,
              TaskAction.start,
              TaskAction.drop,
            ]);
          } else {
            switch (task.outcome) {
              case 'merge-failed':
                actions.addAll([
                  TaskAction.retryMerge,
                  if (working) TaskAction.pause,
                  TaskAction.message,
                ]);
              case 'cannot-continue':
                actions.addAll([
                  TaskAction.message,
                  if (working) TaskAction.pause,
                ]);
              case 'error' || 'cancelled' || 'interrupted' || 'max-tokens':
                actions.addAll([
                  TaskAction.retry,
                  if (working) TaskAction.pause,
                  TaskAction.message,
                ]);
              default:
                actions.addAll([
                  if (working) TaskAction.pause,
                  TaskAction.message,
                ]);
            }
          }
        case 'active':
          actions.addAll([
            TaskAction.message,
            if (working) ...[TaskAction.pause, TaskAction.returnToPending],
            TaskAction.stop,
          ]);
        case 'merging':
          // The queue merges it, or its session resolves a conflict: that
          // can be stopped, and steered while it waits.
          actions.addAll([TaskAction.message, TaskAction.stop]);
        case 'review':
          // A message to a task in review sends it back, so there is no
          // plain message: sending back is the one that asks for the words.
          actions.addAll([
            TaskAction.verify,
            TaskAction.sendBack,
            TaskAction.archive,
          ]);
        case 'done' || 'cancelled':
          actions.addAll([TaskAction.archive, TaskAction.message]);
      }
      // The harness takes a task done by hand in any state, but a task that
      // never started is dropped, and one that is done is done.
      if (const {
        'needs-input',
        'active',
        'merging',
        'review',
      }.contains(column)) {
        // Before archiving a task in review, which is the last of its row.
        final at = actions.indexOf(TaskAction.archive);
        actions.insert(at < 0 ? actions.length : at, TaskAction.complete);
      }
    }

    // A task with no session has nothing to open, say, or to say to.
    if (!hasSession) {
      actions.removeWhere(
        (action) => action == TaskAction.message || action == TaskAction.answer,
      );
    }
    final offered = [
      if (hasSession && !actions.contains(TaskAction.answer))
        TaskAction.openSession,
      ...actions,
      // The priority is the session's, and a completed task has none.
      if (hasSession && column != 'done') TaskAction.setPriority,
      TaskAction.delete,
    ];
    return TaskActions._(
      List.unmodifiable([
        for (final action in offered)
          if (supports == null ||
              action.method == null ||
              supports(action.method!))
            action,
      ]),
    );
  }

  /// Every action, the session first and the destructive ones last.
  final List<TaskAction> all;

  bool contains(TaskAction action) => all.contains(action);

  /// The one thing to do, offered on its own line: accept the work, start
  /// the task, answer it, carry on.  Null when a task has none.
  TaskAction? get primary {
    for (final action in all) {
      if (_primaries.contains(action)) return action;
    }
    return null;
  }

  /// The other actions that are no more than a tap: those of a button row.
  List<TaskAction> get secondary => [
    for (final action in all)
      if (action != primary &&
          !action.destructive &&
          action != TaskAction.openSession &&
          action != TaskAction.answer &&
          action != TaskAction.setPriority)
        action,
  ];

  /// The actions that stop work or throw the task away.
  List<TaskAction> get dangerous => [
    for (final action in all)
      if (action.destructive) action,
  ];

  /// Whether the task's priority can be changed.
  bool get canSetPriority => all.contains(TaskAction.setPriority);

  static const _primaries = {
    TaskAction.verify,
    TaskAction.resume,
    TaskAction.start,
    TaskAction.retry,
    TaskAction.retryMerge,
    TaskAction.answer,
  };
}
