// A compaction can be taken back, and made again, like an undo and a redo.
//
// Nothing a compaction replaced is deleted, so the note of the latest one
// offers "Revert": the model is sent the conversation before it again, in
// place of the summary.  The note is then dimmed and says "Reverted", and
// offers "Go post-compaction", which gives the model the summary again.  The
// harness does it (`compaction/revert`, `compaction/restore`), marks the node
// and announces it, and the note in the transcript changes by itself.
//
//   HARNESS_SHOTS=/some/directory flutter test test/compaction_toggle_test.dart
//
// writes a picture of the conversation in each of the three states, drawn on
// a phone: compacted, reverted, and back.  Without HARNESS_SHOTS the test
// still runs, and writes nothing.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/app.dart';
import 'package:harness_client/src/acp/capabilities.dart';
import 'package:harness_client/src/models/transcript.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/session_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:harness_client/src/ui/adaptive/platform_style.dart';
import 'package:harness_client/src/ui/theme/harness_theme.dart';
import 'package:harness_client/src/ui/widgets/compaction_toggle.dart';
import 'package:harness_client/src/ui/widgets/transcript_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';
import 'support/real_fonts.dart';

const _summary = '''
## Summary so far

- **Goal**: stream the parser's tokens
- `done`: parser.el and lexer.el
''';

Map<String, Object?> _compaction(
  String id, {
  bool reverted = false,
  Map<String, Object?> meta = const {},
  String content = _summary,
}) => {
  'id': id,
  'kind': 'compaction',
  'content': content,
  'meta': {'compaction': 'summary', if (reverted) 'reverted': true, ...meta},
};

TranscriptState _transcript(Iterable<Map<String, Object?>> nodes) {
  final state = TranscriptState();
  for (final node in nodes) {
    state.applyNode(node);
  }
  state.finish();
  return state;
}

Future<void> _settle(WidgetTester tester, [int rounds = 4]) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

