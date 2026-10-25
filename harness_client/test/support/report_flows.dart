// The two ways to a task's report, driven the way a person drives them, and
// the means to compare what they end on: the words of a page and every pixel
// of the app.  The tests of the report (`hand_in_report_test.dart`) and its
// pictures (`hand_in_report_screenshots_test.dart`) share them.
//
// Drawn with the fonts of a phone (`loadRealFonts`): the board's header holds
// a spend chip, which the test font, with its wide letters, squeezes out of
// its row.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/app.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:harness_client/src/ui/screens/hand_in_report_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_harness.dart';
import 'tool_showcase.dart';

/// Time passes, [rounds] frames of 120 ms.
Future<void> settle(WidgetTester tester, [int rounds = 10]) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

/// Time passes in the real world, as decoding a picture takes: a picture has
/// no size until its first frame is decoded, and a page is not what it will be
/// until then.
Future<void> settleDecoded(WidgetTester tester) async {
  for (var i = 0; i < 120; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump();
    if (find.byKey(const ValueKey('picture-loading')).evaluate().isEmpty) {
      return;
    }
  }
}

/// The pictures drawn, and the places where one could not be had.
final drawnPictures = find.byKey(const ValueKey('picture-drawn'));
final failedPictures = find.byKey(const ValueKey('picture-failed'));

/// An app on a phone of [width] by [height] points, connected to a harness
/// that [seed] fills (one that gives the pictures its transcripts show,
/// unless [sessionPictures] is false).  What it draws is in the boundary the
/// key names.
Future<GlobalKey> openApp(
  WidgetTester tester, {
  required void Function(FakeHarness harness) seed,
  double width = 390,
  double height = 844,
  double ratio = 3.0,
  bool apple = false,
  bool sessionPictures = true,
}) async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsController();
  await settings.load();
  if (apple) await settings.setPreviewPlatform(PreviewPlatform.cupertino);
  final harness = FakeHarness(sessionPictures: sessionPictures);
  seed(harness);
  final app = AppController(settings: settings, connector: harness.connector);
  await app.connect('ws://memory/acp');
  tester.view.physicalSize = Size(width * ratio, height * ratio);
  tester.view.devicePixelRatio = ratio;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final frame = GlobalKey();
  await tester.pumpWidget(
    RepaintBoundary(
      key: frame,
      child: HarnessApp(settings: settings, appController: app),
    ),
  );
  await tester.pump();
  await settle(tester, 8);
  return frame;
}

/// The sheet of the task [name] on the board.
Future<void> openSheet(WidgetTester tester, String name) async {
  await tester.tap(find.text('Tasks'));
  await settle(tester, 6);
  await tester.tap(find.text(name));
  await settle(tester, 8);
}

/// "View report", on the sheet of the task [name]: the board's way.
Future<void> viewReport(WidgetTester tester, String name) async {
  await openSheet(tester, name);
  await tester.ensureVisible(find.text('View report'));
  await tester.pump();
  await tester.tap(find.text('View report'));
  await settle(tester, 8);
}

/// The session [toolShowcaseName] opened on the call that handed the work in,
/// and that call opened: the card of the report in the transcript.
Future<void> openHandInCard(WidgetTester tester) async {
  await tester.tap(find.text(toolShowcaseName));
  await settle(tester, 30);
  await tester.tap(find.textContaining('Hand in the finished work'));
  await settle(tester, 8);
}

/// "Open full view", on the call of the session that handed the work in: the
/// session's way.
Future<void> openFullView(WidgetTester tester) async {
  await openHandInCard(tester);
  await tapOpenFullView(tester);
}

/// "Open full view" on the card that is open.  The screenshots in the card
/// have come, and the transcript is as long as it will be, before the
/// button is looked for: it is at the foot of the card, below them.
Future<void> tapOpenFullView(WidgetTester tester) async {
  await settleDecoded(tester);
  await settle(tester, 6);
  final button = find.text('Open full view');
  // The list is scrolled to the button, and once more, as it is not the
  // length it was a moment ago.
  for (var i = 0; i < 2; i++) {
    await tester.ensureVisible(button);
    await tester.pump();
  }
  await tester.tap(button);
  await settle(tester, 8);
}

/// What the page of a report is: its words, in order, and every pixel the
/// app draws.
class ReportPage {
  ReportPage(this.words, this.pixels);

  final List<String> words;
  final Uint8List pixels;

  /// How many bytes of the picture differ from [other]'s, or -1 when the
  /// pictures are not of one size.
  int differences(ReportPage other) {
    if (pixels.length != other.pixels.length) return -1;
    var count = 0;
    for (var i = 0; i < pixels.length; i++) {
      if (pixels[i] != other.pixels[i]) count++;
    }
    return count;
  }
}

/// The picture of [frame] as raw RGBA.
Future<Uint8List> pixelsOf(WidgetTester tester, GlobalKey frame) async {
  final pixels = await tester.runAsync(() async {
    final boundary =
        frame.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage();
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    return data!.buffer.asUint8List();
  });
  return pixels!;
}

/// The page of the report that is open.
Future<ReportPage> readPage(WidgetTester tester, GlobalKey frame) async {
  final page = find.byType(HandInReportScreen);
  expect(page, findsOneWidget);
  // Text is a `RichText`; what can be selected (the markdown of the report
  // is) is an `EditableText`.
  final words = [
    for (final widget in tester.widgetList(
      find.descendant(
        of: page,
        matching: find.byWidgetPredicate(
          (widget) => widget is RichText || widget is EditableText,
        ),
      ),
    ))
      widget is RichText
          ? widget.text.toPlainText()
          : (widget as EditableText).controller.text,
  ];
  return ReportPage(words, await pixelsOf(tester, frame));
}
