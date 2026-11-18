import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/app.dart';
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

/// An app connected to a fake harness that keeps a board.
Future<(SettingsController, FakeHarness, AppController)> _rig() async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsController();
  await settings.load();
  final harness = FakeHarness(boards: true);
  final app = AppController(settings: settings, connector: harness.connector);
  await app.connect('ws://memory/acp');
  return (settings, harness, app);
}

Future<void> _settle(WidgetTester tester, [int rounds = 10]) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 120));
    _takeOverflows(tester);
  }
}

/// The board page can overflow in a phone-wide test view with the test font's
/// square letters; that is no concern of the canvas under test, so overflows
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

/// The boards page of a connected app, on a phone.
Future<AppController> _openBoards(WidgetTester tester) async {
  final (settings, harness, app) = await _rig();
  _phone(tester);
  await tester.pumpWidget(HarnessApp(settings: settings, appController: app));
  await tester.pump();
  await _settle(tester, 8);
  await tester.tap(find.text('Boards').last);
  await _settle(tester, 8);
  return app;
}

/// One board's page, without the shell around it, and the controller it
/// draws from: a test that edits the drawing needs the page's own state.
Future<(AppController, FakeHarness, BoardController)> _openBoard(
  WidgetTester tester,
) async {
  final (settings, harness, app) = await _rig();
  final controller = BoardController(app.harness, boardId: 'b-fieldnotes');
  _phone(tester);
  await tester.pumpWidget(
    HarnessStyle(
      style: HarnessPlatformStyle.material,
      child: MaterialApp(
        theme: HarnessTheme.material(Brightness.light),
        home: BoardScreen(
          app: app,
          board: 'b-fieldnotes',
          controller: controller,
        ),
      ),
    ),
  );
  await tester.pump();
  await _settle(tester, 8);
  addTearDown(controller.dispose);
  return (app, harness, controller);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the boards page', () {
    testWidgets("lists the harness's boards, in the harness's words", (
      tester,
    ) async {
      await _openBoards(tester);
      expect(find.byType(BoardsScreen), findsOneWidget);
      // The board's name and the figures the harness counted for it.
      expect(find.text('atlas / fieldnotes'), findsWidgets);
      expect(find.text('2 diagrams · 13 objects · 1 marker'), findsOneWidget);
      expect(find.textContaining('rev 12'), findsOneWidget);
      // A control is a noun, and the page counts its boards in a noun phrase.
      expect(find.byTooltip('Refresh'), findsOneWidget);
      expect(find.text('1 board'), findsOneWidget);
    });

    testWidgets('a board is made from the list, named, and opened', (
      tester,
    ) async {
      final (settings, harness, app) = await _rig();
      _phone(tester);
      await tester.pumpWidget(
        HarnessApp(settings: settings, appController: app),
      );
      await tester.pump();
      await _settle(tester, 8);
      await tester.tap(find.text('Boards').last);
      await _settle(tester, 8);
      expect(find.byTooltip('New board'), findsOneWidget);
      await tester.tap(find.byTooltip('New board'));
      await _settle(tester, 4);
      expect(find.text('New board'), findsWidgets);
      await tester.enterText(
        find.byKey(const ValueKey('board-new-name')),
        'scaling',
      );
      await tester.tap(find.byKey(const ValueKey('board-new-create')));
      await _settle(tester, 10);
      final made = harness.boardCreations.last;
      expect(made['name'], 'scaling');
      expect(made['id'], startsWith('b-'));
      // The new board opens on a page of its own: the person is taken to
      // what they just made, not left on the list.
      expect(find.byType(BoardScreen), findsOneWidget);
    });

    testWidgets('a harness without boards says so, and invents no row', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsController();
      await settings.load();
      final app = AppController(
        settings: settings,
        connector: FakeHarness().connector,
      );
      await app.connect('ws://memory/acp');
      _phone(tester);
      await tester.pumpWidget(
        HarnessStyle(
          style: HarnessPlatformStyle.material,
          child: MaterialApp(
            theme: HarnessTheme.material(Brightness.light),
            home: BoardsScreen(app: app),
          ),
        ),
      );
      await tester.pump();
      await _settle(tester, 8);
      // A harness with no board methods says so, and invents no row.
      expect(find.text('Unsupported'), findsWidgets);
      expect(find.text('board/list · board/get'), findsOneWidget);
      expect(find.byKey(const ValueKey('board-row-b-fieldnotes')), findsNothing);
    });
  });

  group('a board page', () {
    testWidgets('draws the objects the harness answered with', (tester) async {
      await _openBoard(tester);
      expect(find.bySemanticsLabel('Board canvas'), findsOneWidget);
      // The page names the board and the revision it read.
      expect(find.textContaining('atlas / fieldnotes'), findsWidgets);
      expect(find.textContaining('rev 12'), findsOneWidget);
      // Nothing is selected until a person selects it.
      expect(find.textContaining('No selection'), findsOneWidget);
    });

    testWidgets('moves its selection with Tab, and says what it is', (
      tester,
    ) async {
      await _openBoard(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await _settle(tester, 4);
      // Tab cycles to the first object, and the bar names it: the harness's
      // own name and role, not a label this client invented.
      expect(find.textContaining('the system'), findsOneWidget);
      expect(find.textContaining('Declared'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _settle(tester, 4);
      expect(find.textContaining('No selection'), findsOneWidget);
    });
  });

  group('a person builds their own diagram', () {
    testWidgets('the tools are nouns, and one of them is the hand', (
      tester,
    ) async {
      await _openBoard(tester);
      // A person building a diagram needs the tools to make one: a note, a
      // shape, a frame, a label and ink, and the hand that picks what is
      // there.  Each is a noun, like every label of the app.
      for (final word in ['Select', 'Note', 'Shape', 'Frame', 'Label', 'Ink']) {
        expect(find.text(word), findsOneWidget, reason: word);
      }
      expect(find.byKey(const ValueKey('board-tool-note')), findsOneWidget);
      expect(find.byKey(const ValueKey('board-new-diagram')), findsOneWidget);
    });

    testWidgets('a tap with the note tool creates a note where it landed', (
      tester,
    ) async {
      final (_, harness, _) = await _openBoard(tester);
      await tester.tap(find.byKey(const ValueKey('board-tool-note')));
      await _settle(tester, 3);
      final canvas = tester.getRect(find.byType(CustomPaint).first);
      await tester.tapAt(canvas.center + const Offset(40, 30));
      await _settle(tester, 8);
      // What reached the harness is a real create: one operation, a note,
      // with a shape and a style the grammar names.
      final batches = harness.boardBatches;
      expect(batches, isNotEmpty);
      final op = batches.last.first;
      expect(op['op'], 'create');
      expect(op['kind'], 'note');
      expect(op['diagram'], 'd-overview');
      expect((op['shape'] as Map)['kind'], 'rect');
      expect((op['style'] as Map)['fill'], 'note');
      // The tool goes back to the hand, and the new note is what is selected.
      expect(find.textContaining('note'), findsWidgets);
    });

    testWidgets('a drag moves an object once, by its whole distance', (
      tester,
    ) async {
      final (_, harness, _) = await _openBoard(tester);
      // The api's card, at its place in the fixture.
      final document = BoardDocument.fromWire({
        'id': 'b-fieldnotes',
        'diagram': {'id': 'd-overview'},
        'objects': [
          {
            'id': 'n-api',
            'kind': 'component',
            'diagram': 'd-overview',
            'shape': {'kind': 'rect', 'w': 164, 'h': 91},
            'transform': [1, 0, 0, 1, 330, 214],
            'box': [330, 214, 164, 91],
          },
        ],
      });
      expect(document.objectOf('n-api'), isNotNull);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await _settle(tester, 3);
      final before = harness.boardBatches.length;
      // Drag from inside a card: one commit at the end, not one per frame,
      // and the transform carries the whole move.
      final canvas = tester.getRect(find.byKey(const ValueKey('board-canvas')));
      await tester.dragFrom(canvas.center, const Offset(30, 12));
      await _settle(tester, 8);
      expect(harness.boardBatches.length, greaterThan(before));
      final ops = harness.boardBatches.last;
      final move = ops.firstWhere((op) => op['op'] == 'set-transform',
          orElse: () => ops.first);
      expect(move['op'], 'set-transform');
      expect(move['id'], isNotNull);
      expect(move['transform'], isA<List<Object?>>());
    });

    testWidgets('the words of an object are edited in a sheet', (tester) async {
      final (_, harness, _) = await _openBoard(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await _settle(tester, 3);
      await tester.tap(find.byKey(const ValueKey('board-edit')));
      await _settle(tester, 4);
      expect(find.text('Words'), findsOneWidget);
      expect(find.text('Text'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('board-edit-text')),
        'a new sentence',
      );
      await tester.tap(find.byKey(const ValueKey('board-edit-save')));
      await _settle(tester, 8);
      final ops = harness.boardBatches.last;
      expect(ops.first['op'], 'set-text');
      expect(ops.first['text'], 'a new sentence');
    });

    testWidgets('two selected objects are connected by facing sides', (
      tester,
    ) async {
      final (_, harness, controller) = await _openBoard(tester);
      controller.select('n-api');
      controller.selection = ['n-api', 'n-questions'];
      controller.notifyListeners();
      await _settle(tester, 3);
      await tester.tap(find.byKey(const ValueKey('board-connect')));
      await _settle(tester, 8);
      final op = harness.boardBatches.last.first;
      expect(op['op'], 'connect');
      expect((op['from'] as Map)['object'], 'n-api');
      expect((op['to'] as Map)['object'], 'n-questions');
      // The sides face each other: the api is to the right of the note.
      expect((op['from'] as Map)['anchor'], 'left');
      expect((op['to'] as Map)['anchor'], 'right');
    });

    testWidgets('Delete removes the object, and no longer selects it', (
      tester,
    ) async {
      final (_, harness, _) = await _openBoard(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await _settle(tester, 3);
      await tester.tap(find.byKey(const ValueKey('board-delete')));
      await _settle(tester, 8);
      final op = harness.boardBatches.last.first;
      expect(op['op'], 'delete');
      expect(op['id'], isNotNull);
      expect(find.textContaining('No selection'), findsOneWidget);
    });

    testWidgets('a drill-down is made from the object, into this diagram', (
      tester,
    ) async {
      final (_, harness, _) = await _openBoard(tester);
      // Select an object, then make it a way into the detail: the portal is
      // an ordinary `diagram.portal` of the grammar, and the person picks
      // which diagram it opens.
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await _settle(tester, 3);
      await tester.tap(find.byKey(const ValueKey('board-portal')));
      await _settle(tester, 4);
      expect(find.text('Drill down'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('board-portal-into-d-queue')));
      await _settle(tester, 8);
      final op = harness.boardBatches.last.first;
      expect(op['op'], 'diagram.portal');
      expect(op['to'], 'd-queue');
      expect(op['from'], isNotNull);
      // And the way in is offered on the header now.
      expect(find.byKey(const ValueKey('board-portal-d-queue')), findsOneWidget);
    });

    testWidgets('a discussion is a thread of the task review', (tester) async {
      final (_, harness, controller) = await _openBoard(tester);
      // The api's card marks a task; discussing it asks for a thread of that
      // task's review, anchored to the object, not a comment of the board's.
      controller.select('n-api');
      await _settle(tester, 3);
      await tester.tap(find.byKey(const ValueKey('board-discuss')));
      await _settle(tester, 4);
      await tester.enterText(
        find.byKey(const ValueKey('board-discuss-text')),
        'is this the api?',
      );
      await tester.tap(find.byKey(const ValueKey('board-discuss-send')));
      await _settle(tester, 8);
      final sent = harness.boardDiscussions.last;
      expect(sent['id'], 'b-fieldnotes');
      expect(sent['object'], 'n-api');
      expect((sent['opts'] as Map)['task'], 't-board-fixture');
      expect((sent['opts'] as Map)['text'], 'is this the api?');
      expect((sent['opts'] as Map)['diagram'], 'd-overview');
    });

    testWidgets('a held Shift adds a second object to the selection', (
      tester,
    ) async {
      final (_, _, controller) = await _openBoard(tester);
      // A pointer picks two ends of a connector without a keyboard: a tap
      // picks one, a tap with Shift adds the next.
      // The bar grows when a selection arrives, and the canvas shrinks with
      // it: the surface is measured again for each tap.
      Offset at(String id) {
        final canvas = tester.getRect(find.byKey(const ValueKey('board-canvas')));
        final (x, y, w, h) = controller.document!.objectOf(id)!.box;
        final middle = Offset(x + w / 2, y + h / 2);
        final viewport = Offset(controller.viewportX, controller.viewportY);
        return canvas.center + (middle - viewport) * controller.viewportZoom;
      }

      await tester.tapAt(at('n-api'));
      await _settle(tester, 3);
      expect(controller.selection, ['n-api']);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.tapAt(at('n-questions'));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await _settle(tester, 3);
      expect(controller.selection, ['n-api', 'n-questions']);
      // Both are offered the actions two objects have, and the bar counts
      // them rather than naming only the first.
      expect(find.textContaining('2 selected'), findsOneWidget);
      // A third tap with Shift on a selected object takes it out again.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.tapAt(at('n-api'));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await _settle(tester, 3);
      expect(controller.selection, ['n-questions']);
    });

    testWidgets('two selected objects are grouped, and ungrouped', (
      tester,
    ) async {
      final (_, harness, controller) = await _openBoard(tester);
      controller.selection = ['n-api', 'n-questions'];
      controller.notifyListeners();
      await _settle(tester, 3);
      await tester.tap(find.byKey(const ValueKey('board-group')));
      await _settle(tester, 8);
      final grouped = harness.boardBatches.last.first;
      expect(grouped['op'], 'group');
      expect(grouped['members'], ['n-api', 'n-questions']);
      expect(grouped['diagram'], 'd-overview');
      // The members say they are in a group now, and Ungroup is offered.
      await _settle(tester, 4);
      expect(find.byKey(const ValueKey('board-ungroup')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('board-ungroup')));
      await _settle(tester, 8);
      final ungrouped = harness.boardBatches.last.first;
      expect(ungrouped['op'], 'ungroup');
      expect(ungrouped['id'], isNotNull);
    });

    testWidgets('a task is asked for from the selection, and named', (
      tester,
    ) async {
      final (_, harness, _) = await _openBoard(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await _settle(tester, 3);
      // Only an explicit request makes a task; the action says what it
      // needs, and the sheet asks what the task is.
      expect(find.byKey(const ValueKey('board-request-task')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('board-request-task')));
      await _settle(tester, 4);
      expect(find.text('New task'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('board-task-prompt')),
        'split the worker pool',
      );
      await tester.tap(find.byKey(const ValueKey('board-task-submit')));
      await _settle(tester, 8);
      final submitted = harness.taskSubmissions.last;
      expect(submitted['cwd'], '/Users/noah/Code/emacs-agent-harness');
      final prompt = submitted['prompt']! as String;
      // What the task is, and where it came from: the board, the diagram
      // and the object picked, so the task can find the drawing again.
      expect(prompt, contains('split the worker pool'));
      expect(prompt, contains('harness:board/b-fieldnotes/diagram/d-overview'));
    });

    testWidgets('a revision is pinned, and the pin is what it was', (
      tester,
    ) async {
      final (app, harness, _) = await _openBoard(tester);
      final api = app.harness!;
      final pin = await api.boardPin(
        'b-fieldnotes',
        diagram: 'd-overview',
        title: 'the delivered drawing',
      );
      expect(harness.boardPins.last['id'], 'b-fieldnotes');
      expect((harness.boardPins.last['opts'] as Map)['title'],
          'the delivered drawing');
      // The artifact names its own revision, and the board as it goes on is
      // a separate link: a pin is not the board.
      expect(pin.revision, 12);
      expect(pin.target, contains('/revision/12'));
      expect(pin.current, isNot(contains('/revision/')));
      final kept = await api.boardPinned('b-fieldnotes', pin.id);
      expect(kept.pin.id, pin.id);
      expect(kept.document, isNotNull);
      expect(kept.image, contains('<svg'));
    });

    testWidgets('Rotate turns the object about its own middle', (tester) async {
      final (_, harness, _) = await _openBoard(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await _settle(tester, 3);
      await tester.tap(find.byKey(const ValueKey('board-turn')));
      await _settle(tester, 8);
      final op = harness.boardBatches.last.first;
      expect(op['op'], 'transform');
      expect(op['kind'], 'rotate');
      expect(op['angle'], 90);
      // The pivot is the object's own middle, named by the client: a turn
      // about the origin would carry the object off the board.
      expect(op['pivot'], isA<List<Object?>>());
      expect((op['pivot'] as List<Object?>).length, 2);
    });
  });

  group('a drawing is drawn as the design asks', () {
    test('the same component is placed in both diagrams, once', () {
      final overview = BoardDocument.preview(diagram: 'd-overview');
      final detail = BoardDocument.preview(diagram: 'd-queue');
      final api = overview.objects.firstWhere((o) => o.id == 'n-api');
      // The identity names both views; each view carries one placement.
      expect(api.diagrams, containsAll(<String>['d-overview', 'd-queue']));
      expect(overview.placed.where((o) => o.id == 'n-api').length, 1);
      expect(detail.placed.where((o) => o.id == 'n-api').length, 1);
      // The other views' objects are not drawn in this one.
      expect(detail.placed.map((o) => o.id), isNot(contains('n-questions')));
      expect(overview.placed.map((o) => o.id), isNot(contains('n-handler')));
    });

    test('a diagram draws its own placement of a shared component', () {
      // The engine answers one document per diagram, each carrying that
      // diagram's placement: a document that kept one placement would draw
      // the component where the other view put it, on top of its neighbours.
      final overview = BoardDocument.preview(diagram: 'd-overview');
      final detail = BoardDocument.preview(diagram: 'd-queue');
      (double, double, double, double) box(BoardDocument document) =>
          document.placed.firstWhere((o) => o.id == 'n-api').box;
      expect(box(detail), isNot(box(overview)));
      // And it sits where the detail's own objects are, not off on its own.
      for (final id in ['n-handler', 'n-record']) {
        final other = detail.placed.firstWhere((o) => o.id == id).box;
        final mine = box(detail);
        expect(mine.$2, greaterThan(other.$2), reason: '$id above it');
      }
    });

    test('a diagram draws its own connectors, and no other view\'s', () {
      // A connector belongs to the diagram it was drawn in.  A document that
      // drew every connector would hang the overview's arrows in the detail.
      final overview = BoardDocument.preview(diagram: 'd-overview');
      final detail = BoardDocument.preview(diagram: 'd-queue');
      final overviewIds = overview.connections.map((r) => r.id);
      final detailIds = detail.connections.map((r) => r.id);
      expect(overviewIds, containsAll(<String>['e-jobs', 'e-queue']));
      expect(overviewIds, isNot(contains('e-handler-record')));
      expect(detailIds, ['e-handler-record']);
    });

    test('a picture and a note are drawn where their words can be read', () {
      // Three collisions the pictures showed: the reference picture ran under
      // the worker pool's card, the note's box was shorter than the engine's
      // own so its wrapped fourth line was cut off, and the ink a person drew
      // lay across the open question's note.  All three are placements, so
      // they are checked here rather than by eye.
      final document = BoardDocument.preview();
      BoardObject object(String id) =>
          document.placed.firstWhere((o) => o.id == id);
      (double, double, double, double) box(String id) => object(id).box;
      // The box is the placement: a box that disagrees with its own
      // transform would draw somewhere else than the test believes.
      for (final o in document.placed) {
        expect(o.box, (o.transform.e, o.transform.f, o.box.$3, o.box.$4),
            reason: '${o.id} is drawn where its transform puts it');
      }
      bool clear(
        (double, double, double, double) one,
        (double, double, double, double) two,
      ) =>
          one.$1 >= two.$1 + two.$3 ||
          two.$1 >= one.$1 + one.$3 ||
          one.$2 >= two.$2 + two.$4 ||
          two.$2 >= one.$2 + one.$4;
      final picture = box('n-reference');
      for (final id in ['n-workers', 'n-api', 'n-queue']) {
        expect(clear(picture, box(id)), isTrue,
            reason: 'the picture runs under $id');
      }
      // Raw ink is drawn over what it crosses, so it must not cross a note.
      final ink = box('n-ink');
      for (final o in document.placed.where((o) => o.kind == 'note')) {
        expect(clear(ink, o.box), isTrue,
            reason: 'the ink is drawn across ${o.id}');
      }
      // The note is the size the engine's fixture gives it, which fits the
      // words it holds: the wrapped words need no more lines than the box
      // has room for, and no word is wider than the box.
      final note = document.objects.firstWhere((o) => o.id == 'n-questions');
      final size = note.style.fontSize ?? 18;
      const inset = 14.0;
      final room = note.shape.w - inset * 2;
      expect(note.shape.w, greaterThanOrEqualTo(246));
      expect(note.shape.h, greaterThanOrEqualTo(122));
      for (final word in note.text.split(RegExp(r'\s+'))) {
        expect(
          boardTextWidth(word, size),
          lessThanOrEqualTo(room),
          reason: 'the word "$word" fits the note',
        );
      }
      final lines = (note.shape.h - inset * 2) / boardLineHeight(size);
      // The note's own words, wrapped to its width, at most one line each.
      final wrapped = note.text
          .split('\n')
          .map((line) => (boardTextWidth(line, size) / room).ceil())
          .reduce((a, b) => a + b);
      expect(lines.floor(), greaterThanOrEqualTo(wrapped));
    });

    test('a frame title is drawn in the tab above the frame line', () {
      final document = BoardDocument.preview();
      final frame = document.objects.firstWhere((o) => o.id == 'f-system');
      final size = frame.style.fontSize ?? 19;
      // The tab takes 1.7 of the size above the frame's own top line, and
      // the title's own line sits inside it.
      final tabHeight = (size * 1.7).clamp(size * 1.4, double.infinity);
      final titleTop = -tabHeight + (tabHeight - size * 0.82 * 1.3) / 2;
      expect(titleTop, lessThan(0));
      expect(titleTop + size * 0.82 * 1.3, lessThanOrEqualTo(0));
    });

    testWidgets('a picture that decodes after the first frame is drawn', (
      tester,
    ) async {
      // A picture is decoded asynchronously, so the painter that asks for one
      // is not the painter that draws it: the same store holds the picture by
      // the time the canvas is built again.  The board has to be drawn again
      // for the picture to appear, and a store compared by identity alone
      // never says so.
      final document = BoardDocument.preview();
      final pictures = BoardPictures();
      addTearDown(pictures.dispose);
      BoardCanvasPainter painter() => BoardCanvasPainter(
        document: document,
        theme: BoardTheme.of('electric-commons'),
        selection: const [],
        pictures: pictures,
      );
      final before = painter();
      expect(before.pictures.image(boardPreviewPicture), isNull);
      await tester.runAsync(
        () => pictures.load(document, () {}),
      );
      expect(pictures.image(boardPreviewPicture), isNotNull);
      expect(painter().shouldRepaint(before), isTrue);
    });

    test('a note wraps its words to the width it is given', () {
      final document = BoardDocument.preview();
      final note = document.objects.firstWhere((o) => o.id == 'n-questions');
      const inset = 14.0;
      final size = note.style.fontSize ?? 18;
      final width = note.shape.w - inset * 2;
      // Every word of the note fits on a line no wider than the note: the
      // wrap is a measurement, not a guess.
      for (final word in note.text.split(RegExp(r'\s+'))) {
        expect(boardTextWidth(word, size), lessThanOrEqualTo(width));
      }
      final lines = (note.shape.h - inset * 2) / boardLineHeight(size);
      expect(lines.floor(), greaterThanOrEqualTo(2));
    });

    test('a frame title reads on its tab, in every theme', () {
      // The tab is filled with the accent, and its words are whichever of
      // the theme's ink and paper reads there: night commons fills its tabs
      // with a bright green, where the theme's ink would be a smudge.  The
      // engine's renderer and the canvas pick the same one.
      double ratio(Color a, Color b) {
        final one = a.computeLuminance();
        final two = b.computeLuminance();
        final (light, dark) = one >= two ? (one, two) : (two, one);
        return (light + 0.05) / (dark + 0.05);
      }

      for (final entry in BoardTheme.themes.entries) {
        final theme = BoardTheme.of(entry.key);
        final cap = theme.color('accent')!;
        final ink = theme.color('ink')!;
        final paper = theme.color('paper')!;
        final chosen =
            ratio(ink, cap) < ratio(paper, cap) ? paper : ink;
        expect(
          ratio(chosen, cap),
          greaterThanOrEqualTo(4.5),
          reason: '${entry.key}: the frame title on its tab',
        );
      }
    });

    test('every theme keeps its words legible on what they sit on', () {
      // The design asks for contrast that stays comfortable and legible in
      // all three treatments.  What the canvas sets words in is the ink role
      // on the paper, a note, a card, a frame and an accent cap: each pair is
      // measured, not eyeballed, and the darkest of them still has to read.
      double ratio(Color a, Color b) {
        final one = a.computeLuminance();
        final two = b.computeLuminance();
        final (light, dark) = one >= two ? (one, two) : (two, one);
        return (light + 0.05) / (dark + 0.05);
      }

      // The accent is not one of them: a tab filled with it sets its words
      // in the on-cap colour, which the test above measures.
      for (final entry in BoardTheme.themes.entries) {
        final theme = BoardTheme.of(entry.key);
        final ink = theme.color('ink')!;
        for (final ground in ['paper', 'note', 'card', 'frame']) {
          final colour = theme.color(ground)!;
          final contrast = ratio(ink, colour);
          expect(
            contrast,
            greaterThanOrEqualTo(4.5),
            reason:
                '${entry.key}: ink on $ground is ${contrast.toStringAsFixed(2)}:1',
          );
        }
      }
    });
  });
}
