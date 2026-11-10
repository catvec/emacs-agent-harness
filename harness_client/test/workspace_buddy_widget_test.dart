import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/ui/adaptive/platform_style.dart';
import 'package:harness_client/src/ui/theme/harness_theme.dart';
import 'package:harness_client/src/ui/widgets/buddy_window_host.dart';
import 'package:harness_client/src/ui/widgets/workspace_buddy.dart';
import 'package:harness_client/src/voice/voice_buddy.dart';
import 'package:harness_client/src/voice/voice_models.dart';

import 'support/buddy_fakes.dart';

const _address = 'ws://harness.test:9999/acp';

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

BuddyViewModel buddyModel({
  BuddyPhase phase = BuddyPhase.off,
  BuddyMic? mic,
  BuddyOutput output = BuddyOutput.idle,
  BuddyConnection connection = BuddyConnection.connected,
  String workspace = 'Home',
  String? thread = 'Kitchen renovation',
  String provider = 'Clip',
  bool levelReported = false,
  double level = 0.4,
  bool muted = false,
  bool paused = false,
  bool running = false,
  bool starting = false,
  bool? canStart,
  bool? canEnd,
  bool? canMute,
  bool? canPause,
  bool? canInterrupt,
  bool canRetry = false,
  VoiceProblem? problem,
  String? note,
}) {
  final finished =
      phase == BuddyPhase.off ||
      phase == BuddyPhase.ended ||
      phase == BuddyPhase.failed;
  return BuddyViewModel(
    workspaceName: workspace,
    threadTitle: thread,
    connection: connection,
    connectionDetail: _address,
    providerLabel: provider,
    status: BuddyStatus(
      phase: phase,
      mic: mic ?? _micFor(phase),
      output: output,
      levelReported: levelReported,
    ),
    muted: muted,
    paused: paused,
    starting: starting,
    running: running,
    canStart: canStart ?? finished,
    canEnd: canEnd ?? !finished,
    canMute: canMute ?? (!finished && !paused),
    canPause: canPause ?? !finished,
    canInterrupt: canInterrupt ?? (!finished && !paused),
    canRetry: canRetry,
    problem: problem,
    note: note,
    level: level,
  );
}

/// Open the card's `Details` disclosure: everything the glance no longer
/// stands there repeating.
///
/// The disclosure belongs to the card's own state, which survives a rebuild
/// of the same widget in a test, so this leaves it open only once.
Future<void> _openDetails(WidgetTester tester) async {
  if (find.text('Details').evaluate().isEmpty) return;
  await tester.tap(find.byKey(const Key('buddy-details')));
  await tester.pumpAndSettle();
}

