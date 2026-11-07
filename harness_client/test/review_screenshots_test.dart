// Pictures of the change review on a phone, drawn with the fonts of a phone.
//
//   HARNESS_SHOTS=/some/directory flutter test test/review_screenshots_test.dart
//
// writes a PNG for each case: the files of a review at 360 points, the
// unified diff with its hunk header, line numbers and two threads marked, the comment composer with the keyboard up, a thread with
// its reply box and the keyboard, the review at 900 points with two columns,
// the files at 320 points read at twice the size, and the task bar that leads
// into the review.  Without HARNESS_SHOTS the cases still draw and check that
// nothing overflows, and write nothing.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/app.dart';
import 'package:harness_client/src/models/task.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:harness_client/src/ui/adaptive/platform_style.dart';
import 'package:harness_client/src/ui/screens/review_screen.dart';
import 'package:harness_client/src/ui/theme/harness_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';
import 'support/fake_review.dart';
import 'support/real_fonts.dart';
import 'support/report_flows.dart';

const _taskId = 'task-2';

class _Rig {
  _Rig(this.settings, this.harness, this.app, this.task);
  final SettingsController settings;
  final FakeHarness harness;
  final AppController app;
  final HarnessTask task;
}

Future<_Rig> _rig({void Function(FakeHarness harness)? arrange}) async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsController();
  await settings.load();
  final harness = FakeHarness(reviews: true);
  harness.reviewData = FakeReview(taskId: _taskId);
  arrange?.call(harness);
  final app = AppController(settings: settings, connector: harness.connector);
  await app.connect('ws://memory/acp');
  final task = await app.api!.task(_taskId);
  return _Rig(settings, harness, app, task);
}

Future<void> _settle(WidgetTester tester, [int rounds = 12]) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

Future<ui.Image> _picture(WidgetTester tester, GlobalKey frame) async {
  final image = await tester.runAsync(() async {
    final boundary =
        frame.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    return boundary.toImage(pixelRatio: 2);
  });
  return image!;
}

Future<void> _write(WidgetTester tester, ui.Image image, String path) async {
  await tester.runAsync(() async {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File(path);
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(data!.buffer.asUint8List());
  });
}

Future<GlobalKey> _frame(WidgetTester tester, Widget child) async {
  final frame = GlobalKey();
  await tester.pumpWidget(RepaintBoundary(key: frame, child: child));
  return frame;
}

