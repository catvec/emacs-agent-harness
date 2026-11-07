// The review against a real harness: the Emacs one, with its demo provider,
// over ACP as the app talks to it.
//
//   tool/with_real_harness.sh flutter test test/review_real_harness_test.dart
//
// It is skipped without HARNESS_REAL_ADDRESS and HARNESS_REAL_CWD.  The
// fixture directory must be given explicitly: an empty directory outside any
// repository, which the test makes a project of.  A run that has only an
// address writes nowhere rather than in the checkout it was started from.
// The fake harness says what the review is believed to answer; this is the
// review answering: a task whose branch is committed to, the files and a
// file's patch read at that revision, a comment written through
// `patch-review/apply` at the revision it was read at, a second client of
// the same harness seeing the same thread, and the thread still there after
// the first client's connection went and came back.  The data is the
// harness's; nothing is kept on the phone.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/models/review.dart';
import 'package:harness_client/src/models/task.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final address = Platform.environment['HARNESS_REAL_ADDRESS'];
  final token = Platform.environment['HARNESS_REAL_TOKEN'] ?? '';
  final fixture = Platform.environment['HARNESS_REAL_CWD'] ?? '';
  final skip = address == null || address.isEmpty
      ? 'HARNESS_REAL_ADDRESS names no running harness'
      : fixture.trim().isEmpty
      ? 'HARNESS_REAL_CWD names no isolated fixture directory'
      : false;

  /// The fixture is a directory of its own, empty, and no part of a
  /// repository: the test makes a project of it and writes nothing outside.
  /// A path that could be the checkout is refused before any file is made.
  String? fixtureProblem() {
    final directory = Directory(fixture);
    if (!directory.existsSync()) {
      return 'HARNESS_REAL_CWD is not a directory: $fixture';
    }
    if (directory.listSync().isNotEmpty) {
      return 'HARNESS_REAL_CWD is not empty: $fixture';
    }
    var parent = directory.absolute.parent;
    while (parent.path != parent.parent.path) {
      if (Directory('${parent.path}/.git').existsSync() ||
          File('${parent.path}/.git').existsSync()) {
        return 'HARNESS_REAL_CWD is inside a repository: $fixture';
      }
      parent = parent.parent;
    }
    return null;
  }

  late AppController app;
  late String project;
  late String taskId;
  late String worktree;
  late String branch;
  late ReviewChanges changes;
  late String commentId;
  late String replyId;
  late String threadId;

  ReviewChanges? changesOrNull;
  Future<ReviewChanges?> readChanges() async {
    try {
      changesOrNull = await app.api!.reviewChanges(taskId);
      return changesOrNull;
    } catch (_) {
      return null;
    }
  }

  Future<void> git(List<String> arguments, {String? inDirectory}) async {
    final result = await Process.run('git', [
      '-C',
      inDirectory ?? project,
      '-c',
      'user.name=probe',
      '-c',
      'user.email=probe@example.invalid',
      ...arguments,
    ]);
    if (result.exitCode != 0) {
      fail('git $arguments: ${result.stdout}\n${result.stderr}');
    }
  }

  Future<void> write(String path, String text) async {
    final file = File(path);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(text);
  }

  setUpAll(() async {
    if (skip != false) return;
    final problem = fixtureProblem();
    if (problem != null) fail(problem);
    project = Directory(fixture).absolute.path;
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsController();
    await settings.load();
    app = AppController(settings: settings);
    await app.connect(address!, token: token);
    expect(
      app.isConnected,
      isTrue,
      reason: '${app.phase.name}: ${app.error ?? app.resumeError}',
    );
    await git(['init', '-q', '-b', 'main']);
    await write('$project/README.md', '# The project\n\nA parser.\n');
    await git(['add', '-A']);
    await git(['commit', '-q', '-m', 'Start the project']);
    // A task works in a worktree of the project, and its branch is what a
    // review reads.
    final task = await app.api!.submitTask(
      cwd: project,
      prompt: 'Write the parser docs',
    );
    taskId = task.id;
    // The queue may have started it already, when a slot was free.
    try {
      await app.api!.startTask(taskId);
    } catch (failure) {
      if (!'$failure'.contains('already started')) rethrow;
    }
    HarnessTask? current;
    for (var i = 0; i < 300; i++) {
      current = await app.api!.task(taskId);
      if ((current.worktree ?? '').isNotEmpty &&
          (current.branch ?? '').isNotEmpty) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    worktree = current?.worktree ?? '';
    branch = current?.branch ?? '';
    if (worktree.isEmpty || branch.isEmpty) {
      fail('the task has no branch or worktree: ${current?.columnName}');
    }
    // A commit of our own on the task's branch: the review reads it.
    await write(
      '$worktree/lib/parser.dart',
      'class Parser {\n'
          '  String parse(String text) => text.trim();\n'
          '}\n',
    );
    await write('$worktree/doc/parser.md', '# Parser\n\nIt reads a line.\n');
    await git(['add', '-A'], inDirectory: worktree);
    await git(['commit', '-q', '-m', 'Add the parser'], inDirectory: worktree);
    for (var i = 0; i < 300; i++) {
      if (await readChanges() != null) break;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (changesOrNull == null) {
      fail('the review did not read the branch');
    }
  });

  tearDownAll(() async {
    if (skip != false) return;
    await app.disconnect();
  });

  test('the harness offers the review the app uses', () {
    final api = app.api!;
    expect(api.can('patch-review/get'), isTrue);
    expect(api.can('patch-review/changes'), isTrue);
    expect(api.can('patch-review/diff'), isTrue);
    expect(api.can('patch-review/apply'), isTrue);
    expect(api.can('patch-review/viewed'), isTrue);
    expect(api.can('patch-review/set-viewed'), isTrue);
  }, skip: skip);

  test('reads the files and one patch at the task revision', () async {
    changes = await readChanges() ?? (await app.api!.reviewChanges(taskId));
    expect(changes.taskId, taskId);
    expect(changes.files, isNotEmpty);
    expect(changes.revision, isNotEmpty);
    final parser = changes.file('lib/parser.dart');
    expect(parser, isNotNull);
    final patch = await app.api!.reviewDiff(taskId, 'lib/parser.dart');
    expect(patch.revision, changes.revision);
    expect(patch.patch, contains('class Parser'));
    expect(patch.hunks, isNotEmpty);
    expect(patch.hunks.first.lines, isNotEmpty);
  }, skip: skip);

  test(
    'a comment is written at the revision and seen by another client',
    () async {
      final controller = app.reviewFor(await app.api!.task(taskId))!;
      await controller.load();
      final file = controller.changes!.file('lib/parser.dart')!;
      final draft = controller.lineDraft(file: file, side: 'new', start: 1);
      draft.text = 'The parser should keep the newline it takes off.';
      expect(await controller.saveDraft(draft.key), isTrue);
      final set = controller.set!;
      final thread = set.threads.firstWhere(
        (thread) =>
            thread.comments.any((comment) => comment.body == draft.text),
      );
      threadId = thread.id;
      commentId = thread.comments
          .firstWhere((comment) => comment.body == draft.text)
          .id;
      expect(thread.revision, controller.changes!.revision);
      expect(thread.location!.file, 'lib/parser.dart');
      // A reply is a comment of the same thread, answering the first.
      final reply = controller.replyDraft(thread);
      reply.text = 'The parser keeps the newline, and the test says so.';
      reply.replyTo = commentId;
      expect(await controller.saveDraft(reply.key), isTrue);
      final reading = (await app.api!.review(taskId)).thread(threadId)!;
      replyId = reading.comments
          .firstWhere(
            (comment) =>
                comment.body ==
                'The parser keeps the newline, and the test says so.',
          )
          .id;
      expect(
        reading.comments.any((comment) => comment.replyTo == commentId),
        isTrue,
      );

      // A second phone, connected to the same harness, reads the same thread.
      final otherApp = AppController(settings: app.settings);
      await otherApp.connect(address!, token: token);
      addTearDown(otherApp.disconnect);
      final other = otherApp.reviewFor(await otherApp.api!.task(taskId))!;
      await other.load();
      final otherThread = other.set!.threads.firstWhere(
        (thread) =>
            thread.comments.any((comment) => comment.body == draft.text),
      );
      expect(
        otherThread.comments.any((comment) => comment.id == replyId),
        isTrue,
        reason: 'the reply is the harness\'s, and a second client reads it',
      );
      expect(
        otherThread.comments
            .firstWhere((comment) => comment.id == replyId)
            .replyTo,
        commentId,
      );
    },
    skip: skip,
  );

  test('the thread is there after the connection went and came back', () async {
    await app.disconnect();
    await app.connect(address!, token: token);
    final controller = app.reviewFor(await app.api!.task(taskId))!;
    await controller.load();
    final thread = controller.thread(threadId);
    expect(thread, isNotNull);
    expect(thread!.comments.any((comment) => comment.id == commentId), isTrue);
    expect(thread.revision, changes.revision);
  }, skip: skip);

  test('a draft with no words goes with the feedback, once', () async {
    final controller = app.reviewFor(await app.api!.task(taskId))!;
    await controller.load();
    final file = controller.changes!.file('lib/parser.dart')!;
    final draft = controller.lineDraft(file: file, side: 'new', start: 1);
    draft.text = 'This is a reply with no words beside it.';
    expect(await controller.saveDraft(draft.key), isTrue);
    expect(await controller.send(), isTrue);
    // The same draft is not sent a second time: there is nothing left.
    expect(await controller.send(), isFalse);
    final set = await app.api!.review(taskId);
    final comment = set.threads
        .expand((thread) => thread.comments)
        .firstWhere(
          (comment) =>
              comment.body == 'This is a reply with no words beside it.',
        );
    expect(comment.sent, isNotNull);
    expect(comment.isDraft, isFalse);
  }, skip: skip);

  test('closing the thread is recorded, and it stays readable', () async {
    final controller = app.reviewFor(await app.api!.task(taskId))!;
    await controller.load();
    final thread = controller.thread(threadId)!;
    expect(await controller.setThreadStatus(thread, false), isTrue);
    final read = await app.api!.review(taskId);
    final closed = read.thread(threadId)!;
    expect(closed.isClosed, isTrue);
    expect(closed.closing!.author!.isUser, isTrue);
    expect(closed.comments.length, greaterThan(0));
  }, skip: skip);
}