Future<void> _pump(
  WidgetTester tester,
  BuddyViewModel model, {
  Size size = const Size(1280, 800),
  double textScale = 1,
  bool disableAnimations = false,
  VoidCallback? onStart,
  VoidCallback? onEnd,
  VoidCallback? onMute,
  VoidCallback? onPause,
  VoidCallback? onInterrupt,
  VoidCallback? onRetry,
  VoidCallback? onOff,
  VoidCallback? onOpenWorkspace,
  VoidCallback? onOpenSettings,
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
              alignment: Alignment.bottomRight,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: WorkspaceBuddyView(
                  model: model,
                  onStart: onStart ?? () {},
                  onEnd: onEnd ?? () {},
                  onMute: onMute ?? () {},
                  onPause: onPause ?? () {},
                  onInterrupt: onInterrupt ?? () {},
                  onRetry: onRetry ?? () {},
                  onOff: onOff ?? () {},
                  onOpenWorkspace: onOpenWorkspace ?? () {},
                  onOpenSettings: onOpenSettings ?? () {},
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('the compact card says its workspace, connection and off state', (
    tester,
  ) async {
    await _pump(tester, buddyModel());
    expect(find.text('Buddy'), findsOneWidget);
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Kitchen renovation'), findsOneWidget);
    expect(find.text('Connected'), findsOneWidget);
    expect(find.text('Off'), findsOneWidget);
    expect(find.text('Mic off'), findsOneWidget);
    // The glance: the circle, its two words and the two controls that
    // stop recording.
    expect(find.byKey(const Key('buddy-dot')), findsOneWidget);
    expect(find.text('End'), findsOneWidget);
    expect(find.text('Mute'), findsOneWidget);
    expect(find.text('Details'), findsOneWidget);
    expect(find.byTooltip('Call · end'), findsOneWidget);
    expect(find.byTooltip('Microphone · off'), findsOneWidget);
    expect(find.byTooltip('Buddy · off'), findsOneWidget);
    expect(find.byTooltip('Workspace · open'), findsOneWidget);
    expect(find.byTooltip('Connection · $_address'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
    expect(find.text('Workspace buddy off'), findsNothing);
    // Everything else is one step away, not on the card.
    expect(find.text('Start'), findsNothing);
    expect(find.text('Clip'), findsNothing);
    expect(find.text('Pause'), findsNothing);
    expect(find.text('Interrupt'), findsNothing);
    expect(find.text('Voice settings'), findsNothing);
    expect(find.byTooltip('Microphone · level'), findsNothing);
    await _openDetails(tester);
    expect(find.text('Start'), findsOneWidget);
    expect(find.text('Clip'), findsOneWidget);
    expect(find.text('Pause'), findsOneWidget);
    expect(find.text('Interrupt'), findsOneWidget);
    expect(find.text('Voice settings'), findsOneWidget);
    expect(find.byTooltip('Call · start'), findsOneWidget);
    expect(find.byTooltip('Conversation · live'), findsOneWidget);
    expect(find.byTooltip('Playback · interruption'), findsOneWidget);
    expect(find.byTooltip('Voice settings'), findsOneWidget);
    expect(find.byTooltip('Voice provider · Clip'), findsOneWidget);
    expect(find.text('Less'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('every documented voice state has its exact word', (
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
    final semantics = tester.ensureSemantics();
    for (final entry in labels.entries) {
      await _pump(tester, buddyModel(phase: entry.key));
      expect(
        find.text(entry.value),
        findsOneWidget,
        reason: '${entry.key.name} must read ${entry.value}',
      );
      expect(
        find.bySemanticsLabel('Status · ${entry.value}'),
        findsOneWidget,
        reason: 'the status is a live region with its exact word',
      );
      expect(tester.takeException(), isNull);
    }
    semantics.dispose();
  });

  testWidgets('the microphone line says what is actually open', (tester) async {
    await _pump(
      tester,
      buddyModel(phase: BuddyPhase.listening, levelReported: true),
    );
    expect(find.text('Mic live'), findsOneWidget);
    expect(find.byKey(const Key('buddy-level')), findsNothing);
    await _openDetails(tester);
    expect(find.byKey(const Key('buddy-level')), findsOneWidget);
    expect(find.byTooltip('Microphone · level'), findsOneWidget);
    // Without a reported level there is no meter even while listening.
    await _pump(
      tester,
      buddyModel(phase: BuddyPhase.listening, levelReported: false),
    );
    expect(find.text('Mic live'), findsOneWidget);
    expect(find.byKey(const Key('buddy-level')), findsNothing);
    expect(find.byTooltip('Microphone · level'), findsNothing);

    await _pump(
      tester,
      buddyModel(phase: BuddyPhase.muted, muted: true, levelReported: true),
    );
    expect(find.text('Muted'), findsOneWidget);
    expect(find.text('Mic muted'), findsOneWidget);
    expect(find.byKey(const Key('buddy-level')), findsNothing);
    expect(find.byTooltip('Microphone · level'), findsNothing);
    expect(find.text('Unmute'), findsOneWidget);
    expect(find.byTooltip('Microphone · muted'), findsOneWidget);

    await _pump(tester, buddyModel(phase: BuddyPhase.paused, paused: true));
    expect(find.text('Paused'), findsOneWidget);
    expect(find.text('Mic paused'), findsOneWidget);
    expect(find.byTooltip('Microphone · paused'), findsOneWidget);
    await _openDetails(tester);
    expect(find.text('Resume'), findsOneWidget);
    expect(find.byTooltip('Conversation · paused'), findsOneWidget);

    await _pump(tester, buddyModel(phase: BuddyPhase.starting, starting: true));
    expect(find.text('Starting'), findsOneWidget);
    expect(find.text('Mic starting'), findsOneWidget);
    expect(find.byTooltip('Microphone · starting'), findsOneWidget);

    await _pump(tester, buddyModel(phase: BuddyPhase.ending));
    expect(find.text('Ending'), findsOneWidget);
    expect(find.text('Mic closing'), findsOneWidget);
    expect(find.byTooltip('Microphone · closing'), findsOneWidget);

    await _pump(tester, buddyModel(phase: BuddyPhase.failed));
    expect(find.text('Failed'), findsOneWidget);
    expect(find.text('Mic off'), findsOneWidget);
    expect(find.byTooltip('Microphone · off'), findsOneWidget);
    expect(find.byKey(const Key('buddy-level')), findsNothing);
  });

  testWidgets('input and output are shown at the same time', (tester) async {
    await _pump(
      tester,
      buddyModel(
        phase: BuddyPhase.hearing,
        output: BuddyOutput.speaking,
        levelReported: true,
      ),
    );
    expect(find.text('Hearing you'), findsOneWidget);
    expect(find.text('Mic live'), findsOneWidget);
    await _openDetails(tester);
    expect(find.text('Speaking'), findsOneWidget);
    expect(find.byKey(const Key('buddy-activity')), findsOneWidget);
    await _pump(
      tester,
      buddyModel(
        phase: BuddyPhase.hearing,
        output: BuddyOutput.held,
        levelReported: true,
      ),
    );
    expect(find.text('Hearing you'), findsOneWidget);
    expect(find.text('Mic live'), findsOneWidget);
    await _openDetails(tester);
    expect(find.text('Reply held'), findsOneWidget);
    await _pump(
      tester,
      buddyModel(phase: BuddyPhase.hearing, output: BuddyOutput.working),
    );
    expect(find.text('Hearing you'), findsOneWidget);
    await _openDetails(tester);
    expect(find.text('Working'), findsOneWidget);
  });

  testWidgets('the connection is a word, not only a colour', (tester) async {
    for (final connection in BuddyConnection.values) {
      await _pump(
        tester,
        buddyModel(phase: BuddyPhase.off, connection: connection),
      );
      expect(find.text(connection.label), findsOneWidget);
    }
  });

  testWidgets('permission denial is named and Retry is offered', (
    tester,
  ) async {
    var retries = 0;
    var ends = 0;
    await _pump(
      tester,
      buddyModel(
        phase: BuddyPhase.failed,
        problem: const VoiceProblem(
          'Microphone permission denied',
          detail: 'NotAllowedError: permission denied',
        ),
        canRetry: true,
        canEnd: true,
      ),
      onRetry: () => retries++,
      onEnd: () => ends++,
    );
    expect(find.text('Failed'), findsOneWidget);
    expect(find.text('Mic off'), findsOneWidget);
    expect(find.text('Microphone permission denied'), findsOneWidget);
    expect(find.text('NotAllowedError: permission denied'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.byTooltip('Call · retry'), findsOneWidget);
    expect(find.byTooltip('Microphone · off'), findsOneWidget);
    await tester.tap(find.byKey(const Key('buddy-retry')));
    await tester.pump();
    expect(retries, 1);
    await tester.tap(find.byKey(const Key('buddy-end')));
    await tester.pump();
    expect(ends, 1, reason: 'a failed call can be dismissed with End');
  });

  testWidgets('the safe notes are exact noun phrases', (tester) async {
    for (final note in [
      'No live episode',
      'Voice setup',
      'Call lost',
      'Connection lost',
    ]) {
      await _pump(
        tester,
        buddyModel(phase: BuddyPhase.off, canStart: false, note: note),
      );
      expect(find.text(note), findsOneWidget);
    }
  });

  testWidgets('the controls act and are never only icons', (tester) async {
    var starts = 0;
    var ends = 0;
    var mutes = 0;
    var pauses = 0;
    var interrupts = 0;
    var offs = 0;
    var workspaces = 0;
    var settings = 0;
    await _pump(
      tester,
      buddyModel(
        phase: BuddyPhase.listening,
        running: true,
        levelReported: true,
      ),
      onStart: () => starts++,
      onEnd: () => ends++,
      onMute: () => mutes++,
      onPause: () => pauses++,
      onInterrupt: () => interrupts++,
      onOff: () => offs++,
      onOpenWorkspace: () => workspaces++,
      onOpenSettings: () => settings++,
    );
    // End and Mute are on the glance; the rest are one step away.
    await tester.tap(find.byKey(const Key('buddy-end')));
    await tester.tap(find.byKey(const Key('buddy-mute')));
    await _openDetails(tester);
    await tester.tap(find.byKey(const Key('buddy-start')));
    await tester.tap(find.byKey(const Key('buddy-pause')));
    await tester.tap(find.byKey(const Key('buddy-interrupt')));
    await tester.tap(find.byKey(const Key('buddy-settings')));
    await tester.tap(find.byKey(const Key('buddy-workspace')));
    await tester.tap(find.byKey(const Key('buddy-off')));
    await tester.pump();
    expect(starts, 0, reason: 'Start is disabled while a call runs');
    expect(ends, 1);
    expect(mutes, 1);
    expect(pauses, 1);
    expect(interrupts, 1);
    expect(settings, 1);
    expect(workspaces, 1);
    expect(offs, 1);
  });

  testWidgets('Start is disabled without a live episode and still named', (
    tester,
  ) async {
    await _pump(
      tester,
      buddyModel(
        phase: BuddyPhase.off,
        canStart: false,
        note: 'No live episode',
      ),
    );
    await _openDetails(tester);
    final start = tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('Start'),
        matching: find.byType(FilledButton),
      ),
    );
    expect(start.onPressed, isNull);
    expect(find.text('No live episode'), findsOneWidget);
  });

  testWidgets('the status and microphone are live regions with exact labels', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(
      tester,
      buddyModel(phase: BuddyPhase.listening, levelReported: true),
    );
    final status = tester.getSemantics(
      find.byKey(const Key('buddy-status-node')),
    );
    expect(status.label, 'Status · Listening');
    expect(status.hasFlag(SemanticsFlag.isLiveRegion), isTrue);
    final mic = tester.getSemantics(find.byKey(const Key('buddy-mic-node')));
    expect(mic.label, 'Mic live');
    expect(mic.hasFlag(SemanticsFlag.isLiveRegion), isTrue);
    await _openDetails(tester);
    final start = tester.getSemantics(find.bySemanticsLabel('Start'));
    expect(
      start,
      matchesSemantics(
        label: 'Start',
        tooltip: 'Call · start',
        isButton: true,
        hasEnabledState: true,
        isEnabled: false,
        isFocusable: false,
        hasTapAction: false,
        hasFocusAction: false,
      ),
    );
    expect(
      tester.getSemantics(find.bySemanticsLabel('End')),
      matchesSemantics(
        label: 'End',
        tooltip: 'Call · end',
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
        isFocusable: true,
        hasTapAction: true,
        hasFocusAction: true,
      ),
    );
    expect(
      tester.getSemantics(find.bySemanticsLabel('Mute')),
      matchesSemantics(
        label: 'Mute',
        tooltip: 'Microphone · live',
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
        hasToggledState: true,
        isToggled: false,
        isFocusable: true,
        hasTapAction: true,
        hasFocusAction: true,
      ),
    );
    handle.dispose();
  });

  testWidgets('keyboard focus reaches Start and Enter starts', (tester) async {
    var starts = 0;
    await _pump(
      tester,
      buddyModel(phase: BuddyPhase.off, canStart: true),
      onStart: () => starts++,
    );
    // The card takes no focus when it appears, but a keyboard alone reaches
    // `Details` and then Start: nothing on the card needs a mouse.
    for (var i = 0; i < 12 && find.text('Less').evaluate().isEmpty; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      final details = find.byKey(const Key('buddy-details'));
      if (Focus.of(tester.element(details)).hasFocus) {
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
      }
    }
    expect(find.text('Less'), findsOneWidget, reason: 'Details opened by key');
    for (var i = 0; i < 12; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      final start = find.byKey(const Key('buddy-start'));
      if (Focus.of(tester.element(start)).hasFocus) break;
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(starts, 1, reason: 'a keyboard user can start without a mouse');
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion removes the finite transitions', (tester) async {
    await _pump(tester, buddyModel(phase: BuddyPhase.listening));
    final normal = tester.widget<AnimatedSwitcher>(
      find.byType(AnimatedSwitcher),
    );
    expect(normal.duration, const Duration(milliseconds: 160));
    await _pump(
      tester,
      buddyModel(phase: BuddyPhase.listening),
      disableAnimations: true,
    );
    final reduced = tester.widget<AnimatedSwitcher>(
      find.byType(AnimatedSwitcher),
    );
    expect(reduced.duration, Duration.zero);
    await tester.pumpAndSettle();
    expect(tester.binding.transientCallbackCount, 0);
    expect(find.text('Listening'), findsOneWidget);
  });

  testWidgets('one compact card fits every desktop size and 150% text', (
    tester,
  ) async {
    for (final size in const [
      Size(920, 700),
      Size(1024, 768),
      Size(1280, 800),
      Size(1440, 900),
    ]) {
      for (final scale in const [1.0, 1.5, 2.0]) {
        await _pump(
          tester,
          buddyModel(
            phase: BuddyPhase.listening,
            levelReported: true,
            problem: const VoiceProblem(
              'Live connection failed',
              detail: 'The provider closed the stream.',
            ),
            canRetry: true,
          ),
          size: size,
          textScale: scale,
        );
        final card = tester.getSize(find.byKey(const Key('workspace-buddy')));
        expect(
          card.width,
          lessThanOrEqualTo(size.width - 32),
          reason: '${size.width} at $scale',
        );
        expect(
          card.width,
          lessThanOrEqualTo(376),
          reason: 'the card stays compact at $scale',
        );
        expect(tester.takeException(), isNull);
      }
    }
  });

  testWidgets('the card authors no sentences and no invented stages', (
    tester,
  ) async {
    final states = <BuddyViewModel>[
      buddyModel(),
      buddyModel(phase: BuddyPhase.listening, levelReported: true),
      buddyModel(phase: BuddyPhase.hearing, output: BuddyOutput.speaking),
      buddyModel(phase: BuddyPhase.transcribing),
      buddyModel(phase: BuddyPhase.working),
      buddyModel(phase: BuddyPhase.holdingReply),
      buddyModel(phase: BuddyPhase.speaking),
      buddyModel(phase: BuddyPhase.interrupted),
      buddyModel(phase: BuddyPhase.muted, muted: true),
      buddyModel(phase: BuddyPhase.paused, paused: true),
      buddyModel(phase: BuddyPhase.approval),
      buddyModel(phase: BuddyPhase.ending),
      buddyModel(phase: BuddyPhase.ended),
      buddyModel(phase: BuddyPhase.failed),
      buddyModel(phase: BuddyPhase.unknown),
      buddyModel(
        phase: BuddyPhase.off,
        note: 'No live episode',
        canStart: false,
      ),
    ];
    for (final model in states) {
      await _pump(tester, model);
      final texts = tester
          .widgetList<Text>(find.byType(Text))
          .map((text) => text.data ?? '')
          .where((text) => text.isNotEmpty)
          .toList();
      for (final text in texts) {
        expect(
          text.endsWith('.'),
          isFalse,
          reason: 'authored copy "$text" must not be a sentence',
        );
        final lower = text.toLowerCase();
        expect(lower, isNot(contains('upload')));
        expect(lower, isNot(contains('transfer')));
        expect(lower, isNot(contains('transcod')));
      }
    }
  });

  testWidgets('the layer floats, drags and is clamped at a desktop size', (
    tester,
  ) async {
    final rig = BuddyRig();
    // A widget test runs in fake time, so the rig's timer-based settle is
    // replaced by the pump below; the start itself is all microtasks.
    await rig.controller.enable();
    await rig.controller.start();
    tester.view.physicalSize = const Size(1024, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: HarnessTheme.material(Brightness.light),
        home: Scaffold(
          body: Stack(
            children: [
              const Positioned.fill(
                child: ColoredBox(color: Color(0xFF10123A)),
              ),
              Positioned.fill(
                child: WorkspaceBuddyLayer(
                  controller: rig.controller,
                  onOpenWorkspace: () {},
                  onOpenSettings: () {},
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const Key('workspace-buddy')), findsOneWidget);
    expect(find.text('Listening'), findsOneWidget);
    final card = tester.getRect(find.byKey(const Key('workspace-buddy')));
    expect(card.right, lessThanOrEqualTo(1024 - 16));
    expect(card.bottom, lessThanOrEqualTo(700 - 16));

    // The header drags the whole card, and the card stays inside the window.
    await tester.drag(
      find.byKey(const Key('buddy-drag-handle')),
      const Offset(-160, -120),
    );
    await tester.pump();
    final moved = tester.getRect(find.byKey(const Key('workspace-buddy')));
    expect(moved.left, lessThan(card.left));
    expect(moved.top, lessThan(card.top));
    await tester.drag(
      find.byKey(const Key('buddy-drag-handle')),
      const Offset(5000, 5000),
    );
    await tester.pump();
    final clamped = tester.getRect(find.byKey(const Key('workspace-buddy')));
    expect(clamped.right, lessThanOrEqualTo(1024 - 8));
    expect(clamped.bottom, lessThanOrEqualTo(700 - 8));

    // The off control is not End: the call stays, in the in-call bar.
    await tester.runAsync(() => rig.controller.disable());
    await tester.pump();
    expect(find.byKey(const Key('workspace-buddy')), findsNothing);
    expect(rig.controller.running, isTrue);
    expect(rig.backends.single.stopped, isFalse);
    // The stop awaits real stream cancellation; run it outside fake time.
    await tester.runAsync(() => rig.controller.end());
    await tester.pump();
    expect(rig.backends.single.stopped, isTrue);
    rig.controller.dispose();
    await tester.pump();
  });

  testWidgets('the away card hides, but never ends the call, when narrow', (
    tester,
  ) async {
    final rig = BuddyRig();
    // The rig's settle uses real time, which a widget test's fake time does
    // not advance; the start itself is microtasks.
    await rig.controller.enable();
    await rig.controller.start();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    Widget app() => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: HarnessTheme.material(Brightness.light),
      home: Scaffold(
        body: Stack(
          children: [
            const Positioned.fill(child: ColoredBox(color: Color(0xFF10123A))),
            Positioned.fill(
              child: WorkspaceBuddyLayer(
                controller: rig.controller,
                onOpenWorkspace: () {},
                onOpenSettings: () {},
              ),
            ),
          ],
        ),
      ),
    );
    await tester.pumpWidget(app());
    await tester.pump();
    expect(find.byKey(const Key('workspace-buddy')), findsOneWidget);
    expect(rig.backends.single.started, isTrue);
    expect(rig.controller.running, isTrue);

    // The card is a desktop away surface.  Below the breakpoint it is not
    // built; the in-call bar is, and the call keeps running in it.
    tester.view.physicalSize = const Size(390, 844);
    await tester.pumpWidget(app());
    await tester.pump();
    expect(find.byKey(const Key('workspace-buddy')), findsNothing);
    await tester.runAsync(() async {
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    });
    await tester.pump();
    expect(rig.controller.running, isTrue);
    expect(rig.controller.inCall, isTrue);
    expect(rig.backends.single.stopped, isFalse);

    rig.controller.dispose();
    await tester.pump();
  });

  testWidgets('the card is the away surface, not the focused one', (
    tester,
  ) async {
    final rig = BuddyRig();
    await rig.controller.enable();
    await rig.controller.start();
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    Widget app({required bool away}) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: HarnessTheme.material(Brightness.light),
      home: Scaffold(
        body: Stack(
          children: [
            const Positioned.fill(child: ColoredBox(color: Color(0xFF10123A))),
            Positioned.fill(
              child: WorkspaceBuddyLayer(
                away: away,
                controller: rig.controller,
                onOpenWorkspace: () {},
                onOpenSettings: () {},
              ),
            ),
          ],
        ),
      ),
    );
    await tester.pumpWidget(app(away: false));
    await tester.pump();
    expect(find.byKey(const Key('workspace-buddy')), findsNothing);
    await tester.pumpWidget(app(away: true));
    await tester.pump();
    expect(find.byKey(const Key('workspace-buddy')), findsOneWidget);
    await tester.runAsync(() => rig.controller.disable());
    await tester.pump();
    expect(find.byKey(const Key('workspace-buddy')), findsNothing);
    expect(rig.controller.running, isTrue, reason: 'off is not End');
    await tester.runAsync(() => rig.controller.end());
    rig.controller.dispose();
    await tester.pump();
  });

  testWidgets('opting in draws no card until a call starts', (tester) async {
    final rig = BuddyRig();
    await rig.controller.enable();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: HarnessTheme.material(Brightness.light),
        home: Scaffold(
          body: Stack(
            children: [
              const Positioned.fill(
                child: ColoredBox(color: Color(0xFF10123A)),
              ),
              Positioned.fill(
                child: WorkspaceBuddyLayer(
                  away: true,
                  controller: rig.controller,
                  onOpenWorkspace: () {},
                  onOpenSettings: () {},
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    expect(rig.controller.enabled, isTrue);
    expect(rig.controller.running, isFalse);
    expect(find.byKey(const Key('workspace-buddy')), findsNothing);

    await rig.controller.start();
    await tester.pump();
    expect(rig.controller.running, isTrue);
    expect(find.byKey(const Key('workspace-buddy')), findsOneWidget);

    await tester.runAsync(() => rig.controller.end());
    await tester.pump();
    expect(find.byKey(const Key('workspace-buddy')), findsNothing);
    rig.controller.dispose();
    await tester.pump();
  });

  testWidgets('a taller card is reported to the window, and scrolls', (
    tester,
  ) async {
    final rig = BuddyRig();
    await rig.controller.enable();
    await rig.controller.start();
    // A native window starts at the height it was opened with; the card here
    // is taller than that viewport, as a running or failed card may be.
    tester.view.physicalSize = const Size(320, 140);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final sizes = <Size>[];
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: HarnessTheme.material(Brightness.light),
        home: BuddyWindowContent(
          buddy: rig.controller,
          width: 320,
          theme: HarnessTheme.material(Brightness.light),
          textScaler: TextScaler.noScaling,
          disableAnimations: true,
          startDrag: () {},
          onActivated: (_) {},
          onContentSize: sizes.add,
          onOpenWorkspace: () {},
          onOpenSettings: () async {},
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    final card = tester.getSize(find.byKey(const Key('workspace-buddy')));
    expect(card.height, greaterThan(140));
    expect(sizes, isNotEmpty);
    expect(sizes.last, card);
    expect(
      tester.takeException(),
      isNull,
      reason: 'the window scrolls the card; it does not overflow it',
    );

    // The viewport stays the window's size, and the whole card is reachable.
    final viewport = tester.getSize(
      find.byKey(const Key('buddy-window-scroll')),
    );
    expect(viewport.height, 140);
    final before = tester.getTopLeft(find.byKey(const Key('workspace-buddy')));
    await tester.drag(
      find.byKey(const Key('buddy-window-scroll')),
      const Offset(0, -60),
    );
    await tester.pump();
    final after = tester.getTopLeft(find.byKey(const Key('workspace-buddy')));
    expect(after.dy, lessThan(before.dy));

    await tester.runAsync(() => rig.controller.end());
    rig.controller.dispose();
    await tester.pump();
  });
}
