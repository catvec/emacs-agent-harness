// Pictures of a task's report on phones, drawn with the fonts of a phone.
//
//   HARNESS_SHOTS=/some/directory flutter test test/hand_in_report_screenshots_test.dart
//
// writes a PNG for each case there: the sheet of a task on the board with its
// report card, the page "View report" opens, the page the session's "Open
// full view" opens (the same page, drawn the same, the screenshots the task
// handed in among its evidence drawn), the two side by side from their top,
// from where their evidence begins (the screenshots), a screen further on
// (the second screenshot) and from their end, the report of work that handed
// none in, the page where a screenshot is gone, and the page in the style of
// an iPhone.  Without HARNESS_SHOTS the cases
// still run (they draw, and check that the page is whole on the picture's
// screen, and that the two ways to the report end on the same pixels), and
// write nothing.  The labels of a Material button are drawn as blocks: the
// test engine has no font for a style that names none.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/ui/screens/hand_in_report_screen.dart';

import 'support/fake_harness.dart';
import 'support/handed_in_task.dart';
import 'support/real_fonts.dart';
import 'support/report_flows.dart';

const _width = 360.0;
const _height = 800.0;
const _ratio = 2.0;

/// A report's page as pictures: from its top, from where its evidence
/// begins (the screenshots are there), a screen further on, and from its end,
/// with what the words and pixels of the page were.
class _Page {
  const _Page({
    required this.top,
    required this.evidence,
    required this.more,
    required this.end,
    required this.read,
  });

  final ui.Image top;
  final ui.Image evidence;
  final ui.Image more;
  final ui.Image end;
  final ReportPage read;
}

