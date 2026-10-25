// What the conversation of a task says of it, and offers to do with it, by the
// state the task is in: the words of its bar (`TaskStateLine`), which of the
// actions the harness will take it lays out as buttons and which it keeps in
// its menu (`TaskBarActions`, over `TaskActions`), and what its message box
// says a message does there.  Plain Dart: the table is read without a screen.
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/models/task.dart';
import 'package:harness_client/src/models/task_actions.dart';
import 'package:harness_client/src/models/task_chat.dart';

HarnessTask _task(
  String column, {
  String? state,
  String? outcome,
  bool archived = false,
  bool verified = false,
  bool backlog = false,
  bool returned = false,
  String? hold,
  String? session = 's-1',
  List<String> conflicts = const [],
}) => HarnessTask(
  id: 't-1',
  name: 'A task',
  state: state ?? (column == 'needs-input' ? 'active' : column),
  column: column,
  sessionId: session,
  outcome: outcome,
  archived: archived,
  verified: verified,
  backlog: backlog,
  returned: returned,
  hold: hold == null ? null : TaskHold(kind: hold),
  conflicts: conflicts,
);

TaskBarActions _bar(
  HarnessTask task, {
  bool pendingRequest = false,
  bool Function(String method)? supports,
}) => TaskBarActions.of(
  task,
  TaskActions.of(task, pendingRequest: pendingRequest, supports: supports),
);

