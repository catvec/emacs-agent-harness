// Pictures of the voice pipe, drawn with the fonts of a phone.
//
//   HARNESS_SHOTS=/some/directory flutter test test/voice_pipeline_screenshots_test.dart
//
// writes a PNG for each case there.  Without HARNESS_SHOTS the cases still run
// (they draw, and check that the frame is whole), and write nothing.
//
// Every state here is a fixture: the snapshots are built from events the
// widget tests script, not from a microphone or a speech service.  What is
// real in the pictures is the widget and the state model it draws.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/ui/adaptive/platform_style.dart';
import 'package:harness_client/src/ui/screens/voice_screen.dart';
import 'package:harness_client/src/ui/theme/harness_theme.dart';
import 'package:harness_client/src/ui/widgets/voice_pipeline.dart';
import 'package:harness_client/src/voice/voice_backend.dart';
import 'package:harness_client/src/voice/voice_models.dart';
import 'package:harness_client/src/voice/voice_pipeline.dart';

import 'support/real_fonts.dart';
import 'support/voice_fakes.dart';

final _now = DateTime(2026, 11, 7, 12, 4);

/// A pipe in the middle of a conversation: one burst the filter dropped, one
/// it kept, one being transcribed, one whose turn was answered, and a reply
/// the speaker is playing.
VoicePipelineSnapshot _flow() => VoicePipelineSnapshot(
  generation: 1,
  input: VoiceInputState.live,
  level: 0.56,
  levelSeen: true,
  levelAt: _now,
  speechActive: true,
  segments: const [
    VoiceSegment(
      id: 'r-2',
      stage: VoicePipelineStage.dropped,
      generation: 1,
      duration: Duration(milliseconds: 640),
      drop: VoiceSegmentDrop.tooShort,
    ),
    VoiceSegment(
      id: 'u-4',
      stage: VoicePipelineStage.accepted,
      generation: 1,
      duration: Duration(milliseconds: 1400),
      text: 'and then the',
    ),
    VoiceSegment(
      id: 'u-3',
      stage: VoicePipelineStage.transcribing,
      generation: 1,
      duration: Duration(seconds: 2),
      text: 'check the merge queue',
      revision: 2,
    ),
    VoiceSegment(
      id: 'u-2',
      stage: VoicePipelineStage.transcribed,
      generation: 1,
      duration: Duration(seconds: 1),
      text: 'is the build green',
      revision: 1,
    ),
    VoiceSegment(
      id: 'u-1',
      stage: VoicePipelineStage.answered,
      generation: 1,
      duration: Duration(seconds: 3),
      text: 'run the tests',
      turnId: 't-1',
      revision: 1,
    ),
  ],
  turns: const [
    VoiceTurn(
      id: 't-1',
      stage: 'done',
      generation: 1,
      segmentIds: ['u-1'],
      replyIds: ['n-1'],
    ),
  ],
  replies: const [
    VoiceReply(
      id: 'n-1',
      stage: VoiceReplyStage.speaking,
      generation: 1,
      turnId: 't-1',
      text: 'They all pass.',
    ),
  ],
  accepted: 4,
  dropped: 1,
  spoken: 0,
  playing: true,
);

VoicePipelineSnapshot _held() {
  final base = _flow();
  return VoicePipelineSnapshot(
    generation: base.generation,
    input: VoiceInputState.muted,
    level: 0,
    levelSeen: true,
    levelAt: _now,
    speechActive: false,
    segments: base.segments,
    turns: base.turns,
    replies: const [
      VoiceReply(
        id: 'n-2',
        stage: VoiceReplyStage.held,
        generation: 1,
        turnId: 't-1',
        text: 'The second task is still building.',
      ),
    ],
    accepted: base.accepted,
    dropped: base.dropped,
    spoken: base.spoken,
    playing: false,
  );
}

Widget _app({required Widget child, required Size size, double scale = 1}) =>
    HarnessStyle(
      style: HarnessPlatformStyle.material,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: HarnessTheme.material(Brightness.dark),
        home: MediaQuery(
          data: MediaQueryData(
            size: size,
            textScaler: TextScaler.linear(scale),
          ),
          child: child,
        ),
      ),
    );

Widget _panel(Widget child) => Theme(
  data: HarnessTheme.material(Brightness.dark),
  child: Scaffold(
    backgroundColor: const Color(0xFF0D0D0F),
    body: Padding(padding: const EdgeInsets.all(16), child: child),
  ),
);

