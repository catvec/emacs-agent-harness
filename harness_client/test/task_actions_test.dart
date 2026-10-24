import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/models/task.dart';
import 'package:harness_client/src/models/task_actions.dart';

/// A task as the harness sends it, with a session, and whatever [wire] says.
HarnessTask _task(Map<String, Object?> wire) => HarnessTask.fromWire({
  'id': 't-1',
  'name': 'A task',
  'session': 's-1',
  'project': '/work/project/',
  ...wire,
});

List<TaskAction> _all(
  Map<String, Object?> wire, {
  bool request = false,
  bool Function(String method)? supports,
}) => TaskActions.of(
  _task(wire),
  pendingRequest: request,
  supports: supports,
).all;

const _a = TaskAction.values;

void main() {
  group('the actions the board offers on a card, as Emacs offers them', () {
    test('a task waiting for a slot can be started, dropped or paused', () {
      expect(_all({'state': 'pending', 'column': 'pending'}), [
        TaskAction.openSession,
        TaskAction.start,
        TaskAction.drop,
        TaskAction.pause,
        TaskAction.setPriority,
        TaskAction.delete,
      ]);
    });

    test('a paused task is resumed first, and cannot be paused again', () {
      final paused = _all({
        'state': 'pending',
        'column': 'pending',
        'returned': 1700000000.5,
        'hold': {'kind': 'paused'},
      });
      expect(paused, [
        TaskAction.openSession,
        TaskAction.resume,
        TaskAction.start,
        TaskAction.message,
        TaskAction.drop,
        TaskAction.setPriority,
        TaskAction.delete,
      ]);
      expect(paused, isNot(contains(TaskAction.pause)));
    });

    test('a task held for quota is not paused, and cannot be resumed', () {
      final held = _all({
        'state': 'pending',
        'column': 'pending',
        'returned': 1700000000.5,
        'hold': {'kind': 'quota', 'reason': 'Out of quota'},
      });
      expect(held, isNot(contains(TaskAction.resume)));
      expect(held, contains(TaskAction.pause));
    });

    test('a task that never started is not written to; one returned is', () {
      final fresh = _all({'state': 'pending', 'column': 'pending'});
      expect(fresh, isNot(contains(TaskAction.message)));
      final returned = _all({
        'state': 'pending',
        'column': 'pending',
        'returned': true,
      });
      expect(returned, contains(TaskAction.message));
    });

    test('a task in the backlog is started or queued, or given feedback', () {
      expect(_all({'state': 'pending', 'column': 'backlog', 'backlog': true}), [
        TaskAction.openSession,
        TaskAction.start,
        TaskAction.queue,
        TaskAction.message,
        TaskAction.drop,
        TaskAction.setPriority,
        TaskAction.delete,
      ]);
    });

    test('a task being written up can be steered or stopped', () {
      expect(_all({'state': 'refining', 'column': 'backlog'}), [
        TaskAction.openSession,
        TaskAction.message,
        TaskAction.stop,
        TaskAction.setPriority,
        TaskAction.delete,
      ]);
    });

    test('a task that waits for an answer is answered in its session', () {
      final asking = {'state': 'active', 'column': 'needs-input'};
      // The session says so, or the task stopped for no reason of its own.
      for (final actions in [
        _all(asking),
        _all({...asking, 'outcome': 'error'}, request: true),
      ]) {
        expect(actions, [
          TaskAction.answer,
          TaskAction.stop,
          TaskAction.complete,
          TaskAction.setPriority,
          TaskAction.delete,
        ]);
      }
    });

    group('a task that stopped part way', () {
      const stopped = {'state': 'active', 'column': 'needs-input'};

      test('after an error is retried, paused or written to', () {
        for (final outcome in [
          'error',
          'cancelled',
          'interrupted',
          'max-tokens',
        ]) {
          expect(_all({...stopped, 'outcome': outcome}), [
            TaskAction.openSession,
            TaskAction.retry,
            TaskAction.pause,
            TaskAction.message,
            TaskAction.complete,
            TaskAction.setPriority,
            TaskAction.delete,
          ], reason: outcome);
        }
      });

      test('after a merge that failed is merged again', () {
        expect(_all({...stopped, 'outcome': 'merge-failed'}), [
          TaskAction.openSession,
          TaskAction.retryMerge,
          TaskAction.pause,
          TaskAction.message,
          TaskAction.complete,
          TaskAction.setPriority,
          TaskAction.delete,
        ]);
      });

      test('that cannot continue is written to, not retried', () {
        expect(_all({...stopped, 'outcome': 'cannot-continue'}), [
          TaskAction.openSession,
          TaskAction.message,
          TaskAction.pause,
          TaskAction.complete,
          TaskAction.setPriority,
          TaskAction.delete,
        ]);
      });

      test('for another reason is paused, written to or marked done', () {
        expect(_all({...stopped, 'outcome': 'end-turn'}), [
          TaskAction.openSession,
          TaskAction.pause,
          TaskAction.message,
          TaskAction.complete,
          TaskAction.setPriority,
          TaskAction.delete,
        ]);
      });

      test('whose write-up stopped is retried, started or dropped', () {
        expect(
          _all({
            'state': 'refining',
            'column': 'needs-input',
            'outcome': 'error',
          }),
          [
            TaskAction.openSession,
            TaskAction.retry,
            TaskAction.start,
            TaskAction.drop,
            TaskAction.complete,
            TaskAction.setPriority,
            TaskAction.delete,
          ],
        );
      });

      test('whose write-up found it a duplicate is the person’s to decide', () {
        final duplicate = _task({
          'state': 'refining',
          'column': 'needs-input',
          'outcome': 'duplicate',
        });
        expect(TaskActions.of(duplicate).all, [
          TaskAction.openSession,
          TaskAction.start,
          TaskAction.retry,
          TaskAction.message,
          TaskAction.drop,
          TaskAction.complete,
          TaskAction.setPriority,
          TaskAction.delete,
        ]);
        // Retrying it is writing it up all the same.
        expect(TaskAction.retry.labelFor(duplicate), 'Write it up anyway');
      });

      test('that is not at work cannot be paused', () {
        // A task that is done and on its way back to work is neither at work
        // nor stopped part way: the harness would refuse to pause it.
        final waking = _all({
          'state': 'done',
          'column': 'needs-input',
          'outcome': 'error',
        });
        expect(waking, isNot(contains(TaskAction.pause)));
      });
    });

    test('a task at work is steered, paused, returned or stopped', () {
      expect(_all({'state': 'active', 'column': 'active'}), [
        TaskAction.openSession,
        TaskAction.message,
        TaskAction.pause,
        TaskAction.returnToPending,
        TaskAction.stop,
        TaskAction.complete,
        TaskAction.setPriority,
        TaskAction.delete,
      ]);
    });

    test('only a task in the state active can be returned to pending', () {
      // Its column says it works while a message to a done task is on its
      // way; the harness refuses to return a task that is not at work.
      final waking = _all({'state': 'done', 'column': 'active'});
      expect(waking, isNot(contains(TaskAction.returnToPending)));
      expect(waking, isNot(contains(TaskAction.pause)));
    });

    test('a task in the merge queue can be written to or stopped', () {
      expect(
        _all({
          'state': 'active',
          'column': 'merging',
          'merge-status': 'queued',
        }),
        [
          TaskAction.openSession,
          TaskAction.message,
          TaskAction.stop,
          TaskAction.complete,
          TaskAction.setPriority,
          TaskAction.delete,
        ],
      );
    });

    test('a task in review is verified or sent back, not written to', () {
      final review = _all({'state': 'review', 'column': 'review'});
      expect(review, [
        TaskAction.openSession,
        TaskAction.verify,
        TaskAction.sendBack,
        TaskAction.complete,
        TaskAction.archive,
        TaskAction.setPriority,
        TaskAction.delete,
      ]);
      expect(review, isNot(contains(TaskAction.message)));
    });

    test('a task that was put away is brought back first', () {
      expect(_all({'state': 'review', 'column': 'review', 'archived': true}), [
        TaskAction.openSession,
        TaskAction.unarchive,
        TaskAction.verify,
        TaskAction.setPriority,
        TaskAction.delete,
      ]);
      expect(_all({'state': 'done', 'column': 'done', 'archived': true}), [
        TaskAction.openSession,
        TaskAction.unarchive,
        TaskAction.delete,
      ]);
    });

    test(
      'a task that is done is archived or followed up, and has no priority',
      () {
        expect(_all({'state': 'done', 'column': 'done'}), [
          TaskAction.openSession,
          TaskAction.archive,
          TaskAction.message,
          TaskAction.delete,
        ]);
      },
    );

    test('a task with no session has nothing to open, say or prioritise', () {
      expect(_all({'state': 'review', 'column': 'review', 'session': null}), [
        TaskAction.verify,
        TaskAction.sendBack,
        TaskAction.complete,
        TaskAction.archive,
        TaskAction.delete,
      ]);
      final asking = _all({
        'state': 'active',
        'column': 'needs-input',
        'session': null,
      });
      expect(asking, isNot(contains(TaskAction.answer)));
    });

    test('an action the harness has no method for is not offered', () {
      const lacking = {'task/pause', 'task/resume', 'priority/set'};
      final actions = _all({
        'state': 'active',
        'column': 'active',
      }, supports: (method) => !lacking.contains(method));
      expect(actions, isNot(contains(TaskAction.pause)));
      expect(actions, isNot(contains(TaskAction.setPriority)));
      expect(actions, contains(TaskAction.returnToPending));
      // The session is the app's own to open: no method is needed.
      expect(actions, contains(TaskAction.openSession));
    });
  });

  group('how the actions are laid out', () {
    test('a task in review has one thing to do, and others beside it', () {
      final actions = TaskActions.of(
        _task({'state': 'review', 'column': 'review'}),
      );
      expect(actions.primary, TaskAction.verify);
      expect(actions.secondary, [
        TaskAction.sendBack,
        TaskAction.complete,
        TaskAction.archive,
      ]);
      expect(actions.dangerous, [TaskAction.delete]);
      expect(actions.canSetPriority, isTrue);
    });

    test('the one thing to do is the first of those that carry on', () {
      TaskAction? primary(Map<String, Object?> wire) =>
          TaskActions.of(_task(wire)).primary;
      expect(
        primary({'state': 'pending', 'column': 'pending'}),
        TaskAction.start,
      );
      expect(
        primary({
          'state': 'pending',
          'column': 'pending',
          'hold': {'kind': 'paused'},
        }),
        TaskAction.resume,
      );
      expect(
        primary({'state': 'pending', 'column': 'backlog', 'backlog': true}),
        TaskAction.start,
      );
      expect(
        primary({
          'state': 'active',
          'column': 'needs-input',
          'outcome': 'error',
        }),
        TaskAction.retry,
      );
      expect(
        primary({'state': 'active', 'column': 'needs-input'}),
        TaskAction.answer,
      );
      // A task at work has none: it is open, or steered, or stopped.
      expect(primary({'state': 'active', 'column': 'active'}), isNull);
    });

    test('what stops work or throws a task away is kept apart', () {
      final actions = TaskActions.of(
        _task({'state': 'active', 'column': 'active'}),
      );
      expect(actions.dangerous, [TaskAction.stop, TaskAction.delete]);
      expect(actions.secondary, [
        TaskAction.message,
        TaskAction.pause,
        TaskAction.returnToPending,
        TaskAction.complete,
      ]);
      for (final action in actions.secondary) {
        expect(action.destructive, isFalse, reason: '$action');
      }
    });

    test('a person is asked before what cannot be taken back', () {
      expect(
        [
          for (final action in _a)
            if (action.confirms) action,
        ],
        [
          TaskAction.stop,
          TaskAction.drop,
          TaskAction.complete,
          TaskAction.delete,
        ],
      );
      expect(
        [
          for (final action in _a)
            if (action.needsText) action,
        ],
        [TaskAction.message, TaskAction.sendBack],
      );
    });

    test('verifying work that needs no merge does not say it merges', () {
      final plain = _task({'state': 'review', 'column': 'review'});
      final noMerge = _task({
        'state': 'review',
        'column': 'review',
        'no-merge': true,
      });
      expect(TaskAction.verify.labelFor(plain), 'Verify and merge');
      expect(TaskAction.verify.labelFor(noMerge), 'Verify');
    });
  });

  group('the harness methods the actions use', () {
    test('every action that does something has a method of its own', () {
      expect(
        {
          for (final action in _a)
            if (action.method != null) action.method!,
        },
        {
          'task/start',
          'task/queue',
          'task/retry',
          'task/merge',
          'task/pause',
          'task/resume',
          'task/return-to-pending',
          'task/prompt',
          'task/verify',
          'task/reject',
          'task/cancel',
          'task/complete',
          'task/archive',
          'priority/set',
          'task/delete',
        },
      );
    });

    test('opening a session is the app’s own', () {
      expect(TaskAction.openSession.method, isNull);
      expect(TaskAction.answer.method, isNull);
    });
  });
}
