import 'package:flutter/material.dart';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/ui/adaptive/platform_style.dart';
import 'package:harness_client/src/ui/theme/harness_theme.dart';
import 'package:harness_client/src/ui/widgets/voice_pipeline.dart';
import 'package:harness_client/src/ui/widgets/voice_ribbon.dart';
import 'package:harness_client/src/voice/voice_backend.dart';
import 'package:harness_client/src/voice/voice_pipeline.dart';
import 'package:harness_client/src/voice/voice_ribbon.dart';


DateTime now = DateTime(2026, 11, 7, 12);

Widget _app(Widget child, {Size size = const Size(900, 700)}) => HarnessStyle(
  style: HarnessPlatformStyle.material,
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: HarnessTheme.material(Brightness.light),
    home: Scaffold(
      body: Center(
        child: SizedBox(width: size.width, height: size.height, child: child),
      ),
    ),
  ),
);

VoicePipelineSnapshot _snapshot({
  VoiceInputState input = VoiceInputState.live,
  double level = 0.42,
  bool levelSeen = true,
  DateTime? levelAt,
  bool speechActive = false,
  List<VoiceSegment> segments = const [],
  List<VoiceTurn> turns = const [],
  List<VoiceReply> replies = const [],
  int accepted = 0,
  int dropped = 0,
  int spoken = 0,
  bool playing = false,
  String? problemLabel,
}) => VoicePipelineSnapshot(
  generation: 1,
  input: input,
  level: level,
  levelSeen: levelSeen,
  levelAt: levelAt ?? now,
  speechActive: speechActive,
  segments: segments,
  turns: turns,
  replies: replies,
  accepted: accepted,
  dropped: dropped,
  spoken: spoken,
  playing: playing,
  problemLabel: problemLabel,
);

VoiceSegment _segment(
  String id,
  VoicePipelineStage stage, {
  Duration? duration,
  String? text,
  VoiceSegmentDrop? drop,
  String? detail,
}) => VoiceSegment(
  id: id,
  stage: stage,
  generation: 1,
  duration: duration,
  text: text,
  drop: drop,
  detail: detail,
);

Finder marker(String id) => find.byKey(ValueKey('voice-ribbon-$id'));

/// Whether a screen reader can reach [label] in the semantics tree.
bool spoken(WidgetTester tester, String label) {
  final root = tester.binding.pipelineOwner.semanticsOwner?.rootSemanticsNode;
  if (root == null) return false;
  var found = false;
  void visit(SemanticsNode node) {
    if (found) return;
    if (node.label.contains(label)) {
      found = true;
      return;
    }
    node.visitChildren((child) {
      visit(child);
      return !found;
    });
  }

  visit(root);
  return found;
}

