// The review's asynchronous edges: a diff answer that arrives after the
// reviewer chose another version, a quiet refresh that arrives after a
// selection, a reconnect that lets the old page go.  None of them may put
// lines, marks or threads from one revision under another.  The fake
// harness holds an answer at `beforeAnswer`, so the order is exact rather
// than a race the test hopes to hit.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/acp/acp_client.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/review_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';
import 'support/fake_review.dart';

const _task = 'task-2';
const _file = 'lib/src/state/task_controller.dart';

class _Rig {
  _Rig(this.harness, this.app, this.controller);

  final FakeHarness harness;
  final AppController app;
  final ReviewController controller;
}

Future<_Rig> _rig() async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsController();
  await settings.load();
  final harness = FakeHarness(reviews: true);
  harness.reviewData = FakeReview(taskId: _task);
  final app = AppController(settings: settings, connector: harness.connector);
  await app.connect('ws://memory/acp');
  final task = await app.api!.task(_task);
  final controller = app.reviewFor(task)!;
  await controller.load();
  return _Rig(harness, app, controller);
}

/// One answer the fake harness holds until the test lets it go.
class _Gate {
  final Completer<void> _reached = Completer<void>();
  final Completer<void> _open = Completer<void>();

  Future<void> wait() {
    if (!_reached.isCompleted) _reached.complete();
    return _open.future;
  }

  Future<void> get reached => _reached.future;

