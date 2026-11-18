// The freeform board against a real harness: the Emacs one, over ACP as the
// app talks to it.
//
//   tool/with_real_harness.sh flutter test test/board_real_harness_test.dart
//
// It is skipped without HARNESS_REAL_ADDRESS.  The fake harness says what the
// board is believed to answer; this is the board engine answering: a board
// made through `board/create`, an object put down through the client's own
// patch-preview-commit path, a second read of the board showing it, a pin of
// the revision, and an edit after the pin that the pin does not see.  The
// engine validates every operation, so what passes here is a batch the
// grammar accepts, not a batch the app hoped for.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/board_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final address = Platform.environment['HARNESS_REAL_ADDRESS'];
  final token = Platform.environment['HARNESS_REAL_TOKEN'] ?? '';
  final project = Platform.environment['HARNESS_REAL_CWD'] ?? '';
  final skip = address == null || address.isEmpty
      ? 'HARNESS_REAL_ADDRESS names no running harness'
      : false;

  late AppController app;
  late String boardId;

  setUpAll(() async {
    if (skip != false) return;
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
  });

  tearDownAll(() async {
    if (skip != false) return;
    await app.disconnect();
  });

  test('the harness offers the board methods the app uses', () {
    final api = app.api!;
    expect(api.can('board/list'), isTrue);
    expect(api.can('board/get'), isTrue);
    expect(api.can('board/create'), isTrue);
    expect(api.can('board/patch'), isTrue);
    expect(api.can('board/preview'), isTrue);
    expect(api.can('board/commit'), isTrue);
    expect(api.can('board/undo'), isTrue);
    expect(api.can('board/pins'), isTrue);
  }, skip: skip);

  test('a board is made, drawn on, and read back', () async {
    boardId = 'b-real-${DateTime.now().microsecondsSinceEpoch}';
    final made = await app.api!.boardCreate(
      boardId,
      'the real board',
      project: project.isEmpty ? null : project,
    );
    expect(made.id, boardId);
    expect(made.diagram?.id, 'd-overview');
    expect(made.objects, isEmpty);

    // The client's own authoring path: one create, patched, previewed and
    // committed under an idempotency key.
    final controller = BoardController(app.harness, boardId: boardId);
    addTearDown(controller.dispose);
    await controller.load(showSpinner: false);
    expect(controller.error, isNull, reason: '${controller.error}');
    final placed = await controller.createObject(
      kind: 'note',
      x: 120,
      y: 90,
      name: 'open question',
      text: 'what happens after a timeout?',
      w: 200,
      h: 110,
    );
    expect(placed, isTrue, reason: '${controller.actionError}');
    expect(controller.notice, 'Saved', reason: '${controller.actionError}');
    expect(controller.document!.revision, greaterThan(0));

    // The engine has it, not only the client: a fresh read shows the note.
    final read = await app.api!.boardGet(boardId);
    final note = read.objects.where((o) => o.kind == 'note').toList();
    expect(note, hasLength(1));
    expect(note.first.text, 'what happens after a timeout?');
    expect(note.first.name, 'open question');
  }, skip: skip);

  test('a pinned revision is the artifact, and later edits miss it', () async {
    final pin = await app.api!.boardPin(
      boardId,
      diagram: 'd-overview',
      title: 'the delivered drawing',
    );
    expect(pin.revision, greaterThan(0));
    expect(pin.title, 'the delivered drawing');
    expect(pin.target, contains('/revision/${pin.revision}'));
    expect(pin.current, isNot(contains('/revision/')));

    // An edit after the pin: the board goes on, the artifact does not.
    final controller = BoardController(app.harness, boardId: boardId);
    addTearDown(controller.dispose);
    await controller.load(showSpinner: false);
    final moved = await controller.placeObject(
      controller.document!.objects.first.id,
      40,
      10,
    );
    expect(moved, isTrue, reason: '${controller.actionError}');

    final pins = await app.api!.boardPins(boardId);
    expect(pins.map((p) => p.id), contains(pin.id));
    final kept = await app.api!.boardPinned(boardId, pin.id);
    expect(kept.pin.id, pin.id);
    final pinned = kept.document!.objects.firstWhere((o) => o.kind == 'note');
    final now = (await app.api!.boardGet(boardId))
        .objects
        .firstWhere((o) => o.kind == 'note');
    expect(pinned.box.$1, isNot(now.box.$1));
    expect(kept.image, isNotNull);
    expect(kept.image, contains('<svg'));
  }, skip: skip);
}