/// A transcript of [nodes], drawn on a phone, with a button that records
/// which compaction it was asked about.
Future<List<String>> _show(
  WidgetTester tester,
  Iterable<Map<String, Object?>> nodes, {
  bool canToggle = true,
}) async {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final asked = <String>[];
  await tester.pumpWidget(
    HarnessStyle(
      style: HarnessPlatformStyle.material,
      child: MaterialApp(
        theme: HarnessTheme.material(Brightness.light),
        home: Scaffold(
          body: TranscriptView(
            items: _transcript(nodes).items,
            showThinking: true,
            onToggleCompaction: canToggle
                ? (item) => asked.add(item.nodeId ?? '')
                : null,
          ),
        ),
      ),
    ),
  );
  await _settle(tester);
  return asked;
}

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('what a compaction node says of itself', () {
    TranscriptItem item(Map<String, Object?> node) =>
        (_transcript([node]).items.single);

    test('is reverted when the harness marked it', () {
      expect(item(_compaction('c1')).isRevertedCompaction, isFalse);
      expect(
        item(_compaction('c1', reverted: true)).isRevertedCompaction,
        isTrue,
      );
      // A false the harness sent, and a node that is no compaction.
      expect(
        item({
          'id': 'c1',
          'kind': 'compaction',
          'content': 'x',
          'meta': {'reverted': false},
        }).isRevertedCompaction,
        isFalse,
      );
      expect(
        item({
          'id': 'u1',
          'kind': 'user',
          'content': 'x',
          'meta': {'reverted': true},
        }).isRevertedCompaction,
        isFalse,
      );
    });

    test('can be taken back unless the harness would refuse', () {
      expect(item(_compaction('c1')).canRevertCompaction, isTrue);
      expect(
        item(_compaction('c1', reverted: true)).canRevertCompaction,
        isTrue,
      );
      // Made to hand the conversation over to another model.
      expect(
        item(
          _compaction(
            'c1',
            meta: {
              'handoff': {'mode': 'compact', 'from': 'a:b', 'to': 'c:d'},
            },
          ),
        ).canRevertCompaction,
        isFalse,
      );
      // A cut of an earlier harness kept nothing to go back to.
      expect(
        item(_compaction('c1', meta: {'compaction': 'truncate'}))
            .canRevertCompaction,
        isFalse,
      );
      expect(
        item(
          _compaction(
            'c1',
            meta: {'compaction': 'truncate', 'truncate-after': 'n-9'},
          ),
        ).canRevertCompaction,
        isTrue,
      );
    });

    test('is announced as a capability only when both ways are', () {
      HarnessCapabilities capabilities(List<String> methods) =>
          HarnessCapabilities.fromInitialize({
            '_harness': {'methods': methods},
          });
      expect(
        capabilities(['compaction/revert', 'compaction/restore'])
            .compactionRevert,
        isTrue,
      );
      expect(capabilities(['compaction/revert']).compactionRevert, isFalse);
      expect(capabilities(<String>[]).compactionRevert, isFalse);
    });
  });

  group('the note of a compaction', () {
    testWidgets('offers to revert the latest one', (tester) async {
      final asked = await _show(tester, [
        {'id': 'u1', 'kind': 'user', 'content': 'refactor the parser'},
        _compaction('c1'),
      ]);
      expect(find.textContaining('Context compacted'), findsOneWidget);
      expect(find.text('Revert'), findsOneWidget);
      expect(find.text('Go post-compaction'), findsNothing);
      expect(find.text('Reverted'), findsNothing);
      expect(_dimmedNotes(), findsNothing);

      await tester.tap(find.text('Revert'));
      await _settle(tester);
      expect(asked, ['c1']);
    });

    testWidgets('offers the way back once it was reverted, dimmed', (
      tester,
    ) async {
      final asked = await _show(tester, [_compaction('c1', reverted: true)]);
      expect(find.text('Go post-compaction'), findsOneWidget);
      expect(find.text('Revert'), findsNothing);
      // The note says so, and is drawn as what is not in force.
      expect(find.text('Reverted'), findsOneWidget);
      expect(_dimmedNotes(), findsOneWidget);
      expect(find.textContaining('Context compacted'), findsOneWidget);

      await tester.tap(find.text('Go post-compaction'));
      await _settle(tester);
      expect(asked, ['c1']);
    });

    testWidgets('keeps its button when the summary opens', (tester) async {
      await _show(tester, [_compaction('c1')]);
      expect(find.textContaining('Context compacted'), findsOneWidget);
      expect(find.text('Summary so far'), findsNothing);
      await tester.tap(find.textContaining('Context compacted'));
      await _settle(tester);
      expect(find.text('Summary so far'), findsOneWidget);
      expect(find.text('Revert'), findsOneWidget);
    });

    testWidgets('keeps the summary open when the compaction is taken back', (
      tester,
    ) async {
      // The note stays where it is in the tree, so what the person opened
      // is not shut behind them when the button flips.
      final state = TranscriptState()
        ..applyNode(_compaction('c1'))
        ..finish();
      final shown = ValueNotifier<int>(0);
      addTearDown(shown.dispose);
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        HarnessStyle(
          style: HarnessPlatformStyle.material,
          child: MaterialApp(
            theme: HarnessTheme.material(Brightness.light),
            home: Scaffold(
              body: ValueListenableBuilder<int>(
                valueListenable: shown,
                builder: (context, _, _) => TranscriptView(
                  items: state.items,
                  showThinking: true,
                  onToggleCompaction: (item) =>
                      state.applyNode(_compaction('c1', reverted: true)),
                ),
              ),
            ),
          ),
        ),
      );
      await _settle(tester);
      await tester.tap(find.textContaining('Context compacted'));
      await _settle(tester);
      expect(find.text('Summary so far'), findsOneWidget);

      await tester.tap(find.text('Revert'));
      shown.value++;
      await _settle(tester);
      expect(find.text('Go post-compaction'), findsOneWidget);
      expect(find.text('Summary so far'), findsOneWidget);
    });

    testWidgets('offers it on a short note too', (tester) async {
      await _show(tester, [
        _compaction(
          'c1',
          content: 'Context compacted from 214k tokens to 52k.',
        ),
      ]);
      expect(
        find.textContaining('Context compacted from 214k tokens to 52k.'),
        findsOneWidget,
      );
      expect(find.text('Revert'), findsOneWidget);
    });

    testWidgets('leaves an older compaction without a button', (tester) async {
      final asked = await _show(tester, [
        _compaction('c1'),
        {'id': 'u2', 'kind': 'user', 'content': 'and the lexer'},
        _compaction('c2', reverted: true),
      ]);
      // Only the latest one offers it, whatever the older one says.
      expect(find.text('Revert'), findsNothing);
      expect(find.text('Go post-compaction'), findsOneWidget);
      await tester.tap(find.text('Go post-compaction'));
      await _settle(tester);
      expect(asked, ['c2']);
    });

    testWidgets(
      'has none for a handoff, a harness that cannot, or an old cut',
      (tester) async {
        await _show(tester, [
          _compaction(
            'c1',
            meta: {
              'handoff': {'mode': 'compact', 'from': 'a:b', 'to': 'c:d'},
            },
          ),
        ]);
        expect(find.text('Revert'), findsNothing);

        await _show(tester, [
          _compaction('c1', meta: {'compaction': 'truncate'}),
        ]);
        expect(find.text('Revert'), findsNothing);

        await _show(tester, [_compaction('c1')], canToggle: false);
        expect(find.textContaining('Context compacted'), findsOneWidget);
        expect(find.text('Revert'), findsNothing);
      },
    );
  });

  group('the app', () {
    testWidgets('takes the latest compaction back, and goes back to it', (
      tester,
    ) async {
      final shots = Platform.environment['HARNESS_SHOTS'];
      final real = await loadRealFonts();
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsController();
      await settings.load();
      // Drawn in the style of an iPhone: the test engine draws the label of
      // a Material button, whose style names no font, as squares.
      await settings.setPreviewPlatform(PreviewPlatform.cupertino);
      final now = DateTime.now();
      final harness = FakeHarness();
      harness.sessions['s-revert'] = {
        'id': 's-revert',
        'name': 'Stream the tokens',
        'kind': 'main',
        'project': '/Users/noah/Code/emacs-agent-harness/',
        'cwd': '/Users/noah/Code/emacs-agent-harness/',
        'model': 'claude:claude-fable-5-1',
        'permissionMode': 'auto',
        'status': 'idle',
        'created':
            now.subtract(const Duration(hours: 1)).millisecondsSinceEpoch /
            1000,
        'updated':
            now.subtract(const Duration(minutes: 1)).millisecondsSinceEpoch /
            1000,
        'lastMessage': now.millisecondsSinceEpoch / 1000,
        'contextWindow': 200000,
        'todos': <Object?>[],
        'pending': <Object?>[],
        'queue': <Object?>[],
      };
      var counter = 0;
      Map<String, Object?> node(String kind, String content) => {
        'id': 'n${++counter}',
        'kind': kind,
        'content': content,
        'ts': now.millisecondsSinceEpoch / 1000 - 600 + counter * 20,
      };
      harness.nodes['s-revert'] = [
        node('user', 'Please refactor the parser so it streams its tokens.'),
        node(
          'assistant',
          'Done: **parser.el** now yields tokens one at a time, and I added '
              'tests for the lexer boundary.',
        ),
        node('user', 'Now do the same for the lexer.'),
        node(
          'assistant',
          'Done: **lexer.el** streams too; the buffer is gone.',
        ),
        node('hint', 'Compacting context…'),
        {
          ...node('compaction', _summary),
          'meta': {'compaction': 'summary', 'input-tokens': 181000},
        },
        node('hint', 'Compacted: 181k tokens → summary'),
      ];
      final app = AppController(
        settings: settings,
        connector: harness.connector,
      );
      await app.connect('ws://memory/acp');

      const ratio = 2.0;
      tester.view.physicalSize = const Size(390 * ratio, 700 * ratio);
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

      // The tabs of the home screen are all there under the page that opens,
      // each with a navigation bar of the same hero tag, which Cupertino
      // pages complain of in a debug build: not what is drawn.
      Future<void> settle([int rounds = 10]) async {
        for (var i = 0; i < rounds; i++) {
          await tester.pump(const Duration(milliseconds: 120));
          tester.takeException();
        }
      }

      final boundary = GlobalKey();
      Future<void> shot(String name) async {
        if (shots == null) return;
        await tester.runAsync(() async {
          final render =
              boundary.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await render.toImage(pixelRatio: 1.5);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File('$shots/$name${real ? '' : '-ahem'}.png');
          file.parent.createSync(recursive: true);
          file.writeAsBytesSync(data!.buffer.asUint8List());
        });
      }

      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: HarnessApp(settings: settings, appController: app),
        ),
      );
      await tester.pump();
      await settle();
      await tester.tap(find.text('Stream the tokens'));
      await settle();

      // Compacted: the latest compaction offers to be taken back.
      expect(find.textContaining('Context compacted'), findsOneWidget);
      expect(find.text('Revert'), findsOneWidget);
      await shot('compaction-1-compacted');

      await tester.tap(find.text('Revert'));
      await settle();
      expect(harness.compactionRequests.map((r) => r.method), [
        '_harness/compaction/revert',
      ]);
      expect(find.text('Go post-compaction'), findsOneWidget);
      expect(find.text('Revert'), findsNothing);
      expect(find.text('Reverted'), findsOneWidget);
      await shot('compaction-2-reverted');

      await tester.tap(find.text('Go post-compaction'));
      await settle();
      expect(harness.compactionRequests.map((r) => r.method), [
        '_harness/compaction/revert',
        '_harness/compaction/restore',
      ]);
      expect(find.text('Revert'), findsOneWidget);
      expect(find.text('Reverted'), findsNothing);
      await shot('compaction-3-restored');
    });
  });

  group('taking a compaction back', () {
    Future<(FakeHarness, SessionController)> open(
      List<Map<String, Object?>> nodes,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsController();
      await settings.load();
      final harness = FakeHarness();
      final app = AppController(
        settings: settings,
        connector: harness.connector,
      );
      await app.connect('ws://memory/acp');
      harness.nodes['s1'] = nodes;
      final controller = app.openSession('s1');
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (controller.loading ||
          !controller.transcript.items.any(
            (item) => item.kind == TranscriptKind.compaction,
          )) {
        if (DateTime.now().isAfter(deadline)) fail('The session never opened.');
        await Future<void>.delayed(const Duration(milliseconds: 4));
      }
      return (harness, controller);
    }

    TranscriptItem note(SessionController controller) => controller
        .transcript
        .items
        .firstWhere((item) => item.kind == TranscriptKind.compaction);

    test('asks the harness, and the note follows what it announces', () async {
      final (harness, controller) = await open([
        {'id': 'u1', 'kind': 'user', 'content': 'refactor the parser'},
        _compaction('c1'),
      ]);
      expect(note(controller).isRevertedCompaction, isFalse);

      await controller.toggleCompaction(note(controller));
      expect(
        harness.compactionRequests.last.method,
        '_harness/compaction/revert',
      );
      expect(harness.compactionRequests.last.params, {
        'session-id': 's1',
        'node-id': 'c1',
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(note(controller).isRevertedCompaction, isTrue);
      expect(controller.error, isNull);

      // And back, as often as the person likes.
      for (var i = 0; i < 2; i++) {
        await controller.toggleCompaction(note(controller));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(note(controller).isRevertedCompaction, isFalse);
        await controller.toggleCompaction(note(controller));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(note(controller).isRevertedCompaction, isTrue);
      }
      expect(harness.compactionRequests.map((request) => request.method), [
        '_harness/compaction/revert',
        '_harness/compaction/restore',
        '_harness/compaction/revert',
        '_harness/compaction/restore',
        '_harness/compaction/revert',
      ]);
    });

    test('says why the harness refused', () async {
      final (harness, controller) = await open([_compaction('c1')]);
      harness.refuseCompaction =
          'The compaction cannot be reverted now: the session is running a '
          'turn; wait for it to end, or stop it';
      await controller.toggleCompaction(note(controller));
      expect(controller.error, contains('running a turn'));
      expect(note(controller).isRevertedCompaction, isFalse);
    });
  });
}

/// The notes drawn dimmed, as a compaction is that is not in force.
Finder _dimmedNotes() => find.byWidgetPredicate(
  (widget) => widget is Opacity && widget.opacity == CompactionToggle.dimmed,
);
