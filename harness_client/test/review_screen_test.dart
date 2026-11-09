// The change review on a phone: the files of a hand-in, their unified diff,
// the threads on it, and the feedback that goes back.
//
// The harness is the fake one, answering the same shapes the real review
// does (`test/support/fake_review.dart`): two revisions, threads at both, one
// closed by an agent and unseen, one draft, a rename, a deletion, a binary
// file and a phone's worth of changed files.  What is checked is what the
// person sees and what the app sends: the files, the lines and their numbers,
// the markers on them, the comment on an exact range recorded at the
// revision it was read at, the reply and the resolve, the marks withdrawn by
// a comment, and the feedback or replies that leave the phone once.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/acp/acp_message.dart';
import 'package:harness_client/src/models/review.dart';
import 'package:harness_client/src/models/task.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:harness_client/src/ui/adaptive/platform_style.dart';
import 'package:harness_client/src/ui/screens/review_file_screen.dart';
import 'package:harness_client/src/ui/screens/review_screen.dart';
import 'package:harness_client/src/ui/screens/review_thread_screen.dart';
import 'package:harness_client/src/ui/theme/harness_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';
import 'support/fake_review.dart';

const _reviewTask = 'task-2';
const _workingTask = 'task-1';

class _Rig {
  _Rig(this.settings, this.harness, this.app, this.task);
  final SettingsController settings;
  final FakeHarness harness;
  final AppController app;
  final HarnessTask task;
}

Future<_Rig> _rig({
  String taskId = _reviewTask,
  void Function(FakeHarness harness)? arrange,
}) async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsController();
  await settings.load();
  final harness = FakeHarness(reviews: true);
  harness.reviewData = FakeReview(taskId: taskId);
  arrange?.call(harness);
  final app = AppController(settings: settings, connector: harness.connector);
  await app.connect('ws://memory/acp');
  final task = await app.api!.task(taskId);
  return _Rig(settings, harness, app, task);
}

Future<void> _settle(WidgetTester tester, [int rounds = 12]) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

Future<void> _pump(
  WidgetTester tester,
  _Rig rig, {
  Widget? home,
  double width = 390,
  double height = 844,
  double textScale = 1,
  Brightness brightness = Brightness.light,
}) async {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(
    HarnessStyle(
      style: HarnessPlatformStyle.material,
      child: MaterialApp(
        theme: HarnessTheme.material(brightness),
        home: home ?? ReviewScreen(app: rig.app, task: rig.task),
      ),
    ),
  );
  await tester.pump();
  await _settle(tester);
}

Future<void> _openFile(WidgetTester tester, String path) async {
  await tester.tap(find.byTooltip('Search files'));
  await tester.pump();
  await tester.enterText(
    find.byKey(const ValueKey('review-file-search')),
    path,
  );
  await _settle(tester, 4);
  await tester.tap(find.byKey(ValueKey('review-file-$path')));
  await _settle(tester);
}