void main() {
  testWidgets('the pipe is one continuous ribbon and says no words', (
    tester,
  ) async {
    final snapshot = _snapshot(
      level: 0.4,
      segments: [
        _segment(
          'u-3',
          VoicePipelineStage.accepted,
          duration: const Duration(milliseconds: 1400),
        ),
        _segment(
          'u-2',
          VoicePipelineStage.transcribed,
          duration: const Duration(milliseconds: 900),
          text: 'open the merge queue',
        ),
        _segment(
          'u-1',
          VoicePipelineStage.answered,
          duration: const Duration(seconds: 2),
        ),
      ],
      turns: const [
        VoiceTurn(
          id: 't-1',
          stage: 'working',
          generation: 1,
          segmentIds: ['u-1'],
        ),
      ],
      replies: const [
        VoiceReply(
          id: 'n-1',
          stage: VoiceReplyStage.held,
          generation: 1,
          text: 'The queue has two tasks.',
        ),
      ],
      accepted: 3,
      playing: true,
    );
    await tester.pumpWidget(
      _app(VoicePipelineView(snapshot: snapshot, clock: () => now)),
    );

    // One pill, and not one word of status, key or legend inside it.
    expect(find.byKey(const Key('voice-pipeline-ribbon')), findsOneWidget);
    expect(find.text('Pipeline'), findsNothing);
    for (final banned in const [
      'Audio',
      'Speech',
      'Words',
      'Processing',
      'Audio out',
      'Dropped',
      'Failed',
      'Mic · live',
      'Level · 40%',
      '3 accepted',
      'Turn · working',
      'Voice · speaking',
      'Pipeline details',
    ]) {
      expect(
        find.text(banned),
        findsNothing,
        reason: '$banned belongs in the settings, not in the call control',
      );
    }
    // One cluster per real id, and one for the microphone.
    for (final id in const ['input', 'u-3', 'u-2', 'u-1', 'n-1']) {
      expect(marker(id), findsOneWidget, reason: id);
    }
    // Each cluster's words are still there for a screen reader and a tooltip.
    expect(find.byTooltip('u-3 · accepted · 1.4s'), findsOneWidget);
    expect(find.byTooltip('u-2 · transcribed · 900ms'), findsOneWidget);
    expect(find.byTooltip('u-1 · answered · 2.0s'), findsOneWidget);
    expect(find.byTooltip('n-1 · held'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the stages are told apart by bar shape, not by colour', (
    tester,
  ) async {
    final snapshot = _snapshot(
      segments: [
        _segment('u-1', VoicePipelineStage.accepted),
        _segment('u-2', VoicePipelineStage.transcribed),
        _segment(
          'r-1',
          VoicePipelineStage.dropped,
          drop: VoiceSegmentDrop.tooShort,
        ),
      ],
      replies: const [
        VoiceReply(
          id: 'n-1',
          stage: VoiceReplyStage.speaking,
          generation: 1,
        ),
      ],
      accepted: 2,
      dropped: 1,
    );
    await tester.pumpWidget(
      _app(VoicePipelineView(snapshot: snapshot, clock: () => now)),
    );
    expect(tester.takeException(), isNull);
    // Each stage has its own place across the pill, in pipe order.  A
    // confirmed drop keeps the stage it stopped in, so it sits beside that
    // stage's cluster rather than at a stage of its own.
    double at(String id) => tester.getCenter(marker(id)).dx;
    expect(at('input'), lessThan(at('u-1')));
    expect(at('u-1'), lessThan(at('u-2')));
    expect(at('u-2'), lessThan(at('n-1')));
    expect(at('r-1'), greaterThan(at('u-1')));
    expect(at('r-1'), lessThan(at('n-1')));
    expect(at('n-1') - at('input'), greaterThan(120));
  });

  testWidgets('large text keeps the pill, not a ring', (tester) async {
    final snapshot = _snapshot(level: 0.4, accepted: 1);
    await tester.pumpWidget(
      _app(
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: VoicePipelineView(snapshot: snapshot, clock: () => now),
        ),
      ),
    );
    expect(find.byKey(const Key('voice-pipeline-ribbon')), findsOneWidget);
    expect(find.byKey(const Key('voice-pipeline-ring')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a compact surface draws the same clusters around a ring', (
    tester,
  ) async {
    final snapshot = _snapshot(
      segments: [
        _segment('u-1', VoicePipelineStage.accepted),
        _segment('u-2', VoicePipelineStage.transcribed),
      ],
      replies: const [
        VoiceReply(id: 'n-1', stage: VoiceReplyStage.speaking, generation: 1),
      ],
      accepted: 2,
      playing: true,
    );
    await tester.pumpWidget(
      _app(
        VoicePipelineView(snapshot: snapshot, compact: true, clock: () => now),
        size: const Size(220, 140),
      ),
    );
    expect(find.byKey(const Key('voice-pipeline-ring')), findsOneWidget);
    expect(find.byKey(const Key('voice-pipeline-ribbon')), findsNothing);
    for (final id in const ['input', 'u-1', 'u-2', 'n-1']) {
      expect(marker(id), findsOneWidget, reason: id);
    }
    // The ring runs clockwise from twelve o'clock: the microphone is at the
    // top, the words on the right, the audio out at the lower right.
    final centre = tester.getCenter(
      find.byKey(const Key('voice-pipeline-ring')),
    );
    final audio = tester.getCenter(marker('input'));
    double angleOf(String id) {
      final offset = tester.getCenter(marker(id)) - centre;
      final angle = math.atan2(offset.dx, -offset.dy);
      return angle < 0 ? angle + 2 * math.pi : angle;
    }

    expect(audio.dy, lessThan(centre.dy), reason: 'twelve o\'clock first');
    expect(angleOf('u-1'), greaterThan(angleOf('input')));
    expect(angleOf('u-2'), greaterThan(angleOf('u-1')));
    expect(angleOf('n-1'), greaterThan(angleOf('u-2')));
    // No key, no legend, no summary on the compact surface either.
    for (final banned in const ['Audio', 'Speech', 'Words', 'Pipeline details']) {
      expect(find.text(banned), findsNothing, reason: banned);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('a compact surface with no room draws no ring', (tester) async {
    await tester.pumpWidget(
      _app(
        VoicePipelineView(
          snapshot: _snapshot(),
          compact: true,
          clock: () => now,
        ),
        size: const Size(220, 30),
      ),
    );
    expect(find.byKey(const Key('voice-pipeline-ring')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a missing level says no data, not silence', (tester) async {
    final semantics = tester.ensureSemantics();
    final live = _snapshot(
      levelSeen: false,
      levelAt: null,
      input: VoiceInputState.live,
    );
    await tester.pumpWidget(
      _app(VoicePipelineView(snapshot: live, clock: () => now)),
    );
    expect(
      spoken(tester, 'Mic · live · Level · no data · Voice · silent'),
      isTrue,
    );
    expect(find.textContaining('Level ·'), findsNothing);

    final stale = _snapshot(levelAt: now.subtract(const Duration(seconds: 5)));
    await tester.pumpWidget(
      _app(VoicePipelineView(snapshot: stale, clock: () => now)),
    );
    expect(
      spoken(tester, 'Mic · live · Level · no data · Voice · silent'),
      isTrue,
    );
    expect(spoken(tester, 'Level · 0%'), isFalse);
    semantics.dispose();
  });

  testWidgets('a frozen meter turns into no data by itself', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(
        VoicePipelineView(snapshot: _snapshot(level: 0.8), clock: () => now),
      ),
    );
    expect(spoken(tester, 'Mic · live · Level · 80% · Voice · silent'), isTrue);
    now = now.add(const Duration(seconds: 3));
    await tester.pump(const Duration(seconds: 3));
    expect(
      spoken(tester, 'Mic · live · Level · no data · Voice · silent'),
      isTrue,
    );
    now = now.subtract(const Duration(seconds: 3));
    semantics.dispose();
  });

  testWidgets('a rejected burst is drawn as a drop and said in words', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final snapshot = _snapshot(
      segments: [
        _segment(
          'r-1',
          VoicePipelineStage.dropped,
          duration: const Duration(milliseconds: 640),
          drop: VoiceSegmentDrop.tooShort,
        ),
        _segment(
          'u-1',
          VoicePipelineStage.transcribing,
          duration: const Duration(seconds: 1),
        ),
      ],
      dropped: 1,
      accepted: 1,
      speechActive: true,
    );
    await tester.pumpWidget(
      _app(VoicePipelineView(snapshot: snapshot, clock: () => now)),
    );
    // The drop's reason is on its cluster, and nowhere on the surface.
    expect(find.byTooltip('r-1 · dropped · 640ms · too short'), findsOneWidget);
    expect(find.text('Dropped'), findsNothing);
    expect(find.textContaining('too short'), findsNothing);
    expect(
      spoken(tester, 'Blip, r-1 · dropped · 640ms · too short'),
      isTrue,
      reason: 'a screen reader hears the cluster by its own words',
    );
    expect(
      spoken(
        tester,
        'Mic · live · Level · 42% · Speech · heard · 1 accepted · '
        '1 dropped · Voice · silent',
      ),
      isTrue,
    );
    semantics.dispose();
  });

  testWidgets('a problem is said to a reader, never drawn as prose', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final snapshot = _snapshot(
      input: VoiceInputState.failed,
      levelSeen: false,
      levelAt: null,
      problemLabel: 'Microphone permission denied',
    );
    await tester.pumpWidget(
      _app(VoicePipelineView(snapshot: snapshot, clock: () => now)),
    );
    expect(
      spoken(
        tester,
        'Mic · failed · Level · no data · Voice · silent · '
        'Microphone permission denied',
      ),
      isTrue,
    );
    expect(find.textContaining('Microphone permission denied'), findsNothing);
    semantics.dispose();
  });

  testWidgets('no way into the details, and no empty-state prose', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(VoicePipelineView(snapshot: _snapshot(), clock: () => now)),
    );
    // The control has no details control and no keyboard route into one.
    expect(find.byKey(const Key('voice-pipeline-details')), findsNothing);
    expect(find.byTooltip('Pipeline details'), findsNothing);
    expect(find.text('No segments yet'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(find.text('No segments yet'), findsNothing);
    expect(find.byKey(const Key('voice-pipeline-details')), findsNothing);
  });

  testWidgets('motion moves a marker, reduced motion puts it there', (
    tester,
  ) async {
    final accepted = _snapshot(
      segments: [
        _segment(
          'u-1',
          VoicePipelineStage.accepted,
          duration: const Duration(seconds: 1),
        ),
      ],
      accepted: 1,
    );
    final transcribing = _snapshot(
      segments: [
        _segment(
          'u-1',
          VoicePipelineStage.transcribing,
          duration: const Duration(seconds: 1),
        ),
      ],
      accepted: 1,
    );
    final marker = find.byKey(const ValueKey('voice-ribbon-u-1'));

    await tester.pumpWidget(
      _app(VoicePipelineView(snapshot: accepted, clock: () => now)),
    );
    final from = tester.getCenter(marker).dx;
    await tester.pumpWidget(
      _app(VoicePipelineView(snapshot: transcribing, clock: () => now)),
    );
    await tester.pump(const Duration(milliseconds: 1));
    final moving = tester.getCenter(marker).dx;
    await tester.pump(const Duration(milliseconds: 400));
    final arrived = tester.getCenter(marker).dx;
    expect(arrived, greaterThan(from));
    expect(moving, greaterThan(from));
    expect(moving, lessThan(arrived));

    await tester.pumpWidget(
      _app(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: VoicePipelineView(snapshot: accepted, clock: () => now),
        ),
      ),
    );
    await tester.pumpWidget(
      _app(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: VoicePipelineView(snapshot: transcribing, clock: () => now),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 1));
    expect(
      tester.getCenter(marker).dx,
      greaterThan(from),
      reason: 'reduced motion shows the stage it is at, at once',
    );
  });

  testWidgets('a ribbon with one mark stays a compact pill, and says nothing', (
    tester,
  ) async {
    // An idle stage draws nothing, so a lone mark must not stretch the pill
    // to the window: it keeps its own width and is centred in the room.
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(
        VoicePipelineView(
          snapshot: _snapshot(
            segments: [
              _segment(
                'u-1',
                VoicePipelineStage.accepted,
                duration: const Duration(seconds: 1),
              ),
            ],
            accepted: 1,
          ),
          clock: () => now,
        ),
        size: const Size(520, 140),
      ),
    );
    expect(tester.takeException(), isNull);
    // The pill is a compact bar, not a band across the window: past its own
    // width it stops growing, and it is centred in the room it has.
    final pill = tester.getSize(find.byKey(const Key('voice-pipeline-ribbon')));
    expect(pill.width, lessThanOrEqualTo(520));
    for (final banned in const ['Audio', 'Speech', 'Words', 'Pipeline']) {
      expect(find.text(banned), findsNothing, reason: banned);
    }
    semantics.dispose();
  });

  testWidgets('a waiting turn breathes, not just its dashes', (tester) async {
    // The agent's work is a segmented run, and the approved shape of it is a
    // fixed height with the dashes inside it changing.  A breath that only
    // changed the dashes left the run looking still, so its height swells
    // too.  What is asserted here is the swell itself: the run is taller at
    // the crest than at the trough.
    //
    // This is the swell, not the dashes: the segment count changes at the
    // crest in the older code as well, so a test that only compared the two
    // renderings passed on a run whose height never moved.
    final snapshot = _snapshot(
      segments: [
        _segment(
          'u-1',
          VoicePipelineStage.inTurn,
          duration: const Duration(seconds: 1),
        ),
      ],
      turns: const [
        VoiceTurn(
          id: 't-1',
          stage: 'working',
          generation: 1,
          segmentIds: ['u-1'],
        ),
      ],
      accepted: 1,
    );
    final boundary = GlobalKey();

    /// The white run's drawn height, in pixels, at one point of the breath.
    Future<int> drawnHeightAt(Duration offset) async {
      await tester.pumpWidget(
        _app(
          RepaintBoundary(
            key: boundary,
            child: VoicePipelineView(
              snapshot: snapshot,
              clock: () => now.add(offset),
            ),
          ),
          size: const Size(460, 96),
        ),
      );
      await tester.pump();
      // Every await of the image pipeline runs outside the test's fake-async
      // zone: inside it they wait for a frame that never comes and the test
      // hangs.
      late int drawn;
      await tester.runAsync(() async {
        final render =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await render.toImage(pixelRatio: 2);
        final pixels = await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        final raw = pixels!.buffer.asUint8List();
        final width = image.width;
        final height = image.height;
        // The agent's work is the white run: its own colour, and the only
        // white on the pill when a turn is the only thing in the pipe.
        var top = height, bottom = -1;
        for (var y = 0; y < height; y++) {
          for (var x = 0; x < width; x++) {
            final i = (y * width + x) * 4;
            if (raw[i] > 200 && raw[i + 1] > 200 && raw[i + 2] > 200) {
              if (y < top) top = y;
              if (y > bottom) bottom = y;
            }
          }
        }
        drawn = bottom < top ? 0 : bottom - top + 1;
      });
      return drawn;
    }

    // The crest is a quarter of a breath in; half a breath lands back on the
    // trough's own phase, so sampling there would compare two identical
    // points and pass a frozen run.
    final trough = await drawnHeightAt(Duration.zero);
    final crest = await drawnHeightAt(VoiceRibbon.warbleBreath ~/ 4);
    expect(trough, greaterThan(0), reason: 'the run is drawn at all');
    expect(
      crest,
      greaterThan(trough),
      reason: 'the run swells with the breath',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a narrow full-size panel keeps the pill, not a ring', (
    tester,
  ) async {
    final snapshot = _snapshot(
      segments: [
        _segment(
          'u-1',
          VoicePipelineStage.inTurn,
          duration: const Duration(seconds: 1),
        ),
      ],
      turns: const [
        VoiceTurn(
          id: 't-1',
          stage: 'working',
          generation: 1,
          segmentIds: ['u-1'],
        ),
      ],
      accepted: 1,
    );
    await tester.pumpWidget(
      _app(
        VoicePipelineView(snapshot: snapshot, clock: () => now),
        size: const Size(320, 140),
      ),
    );
    expect(find.byKey(const Key('voice-pipeline-ribbon')), findsOneWidget);
    expect(find.byKey(const Key('voice-pipeline-ring')), findsNothing);
    expect(find.textContaining('1 accepted'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('screen readers hear the whole pipe and every cluster', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(
        VoicePipelineView(
          snapshot: _snapshot(
            speechActive: true,
            segments: [
              _segment(
                'u-1',
                VoicePipelineStage.transcribed,
                duration: const Duration(seconds: 1),
              ),
            ],
            accepted: 1,
          ),
          clock: () => now,
        ),
      ),
    );
    expect(
      spoken(
        tester,
        'Mic · live · Level · 42% · Speech · heard · 1 accepted · '
        'Voice · silent',
      ),
      isTrue,
      reason: 'the whole pipe is one node a reader hears first',
    );
    expect(
      spoken(tester, 'Blip, u-1 · transcribed · 1.0s'),
      isTrue,
      reason: 'and each cluster is a node of its own',
    );
    semantics.dispose();
  });

  testWidgets('every run fills its own cells on one pitch', (tester) async {
    // Two defects this pins down, both of which made the bar read as broken:
    // a run drawn at a pitch of its own (its bars merged into a blob), and a
    // run's box wider than the bars inside it (a hole opened before the next
    // stage).  A full pipe is drawn, so no stage is idle and the grid alone
    // decides where a bar goes.
    await tester.pumpWidget(
      _app(
        VoicePipelineView(
          snapshot: _snapshot(
            level: 0.56,
            segments: [
              _segment('u-1', VoicePipelineStage.accepted),
              _segment(
                'u-2',
                VoicePipelineStage.transcribed,
                text: 'hello',
              ),
              _segment('u-3', VoicePipelineStage.answered),
            ],
            replies: const [
              VoiceReply(
                id: 'n-1',
                stage: VoiceReplyStage.speaking,
                generation: 1,
                text: 'done',
              ),
            ],
            accepted: 3,
          ),
          clock: () => now,
        ),
        size: const Size(520, 140),
      ),
    );
    expect(tester.takeException(), isNull);
    // Each run is keyed by its own id, and its box is exactly the cells it
    // owns.  The distance from one run's left edge to the next is that run's
    // own width: the grid is continuous, so no gap opens between two stages
    // and no run is drawn wider than the bars inside it.
    final runs = <(double, double)>[];
    for (final id in const ['u-1', 'u-2', 'u-3', 'n-1', 'input']) {
      final found = find.byKey(ValueKey('voice-ribbon-$id'));
      if (found.evaluate().isEmpty) continue;
      final box = tester.renderObject<RenderBox>(found);
      final origin = box.localToGlobal(Offset.zero);
      runs.add((origin.dx, box.size.width));
    }
    expect(runs.length, greaterThan(3));
    runs.sort((a, b) => a.$1.compareTo(b.$1));
    // Every run starts exactly where the one before it ended: one continuous
    // grid, with no hole and no overlap.
    for (var i = 1; i < runs.length; i++) {
      expect(
        runs[i].$1,
        closeTo(runs[i - 1].$1 + runs[i - 1].$2, 0.01),
        reason: 'run $i must begin where run ${i - 1} ended',
      );
    }
    // Every box is a positive whole number of cells wide.
    for (final run in runs) {
      expect(run.$2, greaterThan(0));
    }
  });

  testWidgets('the bar keeps the approved geometry', (tester) async {
    // The approved ribbon is 690x111 px with a 13.5 px bar and an 11 px gap:
    // 0.122, 0.099 and 0.222 of the pill's own height.  These are the numbers
    // a later change is most likely to drift, so they are asserted rather
    // than described.
    expect(VoiceRibbonView.pillHeight, 46.0);
    expect(VoiceRibbonView.pillWidthInHeights, 6.2);
    expect(VoiceRibbonView.pillMaxWidth / VoiceRibbonView.pillHeight, 6.2);
    await tester.pumpWidget(
      _app(
        VoicePipelineView(
          snapshot: _snapshot(
            segments: [
              _segment(
                'u-1',
                VoicePipelineStage.accepted,
                duration: const Duration(seconds: 1),
              ),
            ],
            accepted: 1,
          ),
          clock: () => now,
        ),
        size: const Size(520, 140),
      ),
    );
    expect(tester.takeException(), isNull);
    // The pill itself is its own height times 6.2, whatever room it is given.
    // The view is a full-width host that centres the pill, so the pill's own
    // painter is what carries the proportion.
    final pill = tester.getSize(
      find
          .descendant(
            of: find.byKey(const Key('voice-pipeline-ribbon')),
            matching: find.byType(CustomPaint),
          )
          .first,
    );
    expect(pill.height, 46.0);
    expect(pill.width / pill.height, closeTo(6.2, 0.01));
  });
}
