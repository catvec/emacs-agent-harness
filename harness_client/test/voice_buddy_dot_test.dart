// The buddy's circle: its ring table, its words, and the rules that keep it
// from claiming anything the call did not report.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/ui/adaptive/platform_style.dart';
import 'package:harness_client/src/ui/theme/harness_theme.dart';
import 'package:harness_client/src/ui/widgets/voice_buddy_dot.dart';
import 'package:harness_client/src/voice/voice_buddy.dart';

BuddyStatus _status(
  BuddyPhase phase, {
  BuddyMic mic = BuddyMic.off,
  BuddyOutput output = BuddyOutput.idle,
  bool levelReported = false,
}) => BuddyStatus(
  phase: phase,
  mic: mic,
  output: output,
  levelReported: levelReported,
);

/// The microphone each phase really has, from the controller's own resolver.
BuddyMic _micFor(BuddyPhase phase) => switch (phase) {
  BuddyPhase.starting => BuddyMic.starting,
  BuddyPhase.listening ||
  BuddyPhase.hearing ||
  BuddyPhase.transcribing ||
  BuddyPhase.working ||
  BuddyPhase.holdingReply ||
  BuddyPhase.speaking ||
  BuddyPhase.interrupted ||
  BuddyPhase.approval => BuddyMic.live,
  BuddyPhase.muted => BuddyMic.muted,
  BuddyPhase.paused => BuddyMic.paused,
  BuddyPhase.ending => BuddyMic.closing,
  BuddyPhase.off ||
  BuddyPhase.ended ||
  BuddyPhase.failed ||
  BuddyPhase.unknown => BuddyMic.off,
};