/// A file's page drawn from the controller, without going through the list:
/// a test about the diff itself.
Future<void> _pumpFile(
  WidgetTester tester,
  _Rig rig,
  String path, {
  double width = 390,
  double height = 844,
  double textScale = 1,
}) async {
  final controller = rig.app.reviewFor(rig.task)!;
  await controller.load();
  await controller.diffFor(path);
  await _pump(
    tester,
    rig,
    width: width,
    height: height,
    textScale: textScale,
    home: ReviewFileScreen(controller: controller, path: path),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a review says its revision, files, marks and threads', (
    tester,
  ) async {
    final rig = await _rig();
    await _pump(tester, rig);
    expect(find.text('Review the emulator screenshots'), findsOneWidget);
    expect(find.text('Files'), findsOneWidget);
    expect(find.text('34'), findsOneWidget);
    expect(find.text('Threads'), findsOneWidget);
    expect(find.text('6'), findsOneWidget);
    expect(find.text('v2 · 9a8b7c6'), findsOneWidget);
    expect(find.text('34 files · +556 −120'), findsOneWidget);
    expect(find.text('2/34 viewed'), findsOneWidget);
    expect(find.text('1/34 approved'), findsOneWidget);
    expect(find.text('4 open · 1 to review'), findsOneWidget);
    expect(find.text('1 draft'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('review-feedback-button')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a 320 phone and a doubled text size draw no overflow', (
    tester,
  ) async {
    final rig = await _rig();
    await _pump(tester, rig, width: 320, textScale: 2);
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('review-files')), findsOneWidget);
    // The list goes to its end: the threads on the change as a whole.
    await tester.drag(
      find.byKey(const ValueKey('review-files')),
      const Offset(0, -6000),
    );
    await _settle(tester, 6);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a diff and a thread at 320 with doubled text draw no overflow', (
    tester,
  ) async {
    final rig = await _rig();
    final controller = rig.app.reviewFor(rig.task)!;
    await controller.load();
    await controller.diffFor('lib/src/ui/chat_screen.dart');
    await _pump(
      tester,
      rig,
      width: 320,
      textScale: 2,
      home: ReviewFileScreen(
        controller: controller,
        path: 'lib/src/ui/chat_screen.dart',
      ),
    );
    expect(find.byKey(const ValueKey('review-diff')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _pump(
      tester,
      rig,
      width: 320,
      textScale: 2,
      home: ReviewThreadScreen(controller: controller, threadId: 't-long'),
    );
    expect(find.byKey(const ValueKey('review-thread')), findsOneWidget);
    expect(find.byKey(const ValueKey('thread-reply-field')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a file opens its diff with numbers, hunks and markers', (
    tester,
  ) async {
    final rig = await _rig();
    await _pump(tester, rig);
    await _openFile(tester, 'lib/src/ui/chat_screen.dart');
    expect(find.text('chat_screen.dart'), findsOneWidget);
    expect(find.byKey(const ValueKey('review-diff')), findsOneWidget);
    expect(find.text('Hunk 1/2'), findsOneWidget);
    expect(find.textContaining('@@ -36,9 +36,12 @@'), findsOneWidget);
    expect(
      find.textContaining('_Composer(controller: _controller),'),
      findsOneWidget,
    );
    // Two threads are on this file, at two lines, and each is marked where it
    // is: the one on 42–44, and the question on line 40.
    expect(find.byKey(const ValueKey('diff-threads-t-chat')), findsOneWidget);
    expect(find.byKey(const ValueKey('diff-threads-t-long')), findsOneWidget);
    expect(find.text('Open'), findsWidgets);
    // Line numbers on both sides are there, and the deleted side says so
    // beyond colour: the prefix is a character, not a tint.
    expect(find.byKey(const ValueKey('diff-line-42-added')), findsOneWidget);
    expect(find.byKey(const ValueKey('diff-line-o38-deleted')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a range of lines is commented at the revision shown', (
    tester,
  ) async {
    final rig = await _rig();
    await _pumpFile(tester, rig, 'lib/src/ui/chat_screen.dart');
    await tester.tap(find.byKey(const ValueKey('diff-select-lines')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('diff-line-42-added')));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('diff-comment-selection')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('diff-comment-selection')));
    await _settle(tester, 6);
    expect(find.text('Comment'), findsWidgets);
    expect(find.byKey(const ValueKey('review-composer-field')), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('review-composer-field')),
      'The composer should not cover the last message.',
    );
    await tester.tap(find.byKey(const ValueKey('review-composer-save')));
    await _settle(tester);
    final op = rig.harness.reviewData.operations.last;
    expect(op['op'], 'add-comment');
    final comment = asMap(op['comment']);
    expect(comment['body'], 'The composer should not cover the last message.');
    expect(comment['revision'], reviewTip);
    expect(comment['sent'], isNull);
    final location = asMap(comment['location']);
    expect(location['file'], 'lib/src/ui/chat_screen.dart');
    expect(location['side'] ?? 'new', 'new');
    expect(location['line'], isNotNull);
    expect(
      rig.harness.reviewData.threads.any((thread) {
        final comments = thread['comments'] as List;
        return comments.any(
          (comment) =>
              (comment as Map)['body'] ==
              'The composer should not cover the last message.',
        );
      }),
      isTrue,
    );
  });

  testWidgets('a new thread on a file needs no line picked', (tester) async {
    final rig = await _rig();
    await _pumpFile(tester, rig, 'lib/src/ui/chat_screen.dart');
    expect(
      find.byKey(const ValueKey('review-file-new-thread')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('review-file-new-thread')));
    await _settle(tester, 6);
    // The page says what is written, and the thread's place is the file.
    expect(find.text('New thread'), findsWidgets);
    expect(find.text('Comment'), findsWidgets);
    await tester.enterText(
      find.byKey(const ValueKey('review-composer-field')),
      'The whole file needs a pass.',
    );
    await tester.tap(find.byKey(const ValueKey('review-composer-save')));
    await _settle(tester);
    final op = rig.harness.reviewData.operations.last;
    expect(op['op'], 'add-comment');
    final comment = asMap(op['comment']);
    expect(comment['body'], 'The whole file needs a pass.');
    expect(comment['revision'], reviewTip);
    final location = asMap(comment['location']);
    expect(location['file'], 'lib/src/ui/chat_screen.dart');
    expect(location.containsKey('line'), isFalse);
    expect(location.containsKey('end-line'), isFalse);
    expect(
      rig.harness.reviewData.threads.any((thread) {
        final comments = thread['comments'] as List;
        return comments.any(
          (comment) =>
              (comment as Map)['body'] == 'The whole file needs a pass.',
        );
      }),
      isTrue,
    );
  });

  testWidgets('a new thread on the change starts from the review', (
    tester,
  ) async {
    final rig = await _rig();
    await _pump(tester, rig);
    await tester.tap(find.byKey(const ValueKey('review-new-thread')));
    await _settle(tester, 6);
    expect(find.text('New thread'), findsOneWidget);
    expect(find.text('The change'), findsWidgets);
    await tester.enterText(
      find.byKey(const ValueKey('review-composer-field')),
      'The change misses its tests.',
    );
    await tester.tap(find.byKey(const ValueKey('review-composer-save')));
    await _settle(tester);
    final op = rig.harness.reviewData.operations.last;
    expect(op['op'], 'add-comment');
    final comment = asMap(op['comment']);
    expect(comment['body'], 'The change misses its tests.');
    expect(comment['revision'], reviewTip);
    expect(comment.containsKey('location'), isFalse);
  });

  testWidgets('the threads tab starts a thread of its own', (tester) async {
    final rig = await _rig();
    await _pump(tester, rig);
    await tester.tap(find.text('Threads'));
    await _settle(tester, 6);
    final button = find.byKey(const ValueKey('review-new-thread'));
    expect(button, findsOneWidget);
    await tester.tap(button);
    await _settle(tester, 6);
    expect(find.byKey(const ValueKey('review-composer-field')), findsOneWidget);
    expect(find.text('New thread'), findsOneWidget);
  });

  testWidgets('a file thread and a change thread are two drafts', (
    tester,
  ) async {
    final rig = await _rig();
    final controller = rig.app.reviewFor(rig.task)!;
    await controller.load();
    final file = controller.changes!.file('lib/src/ui/chat_screen.dart')!;
    final onFile = controller.newThreadDraft(file: file);
    final onChange = controller.newThreadDraft();
    expect(onFile.key, isNot(onChange.key));
    expect(onFile.location!.file, file.path);
    expect(onFile.location!.line, isNull);
    expect(onChange.location, isNull);
    onFile.text = 'About the file.';
    expect(onChange.text, isEmpty);
    expect(controller.localDrafts.length, 1);
  });

  testWidgets('a wide diff names its controls in words', (tester) async {
    final rig = await _rig();
    await _pumpFile(tester, rig, 'lib/src/ui/chat_screen.dart', width: 900);
    expect(find.text('Comment on lines'), findsOneWidget);
    expect(find.text('Wrap lines'), findsOneWidget);
    expect(find.text('Split view'), findsOneWidget);
    // Each control keeps its word when it is on.
    await tester.tap(find.byKey(const ValueKey('diff-wrap')));
    await tester.pump();
    expect(find.text('No wrap'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('diff-split')));
    await _settle(tester, 4);
    expect(find.text('Unified view'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await _pumpFile(tester, rig, 'lib/src/ui/chat_screen.dart', width: 320);
    expect(find.byTooltip('Line selection'), findsOneWidget);
    expect(find.text('Comment on lines'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a comment on an approved file takes the approval off', (
    tester,
  ) async {
    final rig = await _rig();
    await _pumpFile(tester, rig, 'lib/src/state/task_controller.dart');
    await tester.tap(find.byKey(const ValueKey('diff-select-lines')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('diff-line-o117-deleted')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('diff-comment-selection')));
    await _settle(tester, 6);
    await tester.enterText(
      find.byKey(const ValueKey('review-composer-field')),
      'Keep the notify batched.',
    );
    await tester.tap(find.byKey(const ValueKey('review-composer-save')));
    await _settle(tester);
    expect(rig.harness.reviewData.approved, isEmpty);
    expect(
      rig.harness.reviewData.operations.any(
        (op) => op['op'] == 'set-viewed' || op['op'] == 'seen',
      ),
      isFalse,
      reason: 'the mark comes off by `patch-review/set-viewed`, not an op',
    );
  });

  testWidgets('a thread is read, quoted, answered and resolved', (
    tester,
  ) async {
    final rig = await _rig();
    await _pumpFile(tester, rig, 'lib/src/ui/chat_screen.dart');
    await tester.tap(find.byKey(const ValueKey('diff-threads-t-chat')));
    await _settle(tester, 6);
    expect(find.text('Thread'), findsOneWidget);
    expect(
      find.textContaining('The composer covers the last message'),
      findsOneWidget,
    );
    expect(find.textContaining('The inset is applied twice'), findsOneWidget);
    // Quote puts the comment, quoted, in the box, and the reply records what
    // it answers.
    await tester.tap(find.byKey(const ValueKey('thread-reply-quote')));
    await tester.pump();
    final controller = rig.app.reviewFor(rig.task)!;
    final draft = controller.replyDraft(controller.thread('t-chat')!);
    expect(draft.text, startsWith('> Agent:'));
    expect(draft.replyTo, 'c-chat-2');
    await tester.enterText(
      find.byKey(const ValueKey('thread-reply-field')),
      '${draft.text}Check on a 320 screen too.',
    );
    await tester.tap(find.byKey(const ValueKey('thread-reply-save')));
    await _settle(tester, 8);
    final op = rig.harness.reviewData.operations.last;
    expect(op['op'], 'add-comment');
    expect(asMap(op['comment'])['thread'], 't-chat');
    expect(asMap(op['comment'])['reply-to'], 'c-chat-2');
    expect(asMap(op['comment'])['revision'], reviewTip);
    // Resolve closes it in the harness, and the close is the user's.
    for (var i = 0; i < 8; i++) {
      if (find.byKey(const ValueKey('thread-resolve')).evaluate().isNotEmpty) {
        break;
      }
      await tester.drag(
        find.byKey(const ValueKey('review-thread')),
        const Offset(0, -300),
      );
      await tester.pump();
    }
    await tester.tap(find.byKey(const ValueKey('thread-resolve')));
    await _settle(tester, 8);
    final status = rig.harness.reviewData.operations.last;
    expect(status['op'], 'set-status');
    expect(status['thread'], 't-chat');
    expect(status['status'], 'closed');
    expect(
      (rig.harness.reviewData.threads.firstWhere(
        (thread) => thread['id'] == 't-chat',
      )['status']),
      'closed',
    );
  });

  testWidgets('a closed thread stays readable, at its earlier revision', (
    tester,
  ) async {
    final rig = await _rig();
    await _pump(tester, rig);
    await tester.tap(find.text('Threads'));
    await _settle(tester, 6);
    expect(find.byKey(const ValueKey('review-threads')), findsOneWidget);
    await tester.tap(find.text('To review'));
    await _settle(tester, 4);
    expect(find.text('Earlier revision'), findsWidgets);
    expect(find.text('To review'), findsWidgets);
    expect(rig.app.reviewFor(rig.task)!.thread('t-task')!.isClosed, isTrue);
    await tester.tap(find.textContaining('This re-reads every task'));
    await _settle(tester, 6);
    expect(find.text('Thread'), findsOneWidget);
    expect(find.textContaining('This re-reads every task'), findsOneWidget);
    expect(find.textContaining('Agreed. It is read once'), findsOneWidget);
    // The thread is at its own revision, and the header says so.
    expect(find.text('Earlier revision'), findsOneWidget);
    // It is closed, and can be opened again: a new point is not the old
    // close.
    expect(find.text('To review'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('thread-reopen')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('thread-reopen')));
    await _settle(tester, 8);
    expect(rig.harness.reviewData.operations.last['op'], 'set-status');
    expect(rig.harness.reviewData.operations.last['status'], 'open');
  });

  testWidgets('a review to verify sends the feedback once', (tester) async {
    final rig = await _rig();
    await _pump(tester, rig);
    await tester.tap(find.byKey(const ValueKey('review-feedback-button')));
    await _settle(tester, 6);
    expect(find.text('Feedback'), findsWidgets);
    expect(find.byKey(const ValueKey('review-feedback-field')), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('review-feedback-field')),
      'One more pass on the keyboard inset, then this can merge.',
    );
    await tester.tap(find.byKey(const ValueKey('review-feedback-send')));
    await tester.tap(find.byKey(const ValueKey('review-feedback-send')));
    await _settle(tester, 10);
    expect(
      rig.harness.requests
          .where((request) => request.$1 == '_harness/task/reject')
          .length,
      1,
    );
    final request = rig.harness.requests.lastWhere(
      (request) => request.$1 == '_harness/task/reject',
    );
    expect(
      asString(request.$2['feedback']),
      contains('One more pass on the keyboard inset'),
    );
  });

  testWidgets('a task at work sends replies only, and no rejection', (
    tester,
  ) async {
    final rig = await _rig(taskId: _workingTask);
    await _pump(tester, rig);
    expect(find.text('Replies'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('review-feedback-button')));
    await _settle(tester, 6);
    await tester.enterText(
      find.byKey(const ValueKey('review-feedback-field')),
      'The board still flashes when a column changes.',
    );
    await tester.tap(find.byKey(const ValueKey('review-feedback-send')));
    await _settle(tester, 10);
    expect(rig.harness.reviewData.sends, 1);
    expect(
      rig.harness.reviewData.operations.any((op) {
        return op['op'] == 'add-comment';
      }),
      isTrue,
    );
    expect(
      rig.harness.requests.any(
        (request) => request.$1 == '_harness/task/reject',
      ),
      isFalse,
    );
  });

  testWidgets('the copy of each state is the phrase it was written as', (
    tester,
  ) async {
    final rig = await _rig();
    await _pump(tester, rig);
    // The files: their tabs, the revision, the counts and the marks.
    expect(find.text('Files'), findsOneWidget);
    expect(find.text('Threads'), findsOneWidget);
    expect(find.text('v2 · 9a8b7c6'), findsOneWidget);
    expect(find.text('34 files · +556 −120'), findsOneWidget);
    expect(find.text('4 open · 1 to review'), findsOneWidget);
    expect(find.byTooltip('Search files'), findsOneWidget);
    expect(find.byTooltip('Refresh review'), findsOneWidget);
    expect(find.byTooltip('Review actions'), findsOneWidget);
    expect(find.byTooltip('Flat list'), findsOneWidget);
    expect(find.byTooltip('Skip approved: on'), findsOneWidget);
    // The page a search finds nothing on.
    await tester.tap(find.byTooltip('Search files'));
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('review-file-search')),
      'no-such-file',
    );
    await _settle(tester, 4);
    expect(find.text('No files'), findsOneWidget);
    expect(find.text('No matching file'), findsOneWidget);
    await tester.tap(find.byTooltip('Hide file search'));
    await _settle(tester, 3);
    // The feedback, with the drafts and the words.
    await tester.tap(find.byKey(const ValueKey('review-feedback-button')));
    await _settle(tester, 6);
    expect(find.text('DRAFTS'), findsOneWidget);
    expect(find.text('WORDS'), findsOneWidget);
    expect(find.text('Markdown'), findsOneWidget);
    expect(find.text('Task back · drafts attached'), findsOneWidget);
    expect(find.text('Replies only'), findsOneWidget);
    expect(find.text('Send feedback'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await _settle(tester, 3);
    // A file: what it is, and the controls that say what they do.
    await _openFile(tester, 'lib/src/ui/chat_screen.dart');
    expect(find.text('Modified'), findsOneWidget);
    expect(find.text('+18 −7'), findsOneWidget);
    expect(find.byTooltip('Previous file'), findsOneWidget);
    expect(find.byTooltip('Next file'), findsOneWidget);
    expect(find.text('Viewed'), findsOneWidget);
    expect(find.text('Not approved'), findsOneWidget);
    expect(find.text('Threads'), findsOneWidget);
    expect(find.byTooltip('Line selection'), findsOneWidget);
    expect(find.byTooltip('Wrap lines'), findsOneWidget);
    expect(find.byTooltip('Previous hunk'), findsOneWidget);
    expect(find.byTooltip('Next hunk'), findsOneWidget);
    expect(find.text('Hunk 1/2'), findsOneWidget);
    // The comment that is being written.
    await tester.tap(find.byKey(const ValueKey('diff-select-lines')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('diff-line-42-added')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('diff-comment-selection')));
    await _settle(tester, 6);
    expect(find.text('Comment'), findsWidgets);
    expect(find.text('Draft'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
    expect(find.text('Save'), findsOneWidget);
  });

  testWidgets('a file sits under the directory that holds it, in either view', (
    tester,
  ) async {
    final rig = await _rig();
    await _pump(tester, rig);

    // The tree opens: the control offers the flat list, and shows one.
    expect(find.byTooltip('Flat list'), findsOneWidget);
    expect(find.byIcon(Icons.view_list_outlined), findsOneWidget);
    expect(find.byIcon(Icons.account_tree_outlined), findsNothing);

    // A directory and the rows under it take the same step in.
    final docsName = tester.getTopLeft(
      find.descendant(
        of: find.byKey(const ValueKey('review-dir-docs')),
        matching: find.text('docs'),
      ),
    );
    final srcName = tester.getTopLeft(
      find.descendant(
        of: find.byKey(const ValueKey('review-dir-lib/src')),
        matching: find.text('src'),
      ),
    );
    expect(srcName.dx - docsName.dx, 12);
    // The first thing in a file's row is set in by the file's depth.
    expect(
      tester
          .getTopLeft(
            find.byKey(const ValueKey('review-file-status-docs/logo.png')),
          )
          .dx,
      HarnessSpace.gutter + 12,
    );
    expect(
      tester
          .getTopLeft(
            find.byKey(
              const ValueKey(
                'review-file-status-lib/src/features/feature_00/widget.dart',
              ),
            ),
          )
          .dx,
      HarnessSpace.gutter + 4 * 12,
    );

    // The flat list is flat: every file starts at the edge, and the control
    // now offers the tree, with the tree's own icon.
    await tester.tap(find.byTooltip('Flat list'));
    await _settle(tester, 4);
    expect(find.byTooltip('File tree'), findsOneWidget);
    expect(find.byIcon(Icons.account_tree_outlined), findsOneWidget);
    expect(find.byIcon(Icons.view_list_outlined), findsNothing);
    expect(
      tester
          .getTopLeft(
            find.byKey(const ValueKey('review-file-status-docs/logo.png')),
          )
          .dx,
      HarnessSpace.gutter,
    );
    expect(
      tester
          .getTopLeft(
            find.byKey(
              const ValueKey(
                'review-file-status-lib/src/features/feature_00/widget.dart',
              ),
            ),
          )
          .dx,
      HarnessSpace.gutter,
    );
  });

  testWidgets('an empty review says so in nouns', (tester) async {
    final rig = await _rig(
      arrange: (harness) {
        harness.reviewData.files = [];
        harness.reviewData.threads = [];
        harness.reviewData.seen = [];
        harness.reviewData.approved = [];
      },
    );
    await _pump(tester, rig);
    expect(find.text('No changes'), findsOneWidget);
    expect(find.text('No changed files'), findsOneWidget);
    expect(find.text('0 files · +0 −0'), findsOneWidget);
    await tester.tap(find.text('Threads'));
    await _settle(tester, 4);
    expect(find.text('No threads'), findsOneWidget);
    expect(find.text('No comments'), findsOneWidget);
  });

  testWidgets('a reply answers the comment it was begun on', (tester) async {
    final rig = await _rig();
    await _pumpFile(tester, rig, 'lib/src/ui/chat_screen.dart');
    await tester.tap(find.byKey(const ValueKey('diff-threads-t-chat')));
    await _settle(tester, 6);
    await tester.tap(
      find.byKey(const ValueKey('review-comment-reply-c-chat-1')),
    );
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('thread-reply-field')),
      'It is the third report, and this fixes it.',
    );
    await tester.tap(find.byKey(const ValueKey('thread-reply-save')));
    await _settle(tester, 8);
    final op = rig.harness.reviewData.operations.last;
    expect(op['op'], 'add-comment');
    expect(asMap(op['comment'])['reply-to'], 'c-chat-1');
  });

  testWidgets('the comment and the reply boxes stay above the keyboard', (
    tester,
  ) async {
    final rig = await _rig();
    await _pumpFile(tester, rig, 'lib/src/ui/chat_screen.dart');
    await tester.tap(find.byKey(const ValueKey('diff-select-lines')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('diff-line-42-added')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('diff-comment-selection')));
    await _settle(tester, 6);
    tester.view.viewInsets = const FakeViewPadding(bottom: 320);
    addTearDown(tester.view.resetViewInsets);
    await _settle(tester, 4);
    final save = tester.getRect(
      find.byKey(const ValueKey('review-composer-save')),
    );
    expect(save.bottom, lessThanOrEqualTo(844 - 320));
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Cancel'));
    await _settle(tester, 3);
    tester.view.viewInsets = FakeViewPadding.zero;
    await _settle(tester, 3);
    await tester.tap(find.byKey(const ValueKey('diff-threads-t-chat')));
    await _settle(tester, 6);
    tester.view.viewInsets = const FakeViewPadding(bottom: 320);
    await _settle(tester, 4);
    final reply = tester.getRect(
      find.byKey(const ValueKey('thread-reply-save')),
    );
    expect(reply.bottom, lessThanOrEqualTo(844 - 320));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the diff and the threads step next and previous', (
    tester,
  ) async {
    final rig = await _rig();
    await _pumpFile(tester, rig, 'lib/src/ui/chat_screen.dart');
    await tester.tap(find.byKey(const ValueKey('diff-threads-t-chat')));
    await _settle(tester, 6);
    expect(find.textContaining('chat_screen.dart'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('thread-next')));
    await _settle(tester, 4);
    expect(find.textContaining('task_controller.dart'), findsWidgets);
    expect(find.text('Earlier revision'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('thread-previous')));
    await _settle(tester, 4);
    expect(find.textContaining('chat_screen.dart'), findsWidgets);
    await tester.pageBack();
    await _settle(tester, 4);
    expect(find.text('Hunk 1/2'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('diff-hunk-next')));
    await tester.pump();
    expect(find.text('Hunk 2/2'), findsOneWidget);
  });

  testWidgets('the next file steps over an approved one', (tester) async {
    final rig = await _rig();
    final controller = rig.app.reviewFor(rig.task)!;
    await controller.load();
    controller.selectFile('lib/src/ui/chat_screen.dart');
    final skipped = controller.nextFile();
    expect(skipped, isNotNull);
    expect(skipped, isNot('lib/src/state/task_controller.dart'));
    controller.setSkipApproved(false);
    final all = controller.nextFile();
    expect(all, isNotNull);
    expect(
      controller.navigationFiles
          .where((file) => file.path == 'lib/src/state/task_controller.dart')
          .length,
      1,
    );
  });

  testWidgets('a draft stays through navigation and a dropped connection', (
    tester,
  ) async {
    final rig = await _rig();
    await _pumpFile(tester, rig, 'lib/src/ui/chat_screen.dart');
    await tester.tap(find.byKey(const ValueKey('diff-select-lines')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('diff-line-42-added')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('diff-comment-selection')));
    await _settle(tester, 6);
    await tester.enterText(
      find.byKey(const ValueKey('review-composer-field')),
      'A draft that is not sent yet.',
    );
    await tester.tap(find.text('Cancel'));
    await _settle(tester, 3);
    final controller = rig.app.reviewFor(rig.task)!;
    final drafted = controller.localDrafts.single;
    expect(drafted.text, 'A draft that is not sent yet.');
    expect(drafted.revision, reviewTip);
    expect(drafted.location!.file, 'lib/src/ui/chat_screen.dart');
    // The connection goes and comes back: the harness's comments are read
    // again, and what was typed but not sent is still on the phone, bound to
    // the same revision.
    await rig.app.disconnect();
    await rig.app.connect('ws://memory/acp');
    final task = await rig.app.api!.task(_reviewTask);
    final next = rig.app.reviewFor(task)!;
    await next.load();
    expect(next.localDrafts.single.text, 'A draft that is not sent yet.');
    expect(next.localDrafts.single.revision, reviewTip);
    expect(next.thread('t-chat')!.comments.length, 2);
  });

  testWidgets('two taps on Send replies send one round', (tester) async {
    final rig = await _rig(taskId: _workingTask);
    await _pump(tester, rig);
    await tester.tap(find.byKey(const ValueKey('review-feedback-button')));
    await _settle(tester, 6);
    await tester.enterText(
      find.byKey(const ValueKey('review-feedback-field')),
      'One more look at the board.',
    );
    await tester.tap(find.byKey(const ValueKey('review-feedback-send')));
    await tester.tap(find.byKey(const ValueKey('review-feedback-send')));
    await _settle(tester, 10);
    expect(rig.harness.reviewData.sends, 1);
  });

  testWidgets('another client of the same harness sees the same comment', (
    tester,
  ) async {
    final rig = await _rig();
    final first = rig.app.reviewFor(rig.task)!;
    await first.load();
    final draft = first.lineDraft(
      file: first.changes!.file('lib/src/ui/chat_screen.dart')!,
      side: 'new',
      start: 42,
    );
    draft.text = 'From the other phone.';
    expect(await first.saveDraft(draft.key), isTrue);
    // The review's own draft and this one, once each.
    expect(first.draftCount, 2);

    final secondApp = AppController(
      settings: rig.settings,
      connector: rig.harness.connector,
    );
    await secondApp.connect('ws://memory/acp');
    addTearDown(secondApp.disconnect);
    final secondTask = await secondApp.api!.task(_reviewTask);
    final second = secondApp.reviewFor(secondTask)!;
    await second.load();
    final found = second.set!.threads
        .expand((thread) => thread.comments)
        .where((comment) => comment.body == 'From the other phone.');
    expect(found.length, 1);
  });

  testWidgets('an earlier-revision thread is not drawn on the new lines', (
    tester,
  ) async {
    final rig = await _rig();
    await _pumpFile(tester, rig, 'lib/src/state/task_controller.dart');
    expect(find.byKey(const ValueKey('diff-threads-t-task')), findsNothing);
    expect(find.text('Earlier revision'), findsNothing);
    // It is still in the review, at its own place and revision.
    final controller = rig.app.reviewFor(rig.task)!;
    final thread = controller.thread('t-task')!;
    expect(thread.revision, reviewEarlier);
    expect(thread.location!.file, 'lib/src/state/task_controller.dart');
    expect(thread.location!.line, 118);
  });

  testWidgets('a long reply folds, and unfolds when asked', (tester) async {
    final rig = await _rig();
    await _pumpFile(tester, rig, 'lib/src/ui/chat_screen.dart');
    await tester.tap(find.byKey(const ValueKey('diff-threads-t-long')));
    await _settle(tester, 6);
    for (var i = 0; i < 8; i++) {
      if (find
          .byKey(const ValueKey('review-comment-more-c-long-2'))
          .evaluate()
          .isNotEmpty) {
        break;
      }
      await tester.drag(
        find.byKey(const ValueKey('review-thread')),
        const Offset(0, -300),
      );
      await tester.pump();
    }
    expect(
      find.byKey(const ValueKey('review-comment-more-c-long-2')),
      findsOneWidget,
    );
    expect(find.text('More'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('review-comment-more-c-long-2')),
    );
    await _settle(tester, 3);
    expect(find.text('Less'), findsOneWidget);
    expect(find.textContaining('The tests in'), findsOneWidget);
  });

  testWidgets('a lost answer does not add the comment twice', (tester) async {
    final rig = await _rig();
    final controller = rig.app.reviewFor(rig.task)!;
    await controller.load();
    final file = controller.changes!.file('lib/src/ui/chat_screen.dart')!;
    final draft = controller.lineDraft(file: file, side: 'new', start: 42);
    draft.text = 'Saved once, even when the answer is lost.';
    rig.harness.loseNextApplyAnswer = true;
    expect(await controller.saveDraft(draft.key), isFalse);
    expect(draft.commentId, isNull);
    // The operation was performed; the same id is sent again, and the
    // harness does not add a second comment.
    expect(await controller.saveDraft(draft.key), isTrue);
    final comments = rig.harness.reviewData.threads
        .expand((thread) => thread['comments'] as List)
        .where(
          (comment) =>
              (comment as Map)['body'] ==
              'Saved once, even when the answer is lost.',
        );
    expect(comments.length, 1);
  });

  testWidgets('a newer hand-in is offered, and does not replace the diff', (
    tester,
  ) async {
    final rig = await _rig();
    await _pump(tester, rig);
    final controller = rig.app.reviewFor(rig.task)!;
    expect(controller.changes!.revision, reviewTip);
    rig.harness.reviewData.revision =
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    await controller.load(force: false);
    await _settle(tester, 4);
    expect(find.byKey(const ValueKey('review-stale')), findsOneWidget);
    expect(find.text('New revision'), findsOneWidget);
    expect(find.textContaining('aaaaaaa'), findsWidgets);
    expect(find.textContaining('Shown v2'), findsOneWidget);
    expect(controller.changes!.revision, reviewTip);
    // Reload takes it, deliberately.
    await tester.tap(find.byKey(const ValueKey('review-stale-reload')));
    await _settle(tester, 8);
    expect(
      controller.changes!.revision,
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    );
    expect(find.byKey(const ValueKey('review-stale')), findsNothing);
  });

  testWidgets('viewed and approved are separate marks, and neither merges', (
    tester,
  ) async {
    final rig = await _rig();
    await _pumpFile(tester, rig, 'lib/src/ui/theme.dart');
    final controller = rig.app.reviewFor(rig.task)!;
    final file = controller.changes!.file('lib/src/ui/theme.dart')!;
    expect(controller.viewed.isSeen(file), isFalse);
    await tester.tap(find.text('Not viewed'));
    await _settle(tester, 4);
    expect(controller.viewed.isSeen(file), isTrue);
    expect(controller.viewed.isApproved(file), isFalse);
    await tester.tap(find.text('Not approved'));
    await _settle(tester, 4);
    expect(controller.viewed.isApproved(file), isTrue);
    expect(rig.harness.reviewData.approved.length, 2);
    // A file approved and then changed in a newer revision is not covered:
    // the mark names the blob it was made on.
    expect(
      controller.viewed.isApproved(
        ChangedFile(path: file.path, newBlob: 'another-blob'),
      ),
      isFalse,
    );
  });

  testWidgets('a wide screen offers split view, a phone does not', (
    tester,
  ) async {
    final rig = await _rig();
    await _pumpFile(tester, rig, 'lib/src/ui/chat_screen.dart', width: 320);
    expect(find.byKey(const ValueKey('diff-split')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await _pumpFile(tester, rig, 'lib/src/ui/chat_screen.dart', width: 900);
    expect(find.byKey(const ValueKey('diff-split')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('diff-split')));
    await _settle(tester, 4);
    expect(rig.app.reviewFor(rig.task)!.splitView, isTrue);
    expect(find.byKey(const ValueKey('review-diff-split')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a binary file says so, and a rename names both paths', (
    tester,
  ) async {
    final rig = await _rig();
    await _pumpFile(tester, rig, 'docs/logo.png');
    expect(find.text('Binary file'), findsOneWidget);
    expect(find.text('No text diff'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await _pumpFile(tester, rig, 'lib/src/ui/split_view.dart');
    expect(
      find.text(
        'Renamed · lib/src/ui/old_view.dart → lib/src/ui/split_view.dart',
      ),
      findsOneWidget,
    );
  });

  testWidgets('the versions menu reads an earlier version as it was', (
    tester,
  ) async {
    final rig = await _rig();
    await _pump(tester, rig);
    final controller = rig.app.reviewFor(rig.task)!;
    expect(controller.hasVersions, isTrue);
    await tester.tap(find.byKey(const ValueKey('review-versions')));
    await _settle(tester, 6);
    expect(find.text('Versions'), findsOneWidget);
    expect(find.textContaining('v1 · 0a1b2c3'), findsWidgets);
    await tester.tap(find.textContaining('v1 · 0a1b2c3').last);
    await _settle(tester, 8);
    expect(controller.changes!.revision, reviewEarlier);
    expect(controller.changes!.versionId, reviewEarlier);
    expect(
      controller.changes!.file('lib/src/ui/removed_panel.dart'),
      isNotNull,
    );
    expect(controller.changes!.file('lib/src/ui/new_panel.dart'), isNull);
    expect(find.text('Earlier version'), findsWidgets);
    // The file the earlier comment is on is read at the earlier revision:
    // its marker is on the line it names.
    await _pumpFile(tester, rig, 'lib/src/state/task_controller.dart');
    expect(find.byKey(const ValueKey('diff-threads-t-task')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an earlier version is read, not marked viewed or approved', (
    tester,
  ) async {
    final rig = await _rig();
    final controller = rig.app.reviewFor(rig.task)!;
    await controller.load();
    expect(await controller.selectVersion(reviewEarlier), isTrue);
    await _pumpFile(tester, rig, 'lib/src/state/task_controller.dart');
    expect(
      find.byKey(const ValueKey('review-earlier-version')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('review-viewed')), findsNothing);
    expect(find.byKey(const ValueKey('review-approved')), findsNothing);
    expect(tester.takeException(), isNull);
    final earlierFile = controller.changes!.file(
      'lib/src/state/task_controller.dart',
    )!;
    final before = rig.harness.reviewData.operations.length;
    expect(await controller.setViewed(earlierFile, true), isFalse);
    expect(await controller.setApproved(earlierFile, true), isFalse);
    // An earlier version is read, not reviewed: no mark is kept of it.
    expect(controller.viewed.isSeen(earlierFile), isFalse);
    expect(controller.viewed.isApproved(earlierFile), isFalse);
    expect(rig.harness.reviewData.operations.length, before);
    await tester.pump();
    expect(tester.takeException(), isNull);
    await controller.selectVersion(null);
    await _settle(tester, 6);
    expect(find.byKey(const ValueKey('review-viewed')), findsWidgets);
  });

  testWidgets('a comment keeps its original revision when the newest is read', (
    tester,
  ) async {
    final rig = await _rig();
    final controller = rig.app.reviewFor(rig.task)!;
    await controller.load();
    expect(await controller.selectVersion(reviewEarlier), isTrue);
    final file = controller.changes!.file(
      'lib/src/state/task_controller.dart',
    )!;
    final draft = controller.lineDraft(file: file, side: 'old', start: 118);
    draft.text = 'The line as it was in v1.';
    expect(draft.revision, reviewEarlier);
    expect(await controller.selectVersion(null), isTrue);
    expect(controller.changes!.revision, reviewTip);
    // The draft is still bound to the version it was written on.
    expect(draft.revision, reviewEarlier);
    expect(controller.revisionNote(draft.revision), 'Earlier revision');
    expect(await controller.saveDraft(draft.key), isTrue);
    final thread = controller.set!.threads.firstWhere(
      (thread) => thread.comments.any((c) => c.body == draft.text),
    );
    expect(thread.revision, reviewEarlier);
    expect(thread.location!.line, 118);
  });

  testWidgets('a diff answer for the old version is not drawn on the new one', (
    tester,
  ) async {
    final rig = await _rig();
    final controller = rig.app.reviewFor(rig.task)!;
    await controller.load();
    final gate = Completer<void>();
    var gated = false;
    rig.harness.beforeAnswer = (method, params) async {
      if (!gated &&
          method == '_harness/patch-review/diff' &&
          params['version'] == reviewTip) {
        gated = true;
        await gate.future;
      }
    };
    await _pump(
      tester,
      rig,
      home: ReviewFileScreen(
        controller: controller,
        path: 'lib/src/state/task_controller.dart',
      ),
    );
    for (var i = 0; i < 20 && !gated; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(gated, isTrue);

    // The version is chosen while the old lines are still on their way.  The
    // page reads v1; its lines are not the v2 answer's.
    expect(await controller.selectVersion(reviewEarlier), isTrue);
    await _settle(tester, 8);
    expect(find.textContaining('one pass'), findsOneWidget);
    gate.complete();
    await _settle(tester, 8);
    expect(find.textContaining('one pass'), findsOneWidget);
    expect(find.textContaining('final changed = event.tasks'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'the diff changes with the version, and each line keeps its own',
    (tester) async {
      final rig = await _rig();
      final controller = rig.app.reviewFor(rig.task)!;
      await controller.load();
      await _pumpFile(tester, rig, 'lib/src/state/task_controller.dart');
      expect(find.textContaining('one pass'), findsNothing);
      expect(
        find.byKey(const ValueKey('diff-line-o117-deleted')),
        findsOneWidget,
      );

      // The version the page reads changes the lines on it: the v1 line is
      // drawn, at v1, not under the v2 heading.
      expect(await controller.selectVersion(reviewEarlier), isTrue);
      await _settle(tester, 8);
      expect(find.textContaining('one pass'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('diff-select-lines')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('diff-line-o117-deleted')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('diff-comment-selection')));
      await _settle(tester, 6);
      await tester.enterText(
        find.byKey(const ValueKey('review-composer-field')),
        'The line as v1 had it.',
      );
      await tester.tap(find.byKey(const ValueKey('review-composer-save')));
      await _settle(tester, 10);
      final first = rig.harness.reviewData.operations.last;
      expect(first['op'], 'add-comment');
      expect(asMap(first['comment'])['revision'], reviewEarlier);

      // The same line in the newest version is another comment: the draft of
      // v1 is not edited, and the new one is sent at v2.
      expect(await controller.selectVersion(null), isTrue);
      await _settle(tester, 8);
      expect(find.textContaining('one pass'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('diff-select-lines')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('diff-line-o117-deleted')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('diff-comment-selection')));
      await _settle(tester, 6);
      await tester.enterText(
        find.byKey(const ValueKey('review-composer-field')),
        'The line as v2 has it.',
      );
      await tester.tap(find.byKey(const ValueKey('review-composer-save')));
      await _settle(tester, 10);
      final second = rig.harness.reviewData.operations.last;
      expect(second['op'], 'add-comment');
      expect(asMap(second['comment'])['revision'], reviewTip);
      expect(
        rig.harness.reviewData.threads
            .expand((thread) => thread['comments'] as List)
            .where(
              (comment) =>
                  (comment as Map)['body'] == 'The line as v1 had it.' ||
                  comment['body'] == 'The line as v2 has it.',
            )
            .length,
        2,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a thread opens the version its lines were written at', (
    tester,
  ) async {
    final rig = await _rig();
    await _pump(tester, rig);
    final controller = rig.app.reviewFor(rig.task)!;
    await tester.tap(find.text('Threads'));
    await _settle(tester, 6);
    controller.setThreadFilter(ReviewThreadFilter.closed);
    await _settle(tester, 4);
    expect(find.text('Closed'), findsOneWidget);
    await tester.tap(find.textContaining('This re-reads every task'));
    await _settle(tester, 8);
    await tester.tap(find.byTooltip('Diff position'));
    await _settle(tester, 10);
    expect(controller.selectedVersion, reviewEarlier);
    expect(controller.changes!.revision, reviewEarlier);
    expect(find.byKey(const ValueKey('review-diff')), findsOneWidget);
    expect(find.byKey(const ValueKey('diff-threads-t-task')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a thread on a path that is gone opens it at its revision', (
    tester,
  ) async {
    final rig = await _rig(
      arrange: (harness) {
        final data = harness.reviewData;
        final time = DateTime.now().millisecondsSinceEpoch / 1000;
        data.threads.add({
          'id': 't-retired',
          'status': 'closed',
          'comments': [
            {
              'id': 'c-retired',
              'thread': 't-retired',
              'author': {'kind': 'user', 'name': 'Noah'},
              'body': 'This panel went away.',
              'time': time,
              'sent': time,
              'location': {
                'file': 'lib/src/ui/removed_panel.dart',
                'side': 'new',
                'line': 2,
              },
              'revision': reviewEarlier,
            },
          ],
          'history': [
            {
              'id': 'h-retired',
              'status': 'closed',
              'time': time,
              'author': {'kind': 'agent', 'name': 'Agent'},
            },
          ],
        });
      },
    );
    await _pump(tester, rig);
    final controller = rig.app.reviewFor(rig.task)!;
    await tester.tap(find.text('Threads'));
    await _settle(tester, 6);
    controller.setThreadFilter(ReviewThreadFilter.closed);
    await _settle(tester, 4);
    await tester.tap(find.textContaining('This panel went away'));
    await _settle(tester, 8);
    await tester.tap(find.byTooltip('Diff position'));
    await _settle(tester, 10);
    expect(controller.selectedVersion, reviewEarlier);
    expect(controller.selectedPath, 'lib/src/ui/removed_panel.dart');
    expect(find.textContaining('removed_panel.dart'), findsWidgets);
    expect(
      find.byKey(const ValueKey('diff-threads-t-retired')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a diff too large to draw at once is built as it is read', (
    tester,
  ) async {
    final rig = await _rig();
    rig.harness.reviewData.patches['lib/src/ui/theme.dart'] =
        FakeReview.largePatch(lines: 4000);
    final controller = rig.app.reviewFor(rig.task)!;
    await controller.load();
    final watch = Stopwatch()..start();
    final diff = await controller.diffFor('lib/src/ui/theme.dart');
    watch.stop();
    expect(diff.hunks.length, 1);
    expect(diff.hunks.first.lines.length, 4001);
    expect(watch.elapsedMilliseconds, lessThan(1500));
    await _pumpFile(tester, rig, 'lib/src/ui/theme.dart', height: 600);
    expect(find.byKey(const ValueKey('review-diff')), findsOneWidget);
    // The list builds a window, not four thousand rows.
    expect(find.byType(Text), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
