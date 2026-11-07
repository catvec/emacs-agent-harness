import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/ui/adaptive/platform_style.dart';
import 'package:harness_client/src/ui/theme/harness_theme.dart';
import 'package:harness_client/src/ui/widgets/workspace_call_bar.dart';
import 'package:harness_client/src/voice/voice_buddy.dart';
import 'package:harness_client/src/voice/voice_models.dart';

import 'support/buddy_fakes.dart';

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

BuddyViewModel _model({
  BuddyPhase phase = BuddyPhase.listening,
  BuddyMic? mic,
  BuddyOutput output = BuddyOutput.idle,
  BuddyConnection connection = BuddyConnection.connected,
  String workspace = 'Home',
  String? thread = 'Kitchen renovation',
  String provider = 'Clip',
  bool levelReported = false,
  bool muted = false,
  bool paused = false,
  bool running = true,
  bool? canMute,
  bool? canEnd,
  bool canRetry = false,
  VoiceProblem? problem,
}) {
  final finished =
      phase == BuddyPhase.off ||
      phase == BuddyPhase.ended ||
      phase == BuddyPhase.failed;
  return BuddyViewModel(
    workspaceName: workspace,
    threadTitle: thread,
    connection: connection,
    connectionDetail: 'ws://harness.test:9999/acp',
    providerLabel: provider,
    status: BuddyStatus(
      phase: phase,
      mic: mic ?? _micFor(phase),
      output: output,
      levelReported: levelReported,
    ),
    muted: muted,
    paused: paused,
    starting: phase == BuddyPhase.starting,
    running: running,
    canStart: finished,
    canEnd: canEnd ?? !finished,
    canMute: canMute ?? (!finished && !paused),
    canPause: !finished,
    canInterrupt: !finished && !paused,
    canRetry: canRetry,
    problem: problem,
    note: null,
    level: 0.4,
  );
}

