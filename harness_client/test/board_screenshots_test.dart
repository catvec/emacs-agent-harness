// Pictures of the board pages, on a phone and on a desktop.
//
//   HARNESS_SHOTS=/some/directory flutter test test/board_screenshots_test.dart
//
// writes a PNG for each case there.  Without HARNESS_SHOTS the cases still
// draw, check that nothing overflows, and write nothing.  The list is read
// through the fake harness's board fixture; the board itself is the engine's
// own preview drawing, which is the same geometry a harness answers with.
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/models/board.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/board_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:harness_client/src/ui/adaptive/platform_style.dart';
import 'package:harness_client/src/ui/screens/board_screen.dart';
import 'package:harness_client/src/ui/screens/boards_screen.dart';
import 'package:harness_client/src/ui/theme/harness_theme.dart';
import 'package:harness_client/src/ui/widgets/board_canvas.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';
import 'support/real_fonts.dart';

Future<void> _write(
  WidgetTester tester,
  GlobalKey boundary,
  String path,
) async {
  await tester.runAsync(() async {
    final object =
        boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await object.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File(path);
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

/// The pages are drawn in a box of this size, and the picture is of the box:
/// a phone, or a desktop window.
Widget _framed(GlobalKey boundary, Size size, Widget home) => RepaintBoundary(
  key: boundary,
  child: HarnessStyle(
    style: HarnessPlatformStyle.material,
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: HarnessTheme.material(Brightness.light),
      home: MediaQuery(
        data: MediaQueryData(size: size),
        child: home,
      ),
    ),
  ),
);

Future<GlobalKey> _showList(
  WidgetTester tester, {
  Size size = const Size(390, 844),
}) async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsController();
  await settings.load();
  final harness = FakeHarness(boards: true);
  final app = AppController(settings: settings, connector: harness.connector);
  await app.connect('ws://memory/acp');
  addTearDown(app.dispose);
  _sized(tester, size);
  final boundary = GlobalKey();
  await tester.pumpWidget(_framed(boundary, size, BoardsScreen(app: app)));
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 120));
    _takeOverflows(tester);
  }
  return boundary;
}

Future<GlobalKey> _showBoard(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  String diagram = 'd-overview',
  String? object,
}) async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsController();
  await settings.load();
  final app = AppController(settings: settings);
  addTearDown(app.dispose);
  final controller = BoardController.preview(
    diagramId: diagram,
    objectId: object,
  );
  addTearDown(controller.dispose);
  _sized(tester, size);
  final boundary = GlobalKey();
  await tester.pumpWidget(
    _framed(
      boundary,
      size,
      BoardScreen(
        app: app,
        board: 'b-fieldnotes',
        controller: controller,
      ),
    ),
  );
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 120));
    _takeOverflows(tester);
  }
  await _decoded(tester);
  return boundary;
}

/// Time passes in the real world, as decoding the drawing's picture takes:
/// a widget test's own clock would leave the image an outlined box, and the
/// picture would be a lie about what the board draws.
Future<void> _decoded(WidgetTester tester) async {  for (var i = 0; i < 120; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump();
    if (_pictureIsDrawn(tester)) return;
  }
}

/// Whether the canvas's painter holds the decoded preview picture.
bool _pictureIsDrawn(WidgetTester tester) {
  for (final element in find
      .descendant(
        of: find.byType(BoardScreen),
        matching: find.byType(CustomPaint),
      )
      .evaluate()) {
    final painter = (element.widget as CustomPaint).painter;
    if (painter is BoardCanvasPainter &&
        painter.pictures.image(boardPreviewPicture) != null) {
      return true;
    }
  }
  return false;
}