void main() {
  group('the bar of a task in review', () {
    final task = _task('review');

    test('verifies it or sends it back, and keeps the rest in its menu', () {
      final bar = _bar(task);
      expect(bar.primary, TaskAction.verify);
      expect(bar.buttons, [TaskAction.sendBack]);
      expect(bar.menu, [
        TaskAction.complete,
        TaskAction.archive,
        TaskAction.setPriority,
        TaskAction.delete,
      ]);
    });

    test('says what to do, in a line', () {
      final line = TaskStateLine.of(task);
      expect(line.heading, 'Review');
      expect(line.message, contains('type what should change'));
    });

    test('has no conversation to open, no message to write and no answer', () {
      final bar = _bar(task);
      for (final action in [
        TaskAction.openSession,
        TaskAction.answer,
        TaskAction.message,
      ]) {
        expect(bar.all, isNot(contains(action)));
      }
    });
  });

  group('the bar of a task that has not started', () {
    test('in the backlog starts it or queues it', () {
      final task = _task('backlog', state: 'pending', backlog: true);
      final bar = _bar(task);
      expect(bar.primary, TaskAction.start);
      expect(bar.buttons, [TaskAction.queue]);
      expect(bar.menu, [
        TaskAction.setPriority,
        TaskAction.drop,
        TaskAction.delete,
      ]);
      expect(TaskStateLine.of(task).heading, 'Backlog');
      expect(TaskStateLine.of(task).message, contains('A message here starts'));
    });

    test('being written up can be stopped, and has no button', () {
      final task = _task('backlog', state: 'refining');
      final bar = _bar(task);
      expect(bar.primary, isNull);
      expect(bar.buttons, isEmpty);
      expect(bar.menu, [
        TaskAction.setPriority,
        TaskAction.stop,
        TaskAction.delete,
      ]);
      expect(TaskStateLine.of(task).message, contains('writing it up'));
    });

    test('waiting for a slot is started at once, or paused', () {
      final task = _task('pending');
      final bar = _bar(task);
      expect(bar.primary, TaskAction.start);
      expect(bar.buttons, [TaskAction.pause]);
      expect(bar.menu, [
        TaskAction.setPriority,
        TaskAction.drop,
        TaskAction.delete,
      ]);
      expect(TaskStateLine.of(task).message, 'Waiting for a free slot.');
    });

    test('that is paused is resumed first, and started second', () {
      final task = _task('pending', hold: 'paused');
      final bar = _bar(task);
      expect(bar.primary, TaskAction.resume);
      expect(bar.buttons, [TaskAction.start]);
      expect(TaskStateLine.of(task).message, contains('until you resume'));
    });

    test('that waits for quota or a budget says which', () {
      expect(
        TaskStateLine.of(_task('pending', hold: 'quota')).message,
        contains('quota'),
      );
      expect(
        TaskStateLine.of(_task('pending', hold: 'budget')).message,
        contains('budget'),
      );
    });

    test('that was put back in the queue carries on where it stopped', () {
      final task = _task('pending', returned: true);
      expect(TaskStateLine.of(task).message, contains('carries on'));
    });
  });

  group('the bar of a task at work', () {
    test('has a pause, and keeps the stop in its menu', () {
      final bar = _bar(_task('active'));
      expect(bar.primary, isNull);
      expect(bar.buttons, [TaskAction.pause]);
      expect(bar.menu, [
        TaskAction.returnToPending,
        TaskAction.complete,
        TaskAction.setPriority,
        TaskAction.stop,
        TaskAction.delete,
      ]);
      expect(TaskStateLine.of(_task('active')).heading, 'Active');
    });

    test('in the merge queue can only be stopped or marked complete', () {
      final task = _task('merging');
      final bar = _bar(task);
      expect(bar.primary, isNull);
      expect(bar.buttons, isEmpty);
      expect(bar.menu, [
        TaskAction.complete,
        TaskAction.setPriority,
        TaskAction.stop,
        TaskAction.delete,
      ]);
      expect(TaskStateLine.of(task).message, 'In the merge queue.');
    });

    test('whose merge has conflicts names the files', () {
      final line = TaskStateLine.of(
        _task('merging', conflicts: const ['a.dart', 'b.dart']),
      );
      expect(line.message, 'Conflicts in a.dart, b.dart.');
    });

    test('with many conflicts names three and counts the rest', () {
      final line = TaskStateLine.of(
        _task('merging', conflicts: const ['a', 'b', 'c', 'd', 'e']),
      );
      expect(line.message, 'Conflicts in a, b, c and 2 more.');
    });
  });

  group('the bar of a task that waits for the person', () {
    test('for an answer has the conversation to give it in', () {
      final task = _task('needs-input');
      final bar = _bar(task, pendingRequest: true);
      expect(bar.primary, isNull);
      expect(bar.buttons, isEmpty);
      expect(bar.menu, contains(TaskAction.stop));
      expect(TaskStateLine.of(task).heading, 'Needs input');
      expect(
        TaskStateLine.of(task).message,
        contains('answer in this conversation'),
      );
    });

    for (final outcome in ['error', 'cancelled', 'interrupted', 'max-tokens']) {
      test('that stopped on "$outcome" is tried again, or paused', () {
        final task = _task('needs-input', outcome: outcome);
        final bar = _bar(task);
        expect(bar.primary, TaskAction.retry);
        expect(bar.buttons, [TaskAction.pause]);
        expect(bar.menu, [
          TaskAction.complete,
          TaskAction.setPriority,
          TaskAction.delete,
        ]);
      });
    }

    test('whose merge failed has the merge queued again', () {
      final task = _task(
        'needs-input',
        outcome: 'merge-failed',
        conflicts: const ['a'],
      );
      final bar = _bar(task);
      expect(bar.primary, TaskAction.retryMerge);
      expect(TaskAction.retryMerge.labelFor(task), 'Retry merge');
      expect(TaskStateLine.of(task).message, contains('conflicts in a'));
    });

    test('that cannot continue is not retried: it says why, here', () {
      final task = _task('needs-input', outcome: 'cannot-continue');
      final bar = _bar(task);
      expect(bar.primary, isNull);
      expect(bar.all, isNot(contains(TaskAction.retry)));
      expect(TaskStateLine.of(task).message, contains('Reply here'));
    });

    test('whose write-up found it a duplicate may be started all the same', () {
      final task = _task(
        'needs-input',
        state: 'refining',
        outcome: 'duplicate',
      );
      final bar = _bar(task);
      expect(bar.primary, TaskAction.start);
      expect(bar.buttons, [TaskAction.retry]);
      expect(TaskAction.retry.labelFor(task), 'Write it up anyway');
      expect(bar.menu, contains(TaskAction.drop));
    });

    test('that stopped for a reason nobody named still says it', () {
      final task = _task('needs-input', outcome: 'gone');
      expect(TaskStateLine.of(task).message, 'It stopped (gone).');
    });
  });

  group('the bar of a task that is finished', () {
    test('puts it away', () {
      final task = _task('done', verified: true);
      final bar = _bar(task);
      expect(bar.primary, TaskAction.archive);
      expect(bar.buttons, isEmpty);
      expect(bar.menu, [TaskAction.delete]);
      expect(TaskStateLine.of(task).heading, 'Done');
    });

    test('and archived brings it back', () {
      final bar = _bar(_task('done', archived: true));
      expect(bar.primary, TaskAction.unarchive);
      expect(bar.menu, [TaskAction.delete]);
    });
  });

  group('the bar', () {
    test('of a task with no session offers no priority, which is a session\'s', () {
      final bar = _bar(_task('review', session: null));
      expect(bar.all, isNot(contains(TaskAction.setPriority)));
      expect(bar.primary, TaskAction.verify);
    });

    test('is not offered what the harness cannot do', () {
      final bar = _bar(
        _task('pending'),
        supports: (method) => method != 'task/pause' && method != 'priority/set',
      );
      expect(bar.all, isNot(contains(TaskAction.pause)));
      expect(bar.all, isNot(contains(TaskAction.setPriority)));
      expect(bar.primary, TaskAction.start);
    });

    test('puts what stops work or throws a task away last', () {
      for (final column in [
        'review',
        'backlog',
        'pending',
        'active',
        'merging',
      ]) {
        final menu = _bar(_task(column)).menu;
        final firstDestructive = menu.indexWhere((action) => action.destructive);
        if (firstDestructive < 0) continue;
        expect(
          menu.skip(firstDestructive).every((action) => action.destructive),
          isTrue,
          reason: '$column: $menu',
        );
      }
    });

    test('has no more than two buttons beside the one to take', () {
      for (final column in [
        'review',
        'backlog',
        'pending',
        'active',
        'merging',
        'needs-input',
        'done',
      ]) {
        expect(_bar(_task(column)).buttons.length, lessThanOrEqualTo(2));
      }
    });
  });

  group('what a message does in the conversation of a task', () {
    test('sends a task in review back', () {
      expect(
        taskMessageHint(_task('review')),
        'Feedback · sending it sends the task back',
      );
    });

    test('starts a task in the backlog, a write-up that runs included', () {
      expect(
        taskMessageHint(_task('backlog', state: 'pending')),
        'Message · sending it starts the task',
      );
      expect(
        taskMessageHint(_task('backlog', state: 'refining')),
        'Message · sending it starts the task',
      );
    });

    test('is only a message anywhere else, or for a session of no task', () {
      for (final column in [
        'active',
        'needs-input',
        'pending',
        'merging',
        'done',
      ]) {
        expect(taskMessageHint(_task(column)), isNull, reason: column);
      }
      expect(taskMessageHint(_task('review', archived: true)), isNull);
      expect(taskMessageHint(null), isNull);
    });
  });
}