  void release() {
    if (!_open.isCompleted) _open.complete();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a v1 diff that arrives after v2 is stale and never cached', (
    tester,
  ) async {
    final rig = await _rig();
    final controller = rig.controller;
    expect(await controller.selectVersion(reviewEarlier), isTrue);

    final gate = _Gate();
    rig.harness.beforeAnswer = (method, params) async {
      if (method == '_harness/patch-review/diff' &&
          params['version'] == reviewEarlier) {
        await gate.wait();
      }
    };

    final old = controller.diffFor(_file);
    final oldFails = expectLater(old, throwsA(isA<ReviewStale>()));
    await gate.reached;

    expect(await controller.selectVersion(null), isTrue);
    final current = await controller.diffFor(_file);
    expect(current.revision, reviewTip);

    gate.release();
    await oldFails;
    expect(controller.cachedDiff(_file)!.revision, reviewTip);
    expect(controller.cachedDiffAt(_file, reviewEarlier), isNull);
  });

  testWidgets('a v1 failure after v2 success leaves no error or cache', (
    tester,
  ) async {
    final rig = await _rig();
    final controller = rig.controller;
    expect(await controller.selectVersion(reviewEarlier), isTrue);

    final gate = _Gate();
    rig.harness.beforeAnswer = (method, params) async {
      if (method == '_harness/patch-review/diff' &&
          params['version'] == reviewEarlier) {
        await gate.wait();
        throw StateError('the old diff could not be read');
      }
    };

    final old = controller.diffFor(_file);
    final oldFails = expectLater(old, throwsA(isA<ReviewStale>()));
    await gate.reached;

    expect(await controller.selectVersion(null), isTrue);
    final current = await controller.diffFor(_file);
    expect(current.revision, reviewTip);

    gate.release();
    await oldFails;
    expect(controller.diffError(_file, revision: reviewEarlier), isNull);
    expect(controller.cachedDiff(_file)!.revision, reviewTip);
  });

  testWidgets('old cleanup cannot erase the newer request still in flight', (
    tester,
  ) async {
    final rig = await _rig();
    final controller = rig.controller;
    expect(await controller.selectVersion(reviewEarlier), isTrue);

    final oldGate = _Gate();
    final newGate = _Gate();
    rig.harness.beforeAnswer = (method, params) async {
      if (method != '_harness/patch-review/diff') return;
      if (params['version'] == reviewEarlier) await oldGate.wait();
      if (params['version'] == reviewTip) await newGate.wait();
    };

    final old = controller.diffFor(_file);
    final oldFails = expectLater(old, throwsA(isA<ReviewStale>()));
    await oldGate.reached;

    expect(await controller.selectVersion(null), isTrue);
    final fresh = controller.diffFor(_file);
    await newGate.reached;

    // The old answer cleans up after itself only.  The newer request is
    // still the one diffFor returns, and its loading state is untouched.
    oldGate.release();
    await oldFails;
    expect(identical(controller.diffFor(_file), fresh), isTrue);
    expect(controller.diffIsLoading(_file), isTrue);

    newGate.release();
    final diff = await fresh;
    expect(diff.revision, reviewTip);
    expect(controller.diffIsLoading(_file), isFalse);
    expect(controller.diffError(_file), isNull);
  });

  testWidgets('a quiet refresh cannot overwrite a version chosen meanwhile', (
    tester,
  ) async {
    final rig = await _rig();
    final controller = rig.controller;
    final gate = _Gate();
    var gateNext = true;
    rig.harness.beforeAnswer = (method, params) async {
      if (gateNext &&
          method == '_harness/patch-review/changes' &&
          params['version'] == null) {
        gateNext = false;
        await gate.wait();
      }
    };

    rig.harness.announce('patch-review/changed', [_task]);
    for (var i = 0; i < 20 && !gate._reached.isCompleted; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await gate.reached;

    expect(await controller.selectVersion(reviewEarlier), isTrue);
    gate.release();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(controller.selectedVersion, reviewEarlier);
    expect(controller.changes!.revision, reviewEarlier);
    expect(
      controller.changes!.file('lib/src/ui/removed_panel.dart'),
      isNotNull,
    );
    expect(
      controller.navigationFiles.any(
        (file) => file.path == 'lib/src/ui/removed_panel.dart',
      ),
      isTrue,
    );
    expect(controller.refreshing, isFalse);
  });

  testWidgets('a quiet refresh does not apply after a reconnect', (
    tester,
  ) async {
    final rig = await _rig();
    final old = rig.controller;
    final revision = old.changes!.revision;
    final gate = _Gate();
    var gateNext = true;
    rig.harness.beforeAnswer = (method, params) async {
      if (gateNext &&
          method == '_harness/patch-review/changes' &&
          params['version'] == null) {
        gateNext = false;
        await gate.wait();
      }
    };

    rig.harness.announce('patch-review/changed', [_task]);
    for (var i = 0; i < 20 && !gate._reached.isCompleted; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await gate.reached;

    await rig.app.disconnect();
    rig.harness.beforeAnswer = null;
    await rig.app.connect('ws://memory/acp');
    final task = await rig.app.api!.task(_task);
    final next = rig.app.reviewFor(task)!;
    await next.load();

    gate.release();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(old.isDisposed, isTrue);
    expect(old.changes!.revision, revision);
    expect(old.refreshing, isFalse);
    expect(next.changes!.revision, revision);
  });

  testWidgets('a reconnect lets the old review go without an answer', (
    tester,
  ) async {
    final rig = await _rig();
    final old = rig.controller;
    final revision = old.changes!.revision;

    final gate = _Gate();
    var gateNext = true;
    rig.harness.beforeAnswer = (method, params) async {
      if (gateNext &&
          method == '_harness/patch-review/changes' &&
          params['version'] == null) {
        gateNext = false;
        await gate.wait();
      }
    };
    final pending = old.load(force: true);
    await gate.reached;

    await rig.app.disconnect();
    rig.harness.beforeAnswer = null;
    await rig.app.connect('ws://memory/acp');
    final task = await rig.app.api!.task(_task);
    final next = rig.app.reviewFor(task)!;
    await next.load();

    expect(old.isDisposed, isTrue);
    gate.release();
    await pending;
    expect(old.isDisposed, isTrue);
    expect(old.changes!.revision, revision);
    expect(next.changes!.revision, revision);
  });

  testWidgets('a failed version change keeps the old files and drafts', (
    tester,
  ) async {
    final rig = await _rig();
    final controller = rig.controller;
    expect(await controller.selectVersion(reviewEarlier), isTrue);
    final file = controller.changes!.file(_file)!;
    final draft = controller.lineDraft(
      file: file,
      side: 'new',
      start: 118,
      revision: controller.changes!.revision,
    );
    draft.text = 'Still written against v1.';

    expect(await controller.selectVersion('no-such-version'), isFalse);
    expect(controller.selectedVersion, reviewEarlier);
    expect(controller.changes!.revision, reviewEarlier);
    expect(draft.revision, reviewEarlier);
    expect(draft.text, 'Still written against v1.');
  });

  testWidgets('the same path at two revisions keeps each revision\'s lines', (
    tester,
  ) async {
    final rig = await _rig();
    final controller = rig.controller;
    final v2 = await controller.diffFor(_file);
    expect(v2.revision, reviewTip);
    // A rename is read under the path it has now, and names the path it had.
    final renamed = await controller.diffFor('lib/src/ui/split_view.dart');
    expect(renamed.revision, reviewTip);
    expect(renamed.oldPath, 'lib/src/ui/old_view.dart');
    expect(controller.cachedDiff('lib/src/ui/split_view.dart'), isNotNull);

    expect(await controller.selectVersion(reviewEarlier), isTrue);
    // The answers of v2 are not v1's: the cache is the shown revision's.
    expect(controller.cachedDiffAt(_file, reviewTip), isNull);
    expect(controller.cachedDiff('lib/src/ui/split_view.dart'), isNull);
    final v1 = await controller.diffFor(_file);
    expect(v1.revision, reviewEarlier);
    expect(controller.cachedDiff(_file)!.revision, reviewEarlier);
    expect(controller.cachedDiffAt(_file, reviewEarlier), isNotNull);

    // A path the newest version dropped is a file of v1 only: its failure
    // under v2 is not kept as v1's, and v1 still reads it.
    expect(await controller.selectVersion(null), isTrue);
    Object? failure;
    try {
      await controller.diffFor('lib/src/ui/removed_panel.dart');
    } catch (error) {
      failure = error;
    }
    expect(failure, isA<AcpException>());
    expect(
      controller.diffError('lib/src/ui/removed_panel.dart'),
      contains('No such file'),
    );
    expect(await controller.selectVersion(reviewEarlier), isTrue);
    final retired = await controller.diffFor('lib/src/ui/removed_panel.dart');
    expect(retired.revision, reviewEarlier);
    expect(controller.cachedDiff('lib/src/ui/removed_panel.dart'), isNotNull);
  });

  testWidgets('a comment from v1 stays at v1 and leaves v2 approval alone', (
    tester,
  ) async {
    final rig = await _rig();
    final controller = rig.controller;
    final newest = controller.changes!.file(_file)!;
    expect(await controller.setApproved(newest, true), isTrue);
    final approvedBefore = rig.harness.reviewData.approved.length;

    expect(await controller.selectVersion(reviewEarlier), isTrue);
    final v1 = await controller.diffFor(_file);
    final draft = controller.lineDraft(
      file: controller.changes!.file(_file)!,
      side: 'new',
      start: 118,
      revision: v1.revision,
      diff: v1,
    );
    draft.text = 'The line as v1 had it.';
    expect(draft.revision, reviewEarlier);
    expect(draft.location!.excerpt, contains('one pass'));

    expect(await controller.selectVersion(null), isTrue);
    expect(await controller.saveDraft(draft.key), isTrue);
    expect(controller.viewed.isApproved(newest), isTrue);
    expect(rig.harness.reviewData.approved.length, approvedBefore);
    final thread = controller.set!.threads.firstWhere(
      (thread) => thread.comments.any(
        (comment) => comment.body == 'The line as v1 had it.',
      ),
    );
    expect(thread.revision, reviewEarlier);
  });

  testWidgets('a thread refresh after a version choice does not overwrite it', (
    tester,
  ) async {
    final rig = await _rig();
    final controller = rig.controller;
    final thread = controller.thread('t-chat')!;
    final gate = _Gate();
    var gateNext = true;
    rig.harness.beforeAnswer = (method, params) async {
      if (gateNext && method == '_harness/patch-review/get') {
        gateNext = false;
        await gate.wait();
      }
    };

    final operation = controller.setThreadStatus(thread, false);
    await gate.reached;
    expect(await controller.selectVersion(reviewEarlier), isTrue);

    // This answer arrives from before the choice: its thread must not enter
    // the set the chosen version read.
    rig.harness.reviewData.threads.add({
      'id': 't-late',
      'status': 'open',
      'comments': <Map<String, Object?>>[],
      'history': <Map<String, Object?>>[],
    });
    gate.release();
    await operation;
    expect(controller.set!.threads.any((t) => t.id == 't-late'), isFalse);
    expect(controller.selectedVersion, reviewEarlier);
  });
}