/// The phone's frame as a picture.
Future<ui.Image> _picture(WidgetTester tester, GlobalKey frame) async {
  final image = await tester.runAsync(() async {
    final boundary =
        frame.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    return boundary.toImage(pixelRatio: 1.5);
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

/// [left] and [right] side by side, each under the words that say how it was
/// come to.
Future<ui.Image> _sideBySide(
  WidgetTester tester, {
  required ui.Image left,
  required String leftLabel,
  required ui.Image right,
  required String rightLabel,
}) async {
  const margin = 24.0;
  const bar = 64.0;
  final width = left.width + right.width + margin * 3;
  final height = left.height > right.height ? left.height : right.height;
  final image = await tester.runAsync(() async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, width, height + bar + margin),
      Paint()..color = const Color(0xFFFFFFFF),
    );
    void caption(String text, double x) {
      final painter = TextPainter(
        text: TextSpan(
          text: text,
          style: const TextStyle(
            fontFamily: 'Roboto',
            fontSize: 20,
            fontWeight: FontWeight.w500,
            color: Color(0xFF222222),
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 2,
      )..layout(maxWidth: left.width.toDouble());
      painter.paint(canvas, Offset(x, 14));
    }

    caption(leftLabel, margin);
    caption(rightLabel, margin * 2 + left.width);
    final frame = Paint()
      ..color = const Color(0xFFBBBBBB)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawImage(left, const Offset(margin, bar), Paint());
    canvas.drawRect(
      Rect.fromLTWH(margin, bar, left.width.toDouble(), left.height.toDouble()),
      frame,
    );
    final x = margin * 2 + left.width;
    canvas.drawImage(right, Offset(x, bar), Paint());
    canvas.drawRect(
      Rect.fromLTWH(x, bar, right.width.toDouble(), right.height.toDouble()),
      frame,
    );
    return recorder.endRecording().toImage(
      width.round(),
      (height + bar + margin).round(),
    );
  });
  return image!;
}

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  final shots = Platform.environment['HARNESS_SHOTS'];
  final real = await loadRealFonts();
  String path(String name) => '$shots/$name${real ? '' : '-ahem'}.png';

  /// A phone of the pictures' size, on the work that was handed in.
  Future<GlobalKey> open(
    WidgetTester tester, {
    void Function(FakeHarness harness) seed = seedHandedInTaskWithPictures,
    bool apple = false,
  }) async {
    final frame = await openApp(
      tester,
      seed: seed,
      width: _width,
      height: _height,
      ratio: _ratio,
      apple: apple,
    );
    tester.view.viewPadding = const FakeViewPadding(
      top: 24 * _ratio,
      bottom: 24 * _ratio,
    );
    tester.view.padding = tester.view.viewPadding;
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
    await settle(tester, 2);
    return frame;
  }

  /// The page is whole on the screen: it starts under the header and the
  /// screen is not wider than the phone.
  void expectWhole(WidgetTester tester) {
    final list = tester.getRect(find.byKey(const ValueKey('hand-in-report')));
    expect(list.left, greaterThanOrEqualTo(0));
    expect(list.right, lessThanOrEqualTo(_width + 0.01));
    expect(tester.takeException(), isNull);
  }

  testWidgets('draws the sheet of a task with its report card', (tester) async {
    final frame = await open(tester);
    await openSheet(tester, handedInTaskName);
    await tester.ensureVisible(find.text('View report'));
    await settle(tester, 4);
    expect(find.text('View report'), findsOneWidget);
    if (shots != null) {
      await _write(tester, await _picture(tester, frame), path('report-sheet'));
    }
  });

  /// The page that is open, as pictures from four places.
  Future<_Page> readWhole(WidgetTester tester, GlobalKey frame) async {
    expectWhole(tester);
    // The screenshots have come and are drawn: the page has its height.
    await settleDecoded(tester);
    expect(drawnPictures, findsNWidgets(2));
    final list = find.byKey(const ValueKey('hand-in-report'));
    final top = await _picture(tester, frame);
    // The evidence, from its heading: the first of it is the screenshots.
    await tester.ensureVisible(find.text('EVIDENCE'));
    await settle(tester, 4);
    await settleDecoded(tester);
    final evidence = await _picture(tester, frame);
    // A screen further on: the second screenshot.
    await tester.drag(list, const Offset(0, -560));
    await settle(tester, 6);
    await settleDecoded(tester);
    final more = await _picture(tester, frame);
    await tester.drag(list, const Offset(0, -20000));
    await settle(tester, 8);
    await settleDecoded(tester);
    return _Page(
      top: top,
      evidence: evidence,
      more: more,
      end: await _picture(tester, frame),
      read: await readPage(tester, frame),
    );
  }

  testWidgets('draws the report from the board and from the session', (
    tester,
  ) async {
    var frame = await open(tester);
    await viewReport(tester, handedInTaskName);
    final board = await readWhole(tester, frame);

    await tester.pumpWidget(const SizedBox());
    frame = await open(tester);
    await openHandInCard(tester);
    await settleDecoded(tester);
    final card = await _picture(tester, frame);
    await tapOpenFullView(tester);
    final session = await readWhole(tester, frame);

    // The same words, and the same pixels, from the top and at the end.
    expect(board.read.words, session.read.words);
    expect(board.read.differences(session.read), 0);

    if (shots != null) {
      await _write(tester, board.top, path('report-from-board'));
      await _write(tester, board.evidence, path('report-from-board-evidence'));
      await _write(tester, board.more, path('report-from-board-evidence-more'));
      await _write(tester, board.end, path('report-from-board-end'));
      await _write(tester, session.top, path('report-from-session'));
      await _write(
        tester,
        session.evidence,
        path('report-from-session-evidence'),
      );
      await _write(
        tester,
        session.more,
        path('report-from-session-evidence-more'),
      );
      await _write(tester, session.end, path('report-from-session-end'));
      await _write(tester, card, path('report-session-card'));
      const boardWay = 'Tasks > the task > View report';
      const sessionWay =
          'Sessions > the task\'s session > hand-in > Open full view';
      Future<void> both(String name, ui.Image left, ui.Image right) async {
        await _write(
          tester,
          await _sideBySide(
            tester,
            left: left,
            leftLabel: boardWay,
            right: right,
            rightLabel: sessionWay,
          ),
          path(name),
        );
      }

      await both('report-both-entry-points', board.top, session.top);
      await both(
        'report-both-entry-points-evidence',
        board.evidence,
        session.evidence,
      );
      await both(
        'report-both-entry-points-evidence-more',
        board.more,
        session.more,
      );
      await both('report-both-entry-points-end', board.end, session.end);
    }
  });

  testWidgets('draws the report where a screenshot is gone', (tester) async {
    // The worktree of a finished task goes with the task: its files are gone.
    final frame = await open(tester, seed: seedHandedInTask);
    await viewReport(tester, handedInTaskName);
    await settle(tester, 6);
    expectWhole(tester);
    expect(failedPictures, findsNWidgets(2));
    await tester.drag(
      find.byKey(const ValueKey('hand-in-report')),
      const Offset(0, -520),
    );
    await settle(tester, 6);
    if (shots != null) {
      await _write(
        tester,
        await _picture(tester, frame),
        path('report-screenshot-gone'),
      );
    }
  });

  testWidgets('draws the report of work that handed none in', (tester) async {
    final frame = await open(tester, seed: seedUnreportedTask);
    await viewReport(tester, unreportedTaskName);
    expectWhole(tester);
    expect(find.text('LAST MESSAGE'), findsOneWidget);
    if (shots != null) {
      await _write(
        tester,
        await _picture(tester, frame),
        path('report-unreported'),
      );
    }
  });

  testWidgets('draws the report in the style of an iPhone', (tester) async {
    final frame = await open(tester, apple: true);
    await openSheet(tester, handedInTaskName);
    tester.takeException();
    await tester.ensureVisible(find.text('View report'));
    await settle(tester, 4);
    if (shots != null) {
      await _write(
        tester,
        await _picture(tester, frame),
        path('report-sheet-ios'),
      );
    }
    await tester.tap(find.text('View report'));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 120));
      // The tabs of the home screen are all there under the page that
      // opens, each with a navigation bar of the same hero tag, which
      // Cupertino pages complain of in a debug build: not what is drawn.
      tester.takeException();
    }
    expect(find.byType(HandInReportScreen), findsOneWidget);
    expect(find.text('PROBLEM'), findsOneWidget);
    await settleDecoded(tester);
    expect(drawnPictures, findsNWidgets(2));
    if (shots != null) {
      await _write(
        tester,
        await _picture(tester, frame),
        path('report-from-board-ios'),
      );
    }
  });
}