Future<void> _pump(
  WidgetTester tester,
  BuddyStatus status, {
  double level = 0,
  double size = 44,
  bool pulseAllowed = true,
  double textScale = 1,
}) async {
  await tester.pumpWidget(
    HarnessStyle(
      style: HarnessPlatformStyle.material,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: HarnessTheme.material(Brightness.light),
        home: MediaQuery(
          data: MediaQueryData(
            size: const Size(400, 400),
            textScaler: TextScaler.linear(textScale),
          ),
          child: Scaffold(
            body: Center(
              child: VoiceBuddyDot(
                status: status,
                workspaceName: 'Home',
                level: level,
                size: size,
                pulseAllowed: pulseAllowed,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('the ring says only what was reported', () {
    test('every phase maps to the tone its words stand for', () {
      const expected = {
        BuddyPhase.off: BuddyRingTone.neutral,
        BuddyPhase.starting: BuddyRingTone.attention,
        BuddyPhase.listening: BuddyRingTone.live,
        BuddyPhase.hearing: BuddyRingTone.hearing,
        BuddyPhase.transcribing: BuddyRingTone.attention,
        BuddyPhase.working: BuddyRingTone.attention,
        BuddyPhase.holdingReply: BuddyRingTone.attention,
        BuddyPhase.speaking: BuddyRingTone.live,
        BuddyPhase.interrupted: BuddyRingTone.muted,
        BuddyPhase.muted: BuddyRingTone.muted,
        BuddyPhase.paused: BuddyRingTone.muted,
        BuddyPhase.approval: BuddyRingTone.attention,
        BuddyPhase.ending: BuddyRingTone.muted,
        BuddyPhase.ended: BuddyRingTone.neutral,
        BuddyPhase.failed: BuddyRingTone.failed,
        BuddyPhase.unknown: BuddyRingTone.unknown,
      };
      for (final entry in expected.entries) {
        final ring = buddyRingFor(_status(entry.key, mic: _micFor(entry.key)));
        expect(
          ring.tone,
          entry.value,
          reason: '${entry.key.name} must ring as ${entry.value.name}',
        );
        // The words are the ones the bar and the card say, unchanged.
        expect(ring.word, entry.key.label);
        expect(ring.micWord, _micFor(entry.key).label);
      }
    });

    test('the ring carries non-colour cues for every grouped tone', () {
      final muted = buddyRingFor(
        _status(BuddyPhase.muted, mic: BuddyMic.muted),
      );
      expect(muted.dashed, isTrue, reason: 'Muted is a broken ring');
      final paused = buddyRingFor(
        _status(BuddyPhase.paused, mic: BuddyMic.paused),
      );
      expect(paused.dashed, isTrue, reason: 'Paused is a broken ring too');
      final hearing = buddyRingFor(
        _status(BuddyPhase.hearing, mic: BuddyMic.live),
      );
      expect(hearing.weight, greaterThan(3), reason: 'speech thickens the ring');
      final quiet = buddyRingFor(
        _status(BuddyPhase.listening, mic: BuddyMic.live),
      );
      expect(quiet.weight, 3);
      expect(quiet.dashed, isFalse);
      final held = buddyRingFor(
        _status(BuddyPhase.holdingReply, mic: BuddyMic.live),
      );
      expect(held.gap, isTrue, reason: 'a held reply leaves a gap at the top');
      expect(quiet.gap, isFalse);
    });

    test('the ring pulses only on a live microphone with reported levels', () {
      expect(
        buddyRingFor(
          _status(BuddyPhase.listening, mic: BuddyMic.live),
        ).pulse,
        isFalse,
        reason: 'no level was reported, so nothing may move',
      );
      expect(
        buddyRingFor(
          _status(
            BuddyPhase.listening,
            mic: BuddyMic.live,
            levelReported: true,
          ),
        ).pulse,
        isTrue,
      );
      for (final phase in [
        BuddyPhase.muted,
        BuddyPhase.paused,
        BuddyPhase.failed,
        BuddyPhase.ended,
        BuddyPhase.off,
        BuddyPhase.speaking,
      ]) {
        expect(
          buddyRingFor(
            _status(phase, mic: _micFor(phase), levelReported: true),
          ).pulse,
          isFalse,
          reason: '${phase.name} must not draw capture activity',
        );
      }
    });

    test('the label is the status and the microphone, in words', () {
      expect(
        buddyRingFor(_status(BuddyPhase.hearing, mic: BuddyMic.live)).label,
        'Status · Hearing you · Mic live',
      );
      expect(
        buddyRingFor(_status(BuddyPhase.muted, mic: BuddyMic.muted)).label,
        'Status · Muted · Mic muted',
      );
      expect(
        buddyRingFor(_status(BuddyPhase.unknown, mic: BuddyMic.live)).label,
        'Status · Status unknown · Mic live',
      );
    });
  });

  group('the circle draws it', () {
    testWidgets('it announces the status and the microphone, not colour', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await _pump(tester, _status(BuddyPhase.hearing, mic: BuddyMic.live));
      expect(
        find.bySemanticsLabel(RegExp('Status · Hearing you · Mic live')),
        findsOneWidget,
      );
      expect(
        tester
            .getSemantics(find.byKey(const Key('voice-buddy-dot')))
            .tooltip,
        'Voice buddy · Hearing you',
      );
      expect(find.byKey(const Key('voice-buddy-face')), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('the face is the workspace initial, uppercase and singular', (
      tester,
    ) async {
      await _pump(tester, _status(BuddyPhase.listening, mic: BuddyMic.live));
      expect(find.text('H'), findsOneWidget);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: VoiceBuddyDot(
                status: _status(BuddyPhase.listening, mic: BuddyMic.live),
                workspaceName: '  ',
                size: 44,
              ),
            ),
          ),
        ),
      );
      expect(find.text('?'), findsOneWidget);
    });

    testWidgets('a muted call draws a broken ring and no pulse', (tester) async {
      await _pump(
        tester,
        _status(BuddyPhase.muted, mic: BuddyMic.muted, levelReported: true),
        level: 0.9,
      );
      final semantics = tester.ensureSemantics();
      expect(
        find.bySemanticsLabel(RegExp('Status · Muted · Mic muted')),
        findsOneWidget,
      );
      semantics.dispose();
      // The ring is drawn by a painter, so the test states its shape.
      final ring = buddyRingFor(
        _status(BuddyPhase.muted, mic: BuddyMic.muted, levelReported: true),
      );
      expect(ring.dashed, isTrue);
      expect(ring.pulse, isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a failed call is an error ring, never a live one', (
      tester,
    ) async {
      await _pump(tester, _status(BuddyPhase.failed));
      final ring = buddyRingFor(_status(BuddyPhase.failed));
      expect(ring.tone, BuddyRingTone.failed);
      expect(ring.micWord, 'Mic off');
      expect(tester.takeException(), isNull);
    });

    testWidgets('an unknown state says so rather than guessing', (tester) async {
      final semantics = tester.ensureSemantics();
      await _pump(
        tester,
        _status(BuddyPhase.unknown, mic: _micFor(BuddyPhase.unknown)),
      );
      expect(
        tester
            .getSemantics(find.byKey(const Key('voice-buddy-dot')))
            .tooltip,
        'Voice buddy · Status unknown',
      );
      semantics.dispose();
      expect(tester.takeException(), isNull);
    });

    testWidgets('the ring scales with text and keeps its glyph', (
      tester,
    ) async {
      await _pump(
        tester,
        _status(BuddyPhase.speaking, mic: BuddyMic.live),
        size: 64,
        textScale: 2,
      );
      expect(VoiceBuddyDot.ringFor(64), 3);
      expect(VoiceBuddyDot.ringFor(28), 2);
      expect(find.byIcon(Icons.volume_up_rounded), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('nothing moves on a clock', (tester) async {
      // A circle that pulses on a timer would need a pump to change.  Two
      // identical frames prove it draws from the report alone.
      await _pump(tester, _status(BuddyPhase.listening, mic: BuddyMic.live));
      final first = tester.widget<CustomPaint>(
        find
            .descendant(
              of: find.byKey(const Key('voice-buddy-dot')),
              matching: find.byType(CustomPaint),
            )
            .first,
      );
      await tester.pump(const Duration(seconds: 3));
      final second = tester.widget<CustomPaint>(
        find
            .descendant(
              of: find.byKey(const Key('voice-buddy-dot')),
              matching: find.byType(CustomPaint),
            )
            .first,
      );
      expect(identical(first.painter, second.painter), isTrue);
    });
  });
}
