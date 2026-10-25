// Pictures of the pictures: the screenshots a task handed in, the image a
// `read_file` call read, a picture shown larger, the report a task's sheet
// opens, and the places where a picture is not there, on a phone, drawn with
// the fonts of one.
//
//   HARNESS_SHOTS=/some/directory flutter test test/picture_screenshots_test.dart
//
// writes a PNG for each case there.  Without HARNESS_SHOTS the cases still
// run (they draw, and check what is on the screen), and write nothing.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/app.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';
import 'support/real_fonts.dart';
import 'support/tool_showcase.dart';
import 'support/transcript_log.dart';

/// Screenshots of the app itself, as a task that changed it would hand in.
final _chat = File('screenshots/android-chat.png').readAsBytesSync();

void _givePictures(FakeHarness harness) {
  harness.seedShowcasePictures();
  harness.pictureFiles['/work/shots/chat.png'] = (
    mime: 'image/png',
    bytes: _chat,
  );
  harness.pictureFiles['screenshots/android-chat.png'] = (
    mime: 'image/png',
    bytes: _chat,
  );
}

/// A session in which a `read_file` call read a screenshot.
void _seedRead(FakeHarness harness) {
  final log = TranscriptLog()
    ..user('What does the chat look like now?')
    ..say('Let me look at the screenshot the last run left.')
    ..call(
      'c1',
      'read_file',
      title: 'Read file: shots/chat.png',
      input: {'path': 'shots/chat.png'},
      output: 'Image chat.png (image/png, 217 KiB, 1082x2402 px).',
      attachments: [
        {
          'path': '/work/shots/chat.png',
          'mime': 'image/png',
          'size': _chat.length,
          'name': 'chat.png',
        },
      ],
    )
    ..say('The tool cards are closed until they are opened, as intended.');
  harness.sessions['s-read'] = {
    ...toolShowcaseSession(),
    'id': 's-read',
    'name': 'Look at the chat',
  };
  harness.nodes['s-read'] = [...log.nodes];
}

void _seedShowcase(FakeHarness harness) => harness.seedToolShowcase();

/// The task in review has a session, as every task does.
void _seedReview(FakeHarness harness) =>
    harness.tasks['task-2']!['session'] = 's-review';

/// A phone's screen, in points.
const _width = 390.0;
const _height = 844.0;

class _Case {
  const _Case(this.file, this.run, {this.seed, this.apple = false});
  final String file;

  /// Drawn in the style of an iPhone, not of an Android phone.
  final bool apple;

  /// What the person does, once the app is open.
  final Future<void> Function(WidgetTester tester, FakeHarness harness) run;

  /// What the harness has, before the app connects.
  final void Function(FakeHarness harness)? seed;
}

Future<void> _pump(WidgetTester tester, [int rounds = 8]) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

