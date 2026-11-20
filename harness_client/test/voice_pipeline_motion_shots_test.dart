// A motion capture of the voice ribbon, drawn with the fonts of a phone.
//
//   HARNESS_SHOTS=/some/directory flutter test test/voice_pipeline_motion_shots_test.dart
//
// writes one PNG per frame there, in order.  `scripts/voice-ribbon-motion.py`
// joins them into the GIF the review asks for.  Without HARNESS_SHOTS the case
// still runs and writes nothing.
//
// The frames are a fixture: a scripted sequence of the protocol's own events,
// fed to the same widget the app draws, so what moves is the real handoff and
// the real warble, and nothing moves on a clock of its own.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/ui/adaptive/platform_style.dart';
import 'package:harness_client/src/ui/theme/harness_theme.dart';
import 'package:harness_client/src/ui/widgets/voice_pipeline.dart';
import 'package:harness_client/src/voice/voice_backend.dart';
import 'package:harness_client/src/voice/voice_pipeline.dart';
import 'package:harness_client/src/voice/voice_ribbon.dart';

import 'support/real_fonts.dart';

final _start = DateTime(2026, 11, 7, 12, 4);

VoicePipelineSnapshot _snapshot({
  required List<VoiceSegment> segments,
  required List<VoiceReply> replies,
  bool playing = false,
}) => VoicePipelineSnapshot(
  generation: 1,
  input: VoiceInputState.live,
  level: 0.56,
  levelSeen: true,
  levelAt: _start,
  speechActive: true,
  segments: segments,
  turns: const [],
  replies: replies,
  accepted: segments.length,
  dropped: 0,
  spoken: 0,
  playing: playing,
);

const _dropped = VoiceSegment(
  id: 'r-2',
  stage: VoicePipelineStage.dropped,
  generation: 1,
  duration: Duration(milliseconds: 640),
  drop: VoiceSegmentDrop.tooShort,
);

/// The sequence: a burst is kept, transcribed, sent, answered, and spoken,
/// while a second burst is dropped.  Every step is one real stage change.
List<VoicePipelineSnapshot> _frames() {
  const kept = VoiceSegment(
    id: 'u-1',
    stage: VoicePipelineStage.accepted,
    generation: 1,
    duration: Duration(milliseconds: 1400),
    text: 'run the tests',
  );
  const transcribing = VoiceSegment(
    id: 'u-1',
    stage: VoicePipelineStage.transcribing,
    generation: 1,
    duration: Duration(milliseconds: 1400),
    text: 'run the tests',
    revision: 1,
  );
  const transcribed = VoiceSegment(
    id: 'u-1',
    stage: VoicePipelineStage.transcribed,
    generation: 1,
    duration: Duration(milliseconds: 1400),
    text: 'run the tests',
    revision: 2,
  );
  const answered = VoiceSegment(
    id: 'u-1',
    stage: VoicePipelineStage.answered,
    generation: 1,
    duration: Duration(milliseconds: 1400),
    text: 'run the tests',
    turnId: 't-1',
    revision: 3,
  );
  const handed = VoiceReply(
    id: 'n-1',
    stage: VoiceReplyStage.handed,
    generation: 1,
    turnId: 't-1',
    text: 'They all pass.',
  );
  const speaking = VoiceReply(
    id: 'n-1',
    stage: VoiceReplyStage.speaking,
    generation: 1,
    turnId: 't-1',
    text: 'They all pass.',
  );
  return [
    _snapshot(segments: const [_dropped, kept], replies: const []),
    _snapshot(segments: const [_dropped, transcribing], replies: const []),
    _snapshot(segments: const [_dropped, transcribing], replies: const []),
    _snapshot(segments: const [_dropped, transcribed], replies: const []),
    _snapshot(segments: const [_dropped, answered], replies: const [handed]),
    _snapshot(segments: const [_dropped, answered], replies: const [speaking]),
    _snapshot(
      segments: const [_dropped, answered],
      replies: const [speaking],
      playing: true,
    ),
    _snapshot(segments: const [_dropped, answered], replies: const [speaking]),
  ];
}

