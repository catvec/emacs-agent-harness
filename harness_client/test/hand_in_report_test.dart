// The report a task's work was handed in with is read on one page, whichever
// way it is come to: the "Open full view" of the `hand_in` call in the task's
// session, and the "View report" on the bar of the task's conversation (a tap
// on the task, on the board, opens the conversation; there is no sheet).  The
// two used to be drawn by two pieces of code (a sheet drew the summary, how to
// reproduce it and a line a piece of evidence, and left the problem out; the
// session's page drew the report), so the same report looked like two.  These
// open both and look at what is drawn: the same words, in the same order, and
// the same pixels.
//
// Drawn with the fonts of a phone: the board's header holds a spend chip,
// which the test font, with its wide letters, squeezes out of its row.
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/models/tool_display.dart';
import 'package:harness_client/src/models/transcript.dart';
import 'package:harness_client/src/ui/adaptive/platform_style.dart';
import 'package:harness_client/src/ui/screens/hand_in_report_screen.dart';
import 'package:harness_client/src/ui/screens/tool_detail_screen.dart';
import 'package:harness_client/src/ui/theme/harness_theme.dart';

import 'support/fake_harness.dart';
import 'support/handed_in_task.dart';
import 'support/real_fonts.dart';
import 'support/report_flows.dart';
import 'support/tool_showcase.dart';

/// The report of the handed-in task, as the page of a bare app draws it.
Future<void> _pumpPage(
  WidgetTester tester,
  HandInReport report, {
  double width = 390,
  HarnessPlatformStyle style = HarnessPlatformStyle.material,
  double textScale = 1,
}) async {
  tester.view.physicalSize = Size(width * 3, 2532);
  tester.view.devicePixelRatio = 3.0;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(
    HarnessStyle(
      style: style,
      child: MaterialApp(
        theme: HarnessTheme.material(Brightness.light),
        home: HandInReportScreen(report: report),
      ),
    ),
  );
  await settle(tester, 4);
}