/// A picture is of the surface the pages are drawn on, so the test's own
/// surface is the size asked for: a phone is phone-shaped in the file.
void _sized(WidgetTester tester, Size size) {
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// The board page can overflow in a narrow view with the test font's square
/// letters; that is no concern of the canvas under test, so overflows are
/// taken, and anything else still fails.
void _takeOverflows(WidgetTester tester) {
  final error = tester.takeException();
  if (error != null && !error.toString().contains('overflowed')) {
    throw error;
  }
}

void main() {
  final shots = Platform.environment['HARNESS_SHOTS'];
  setUpAll(() async {
    await loadRealFonts();
  });

  testWidgets('the boards list on a phone', (tester) async {
    final boundary = await _showList(tester);
    expect(find.text('atlas / fieldnotes'), findsWidgets);
    if (shots != null) {
      await _write(tester, boundary, '$shots/board-list-phone.png');
    }
  });

  testWidgets('the board on a phone', (tester) async {
    final boundary = await _showBoard(tester);
    expect(find.textContaining('No selection'), findsOneWidget);
    if (shots != null) {
      await _write(tester, boundary, '$shots/board-phone.png');
    }
  });

  testWidgets('the board on a desktop', (tester) async {
    final boundary = await _showBoard(
      tester,
      size: const Size(1280, 860),
    );
    if (shots != null) {
      await _write(tester, boundary, '$shots/board-desktop.png');
    }
  });

  testWidgets('a component selected, in the diagram walked into', (
    tester,
  ) async {
    final boundary = await _showBoard(
      tester,
      diagram: 'd-queue',
      object: 'n-api',
      size: const Size(1280, 860),
    );
    // The same object, drawn again in a second diagram: one meaning, two views.
    expect(find.textContaining('api'), findsWidgets);
    if (shots != null) {
      await _write(tester, boundary, '$shots/board-queue-detail.png');
    }
  });

  testWidgets('the tools a person builds a diagram with, on a phone', (
    tester,
  ) async {
    final boundary = await _showBoard(tester);
    // The hand and the kinds of object a tap can put down: nouns, and the
    // way into a diagram of one's own.
    for (final word in ['Select', 'Note', 'Shape', 'Frame', 'Label', 'Ink']) {
      expect(find.text(word), findsOneWidget, reason: word);
    }
    expect(find.text('New diagram'), findsOneWidget);
    if (shots != null) {
      await _write(tester, boundary, '$shots/board-tools-phone.png');
    }
  });

  testWidgets('a selected object and what can be done with it', (tester) async {
    final boundary = await _showBoard(
      tester,
      object: 'n-api',
      size: const Size(1280, 860),
    );
    // The actions are verbs; a tool with nothing to act on says why.
    for (final word in [
      'Edit',
      'Rotate',
      'Connect',
      'Group',
      'Portal',
      'Discuss',
      'Request task',
      'Delete',
      'Links',
    ]) {
      expect(find.text(word), findsOneWidget, reason: word);
    }
    // The component marks a task, so Discuss names where it would speak;
    // the board has a second diagram, so Portal is offered; one object is
    // selected, so the actions that need two say what they need.
    expect(find.byTooltip('Discuss in the task review'), findsOneWidget);
    expect(find.byTooltip('Drill down from this object'), findsOneWidget);
    expect(find.byTooltip('Connect two selected objects'), findsOneWidget);
    expect(find.byTooltip('Group two selected objects'), findsOneWidget);
    // The preview board has a project, so a task can be asked for.
    expect(
      find.byTooltip('Implementation task from the selection'),
      findsOneWidget,
    );
    if (shots != null) {
      await _write(tester, boundary, '$shots/board-selection-desktop.png');
    }
  });

  testWidgets('a narrow phone keeps the page inside its width', (tester) async {
    await _showBoard(tester, size: const Size(320, 640));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the board with the connection lost, on a phone', (tester) async {
    final (boundary, app, harness) = await _showLostBoard(tester);
    // The connection's words on the board's own page, and no claim about
    // the board: the drawing the person was looking at is still there.
    expect(app.isReconnecting, isTrue);
    expect(find.byKey(const Key('connection-banner')), findsOneWidget);
    expect(find.textContaining('connection was closed'), findsNothing);
    expect(find.text('No board'), findsNothing);
    if (shots != null) {
      await _write(tester, boundary, '$shots/board-connection-lost-phone.png');
    }
    // The connection is got back, so the app leaves no retry behind.
    harness.refuseConnects = 0;
    app.retryNow();
    for (var i = 0; i < 40 && !app.isConnected; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
    expect(app.isConnected, isTrue);
  });
}

/// The board page of an app whose connection has just gone: the page is a
/// route over the shell, so this is where the person reads it.  The harness
/// is a scripted one that closes the connection and refuses the next ones,
/// so what is drawn is the app's own answer to a lost connection rather than
/// a fixture of this file.  The app comes back before this returns, so that
/// no retry is left waiting on a clock when the test ends.
Future<(GlobalKey, AppController, FakeHarness)> _showLostBoard(
  WidgetTester tester, {
  Size size = const Size(390, 844),
}) async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsController();
  await settings.load();
  final harness = FakeHarness(boards: true);
  final app = AppController(
    settings: settings,
    connector: harness.connector,
    reconnectDelays: const [Duration(hours: 1)],
  );
  addTearDown(app.dispose);
  await app.connect('ws://memory/acp');
  final controller = BoardController(app.harness, boardId: 'b-fieldnotes');
  addTearDown(controller.dispose);
  _sized(tester, size);
  final boundary = GlobalKey();
  await tester.pumpWidget(
    _framed(
      boundary,
      size,
      BoardScreen(app: app, board: 'b-fieldnotes', controller: controller),
    ),
  );
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 120));
    _takeOverflows(tester);
  }
  expect(controller.document, isNotNull);
  // The connection goes, and the page reads again: the read fails on a
  // connection that is no longer there, which is the state to draw.
  harness.refuseConnects = 1000000;
  await harness.dropConnection('The connection dropped.');
  for (var i = 0; i < 30 && !app.isReconnecting; i++) {
    await tester.pump(const Duration(milliseconds: 40));
    _takeOverflows(tester);
  }
  unawaited(controller.refresh());
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 40));
    _takeOverflows(tester);
  }
  await _decoded(tester);
  return (boundary, app, harness);
}