Future<void> _size(WidgetTester tester, double width, double height) async {
  const ratio = 2.0;
  tester.view.physicalSize = Size(width * ratio, height * ratio);
  tester.view.devicePixelRatio = ratio;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _write(
  WidgetTester tester,
  GlobalKey boundary,
  String path,
) async {
  await tester.runAsync(() async {
    final render =
        boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await render.toImage(pixelRatio: 1.5);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File(path);
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(data!.buffer.asUint8List());
  });
}

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  final shots = Platform.environment['HARNESS_SHOTS'];
  final real = await loadRealFonts();

  testWidgets('draws the pipe in flow', (tester) async {
    await _size(tester, 720, 190);
    final boundary = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: _app(
          size: const Size(720, 190),
          child: _panel(
            VoicePipelineView(snapshot: _flow(), clock: () => _now),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('Pipeline'), findsOneWidget);
    if (shots != null) {
      await _write(
        tester,
        boundary,
        '$shots/voice-pipeline-flow${real ? '' : '-ahem'}.png',
      );
    }
  });

  testWidgets('draws the compact presentation a buddy shows', (tester) async {
    await _size(tester, 320, 96);
    final boundary = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: _app(
          size: const Size(320, 96),
          child: _panel(
            VoicePipelineView(
              snapshot: _flow(),
              compact: true,
              clock: () => _now,
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(
      find.text(
        'Mic · live · 4 accepted · 1 dropped · Turn · done · Voice · speaking',
      ),
      findsOneWidget,
    );
    if (shots != null) {
      await _write(
        tester,
        boundary,
        '$shots/voice-pipeline-compact${real ? '' : '-ahem'}.png',
      );
    }
  });

  testWidgets('draws a held reply with the microphone muted', (tester) async {
    await _size(tester, 720, 190);
    final boundary = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: _app(
          size: const Size(720, 190),
          child: _panel(
            VoicePipelineView(snapshot: _held(), clock: () => _now),
          ),
        ),
      ),
    );
    expect(find.textContaining('Voice · held'), findsWidgets);
    expect(tester.takeException(), isNull);
    if (shots != null) {
      await _write(
        tester,
        boundary,
        '$shots/voice-pipeline-held${real ? '' : '-ahem'}.png',
      );
    }
  });

  testWidgets('reduced motion shows the same facts, without movement', (
    tester,
  ) async {
    await _size(tester, 720, 190);
    final boundary = GlobalKey();
    final snapshot = _flow();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: _app(
          size: const Size(720, 190),
          child: _panel(
            MediaQuery(
              data: const MediaQueryData(disableAnimations: true),
              child: VoicePipelineView(snapshot: snapshot, clock: () => _now),
            ),
          ),
        ),
      ),
    );
    expect(
      find.text(snapshot.summary(_now)),
      findsOneWidget,
      reason: 'a still pipe says everything the moving one says',
    );
    expect(tester.takeException(), isNull);
    if (shots != null) {
      await _write(
        tester,
        boundary,
        '$shots/voice-pipeline-reduced-motion${real ? '' : '-ahem'}.png',
      );
    }
  });

  testWidgets('draws the pipe at large text', (tester) async {
    await _size(tester, 390, 420);
    final boundary = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: _app(
          size: const Size(390, 420),
          scale: 2,
          child: _panel(
            Align(
              alignment: Alignment.topCenter,
              child: VoicePipelineView(snapshot: _flow(), clock: () => _now),
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    if (shots != null) {
      await _write(
        tester,
        boundary,
        '$shots/voice-pipeline-large-text${real ? '' : '-ahem'}.png',
      );
    }
  });

  testWidgets('draws the voice screen with the pipe in it', (tester) async {
    await _size(tester, 390, 844);
    final boundary = GlobalKey();
    final rig = Rig();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: _app(
          size: const Size(390, 844),
          child: VoiceScreen(controller: rig.controller),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    rig.backend.emit(
      const VoiceCaptionEvent(
        VoiceSpeaker.you,
        'run the tests',
        finalized: true,
        segmentId: 'u-1',
      ),
    );
    rig.backend.emit(
      const VoiceSegmentEvent(
        id: 'u-1',
        stage: VoiceSegmentStage.accepted,
        duration: Duration(milliseconds: 1400),
      ),
    );
    rig.backend.emit(
      const VoiceSegmentEvent(id: 'u-1', stage: VoiceSegmentStage.transcribing),
    );
    await tester.pump(const Duration(milliseconds: 20));
    rig.session.reply('They all pass.');
    await tester.pump(const Duration(milliseconds: 40));
    final reply = rig.controller.pipelineState.replies.isEmpty
        ? null
        : rig.controller.pipelineState.replies.last;
    if (reply != null) {
      rig.backend.emit(VoicePlaybackEvent(playing: true, replyId: reply.id));
    }
    await tester.pump(const Duration(milliseconds: 40));
    expect(find.byType(VoicePipelineView), findsOneWidget);
    expect(find.text('Prompt'), findsNothing);
    expect(tester.takeException(), isNull);
    if (shots != null) {
      await _write(
        tester,
        boundary,
        '$shots/voice-pipeline-screen${real ? '' : '-ahem'}.png',
      );
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
