import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/ui/adaptive/platform_style.dart';
import 'package:harness_client/src/ui/screens/voice_screen.dart';
import 'package:harness_client/src/ui/theme/harness_theme.dart';
import 'package:harness_client/src/ui/widgets/voice_pipeline.dart';
import 'package:harness_client/src/voice/voice_backend.dart';
import 'package:harness_client/src/voice/voice_pipeline.dart';

import 'support/voice_fakes.dart';

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

Finder marker(String id) => find.byKey(ValueKey('lane-$id'));

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
  testWidgets('the pipe names its stages and carries its state in words', (
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

    expect(find.text('Pipeline'), findsOneWidget);
    expect(find.text('Input'), findsOneWidget);
    expect(find.text('Filter'), findsOneWidget);
    expect(find.text('Words'), findsOneWidget);
    expect(find.text('Turn'), findsOneWidget);
    expect(find.text('Speaker'), findsOneWidget);
    expect(find.text('Mic · live'), findsOneWidget);
    expect(find.text('Level · 40%'), findsOneWidget);
    expect(
      find.text(
        'Mic · live · Level · 40% · 3 accepted · Turn · working · '
        'Voice · speaking',
      ),
      findsOneWidget,
      reason: 'one line carries every fact, so colour is never the only signal',
    );
    expect(find.byKey(const Key('voice-pipeline-speaker')), findsOneWidget);
    expect(find.text('accepted · 1.4s'), findsOneWidget);
    expect(find.text('transcribed · 900ms'), findsOneWidget);
    expect(find.text('answered · 2.0s'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('every stage header has a one-line tooltip', (tester) async {
    await tester.pumpWidget(
      _app(VoicePipelineView(snapshot: _snapshot(), clock: () => now)),
    );
    for (final help in const [
      'Microphone level before the speech filter',
      'Speech kept for transcription',
      'Speech to text',
      'Agent work',
      'Playback',
    ]) {
      expect(find.byTooltip(help), findsOneWidget, reason: help);
    }
    expect(find.byTooltip('Pipeline details'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Pipeline details')), findsWidgets);
  });

  testWidgets('a missing level says no data, not silence', (tester) async {
    final live = _snapshot(
      levelSeen: false,
      levelAt: null,
      input: VoiceInputState.live,
    );
    await tester.pumpWidget(
      _app(VoicePipelineView(snapshot: live, clock: () => now)),
    );
    expect(find.text('Mic · live'), findsOneWidget);
    expect(find.text('Level · no data'), findsOneWidget);

    final stale = _snapshot(levelAt: now.subtract(const Duration(seconds: 5)));
    await tester.pumpWidget(
      _app(VoicePipelineView(snapshot: stale, clock: () => now)),
    );
    expect(find.text('Level · no data'), findsOneWidget);
    expect(find.textContaining('Level · 0%'), findsNothing);
  });

  testWidgets('a frozen meter turns into no data by itself', (tester) async {
    await tester.pumpWidget(
      _app(
        VoicePipelineView(snapshot: _snapshot(level: 0.8), clock: () => now),
      ),
    );
    expect(find.text('Level · 80%'), findsOneWidget);
    now = now.add(const Duration(seconds: 3));
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('Level · no data'), findsOneWidget);
    now = now.subtract(const Duration(seconds: 3));
  });

  testWidgets('a rejected burst says what was dropped and why', (tester) async {
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
    expect(find.textContaining('too short'), findsOneWidget);
    expect(find.text('1.0'), findsNothing);
    expect(find.text('heard'), findsOneWidget);
    expect(
      find.text(
        'Mic · live · Level · 42% · Speech · heard · 1 accepted · 1 dropped · '
        'Voice · silent',
      ),
      findsOneWidget,
    );
    final semantics = tester.ensureSemantics();
    await tester.pump();
    expect(
      spoken(tester, 'Segment r-1, dropped, 640ms of audio, too short'),
      isTrue,
    );
    expect(spoken(tester, 'Speech gate, speech heard'), isTrue);
    semantics.dispose();
  });

  testWidgets('a problem is named beside the meter in the summary', (
    tester,
  ) async {
    final snapshot = _snapshot(
      input: VoiceInputState.failed,
      levelSeen: false,
      levelAt: null,
      problemLabel: 'Microphone permission denied',
    );
    await tester.pumpWidget(
      _app(VoicePipelineView(snapshot: snapshot, clock: () => now)),
    );
    expect(find.text('Mic · failed'), findsOneWidget);
    expect(
      find.text(
        'Mic · failed · Level · no data · Voice · silent · '
        'Microphone permission denied',
      ),
      findsOneWidget,
    );
  });

  testWidgets('the details list names every marker by its id and stage', (
    tester,
  ) async {
    final snapshot = _snapshot(
      segments: [
        _segment(
          'u-1',
          VoicePipelineStage.transcribed,
          duration: const Duration(milliseconds: 1400),
          text: 'open the merge queue',
        ),
        _segment(
          'r-1',
          VoicePipelineStage.dropped,
          duration: const Duration(milliseconds: 80),
          drop: VoiceSegmentDrop.tooShort,
        ),
        _segment(
          'r-2',
          VoicePipelineStage.dropped,
          duration: const Duration(milliseconds: 640),
          detail: 'muted',
        ),
      ],
      turns: const [
        VoiceTurn(
          id: 't-1',
          stage: 'working',
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
        ),
      ],
      accepted: 1,
      dropped: 2,
      playing: true,
    );
    await tester.pumpWidget(
      _app(VoicePipelineView(snapshot: snapshot, clock: () => now)),
    );
    expect(find.textContaining('u-1 · transcribed'), findsNothing);
    await tester.tap(find.byKey(const Key('voice-pipeline-details')));
    await tester.pump();
    expect(
      find.text('u-1 · transcribed · 1.4s · "open the merge queue"'),
      findsOneWidget,
    );
    expect(find.text('r-1 · dropped · 80ms · too short'), findsOneWidget);
    expect(
      find.text('r-2 · dropped · 640ms · muted'),
      findsOneWidget,
      reason: 'a burst stopped by the mute button says why',
    );
    expect(find.text('t-1 · replied · 1 utterance · 1 reply'), findsOneWidget);
    expect(find.text('n-1 · speaking · t-1'), findsOneWidget);
    await tester.tap(find.byKey(const Key('voice-pipeline-details')));
    await tester.pump();
    expect(find.textContaining('u-1 · transcribed'), findsNothing);
  });

  testWidgets('an empty pipe says so, and a keyboard can open it', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(VoicePipelineView(snapshot: _snapshot(), clock: () => now)),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(find.text('No segments yet'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(find.text('No segments yet'), findsNothing);
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
    final marker = find.byKey(const ValueKey('lane-u-1'));

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

  testWidgets('a narrow panel keeps every fact in its summary', (tester) async {
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
        VoicePipelineView(snapshot: snapshot, compact: true, clock: () => now),
        size: const Size(300, 90),
      ),
    );
    expect(find.text('Pipeline'), findsNothing);
    expect(
      find.text('Mic · live · 1 accepted · Turn · working · Voice · silent'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(
      _app(
        VoicePipelineView(snapshot: snapshot, clock: () => now),
        size: const Size(320, 140),
      ),
    );
    expect(find.text('Pipeline'), findsNothing, reason: 'a narrow view folds');
    expect(find.textContaining('1 accepted'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('large text fits the wide view and its summary', (tester) async {
    tester.view.physicalSize = const Size(390 * 2, 844 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: HarnessTheme.material(Brightness.light),
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: Scaffold(
            body: Center(
              child: SizedBox(
                width: 390,
                height: 260,
                child: VoicePipelineView(
                  snapshot: _snapshot(
                    segments: [
                      _segment(
                        'u-1',
                        VoicePipelineStage.transcribed,
                        duration: const Duration(seconds: 1),
                        text: 'open the merge queue',
                      ),
                    ],
                    accepted: 1,
                  ),
                  clock: () => now,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    // Large text folds to the compact presentation, which names the same
    // facts in a summary that is free to wrap.
    expect(
      find.text('Pipeline'),
      findsNothing,
      reason: 'large text folds to the compact view',
    );
    expect(find.textContaining('1 accepted'), findsWidgets);
    expect(find.textContaining('Voice · silent'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the voice screen draws the pipe at phone and large text sizes', (
    tester,
  ) async {
    for (final (width, height, scale) in const [
      (390.0, 844.0, 1.0),
      (300.0, 640.0, 1.0),
      (390.0, 844.0, 1.6),
      (390.0, 844.0, 2.0),
    ]) {
      tester.view.physicalSize = Size(width * 2, height * 2);
      tester.view.devicePixelRatio = 2;
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final rig = Rig();
      await tester.pumpWidget(
        _app(
          VoiceScreen(controller: rig.controller),
          size: Size(width, height),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      rig.backend.emit(
        const VoiceSegmentEvent(
          id: 'u-1',
          stage: VoiceSegmentStage.transcribing,
          duration: Duration(milliseconds: 1400),
        ),
      );
      await tester.pump();
      expect(
        find.byType(VoicePipelineView),
        findsOneWidget,
        reason: '$width x $height at $scale',
      );
      expect(
        tester.takeException(),
        isNull,
        reason: '$width x $height at $scale',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('screen readers get the summary and each stage', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(
        VoicePipelineView(
          snapshot: _snapshot(speechActive: true),
          clock: () => now,
        ),
      ),
    );
    expect(
      spoken(
        tester,
        'Mic · live · Level · 42% · Speech · heard · Voice · silent',
      ),
      isTrue,
      reason: 'the summary is what a reader hears for the whole pipe',
    );
    expect(spoken(tester, 'Speaker · silent'), isTrue);
    expect(spoken(tester, 'Speech gate, speech heard'), isTrue);
    semantics.dispose();
  });
}
