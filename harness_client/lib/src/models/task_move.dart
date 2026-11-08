import 'task.dart';
import 'task_actions.dart';

/// A move of a task to another column of the board: the column to drop it on,
/// and the action of the harness that puts the task in that column's state.
///
/// The board is drawn from the harness's own columns, and a person moves a
/// task by dragging its card there.  What a column means is a state of the
/// task, so not every column is a place a task can be put by hand: a task
/// needs input because its session waits on the person, and one is cancelled
/// only after it was stopped and then marked done.  A move is offered where
/// one of the actions that [TaskActions] offers for the task reaches the
/// column; the harness decides in the end, and says so when it refuses.
///
/// The actions of a column, in the order a drop tries them: a task in the
/// backlog is queued or started for Active, a task at work is returned to the
/// queue (not paused, which would hold it) for Pending, a task in review is
/// sent back with feedback for Active, and put in review by hand for Review.
class TaskMove {
  const TaskMove({
    required this.task,
    required this.column,
    required this.action,
  });

  final HarnessTask task;

  /// The column the card is dropped on.
  final String column;

  /// What the harness does to get the task there.
  final TaskAction action;

  /// The move of [task] to [column], from the [actions] the task offers, or
  /// null when no action takes it there.
  ///
  /// A task that was put away is brought back first, and one already in
  /// [column] has nowhere to go: neither is a move.
  static TaskMove? of(HarnessTask task, String column, TaskActions actions) {
    if (task.archived || task.columnName == column) return null;
    for (final action in _actionsFor[column] ?? const <TaskAction>[]) {
      if (actions.contains(action)) {
        return TaskMove(task: task, column: column, action: action);
      }
    }
    return null;
  }

  /// What the drop does, in the words of its action: what the column it is
  /// over says while the card is carried there.
  String get label => action.labelFor(task);

  /// The actions that move a task to a column.  Needs input and cancelled
  /// have none: they are not states a person puts a task in.
  static const _actionsFor = <String, List<TaskAction>>{
    'active': [TaskAction.start, TaskAction.retry, TaskAction.sendBack],
    'pending': [TaskAction.queue, TaskAction.returnToPending, TaskAction.pause],
    'backlog': [TaskAction.park],
    'review': [TaskAction.putInReview],
    'merging': [TaskAction.verify],
    'done': [TaskAction.complete],
  };

  /// Every column a card can be dropped on, for a board that shows them all
  /// while a card is carried.
  static Iterable<String> get columns => _actionsFor.keys;
}