Widget _app(Widget child, Size size) => HarnessStyle(
  style: HarnessPlatformStyle.material,
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: HarnessTheme.material(Brightness.dark),
    home: MediaQuery(
      data: MediaQueryData(size: size),
      child: child,
    ),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('draws the ribbon moving through its stages', (tester) async {
    final shots = Platform.environment['HARNESS_SHOTS'];
    final real = await loadRealFonts();
    final suffix = real ? '' : '-ahem';
    const size = Size(460, 96);
    tester.view.physicalSize = size * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final boundary = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: _app(
          Theme(
            data: HarnessTheme.material(Brightness.dark),
            child: Scaffold(
              backgroundColor: const Color(0xFF0D0D0F),
              body: Padding(
                padding: const EdgeInsets.all(16),
                child: VoicePipelineView(
                  snapshot: _frames().first,
                  clock: () => _start,
                ),
              ),
            ),
          ),
          size,
        ),
      ),
    );
    var index = 0;
    for (final snapshot in _frames()) {
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: _app(
            Theme(
              data: HarnessTheme.material(Brightness.dark),
              child: Scaffold(
                backgroundColor: const Color(0xFF0D0D0F),
                body: Padding(
                  padding: const EdgeInsets.all(16),
                  child: VoicePipelineView(
                    snapshot: snapshot,
                    clock: () => _start,
                  ),
                ),
              ),
            ),
            size,
          ),
        ),
      );
      // Let the handoff's own move finish before the frame is taken.
      await tester.pump(const Duration(milliseconds: 260));
      expect(tester.takeException(), isNull);
      if (shots != null) {
        await tester.runAsync(() async {
          final render =
              boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final image = await render.toImage(pixelRatio: 2);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File(
            '$shots/voice-pipeline-motion-${index.toString().padLeft(2, '0')}$suffix.png',
          );
          file.parent.createSync(recursive: true);
          file.writeAsBytesSync(data!.buffer.asUint8List());
        });
      }
      index++;
    }
  });

  // The handoff capture above holds the clock still, so it shows the stages
  // moving and not the breath: the breath is the one thing that moves with
  // no event at all.  This capture advances the clock across one breath, with
  // a burst waiting in the words, so a reader can see the waiting run swell
  // and settle in place.
  testWidgets('draws the waiting run breathing', (tester) async {
    final shots = Platform.environment['HARNESS_SHOTS'];
    final real = await loadRealFonts();
    final suffix = real ? '' : '-ahem';
    const size = Size(460, 96);
    tester.view.physicalSize = size * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final boundary = GlobalKey();
    const transcribing = VoiceSegment(
      id: 'u-1',
      stage: VoicePipelineStage.transcribing,
      generation: 1,
      duration: Duration(milliseconds: 1400),
      text: 'run the tests',
      revision: 1,
    );
    final snapshot = _snapshot(segments: const [transcribing], replies: const []);
    // Sixteen redraws across more than one breath: one frame per redraw, at
    // the interval the host really uses.
    const redraw = Duration(
      microseconds:
          Duration.microsecondsPerSecond ~/ VoiceRibbon.warbleFramesPerSecond,
    );
    for (var tick = 0; tick < 16; tick++) {
      final at = _start.add(redraw * tick);
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: _app(
            Theme(
              data: HarnessTheme.material(Brightness.dark),
              child: Scaffold(
                backgroundColor: const Color(0xFF0D0D0F),
                body: Padding(
                  padding: const EdgeInsets.all(16),
                  child: VoicePipelineView(snapshot: snapshot, clock: () => at),
                ),
              ),
            ),
            size,
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      if (shots != null) {
        await tester.runAsync(() async {
          final render =
              boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final image = await render.toImage(pixelRatio: 2);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File(
            '$shots/voice-ribbon-breath-${tick.toString().padLeft(2, '0')}$suffix.png',
          );
          file.parent.createSync(recursive: true);
          file.writeAsBytesSync(data!.buffer.asUint8List());
        });
      }
    }
  });

  // A segmented waiting run: the agent's work and a handed reply.  Their
  // approved shapes are a fixed height with the dashes inside them changing,
  // so a breath that only changed the dashes left them looking still.  This
  // capture shows their height swelling too.
  testWidgets('draws a segmented run breathing', (tester) async {
    final shots = Platform.environment['HARNESS_SHOTS'];
    final real = await loadRealFonts();
    final suffix = real ? '' : '-ahem';
    const size = Size(460, 96);
    tester.view.physicalSize = size * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final boundary = GlobalKey();
    const inTurn = VoiceSegment(
      id: 'u-1',
      stage: VoicePipelineStage.inTurn,
      generation: 1,
      duration: Duration(milliseconds: 1400),
      text: 'run the tests',
      turnId: 't-1',
      revision: 3,
    );
    final snapshot = _snapshot(segments: const [inTurn], replies: const []);
    const redraw = Duration(
      microseconds:
          Duration.microsecondsPerSecond ~/ VoiceRibbon.warbleFramesPerSecond,
    );
    for (var tick = 0; tick < 16; tick++) {
      final at = _start.add(redraw * tick);
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: _app(
            Theme(
              data: HarnessTheme.material(Brightness.dark),
              child: Scaffold(
                backgroundColor: const Color(0xFF0D0D0F),
                body: Padding(
                  padding: const EdgeInsets.all(16),
                  child: VoicePipelineView(snapshot: snapshot, clock: () => at),
                ),
              ),
            ),
            size,
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      if (shots != null) {
        await tester.runAsync(() async {
          final render =
              boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final image = await render.toImage(pixelRatio: 2);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File(
            '$shots/voice-ribbon-segmented-${tick.toString().padLeft(2, '0')}$suffix.png',
          );
          file.parent.createSync(recursive: true);
          file.writeAsBytesSync(data!.buffer.asUint8List());
        });
      }
    }
  });
}