Future<GlobalKey> _pumpReview(
  WidgetTester tester,
  _Rig rig, {
  double width = 360,
  double height = 800,
  double textScale = 1,
  bool keyboard = false,
}) async {
  tester.view.physicalSize = Size(width * 2, height * 2);
  tester.view.devicePixelRatio = 2;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  if (keyboard) {
    tester.view.viewInsets = const FakeViewPadding(bottom: 640);
    addTearDown(tester.view.resetViewInsets);
  }
  final frame = await _frame(
    tester,
    HarnessStyle(
      style: HarnessPlatformStyle.material,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: HarnessTheme.material(Brightness.light),
        home: ReviewScreen(app: rig.app, task: rig.task),
      ),
    ),
  );
  await tester.pump();
  await _settle(tester);
  return frame;
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final shots = Platform.environment['HARNESS_SHOTS'];

  setUpAll(() async {
    await loadRealFonts();
  });

  testWidgets('draws the files of a review', (tester) async {
    final rig = await _rig();
    final frame = await _pumpReview(tester, rig);
    expect(find.text('Files'), findsOneWidget);
    expect(tester.takeException(), isNull);
    if (shots != null) {
      await _write(
        tester,
        await _picture(tester, frame),
        '$shots/review-files.png',
      );
    }
  });

  testWidgets('draws the unified diff with its threads', (tester) async {
    final rig = await _rig();
    final frame = await _pumpReview(tester, rig);
    await _openFile(tester, 'lib/src/ui/chat_screen.dart');
    expect(find.byKey(const ValueKey('diff-threads-t-chat')), findsOneWidget);
    expect(tester.takeException(), isNull);
    if (shots != null) {
      await _write(
        tester,
        await _picture(tester, frame),
        '$shots/review-diff.png',
      );
    }
  });

  testWidgets('draws the comment box with the keyboard up', (tester) async {
    final rig = await _rig();
    final frame = await _pumpReview(tester, rig);
    await _openFile(tester, 'lib/src/ui/chat_screen.dart');
    await tester.tap(find.byKey(const ValueKey('diff-select-lines')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('diff-line-42-added')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('diff-comment-selection')));
    await _settle(tester, 6);
    await tester.enterText(
      find.byKey(const ValueKey('review-composer-field')),
      'The composer still covers the last message when the keyboard opens on a small screen.',
    );
    await tester.pump();
    // The keyboard takes the bottom of the screen: the box stays above it.
    tester.view.viewInsets = const FakeViewPadding(bottom: 640);
    addTearDown(tester.view.resetViewInsets);
    await _settle(tester, 4);
    expect(find.byKey(const ValueKey('review-composer-save')), findsOneWidget);
    expect(tester.takeException(), isNull);
    if (shots != null) {
      await _write(
        tester,
        await _picture(tester, frame),
        '$shots/review-comment-keyboard.png',
      );
    }
  });

  testWidgets('draws a thread with its reply box and the keyboard', (
    tester,
  ) async {
    final rig = await _rig();
    final frame = await _pumpReview(tester, rig);
    await tester.tap(find.text('Threads'));
    await _settle(tester, 6);
    await tester.tap(
      find.textContaining('The composer covers the last message'),
    );
    await _settle(tester, 8);
    await tester.tap(find.byKey(const ValueKey('thread-reply-field')));
    await tester.enterText(
      find.byKey(const ValueKey('thread-reply-field')),
      'Confirmed on a 320 screen: the last message is above the composer now.',
    );
    await tester.pump();
    tester.view.viewInsets = const FakeViewPadding(bottom: 640);
    addTearDown(tester.view.resetViewInsets);
    await _settle(tester, 4);
    expect(tester.takeException(), isNull);
    if (shots != null) {
      await _write(
        tester,
        await _picture(tester, frame),
        '$shots/review-thread-keyboard.png',
      );
    }
  });

  testWidgets('draws two columns on a wide screen', (tester) async {
    final rig = await _rig();
    final frame = await _pumpReview(tester, rig, width: 900, height: 800);
    await _openFile(tester, 'lib/src/ui/chat_screen.dart');
    await tester.tap(find.byKey(const ValueKey('diff-split')));
    await _settle(tester, 4);
    expect(find.byKey(const ValueKey('review-diff-split')), findsOneWidget);
    expect(tester.takeException(), isNull);
    if (shots != null) {
      await _write(
        tester,
        await _picture(tester, frame),
        '$shots/review-wide-split.png',
      );
    }
  });

  testWidgets('draws the files at 320 points read at twice the size', (
    tester,
  ) async {
    final rig = await _rig();
    final frame = await _pumpReview(tester, rig, width: 320, textScale: 2);
    expect(tester.takeException(), isNull);
    if (shots != null) {
      await _write(
        tester,
        await _picture(tester, frame),
        '$shots/review-320-text2.png',
      );
    }
  });

  testWidgets('draws the bar that leads into the review', (tester) async {
    tester.view.viewInsets = FakeViewPadding.zero;
    addTearDown(tester.view.resetViewInsets);
    FocusManager.instance.primaryFocus?.unfocus();
    final rig = await _rig(
      arrange: (harness) {
        harness.tasks['task-2']!['session'] = 's-task-2';
        harness.sessions['s-task-2'] = {
          'id': 's-task-2',
          'name': 'Review the emulator screenshots',
          'kind': 'main',
          'project': '/Users/noah/Code/emacs-agent-harness/',
          'cwd':
              '/Users/noah/Code/emacs-agent-harness/.worktrees/task-screens/',
          'model': 'claude:claude-fable-5-1',
          'permissionMode': 'auto',
          'status': 'idle',
          'created': DateTime.now().millisecondsSinceEpoch / 1000,
          'updated': DateTime.now().millisecondsSinceEpoch / 1000,
          'pending': [],
          'queue': [],
        };
      },
    );
    tester.view.physicalSize = const Size(720, 1600);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final frame = await _frame(
      tester,
      HarnessApp(settings: rig.settings, appController: rig.app),
    );
    await tester.pump();
    await _settle(tester, 10);
    await openTaskSession(tester, 's-task-2');
    for (var i = 0; i < 60; i++) {
      if (find.byKey(const Key('task-review')).evaluate().isNotEmpty) break;
      await tester.pump(const Duration(milliseconds: 120));
    }
    expect(find.byKey(const Key('task-review')), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('task-review')));
    await _settle(tester, 4);
    expect(find.byKey(const Key('task-review')), findsOneWidget);
    expect(tester.takeException(), isNull);
    if (shots != null) {
      await _write(
        tester,
        await _picture(tester, frame),
        '$shots/review-task-bar.png',
      );
    }
  });
}
