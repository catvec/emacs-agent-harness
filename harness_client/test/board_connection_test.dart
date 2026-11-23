// The board pages while the connection to the harness goes.
//
// A board page is opened over the shell, so the shell's own connection
// banner is covered by it.  A connection that goes must therefore say so on
// the board's own page, in the app's words for a lost connection -- and must
// never be shown as the board's answer: "No board · The connection was
// closed." is the defect this holds shut, and "ACP error -32003: ..." on the
// list of boards is the same defect one page out.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/app.dart';
import 'package:harness_client/src/acp/acp_client.dart';
import 'package:harness_client/src/models/board.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/board_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:harness_client/src/ui/adaptive/platform_style.dart';
import 'package:harness_client/src/ui/screens/board_screen.dart';
import 'package:harness_client/src/ui/screens/boards_screen.dart';
import 'package:harness_client/src/ui/theme/harness_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';

class _Rig {
  _Rig(this.settings, this.harness, this.app);
  final SettingsController settings;
  final FakeHarness harness;
  final AppController app;
}

Future<_Rig> _rig() async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsController();
  await settings.load();
  final harness = FakeHarness(boards: true);
  final app = AppController(
    settings: settings,
    connector: harness.connector,
    reconnectDelays: const [Duration(hours: 1)],
  );
  // The app is disposed by whoever shows it: the widget tree for a test that
  // pumps the app, and the board page's own test for one that does not.
  await app.connect('ws://memory/acp');
  // A request made while the app is getting a lost connection back waits
  // for the new one: in these tests the harness is out of reach, so the
  // wait is short rather than the ten seconds a person gets.
  app.api!.reconnectGrace = const Duration(milliseconds: 20);
  return _Rig(settings, harness, app);
}

Future<void> _settle(WidgetTester tester, [int rounds = 10]) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 120));
    _takeOverflows(tester);
  }
}

/// The board page can overflow in a phone-wide test view with the test font's
/// square letters; that is no concern of what is under test, so overflows
/// are taken, and anything else still fails.
void _takeOverflows(WidgetTester tester) {
  final error = tester.takeException();
  if (error != null && !error.toString().contains('overflowed')) {
    throw error;
  }
}

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// One board's page, alone, drawing from a controller the test can read.
Future<BoardController> _boardPage(
  WidgetTester tester,
  _Rig rig,
) async {
  // The page does not own the app: whoever made it does.
  addTearDown(rig.app.dispose);
  final controller = BoardController(rig.app.harness, boardId: 'b-fieldnotes');
  addTearDown(controller.dispose);
  _phone(tester);
  await tester.pumpWidget(
    HarnessStyle(
      style: HarnessPlatformStyle.material,
      child: MaterialApp(
        theme: HarnessTheme.material(Brightness.light),
        home: BoardScreen(
          app: rig.app,
          board: 'b-fieldnotes',
          controller: controller,
        ),
      ),
    ),
  );
  await tester.pump();
  await _settle(tester, 8);
  return controller;
}

/// The harness out of reach: what the app holds now is closed, and every
/// attempt to open another is refused.  A request made in that state fails
/// as a request on a closed connection does.
Future<void> _unreachable(WidgetTester tester, _Rig rig) async {
  rig.harness.refuseConnects = 1000000;
  await rig.harness.dropConnection('The connection dropped.');
  await _until(tester, () => rig.app.isReconnecting);
}

/// The harness is back, and the app is in again.  A test ends here: an app
/// still waiting to try again would leave its timer behind, which the test
/// binding refuses.
Future<void> _reachable(WidgetTester tester, _Rig rig) async {
  rig.harness.refuseConnects = 0;
  rig.app.retryNow();
  await _until(tester, () => rig.app.isConnected);
  await _settle(tester, 6);
}

