// What dropping a task on a column of the board does: which action of the
// harness moves it to that column's state, and where no action does.
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/models/task.dart';
import 'package:harness_client/src/models/task_actions.dart';
import 'package:harness_client/src/models/task_move.dart';

/// A task as the harness sends it, with a session, and whatever [wire] says.
HarnessTask _task(Map<String, Object?> wire) => HarnessTask.fromWire({
  'id': 't-1',
  'name': 'A task',
  'session': 's-1',
  'project': '/work/project/',
  ...wire,
});

/// What dropping the task described by [wire] on [column] does, if anything.
TaskMove? _move(
  Map<String, Object?> wire,
  String column, {
  bool request = false,
  bool Function(String method)? supports,
}) {
  final task = _task(wire);
  return TaskMove.of(
    task,
    column,
    TaskActions.of(task, pendingRequest: request, supports: supports),
  );
}

const _pending = {'state': 'pending', 'column': 'pending'};
const _backlog = {'state': 'pending', 'column': 'backlog', 'backlog': true};
const _active = {'state': 'active', 'column': 'active'};
const _stopped = {
  'state': 'active',
  'column': 'needs-input',
  'outcome': 'error',
};
const _review = {'state': 'review', 'column': 'review'};
const _merging = {
  'state': 'active',
  'column': 'merging',
  'merge-status': 'queued',
};
const _done = {'state': 'done', 'column': 'done'};

void main() {
  group('a task dropped on a column', () {
    test(
      'waiting for a slot is started for Active, and parked for Backlog',
      () {
        expect(_move(_pending, 'active')?.action, TaskAction.start);
        expect(_move(_pending, 'backlog')?.action, TaskAction.park);
        expect(_move(_pending, 'pending'), isNull);
      },
    );

    test('in the backlog is queued for Pending, and started for Active', () {
      expect(_move(_backlog, 'pending')?.action, TaskAction.queue);
      expect(_move(_backlog, 'active')?.action, TaskAction.start);
    });

    test('at work is returned to the queue, not paused there', () {
      final move = _move(_active, 'pending');
      expect(move?.action, TaskAction.returnToPending);
      expect(move?.label, 'Return to queue');
    });

    test('at work is put in review by hand, and marked done', () {
      expect(_move(_active, 'review')?.action, TaskAction.putInReview);
      expect(_move(_active, 'done')?.action, TaskAction.complete);
    });

    test('stopped part way is retried for Active, paused for Pending, put in '
        'review, or marked done', () {
      expect(_move(_stopped, 'active')?.action, TaskAction.retry);
      expect(_move(_stopped, 'pending')?.action, TaskAction.pause);
      expect(_move(_stopped, 'review')?.action, TaskAction.putInReview);
      expect(_move(_stopped, 'done')?.action, TaskAction.complete);
    });

    test('that asks a question is not taken back to work, but can be marked '
        'done', () {
      final asking = {..._active, 'column': 'needs-input'};
      for (final column in ['active', 'pending', 'review', 'merging']) {
        expect(_move(asking, column, request: true), isNull, reason: column);
      }
      expect(_move(asking, 'done', request: true)?.action, TaskAction.complete);
    });

    test('whose write-up stopped is started, but not put in review', () {
      const writeUp = {
        'state': 'refining',
        'column': 'needs-input',
        'outcome': 'error',
      };
      expect(_move(writeUp, 'active')?.action, TaskAction.start);
      expect(_move(writeUp, 'review'), isNull);
    });

    test('in review is sent back for Active, verified for Merging, and '
        'completed for Done', () {
      expect(_move(_review, 'active')?.action, TaskAction.sendBack);
      expect(_move(_review, 'merging')?.action, TaskAction.verify);
      expect(_move(_review, 'done')?.action, TaskAction.complete);
      expect(_move(_review, 'pending'), isNull);
    });

    test('in the merge queue is only marked done', () {
      expect(_move(_merging, 'done')?.action, TaskAction.complete);
      expect(_move(_merging, 'review'), isNull);
    });

    test('that is finished, cancelled or put away is moved nowhere', () {
      for (final column in TaskMove.columns) {
        expect(_move(_done, column), isNull, reason: column);
      }
      expect(_move({..._review, 'archived': true}, 'merging'), isNull);
    });
  });

  group('a move', () {
    test('is only offered where the harness has the action', () {
      expect(
        _move(_pending, 'backlog', supports: (method) => method != 'task/park'),
        isNull,
      );
      expect(
        _move(
          _active,
          'review',
          supports: (method) => method != 'task/force-review',
        ),
        isNull,
      );
    });

    test('says what the drop does, in the words of its action', () {
      expect(_move(_pending, 'active')?.label, 'Start now');
      expect(_move(_pending, 'backlog')?.label, 'Move to backlog');
      expect(_move(_review, 'merging')?.label, 'Verify and merge');
      expect(_move(_review, 'active')?.label, 'Send back');
      expect(_move(_active, 'review')?.label, 'Put in review');
      expect(_move(_active, 'done')?.label, 'Mark complete');
    });

    test('has no words for needs input or cancelled as a target', () {
      for (final column in ['needs-input', 'cancelled']) {
        expect(_move(_active, column), isNull, reason: column);
      }
      expect(TaskMove.columns, [
        'active',
        'pending',
        'backlog',
        'review',
        'merging',
        'done',
      ]);
    });
  });
}
