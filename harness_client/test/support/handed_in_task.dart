// A task whose work was handed in, for the tests of how its report is read:
// the session of the tool showcase (see `tool_showcase.dart`), which ends in
// a `hand_in` call, and the task that session is the session of, in review.
// The harness keeps one record of what was handed in, on the result of the
// call and on the task; the task here carries the very record that is on the
// call, so the two views of it can be told apart only by how they are drawn.
//
// It lives beside the fake harness and not in it: the fake harness is
// shared by almost every suite, and a task on its board changes what they
// count.

import 'package:harness_client/src/acp/acp_message.dart';

import 'fake_harness.dart';
import 'tool_showcase.dart';

const handedInTaskId = 'task-handed-in';
const handedInTaskName = 'Make the tool cards readable';

/// The task of the work that handed nothing in: its session replied instead
/// of calling `hand_in`.
const unreportedTaskId = 'task-unreported';
const unreportedTaskName = 'Rotate the signing keys';

/// What the last message of the session of [unreportedTaskId] said.
const unreportedLastMessage =
    'I rotated the keys on the build machine, but **could not reach** the '
    'registry to publish them, so nothing is handed in yet.';

/// The record on the result of the `hand_in` call of [session]: what the
/// harness kept of the work that was handed in.
Map<String, Object?> handedInRecord(
  FakeHarness harness, {
  String session = toolShowcaseId,
}) {
  for (final node in harness.nodes[session] ?? const <Map<String, Object?>>[]) {
    if (node['kind'] == 'tool-result' && node['call-id'] == 'call-hand-in') {
      return asMap(asMap(node['meta'])['report']);
    }
  }
  throw StateError('session $session handed nothing in');
}

/// When the work was handed in.  Fixed, not the time the test ran: a test
/// that opens the report twice compares the words of the two pages, and a
/// clock that ticks over a minute between the two would put another time on
/// the second.
final handedInAt = DateTime(2026, 10, 23, 14, 15);

/// The board of [harness] holds only [handedInTaskId], in review, and the
/// showcase session it is the session of is there to be opened.  The
/// report of the task is the record on the session's `hand_in` call.
void seedHandedInTask(FakeHarness harness) {
  harness.seedToolShowcase();
  // The record is the one the call and the task both carry.
  handedInRecord(harness)['at'] = handedInAt.millisecondsSinceEpoch / 1000;
  harness.tasks
    ..clear()
    ..[handedInTaskId] = _task(
      handedInTaskId,
      handedInTaskName,
      session: toolShowcaseId,
      report: handedInRecord(harness),
    );
}

/// [seedHandedInTask], and the harness can give the pictures the report
/// names (`session/image`): the screenshots a task that changed the app
/// hands in, which are screenshots of the app itself.  Run from
/// `harness_client`, as the tests are.
void seedHandedInTaskWithPictures(FakeHarness harness) {
  seedHandedInTask(harness);
  harness.seedShowcasePictures();
}

/// [handedInTaskId], and beside it [unreportedTaskId], in review as well,
/// whose round of work ended without a report: the harness recorded the last
/// message the session wrote instead (`missing`), and that message is the
/// last of the conversation the task opens to.
void seedUnreportedTask(FakeHarness harness) {
  seedHandedInTask(harness);
  final report = {
    'summary': unreportedLastMessage,
    'at': DateTime.now().millisecondsSinceEpoch / 1000,
    'missing': true,
  };
  harness.tasks[unreportedTaskId] = _task(
    unreportedTaskId,
    unreportedTaskName,
    report: report,
  );
  harness.seedHandIn(unreportedTaskId, report);
}

Map<String, Object?> _task(
  String id,
  String name, {
  String? session,
  required Map<String, Object?> report,
}) {
  final now = DateTime.now();
  return {
    'id': id,
    'name': name,
    'prompt': 'Do the work called "$name", and hand it in.',
    'state': 'review',
    'column': 'review',
    'priority': 'medium',
    'project': '/Users/noah/Code/emacs-agent-harness/',
    'cwd': '/Users/noah/Code/emacs-agent-harness/.worktrees/task-$id/',
    'branch': 'task/$id',
    if (session != null) 'session': session,
    'created':
        now.subtract(const Duration(hours: 1)).millisecondsSinceEpoch / 1000,
    'updated':
        now.subtract(const Duration(minutes: 5)).millisecondsSinceEpoch / 1000,
    'report': report,
  };
}