/// Time passes in the real world, as decoding a picture takes.
Future<void> _decoded(WidgetTester tester) async {
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

final _drawn = find.byKey(const ValueKey('picture-drawn'));

Future<void> _scrollTo(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await _pump(tester, 4);
}

final _cases = <_Case>[
  _Case('picture-read-file', seed: _seedRead, (tester, harness) async {
    await tester.tap(find.text('Look at the chat'));
    await _pump(tester, 20);
    await tester.tap(find.textContaining('Read file: shots/chat.png'));
    await _pump(tester, 12);
    await _decoded(tester);
    expect(_drawn, findsOneWidget);
    expect(find.text('PICTURE'), findsOneWidget);
    expect(harness.imageRequests, [('s-read', '/work/shots/chat.png')]);
  }),
  _Case('picture-hand-in', seed: _seedShowcase, (tester, harness) async {
    await tester.tap(find.text(toolShowcaseName));
    await _pump(tester, 30);
    await tester.tap(find.textContaining('Hand in the finished work'));
    await _pump(tester, 12);
    await _decoded(tester);
    expect(_drawn, findsNWidgets(2));
    await _scrollTo(tester, find.textContaining('A bash call opened'));
    await _decoded(tester);
  }),
  _Case('picture-viewer', seed: _seedRead, (tester, harness) async {
    await tester.tap(find.text('Look at the chat'));
    await _pump(tester, 20);
    await tester.tap(find.textContaining('Read file: shots/chat.png'));
    await _pump(tester, 12);
    await _decoded(tester);
    await tester.tap(_drawn);
    await _pump(tester, 10);
    await _decoded(tester);
    expect(find.byKey(const ValueKey('picture-viewer')), findsOneWidget);
    // A double tap zooms in on the place that was tapped.
    final at = tester.getCenter(find.byType(InteractiveViewer));
    await tester.tapAt(at);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(at);
    await _pump(tester, 4);
  }),
  _Case('picture-task-sheet', seed: _seedReview, (tester, harness) async {
    await tester.tap(find.text('Tasks'));
    await _pump(tester, 6);
    await tester.ensureVisible(find.text('Review'));
    await tester.tap(find.text('Review'));
    await _pump(tester, 4);
    await tester.tap(find.text('Review the emulator screenshots'));
    await _pump(tester, 12);
    // The sheet leads to the report; the report is on its page.
    await _scrollTo(tester, find.text('View report'));
    await tester.tap(find.text('View report'));
    await _pump(tester, 12);
    await _decoded(tester);
    expect(_drawn, findsOneWidget);
    await _scrollTo(tester, find.text('flutter test: 38 passing'));
    await _decoded(tester);
  }),
  _Case(
    'picture-gone',
    seed: (harness) {
      _seedShowcase(harness);
      harness.pictureFiles.clear();
    },
    (tester, harness) async {
      await tester.tap(find.text(toolShowcaseName));
      await _pump(tester, 30);
      await tester.tap(find.textContaining('Hand in the finished work'));
      await _pump(tester, 12);
      expect(find.byKey(const ValueKey('picture-failed')), findsNWidgets(2));
      await _scrollTo(tester, find.textContaining('A bash call opened'));
    },
  ),
  _Case('picture-hand-in-apple', seed: _seedShowcase, apple: true, (
    tester,
    harness,
  ) async {
    await tester.tap(find.text(toolShowcaseName));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 120));
      // The tabs of the home screen are all there under the page that opens,
      // each with a navigation bar of the same hero tag, which Cupertino
      // pages complain of in a debug build: not what is drawn.
      tester.takeException();
    }
    await tester.tap(find.textContaining('Hand in the finished work'));
    await _pump(tester, 12);
    await _decoded(tester);
    expect(_drawn, findsNWidgets(2));
    await _scrollTo(tester, find.textContaining('A bash call opened'));
    await _decoded(tester);
    // Tapped, it is shown larger in the style of the phone.
    await tester.tap(_drawn.first);
    await _pump(tester, 10);
    tester.takeException();
    expect(find.byKey(const ValueKey('picture-viewer')), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close_rounded));
    await _pump(tester, 10);
    tester.takeException();
    expect(find.byKey(const ValueKey('picture-viewer')), findsNothing);
    await _decoded(tester);
  }),
  _Case('picture-older-harness', seed: _seedShowcase, (tester, harness) async {
    await tester.tap(find.text(toolShowcaseName));
    await _pump(tester, 30);
    await tester.tap(find.textContaining('Hand in the finished work'));
    await _pump(tester, 12);
    expect(_drawn, findsNothing);
    expect(harness.imageRequests, isEmpty);
    await _scrollTo(tester, find.textContaining('A bash call opened'));
  }),
];

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  final shots = Platform.environment['HARNESS_SHOTS'];
  final real = await loadRealFonts();

  for (final shot in _cases) {
    testWidgets('draws ${shot.file}', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsController();
      await settings.load();
      if (shot.apple) {
        await settings.setPreviewPlatform(PreviewPlatform.cupertino);
      }
      final harness = FakeHarness(
        sessionPictures: shot.file != 'picture-older-harness',
      );
      _givePictures(harness);
      shot.seed?.call(harness);
      final app = AppController(
        settings: settings,
        connector: harness.connector,
      );
      await app.connect('ws://memory/acp');

      const ratio = 2.0;
      tester.view.physicalSize = const Size(_width * ratio, _height * ratio);
      tester.view.devicePixelRatio = ratio;
      tester.view.viewPadding = const FakeViewPadding(
        top: 24 * ratio,
        bottom: 24 * ratio,
      );
      tester.view.padding = tester.view.viewPadding;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);

      final boundary = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: HarnessApp(settings: settings, appController: app),
        ),
      );
      await tester.pump();
      await _pump(tester, 10);

      await shot.run(tester, harness);
      // What grew when a picture came has grown.
      await _decoded(tester);
      await _pump(tester, 6);

      if (shots != null) {
        await tester.runAsync(() async {
          final render =
              boundary.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await render.toImage(pixelRatio: 1.5);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File('$shots/${shot.file}${real ? '' : '-ahem'}.png');
          file.parent.createSync(recursive: true);
          file.writeAsBytesSync(data!.buffer.asUint8List());
        });
      }
    });
  }
}
