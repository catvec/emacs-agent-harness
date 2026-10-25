import 'task.dart';
import 'task_actions.dart';

/// How a task stands, in the words of its conversation's bar (`SessionTaskBar`).
///
/// A task is handled in its conversation: tapping it on the board opens the
/// conversation, and the bar above the message box says where the task stands
/// and offers what can be done about it.  The board is only a list.  What can
/// be done is [TaskActions]'s (the sets the board of Emacs offers on a card);
/// this is what is said of the state, plain Dart so that it is read, and
/// tested, without a screen.
class TaskStateLine {
  const TaskStateLine({required this.heading, this.message});

  /// The task's column, in words: where it stands.
  final String heading;

  /// A line about the state: what it waits for, what went wrong.
  final String? message;

  /// The line for [task] in the state it is in now.
  static TaskStateLine of(HarnessTask task) {
    final heading = taskColumnLabel(task.columnName);
    if (task.isReview) {
      // A round of work that ended without `hand_in` has no report, only the
      // last message of its session, which is in the conversation above.
      final none = task.report?.missing == true
          ? 'Its last message is above. '
          : '';
      return TaskStateLine(
        heading: heading,
        message:
            '${none}Verify it, or type what should change below to send it '
            'back.',
      );
    }
    if (task.isClosed) return TaskStateLine(heading: heading);
    if (task.isBacklog) {
      return TaskStateLine(
        heading: heading,
        message: task.isRefining
            ? 'An agent is writing it up. A message here starts the task '
                  'instead.'
            : 'Waiting for you to start it. A message here starts it too.',
      );
    }
    if (task.isPending) {
      final hold = task.hold;
      return TaskStateLine(
        heading: heading,
        message: switch (hold?.kind) {
          'paused' => 'Held in the queue until you resume it.',
          'quota' => 'Waiting for quota to come back.',
          'budget' => 'Waiting for a budget to be raised.',
          _ =>
            task.returned
                ? 'Back in the queue: it carries on where it stopped.'
                : 'Waiting for a free slot.',
        },
      );
    }
    if (task.isMerging) {
      return TaskStateLine(
        heading: heading,
        message: task.conflicts.isEmpty
            ? 'In the merge queue.'
            : 'Conflicts in ${_files(task.conflicts)}.',
      );
    }
    final outcome = task.outcome;
    if (task.needsInput && outcome != null) {
      return TaskStateLine(
        heading: heading,
        message: _stopped(task, outcome),
      );
    }
    if (task.needsInput) {
      return TaskStateLine(
        heading: heading,
        message: 'Waiting for your answer in this conversation.',
      );
    }
    return TaskStateLine(heading: heading);
  }

  /// What a task that stopped and waits for the person says of why.
  static String _stopped(HarnessTask task, String outcome) => switch (outcome) {
    'merge-failed' =>
      task.conflicts.isEmpty
          ? 'Merging its branch failed.'
          : 'Merging its branch failed: conflicts in '
                '${_files(task.conflicts)}.',
    'cannot-continue' =>
      'It said it cannot continue. Reply here to help it, or mark it '
          'complete.',
    'duplicate' => 'Its write-up found the board has it already.',
    'error' => 'Its last turn ended in an error.',
    'cancelled' => 'It was stopped before it finished.',
    'interrupted' => 'It was interrupted before it finished.',
    'max-tokens' => 'It ran out of output tokens.',
    _ => 'It stopped ($outcome).',
  };

  static String _files(List<String> files) {
    final shown = files.take(3).join(', ');
    final left = files.length - 3;
    return left > 0 ? '$shown and $left more' : shown;
  }
}

/// Which of the actions of a task the bar of its conversation shows as
/// buttons, and which it keeps in its menu.
///
/// The conversation is the task's session, so there is nothing to open, no
/// request to take to it (a question has its own card there) and no message to
/// offer (the box under the bar is where one is written, and what the harness
/// does with it is the box's hint).  What is left: the action to take, up to
/// two more that are no more than a tap, and a menu of the rest, the ones that
/// stop work or throw the task away last.
class TaskBarActions {
  const TaskBarActions({
    this.primary,
    this.buttons = const [],
    this.menu = const [],
  });

  /// The one thing to do: accept the work, start the task, carry on.
  final TaskAction? primary;

  /// The ones beside it, a button each.
  final List<TaskAction> buttons;

  /// The rest, in a menu.
  final List<TaskAction> menu;

  /// Every action the bar offers, in the order it shows them.
  List<TaskAction> get all => [
    if (primary case final first?) first,
    ...buttons,
    ...menu,
  ];

  /// What a button is for: the quick, undoable ways to go on.
  static const _quick = {
    TaskAction.sendBack,
    TaskAction.queue,
    TaskAction.start,
    TaskAction.resume,
    TaskAction.pause,
    TaskAction.retry,
    TaskAction.retryMerge,
  };

  /// What the conversation has already.
  static const _here = {
    TaskAction.openSession,
    TaskAction.answer,
    TaskAction.message,
  };

  /// The bar's buttons and menu for [task], from what [actions] offers it.
  static TaskBarActions of(HarnessTask task, TaskActions actions) {
    final offered = [
      for (final action in actions.all)
        if (!_here.contains(action)) action,
    ];
    var primary = actions.primary;
    if (primary != null && _here.contains(primary)) primary = null;
    // A task that is over, finished or cancelled, is put away, and one that
    // was is brought back: the one thing left to do with it.
    if (primary == null) {
      if (task.archived && offered.contains(TaskAction.unarchive)) {
        primary = TaskAction.unarchive;
      } else if (task.isClosed && offered.contains(TaskAction.archive)) {
        primary = TaskAction.archive;
      }
    }
    final buttons = <TaskAction>[
      for (final action in offered)
        if (action != primary && _quick.contains(action)) action,
    ].take(2).toList();
    final menu = <TaskAction>[
      for (final action in offered)
        if (action != primary && !buttons.contains(action)) action,
    ];
    return TaskBarActions(
      primary: primary,
      buttons: buttons,
      // What stops work or throws the task away comes last.
      menu: [
        for (final action in menu)
          if (!action.destructive) action,
        for (final action in menu)
          if (action.destructive) action,
      ],
    );
  }
}

/// What the message box of a task's conversation says a message does there, in
/// place of the usual line, or null when it is no different: the harness takes
/// a message to the session of a task in review for the feedback that sends it
/// back, and one to a task that waits in the backlog for its start.
String? taskMessageHint(HarnessTask? task) {
  if (task == null || task.archived) return null;
  if (task.isReview) return 'Feedback · sending it sends the task back';
  if (task.isBacklog) return 'Message · sending it starts the task';
  return null;
}

/// A column of the board in words.
String taskColumnLabel(String column) => switch (column) {
  'needs-input' => 'Needs input',
  'active' => 'Active',
  'review' => 'Review',
  'pending' => 'Pending',
  'merging' => 'Merging',
  'backlog' => 'Backlog',
  'done' => 'Done',
  'cancelled' => 'Cancelled',
  _ => column,
};