/// Pump until [done]: a widget test's clock moves only when it pumps, so
/// what the app does on its own -- noticing a connection that went, failing
/// a request on it -- happens as the frames go by.
Future<void> _until(
  WidgetTester tester,
  bool Function() done, {
  int rounds = 40,
}) async {
  for (var i = 0; i < rounds; i++) {
    if (done()) return;
    await tester.pump(const Duration(milliseconds: 40));
    _takeOverflows(tester);
  }
  if (!done()) fail('Timed out waiting for the app.');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('a board page whose connection goes', () {
    testWidgets('says the connection is being got back, and keeps the board', (
      tester,
    ) async {
      final rig = await _rig();
      final controller = await _boardPage(tester, rig);
      expect(controller.document, isNotNull);
      expect(find.byKey(const Key('connection-banner')), findsNothing);

      await _unreachable(tester, rig);
      // A refresh while the connection is out: the harness answers nothing,
      // because there is no connection to answer on.
      unawaited(controller.refresh());
      await _settle(tester, 8);

      // Not the board's error: the connection's, on the board's own page.
      expect(find.byKey(const Key('connection-banner')), findsOneWidget);
      expect(find.text('Connection lost. Reconnecting…'), findsOneWidget);
      expect(find.textContaining('connection was closed'), findsNothing);
      expect(find.text('No board'), findsNothing);
      // What the person was looking at is still there.
      expect(controller.document, isNotNull);
      expect(find.byKey(const ValueKey('board-canvas')), findsOneWidget);
      await _reachable(tester, rig);
    });

    testWidgets('a board never read waits, rather than saying there is none', (
      tester,
    ) async {
      final rig = await _rig();
      await _unreachable(tester, rig);
      final controller = await _boardPage(tester, rig);
      expect(controller.document, isNull);
      expect(controller.connectionLost, isTrue);
      // A wait for the connection, whose banner says why: not "No board",
      // which is a claim about the harness that nobody made.
      expect(find.text('No board'), findsNothing);
      expect(find.textContaining('connection was closed'), findsNothing);
      expect(find.byKey(const Key('connection-banner')), findsOneWidget);
      await _reachable(tester, rig);
    });

    testWidgets('an edit whose answer was lost is unconfirmed, not refused', (
      tester,
    ) async {
      final rig = await _rig();
      final controller = await _boardPage(tester, rig);
      await _unreachable(tester, rig);
      final before = rig.harness.boardBatches.length;

      // A tap with the note tool: the ordinary patch, preview and commit.
      await tester.tap(find.byKey(const ValueKey('board-tool-note')));
      await tester.pump();
      final canvas = tester.getRect(find.byKey(const ValueKey('board-canvas')));
      await tester.tapAt(canvas.center);
      await _settle(tester, 8);

      // Nothing reached the harness, and the page says what that means: the
      // answer never came, so it is unconfirmed -- not refused, which is
      // something only the harness can say.
      expect(rig.harness.boardBatches.length, before);
      expect(controller.actionError, isNull);
      expect(controller.notice, 'Unconfirmed');
      expect(controller.connectionLost, isTrue);
      expect(find.textContaining('Unconfirmed'), findsWidgets);
      expect(find.textContaining('connection was closed'), findsNothing);
      expect(find.byKey(const Key('connection-banner')), findsOneWidget);
      await _reachable(tester, rig);
    });

    testWidgets('reads the board again once the connection is back', (
      tester,
    ) async {
      final rig = await _rig();
      final controller = await _boardPage(tester, rig);
      await _unreachable(tester, rig);
      unawaited(controller.refresh());
      await _settle(tester, 8);
      expect(controller.connectionLost, isTrue);
      final reads = rig.harness.requestsByClient
          .where((method) => method == '_harness/board/get')
          .length;

      // The harness is back: the app connects again by itself, and the page
      // reads what the board holds now -- the edit whose answer was lost is
      // settled by that, and the notice that said so goes.
      rig.harness.refuseConnects = 0;
      rig.app.retryNow();
      await _settle(tester, 16);
      expect(rig.app.isConnected, isTrue);
      expect(controller.connectionLost, isFalse);
      expect(controller.notice, isNull);
      expect(
        rig.harness.requestsByClient
            .where((method) => method == '_harness/board/get')
            .length,
        greaterThan(reads),
      );
      expect(find.byKey(const Key('connection-banner')), findsNothing);
    });
  });

  group('the boards page while the connection goes', () {
    testWidgets('a board made while the connection went is unconfirmed', (
      tester,
    ) async {
      final rig = await _rig();
      _phone(tester);
      await tester.pumpWidget(
        HarnessApp(settings: rig.settings, appController: rig.app),
      );
      await tester.pump();
      await _settle(tester, 8);
      await tester.tap(find.text('Boards').last);
      await _settle(tester, 8);
      await _unreachable(tester, rig);

      // A new board: the sheet is answered, and the request it makes is one
      // whose answer never comes.
      await tester.tap(find.byTooltip('New board').last);
      await _settle(tester, 4);
      await tester.enterText(find.byKey(const ValueKey('board-new-name')), 'notes');
      await tester.tap(find.byKey(const ValueKey('board-new-create')));
      await _settle(tester, 8);

      // Not refused, which only the harness can say, and not silently gone:
      // the page says the making is unconfirmed.
      expect(find.textContaining('Unconfirmed'), findsOneWidget);
      expect(find.textContaining('ACP error'), findsNothing);
      expect(find.byKey(const Key('connection-banner')), findsOneWidget);
      await _reachable(tester, rig);
    });

    testWidgets('keeps the boards it read, and says the connection is out', (
      tester,
    ) async {
      final rig = await _rig();
      _phone(tester);
      await tester.pumpWidget(
        HarnessApp(settings: rig.settings, appController: rig.app),
      );
      await tester.pump();
      await _settle(tester, 8);
      await tester.tap(find.text('Boards').last);
      await _settle(tester, 8);
      expect(find.text('atlas / fieldnotes'), findsWidgets);

      await _unreachable(tester, rig);
      // A refresh while the connection is out.
      await tester.tap(find.byTooltip('Refresh').last);
      await _settle(tester, 10);

      // The list is what the harness last said, and the failure is the
      // connection's, in the app's words: no exception text, no claim that
      // the harness has no boards.
      expect(find.byType(BoardsScreen), findsOneWidget);
      expect(find.text('atlas / fieldnotes'), findsWidgets);
      expect(find.textContaining('ACP error'), findsNothing);
      expect(find.textContaining('connection was closed'), findsNothing);
      expect(find.text('No boards'), findsNothing);
      expect(find.byKey(const Key('connection-banner')), findsOneWidget);
      await _reachable(tester, rig);
    });

    testWidgets('a list never read waits, rather than saying there are none', (
      tester,
    ) async {
      final rig = await _rig();
      _phone(tester);
      await tester.pumpWidget(
        HarnessApp(settings: rig.settings, appController: rig.app),
      );
      await tester.pump();
      await _settle(tester, 8);
      // The connection goes before the boards page is ever opened, so its
      // first read is made with none.
      await _unreachable(tester, rig);
      await tester.tap(find.text('Boards').last);
      await _settle(tester, 10);
      expect(find.text('No boards'), findsNothing);
      expect(find.textContaining('ACP error'), findsNothing);
      expect(find.byKey(const Key('connection-banner')), findsOneWidget);
      await _reachable(tester, rig);
    });
  });

  group('the words', () {
    test('a lost connection is the transport failure, and nothing else', () {
      expect(boardTransportFailure(const AcpException(-32003, 'x')), isTrue);
      // The board's own refusals are the harness's answers, and are shown.
      expect(boardTransportFailure(const AcpException(-32603, 'x')), isFalse);
      expect(boardTransportFailure(const AcpException(-32602, 'x')), isFalse);
      expect(boardTransportFailure(Exception('something else')), isFalse);
      // A state, and no guess at what became of the edit.
      expect(boardUnconfirmedNotice, 'Unconfirmed');
    });

    test('a place is read from the wire as the page shows it', () {
      final place = BoardPlace.fromWire({'board': 'b-1', 'diagram': 'd-1'});
      expect(place.board, 'b-1');
      expect(place.isEmpty, isFalse);
    });
  });
}