/// [ToolDetailScreen] for [tool], in a bare app.
Future<void> _pumpFullView(WidgetTester tester, ToolView tool) async {
  await tester.pumpWidget(
    HarnessStyle(
      style: HarnessPlatformStyle.material,
      child: MaterialApp(
        theme: HarnessTheme.material(Brightness.light),
        home: ToolDetailScreen(tool: tool),
      ),
    ),
  );
  await settle(tester, 3);
}

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  await loadRealFonts();

  group('the report of a task\'s work', () {
    testWidgets('is the same page from the task and from the session', (
      tester,
    ) async {
      // From the task: its conversation, and "View report" on its bar.
      var frame = await openApp(tester, seed: seedHandedInTask);
      await viewReport(tester, handedInTaskName);
      expect(find.byType(ToolDetailScreen), findsNothing);
      final fromTask = await readPage(tester, frame);

      // From the session of the task: the call that handed the work in,
      // opened, and its "Open full view".  A new app, so that nothing of the
      // first is left on the screen.
      await tester.pumpWidget(const SizedBox());
      frame = await openApp(tester, seed: seedHandedInTask);
      await openFullView(tester);
      final fromSession = await readPage(tester, frame);

      // The page says what was handed in: the problem comes first, which the
      // sheet of the board used to leave out.
      expect(
        fromTask.words.where((words) => words.contains('Tool call results')),
        isNotEmpty,
        reason: 'the problem is on the page',
      );
      for (final heading in [
        'PROBLEM',
        'SUMMARY',
        'TO REPRODUCE',
        'EVIDENCE',
      ]) {
        expect(find.text(heading), findsOneWidget, reason: heading);
      }
      // The same words in the same order, and the same picture.
      expect(fromTask.words, fromSession.words);
      expect(
        fromTask.differences(fromSession),
        0,
        reason: 'the two pages are not drawn the same',
      );
    });

    testWidgets('reads to its end on the page: the quoted call is open', (
      tester,
    ) async {
      await openApp(tester, seed: seedHandedInTask);
      await viewReport(tester, handedInTaskName);
      // The page of a report opens what the card of it keeps shut.
      expect(find.text('INPUT'), findsOneWidget);
      expect(find.text('OUTPUT'), findsOneWidget);
      expect(find.textContaining('Resolving dependencies...'), findsWidgets);
      expect(find.text('Open full view'), findsNothing);
    });

    testWidgets('has a line on the task\'s bar that leads to it and draws none '
        'of it', (tester) async {
      await openApp(tester, seed: seedHandedInTask);
      await openTask(tester, handedInTaskName);
      // The task opens to its conversation, not to a sheet.
      expect(find.byType(BottomSheet), findsNothing);
      final bar = find.byKey(const Key('task-bar'));
      expect(bar, findsOneWidget);
      Finder inBar(Finder finder) =>
          find.descendant(of: bar, matching: finder);
      // What there is to say of the report, and the way to read it.
      expect(
        inBar(find.textContaining('Handed in')),
        findsOneWidget,
        reason: 'when it was handed in',
      );
      expect(
        inBar(find.textContaining('5 pieces of evidence')),
        findsOneWidget,
      );
      expect(inBar(find.text('View report')), findsOneWidget);
      // The report itself is not drawn here: no heading of it, none of its
      // words.
      for (final heading in [
        'PROBLEM',
        'SUMMARY',
        'TO REPRODUCE',
        'EVIDENCE',
      ]) {
        expect(inBar(find.text(heading)), findsNothing, reason: heading);
      }
      expect(
        inBar(find.textContaining('Tool call results are hard to read')),
        findsNothing,
      );
      expect(inBar(find.textContaining('What was wrong')), findsNothing);

      // The page opens over the conversation, and closing it leaves the bar
      // as it was, with the actions of the review in reach.
      await tester.ensureVisible(find.text('View report'));
      await tester.pump();
      await tester.tap(find.text('View report'));
      await settle(tester, 8);
      expect(find.byType(HandInReportScreen), findsOneWidget);
      expect(find.text('Hand-in report'), findsOneWidget);
      await tester.pageBack();
      await settle(tester, 8);
      expect(find.byType(HandInReportScreen), findsNothing);
      expect(find.text('Verify and merge'), findsOneWidget);
    });

    for (final (width, scale) in [(320.0, 1.0), (320.0, 1.5)]) {
      testWidgets(
        'has a bar whose report line fits a phone $width points wide, '
        'text at $scale×',
        (tester) async {
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          await openApp(
            tester,
            seed: seedHandedInTask,
            width: width,
            height: 640,
          );
          await openTaskSession(tester, toolShowcaseId);
          await tester.ensureVisible(find.text('View report'));
          await tester.pump();
          final button = tester.getRect(
            find.widgetWithText(TextButton, 'View report'),
          );
          expect(button.left, greaterThanOrEqualTo(0));
          expect(button.right, lessThanOrEqualTo(width));
          expect(
            tester.getRect(find.text('View report')).right,
            lessThanOrEqualTo(button.right),
            reason: 'the label is inside its button',
          );
          final state = tester.getRect(find.textContaining('Handed in'));
          expect(state.right, lessThanOrEqualTo(width));
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets('says when the round of work handed none in', (tester) async {
      await openApp(tester, seed: seedUnreportedTask);
      await openTask(tester, unreportedTaskName);
      // The bar says so before the report is opened.
      expect(find.text('No report was handed in'), findsOneWidget);
      expect(find.textContaining('piece'), findsNothing);
      await tester.ensureVisible(find.text('View report'));
      await tester.pump();
      await tester.tap(find.text('View report'));
      await settle(tester, 8);

      // The page says it, and shows what the session said last, as what it
      // is: not a summary, and nothing to reproduce or to show.
      expect(find.byType(HandInReportScreen), findsOneWidget);
      expect(find.text('No report was handed in'), findsOneWidget);
      expect(find.text('LAST MESSAGE'), findsOneWidget);
      expect(find.textContaining('could not reach'), findsOneWidget);
      for (final heading in [
        'PROBLEM',
        'SUMMARY',
        'TO REPRODUCE',
        'EVIDENCE',
      ]) {
        expect(find.text(heading), findsNothing, reason: heading);
      }
      expect(find.textContaining('Handed in'), findsNothing);
    });

    testWidgets('is not there for a task that has handed nothing in', (
      tester,
    ) async {
      await openApp(
        tester,
        seed: (harness) {
          seedHandedInTask(harness);
          harness.tasks['task-working'] = {
            'id': 'task-working',
            'name': 'Still at work',
            'prompt': 'Not done yet.',
            'state': 'review',
            'column': 'review',
            'priority': 'medium',
            'project': '/Users/noah/Code/emacs-agent-harness/',
            'created': DateTime.now().millisecondsSinceEpoch / 1000,
            'updated': DateTime.now().millisecondsSinceEpoch / 1000,
          };
          harness.seedTaskSession('task-working');
        },
      );
      await openTask(tester, 'Still at work');
      expect(find.text('Verify and merge'), findsOneWidget);
      expect(find.textContaining('Handed in'), findsNothing);
      expect(find.text('View report'), findsNothing);
    });
  });

  group('the screenshots in the evidence of a report', () {
    // The two a task that changed the app handed in, named by their paths on
    // the harness's machine, which the phone cannot open: the harness gives
    // them (`session/image`), of the session that handed them in.
    const shots = [
      '$toolShowcasePictures/android-tool-call.png',
      '$toolShowcasePictures/android-hand-in.png',
    ];
    late FakeHarness harness;
    void seedWithPictures(FakeHarness h) {
      harness = h;
      seedHandedInTaskWithPictures(h);
    }

    void seedWithoutFiles(FakeHarness h) {
      harness = h;
      seedHandedInTask(h);
    }

    testWidgets('are drawn on the page, the same from the task and the session', (
      tester,
    ) async {
      var frame = await openApp(tester, seed: seedWithPictures);
      await viewReport(tester, handedInTaskName);
      await settleDecoded(tester);
      expect(find.byType(HandInReportScreen), findsOneWidget);
      expect(drawnPictures, findsNWidgets(2));
      expect(failedPictures, findsNothing);
      // Each is asked of the session of the task, by the path the report
      // names it by.
      expect(harness.imageRequests, [
        (toolShowcaseId, shots[0]),
        (toolShowcaseId, shots[1]),
      ]);
      final fromTask = await readPage(tester, frame);

      await tester.pumpWidget(const SizedBox());
      frame = await openApp(tester, seed: seedWithPictures);
      await openFullView(tester);
      await settleDecoded(tester);
      expect(find.byType(HandInReportScreen), findsOneWidget);
      expect(drawnPictures, findsNWidgets(2));
      expect(failedPictures, findsNothing);
      expect(harness.imageRequests, [
        (toolShowcaseId, shots[0]),
        (toolShowcaseId, shots[1]),
      ]);
      final fromSession = await readPage(tester, frame);

      expect(fromTask.words, fromSession.words);
      expect(
        fromTask.differences(fromSession),
        0,
        reason: 'the two pages are not drawn the same',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('are shown larger when tapped, and the page is still there', (
      tester,
    ) async {
      await openApp(tester, seed: seedWithPictures);
      await viewReport(tester, handedInTaskName);
      await settleDecoded(tester);
      await tester.ensureVisible(drawnPictures.first);
      await tester.pump();
      await tester.tap(drawnPictures.first);
      await settle(tester, 10);
      expect(find.byKey(const ValueKey('picture-viewer')), findsOneWidget);
      expect(
        harness.imageRequests.length,
        2,
        reason: 'it is shown from the bytes the page has',
      );
      await tester.tap(find.byIcon(Icons.close_rounded));
      await settle(tester, 10);
      expect(find.byKey(const ValueKey('picture-viewer')), findsNothing);
      await settleDecoded(tester);
      expect(find.byType(HandInReportScreen), findsOneWidget);
      expect(drawnPictures, findsNWidgets(2));
      expect(tester.takeException(), isNull);
    });

    testWidgets('are named, the same from both, by a harness that gives none', (
      tester,
    ) async {
      var frame = await openApp(
        tester,
        seed: seedWithPictures,
        sessionPictures: false,
      );
      await viewReport(tester, handedInTaskName);
      expect(harness.imageRequests, isEmpty);
      expect(drawnPictures, findsNothing);
      expect(failedPictures, findsNothing);
      // As the app showed them before pictures were drawn: by name.
      expect(find.text('android-tool-call.png'), findsOneWidget);
      expect(find.text('android-hand-in.png'), findsOneWidget);
      final fromTask = await readPage(tester, frame);

      await tester.pumpWidget(const SizedBox());
      frame = await openApp(
        tester,
        seed: seedWithPictures,
        sessionPictures: false,
      );
      await openFullView(tester);
      expect(harness.imageRequests, isEmpty);
      expect(drawnPictures, findsNothing);
      final fromSession = await readPage(tester, frame);

      expect(fromTask.words, fromSession.words);
      expect(fromTask.differences(fromSession), 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('that are gone say so, the same from both, and can be asked for', (
      tester,
    ) async {
      // The worktree of a finished task goes with the task: the files are
      // gone, and the harness says so.
      var frame = await openApp(tester, seed: seedWithoutFiles);
      await viewReport(tester, handedInTaskName);
      await settle(tester, 6);
      expect(drawnPictures, findsNothing);
      expect(failedPictures, findsNWidgets(2));
      expect(
        find.textContaining(
          'android-tool-call.png is gone from the harness’s machine',
        ),
        findsOneWidget,
      );
      // The rest of the page reads as it did.
      expect(find.text('PROBLEM'), findsOneWidget);
      expect(find.text('EVIDENCE'), findsOneWidget);
      final fromTask = await readPage(tester, frame);

      await tester.pumpWidget(const SizedBox());
      frame = await openApp(tester, seed: seedWithoutFiles);
      await openFullView(tester);
      await settle(tester, 6);
      expect(failedPictures, findsNWidgets(2));
      final fromSession = await readPage(tester, frame);
      expect(fromTask.words, fromSession.words);
      expect(fromTask.differences(fromSession), 0);

      // The file is back: the person asks again.
      harness.seedShowcasePictures();
      await tester.ensureVisible(find.text('Try again').first);
      await tester.pump();
      await tester.tap(find.text('Try again').first);
      await settle(tester, 8);
      await settleDecoded(tester);
      expect(drawnPictures, findsOneWidget);
      expect(failedPictures, findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('the page of a report', () {
    late HandInReport report;
    late Map<String, Object?> record;

    setUp(() {
      final harness = FakeHarness();
      seedHandedInTask(harness);
      record = handedInRecord(harness);
      report = HandInReport.fromWire(record);
    });

    for (final (width, scale) in [(320.0, 1.0), (390.0, 1.5), (320.0, 1.5)]) {
      testWidgets('fits a phone $width points wide, text at $scale×', (
        tester,
      ) async {
        await _pumpPage(tester, report, width: width, textScale: scale);
        expect(find.text('PROBLEM'), findsOneWidget);
        expect(find.text('EVIDENCE'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('looks the same, and opens the same, on an Apple phone', (
      tester,
    ) async {
      await _pumpPage(tester, report, style: HarnessPlatformStyle.cupertino);
      expect(find.byType(CupertinoNavigationBar), findsOneWidget);
      expect(find.text('Hand-in report'), findsOneWidget);
      expect(find.text('PROBLEM'), findsOneWidget);
      expect(find.textContaining('Handed in'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('is what the full view of a call that went through is', (
      tester,
    ) async {
      await _pumpFullView(
        tester,
        ToolView(
          callId: 'c1',
          tool: 'mcp__harness__hand_in',
          status: 'completed',
          output: 'Handed in.',
          meta: {'report': record},
        ),
      );
      expect(find.byType(HandInReportScreen), findsOneWidget);
      expect(find.text('PROBLEM'), findsOneWidget);
    });

    testWidgets('is not what the full view of a refused hand-in is', (
      tester,
    ) async {
      // No report was handed in: what was asked for, and why it was refused.
      await _pumpFullView(
        tester,
        ToolView(
          callId: 'c1',
          tool: 'hand_in',
          status: 'failed',
          isError: true,
          input: {'problem': 'Why', 'summary': 'Because', 'evidence': []},
          output: 'hand_in needs evidence: at least one image.',
        ),
      );
      expect(find.byType(HandInReportScreen), findsNothing);
      expect(find.text('ERROR'), findsOneWidget);
      expect(find.text('PROBLEM'), findsNothing);
    });
  });
}