Future<void> _pump(
  WidgetTester tester,
  BuddyViewModel model, {
  Size size = const Size(1280, 800),
  double textScale = 1,
  bool disableAnimations = false,
  VoidCallback? onMute,
  VoidCallback? onEnd,
  VoidCallback? onRetry,
  VoidCallback? onOpenCallView,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    HarnessStyle(
      style: HarnessPlatformStyle.material,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: HarnessTheme.material(Brightness.light),
        home: MediaQuery(
          data: MediaQueryData(
            size: size,
            textScaler: TextScaler.linear(textScale),
            disableAnimations: disableAnimations,
          ),
          child: Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: WorkspaceCallBarView(
                model: model,
                onMute: onMute ?? () {},
                onEnd: onEnd ?? () {},
                onRetry: onRetry ?? () {},
                onOpenCallView: onOpenCallView,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('the bar says the call, the status and the microphone', (
    tester,
  ) async {
    var muted = 0;
    var ended = 0;
    var opened = 0;
    await _pump(
      tester,
      _model(),
      size: const Size(1280, 800),
      onMute: () => muted++,
      onEnd: () => ended++,
      onOpenCallView: () => opened++,
    );
    expect(find.byKey(const Key('workspace-call-bar')), findsOneWidget);
    expect(find.text('In a call'), findsOneWidget);
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Kitchen renovation'), findsOneWidget);
    expect(find.text('Listening'), findsOneWidget);
    expect(find.text('Mic live'), findsOneWidget);
    expect(find.bySemanticsLabel('Status · Listening'), findsOneWidget);
    expect(find.bySemanticsLabel('Mic live'), findsOneWidget);
    expect(find.bySemanticsLabel('End'), findsOneWidget);
    expect(find.bySemanticsLabel('Mute'), findsOneWidget);
    expect(find.bySemanticsLabel('Call view'), findsOneWidget);
    expect(
      tester.getSemantics(find.byKey(const Key('call-bar-end'))).tooltip,
      'Call · end',
    );
    expect(
      tester.getSemantics(find.byKey(const Key('call-bar-mute'))).tooltip,
      'Microphone · live',
    );
    expect(
      tester.getSemantics(find.byKey(const Key('call-bar-view'))).tooltip,
      'Call · view',
    );

    await tester.tap(find.byKey(const Key('call-bar-mute')));
    await tester.tap(find.byKey(const Key('call-bar-end')));
    await tester.tap(find.byKey(const Key('call-bar-view')));
    expect(muted, 1);
    expect(ended, 1);
    expect(opened, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the bar keeps the words at a phone width', (tester) async {
    await _pump(
      tester,
      _model(),
      size: const Size(390, 844),
      onOpenCallView: () {},
    );
    expect(find.text('In a call'), findsOneWidget);
    expect(find.text('Listening'), findsOneWidget);
    expect(find.text('Mic live'), findsOneWidget);
    expect(find.bySemanticsLabel('End'), findsOneWidget);
    expect(find.bySemanticsLabel('Call view'), findsOneWidget);
    expect(find.byKey(const Key('call-bar-end')), findsOneWidget);
    expect(find.byKey(const Key('call-bar-view')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the bar reports mute, pause, ending and a failure as they are', (
    tester,
  ) async {
    await _pump(
      tester,
      _model(phase: BuddyPhase.muted, muted: true),
      size: const Size(390, 844),
      onOpenCallView: () {},
    );
    expect(find.text('Muted'), findsOneWidget);
    expect(find.text('Mic muted'), findsOneWidget);
    expect(find.bySemanticsLabel('Unmute'), findsOneWidget);
    expect(
      tester.getSemantics(find.byKey(const Key('call-bar-mute'))).tooltip,
      'Microphone · muted',
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('call-bar-mute')),
        matching: find.byIcon(Icons.mic_off_rounded),
      ),
      findsOneWidget,
    );

    await _pump(
      tester,
      _model(phase: BuddyPhase.paused, paused: true),
      size: const Size(390, 844),
      onOpenCallView: () {},
    );
    expect(find.text('Paused'), findsOneWidget);
    expect(find.text('Mic paused'), findsOneWidget);
    expect(
      tester.getSemantics(find.byKey(const Key('call-bar-mute'))).tooltip,
      'Microphone · paused',
    );

    await _pump(
      tester,
      _model(phase: BuddyPhase.ending, canEnd: false),
      size: const Size(390, 844),
      onOpenCallView: () {},
    );
    expect(find.text('Ending'), findsOneWidget);
    expect(find.text('Mic closing'), findsOneWidget);
    expect(
      tester.getSemantics(find.byKey(const Key('call-bar-mute'))).tooltip,
      'Microphone · closing',
    );
    expect(
      tester
          .widget<InkWell>(
            find.descendant(
              of: find.byKey(const Key('call-bar-end')),
              matching: find.byType(InkWell),
            ),
          )
          .onTap,
      isNull,
      reason: 'End is not offered twice while the call is ending',
    );

    await _pump(
      tester,
      _model(
        phase: BuddyPhase.failed,
        canEnd: true,
        canRetry: true,
        problem: const VoiceProblem(
          'Microphone permission denied',
          detail: 'NotAllowedError: permission denied',
        ),
      ),
      size: const Size(390, 844),
      onOpenCallView: () {},
    );
    expect(find.text('Failed'), findsOneWidget);
    expect(find.text('Mic off'), findsOneWidget);
    expect(
      tester.getSemantics(find.byKey(const Key('call-bar-mute'))).tooltip,
      'Microphone · off',
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('call-bar-mute')),
        matching: find.byIcon(Icons.mic_off_rounded),
      ),
      findsOneWidget,
    );
    expect(
      tester
          .widget<InkWell>(
            find.descendant(
              of: find.byKey(const Key('call-bar-end')),
              matching: find.byType(InkWell),
            ),
          )
          .onTap,
      isNotNull,
      reason: 'a failed call can be dismissed with End',
    );
    expect(find.byKey(const Key('call-bar-retry')), findsOneWidget);
    expect(find.bySemanticsLabel('Retry'), findsOneWidget);
    expect(
      tester.getSemantics(find.byKey(const Key('call-bar-retry'))).tooltip,
      'Call · retry',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a start with no controller yet offers no call view', (
    tester,
  ) async {
    await _pump(
      tester,
      _model(phase: BuddyPhase.starting),
      size: const Size(390, 844),
      onOpenCallView: null,
    );
    expect(find.text('Starting'), findsOneWidget);
    expect(find.text('Mic starting'), findsOneWidget);
    expect(find.byKey(const Key('call-bar-view')), findsNothing);
    expect(find.bySemanticsLabel('Call view'), findsNothing);
    expect(find.byKey(const Key('call-bar-identity')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('every phase has one exact word and no invented stage', (
    tester,
  ) async {
    final labels = <BuddyPhase, String>{
      BuddyPhase.off: 'Off',
      BuddyPhase.starting: 'Starting',
      BuddyPhase.listening: 'Listening',
      BuddyPhase.hearing: 'Hearing you',
      BuddyPhase.transcribing: 'Transcribing',
      BuddyPhase.working: 'Working',
      BuddyPhase.holdingReply: 'Holding reply',
      BuddyPhase.speaking: 'Speaking',
      BuddyPhase.interrupted: 'Interrupted',
      BuddyPhase.muted: 'Muted',
      BuddyPhase.paused: 'Paused',
      BuddyPhase.approval: 'Approval needed',
      BuddyPhase.ending: 'Ending',
      BuddyPhase.ended: 'Ended',
      BuddyPhase.failed: 'Failed',
      BuddyPhase.unknown: 'Status unknown',
    };
    for (final entry in labels.entries) {
      await _pump(
        tester,
        _model(
          phase: entry.key,
          muted: entry.key == BuddyPhase.muted,
          paused: entry.key == BuddyPhase.paused,
          canRetry: entry.key == BuddyPhase.failed,
        ),
        size: const Size(1280, 800),
        onOpenCallView: () {},
      );
      expect(
        find.text(entry.value),
        findsOneWidget,
        reason: '${entry.key} says ${entry.value}',
      );
      final texts = tester
          .widgetList<Text>(find.byType(Text))
          .map((text) => text.data ?? '')
          .where((text) => text.isNotEmpty);
      for (final text in texts) {
        expect(text.endsWith('.'), isFalse, reason: '"$text" is a sentence');
        final lower = text.toLowerCase();
        expect(lower, isNot(contains('upload')));
        expect(lower, isNot(contains('transfer')));
        expect(lower, isNot(contains('transcod')));
      }
    }
  });

  testWidgets('the bar fits a phone and every desktop size at 150% text', (
    tester,
  ) async {
    for (final size in const [
      Size(320, 640),
      Size(390, 844),
      Size(600, 800),
      Size(920, 700),
      Size(1280, 800),
      Size(1440, 900),
    ]) {
      for (final scale in const [1.0, 1.5, 2.0]) {
        await _pump(
          tester,
          _model(canRetry: true, problem: const VoiceProblem('Failed')),
          size: size,
          textScale: scale,
          onOpenCallView: () {},
        );
        expect(
          tester.takeException(),
          isNull,
          reason: '${size.width} at $scale',
        );
        final bar = tester.getSize(find.byKey(const Key('workspace-call-bar')));
        expect(bar.width, size.width, reason: '${size.width} at $scale');
        expect(bar.height, lessThanOrEqualTo(80), reason: 'a bar, not a page');
        expect(
          tester.getRect(find.byKey(const Key('call-bar-end'))).right,
          lessThanOrEqualTo(size.width),
        );
      }
    }
  });

  testWidgets('reduced motion makes the status change immediate', (
    tester,
  ) async {
    await _pump(
      tester,
      _model(),
      size: const Size(1280, 800),
      disableAnimations: true,
      onOpenCallView: () {},
    );
    final switcher = tester.widget<AnimatedSwitcher>(
      find.byType(AnimatedSwitcher),
    );
    expect(switcher.duration, Duration.zero);
  });

  test('the bar and the away card never both take the call', () async {
    final rig = BuddyRig();
    bool visible() =>
        workspaceCallBarVisible(controller: rig.controller, hasSession: true);
    expect(
      workspaceCallBarVisible(controller: null, hasSession: true),
      isFalse,
    );
    expect(
      workspaceCallBarVisible(controller: rig.controller, hasSession: false),
      isFalse,
      reason: 'no session, no call',
    );
    await rig.controller.enable();
    await rig.controller.start();
    expect(visible(), isTrue);
    rig.controller.callViewOpen = true;
    expect(visible(), isFalse);
    rig.controller.callViewOpen = false;
    await rig.controller.disable();
    expect(visible(), isTrue);
    expect(rig.controller.running, isTrue, reason: 'off is not End');
    await rig.controller.end();
    await settle();
    expect(visible(), isFalse);
    rig.controller.dispose();
  });
}
