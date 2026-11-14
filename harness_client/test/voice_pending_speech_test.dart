import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/ui/adaptive/platform_style.dart';
import 'package:harness_client/src/ui/screens/voice_screen.dart';
import 'package:harness_client/src/ui/theme/harness_theme.dart';
import 'package:harness_client/src/ui/widgets/voice_pending_speech.dart';
import 'package:harness_client/src/ui/widgets/workspace_buddy.dart';
import 'package:harness_client/src/ui/widgets/workspace_call_bar.dart';
import 'package:harness_client/src/voice/voice_backend.dart';
import 'package:harness_client/src/voice/voice_models.dart';
import 'package:harness_client/src/voice/voice_settings.dart';

import 'support/buddy_fakes.dart';
import 'support/voice_fakes.dart';

const _pending = Key('voice-pending-speech');
const _send = Key('voice-pending-send');
const _tooltip = Key('voice-pending-tooltip');
const _submission = 'Pending speech submission';

Widget _app(
  Widget home, {
  double textScale = 1,
  TransitionBuilder? builder,
}) => HarnessStyle(
  style: HarnessPlatformStyle.material,
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: HarnessTheme.material(Brightness.dark),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(textScale),
        disableAnimations: true,
      ),
      child: builder == null ? child! : builder(context, child),
    ),
    home: home,
  ),
);

void _size(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<Rig> _start(WidgetTester tester) async {
  final rig = Rig(settings: const VoiceSettings());
  // Keep the backend subscription in the test clock's zone: its event
  // callbacks create the grace timer that tester.pump advances.
  await rig.controller.start();
  await tester.pump();
  addTearDown(rig.controller.dispose);
  return rig;
}

void _prompt(FakeBackend backend, String text, {String id = 'u-1'}) {
  backend.emit(
    VoicePromptEvent(VoicePrompt(id: id, segmentId: id, text: text)),
  );
}

void _expectCopy(
  WidgetTester tester,
  String status,
  String draft, {
  bool enabled = true,
}) {
  expect(find.byKey(_pending), findsOneWidget);
  final words = tester
      .widgetList<Text>(
        find.descendant(of: find.byKey(_pending), matching: find.byType(Text)),
      )
      .map((text) => text.data)
      .toList();
  expect(words, ['Unsent speech', 'Submission', status, draft]);
  expect(
    tester.widget<TextButton>(find.byKey(_send)).onPressed,
    enabled ? isNotNull : isNull,
  );
  expect(tester.getSize(find.byKey(_send)).height, greaterThanOrEqualTo(48));
  final labelStyle = tester.widget<TextButton>(find.byKey(_send))
      .style!.textStyle!.resolve({})!;
  final themeLabel = Theme.of(tester.element(find.byKey(_send)))
      .textTheme.labelSmall!;
  expect(labelStyle.fontFamily, themeLabel.fontFamily);
  expect(labelStyle.fontFamilyFallback, themeLabel.fontFamilyFallback);
  expect(tester.takeException(), isNull);
}

void main() {
  for (final compact in [false, true]) {
    for (final sample in const [
      ('Check the build.', 'Finishing thought'),
      ('Check the build, hold on', 'Waiting for continuation'),
      ('Check the build and', 'Possible cut-off'),
    ]) {
      testWidgets(
        '${compact ? 'compact' : 'full'} pending speech renders ${sample.$2} exactly',
        (tester) async {
          _size(tester, const Size(390, 844));
          final rig = await _start(tester);
          await tester.pumpWidget(
            _app(
              compact
                  ? Scaffold(
                      body: Padding(
                        padding: const EdgeInsets.all(12),
                        child: VoicePendingSpeech(
                          controller: rig.controller,
                          compact: true,
                        ),
                      ),
                    )
                  : VoiceScreen(controller: rig.controller, attached: true),
            ),
          );
          expect(find.byKey(_pending), findsNothing);
          expect(find.text('Unsent speech'), findsNothing);
          expect(find.text('Submission'), findsNothing);
          _prompt(rig.backend, sample.$1);
          await tester.pump();
          _expectCopy(tester, sample.$2, sample.$1);
          expect(rig.session.sent, isEmpty);
          expect(find.byTooltip(_submission), findsOneWidget);
          expect(tester.widget<Tooltip>(find.byKey(_tooltip)).message, _submission);

          // Inspect the actual overlay text as well as the tooltip property.
          tester.state<TooltipState>(find.byKey(_tooltip)).ensureTooltipVisible();
          await tester.pump(const Duration(milliseconds: 200));
          expect(find.text(_submission), findsOneWidget);
          Tooltip.dismissAllToolTips();
          await tester.pump(const Duration(milliseconds: 200));

          await tester.tap(find.byKey(_send));
          await tester.pump();
          expect(rig.session.sent.map((prompt) => prompt.text), [sample.$1]);
          expect(find.byKey(_pending), findsNothing);
          expect(find.text('Submission'), findsNothing);
          expect(find.byTooltip(_submission), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('speech and outstanding transcription disable the visible action', (
    tester,
  ) async {
    _size(tester, const Size(390, 844));
    final rig = await _start(tester);
    await tester.pumpWidget(
      _app(VoiceScreen(controller: rig.controller, attached: true)),
    );
    _prompt(rig.backend, 'Check the build, hold on');
    await tester.pump();
    expect(tester.widget<TextButton>(find.byKey(_send)).onPressed, isNotNull);

    rig.backend.emit(const VoiceSpeechEvent(true));
    await tester.pump();
    expect(find.text('Waiting for continuation'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(_pending),
        matching: find.text('Check the build, hold on'),
      ),
      findsOneWidget,
    );
    expect(find.text('Submission'), findsOneWidget);
    expect(find.byTooltip(_submission), findsOneWidget);
    expect(tester.widget<TextButton>(find.byKey(_send)).onPressed, isNull);
    await tester.tap(find.byKey(_send));
    await tester.pump();
    expect(rig.session.sent, isEmpty);

    rig.backend.emit(const VoiceSpeechEvent(false));
    await tester.pump();
    expect(tester.widget<TextButton>(find.byKey(_send)).onPressed, isNotNull);
    rig.backend.emit(
      const VoiceSegmentEvent(id: 'u-2', stage: VoiceSegmentStage.accepted),
    );
    rig.backend.emit(
      const VoiceSegmentEvent(id: 'u-2', stage: VoiceSegmentStage.transcribing),
    );
    await tester.pump();
    expect(find.text('Unsent speech'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(_pending),
        matching: find.text('Check the build, hold on'),
      ),
      findsOneWidget,
    );
    expect(tester.widget<TextButton>(find.byKey(_send)).onPressed, isNull);
    await tester.tap(find.byKey(_send));
    await tester.pump();
    expect(rig.session.sent, isEmpty);

    rig.backend.emit(
      const VoiceSegmentEvent(
        id: 'u-2',
        stage: VoiceSegmentStage.dropped,
        drop: VoiceSegmentDrop.noWords,
      ),
    );
    await tester.pump();
    expect(tester.widget<TextButton>(find.byKey(_send)).onPressed, isNotNull);
    await tester.tap(find.byKey(_send));
    await tester.pump();
    expect(rig.session.sent.map((prompt) => prompt.text), ['Check the build, hold on']);
    expect(find.byKey(_pending), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('continuation updates the visible draft before grace removes it', (
    tester,
  ) async {
    _size(tester, const Size(390, 844));
    final rig = await _start(tester);
    await tester.pumpWidget(
      _app(VoiceScreen(controller: rig.controller, attached: true)),
    );
    _prompt(rig.backend, 'Check the build, hold on');
    await tester.pump();
    _expectCopy(tester, 'Waiting for continuation', 'Check the build, hold on');
    _prompt(rig.backend, 'Use the release branch.', id: 'u-2');
    await tester.pump();
    _expectCopy(
      tester,
      'Finishing thought',
      'Check the build, hold on Use the release branch.',
    );
    expect(rig.session.sent, isEmpty);
    await tester.pump(const Duration(milliseconds: 1300));
    await tester.pump();
    expect(find.byKey(_pending), findsNothing);
    expect(find.text('Unsent speech'), findsNothing);
    expect(find.text('Submission'), findsNothing);
    expect(find.byTooltip(_submission), findsNothing);
    expect(
      rig.session.sent.map((prompt) => prompt.text),
      ['Check the build, hold on Use the release branch.'],
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('pending limit renders its exact failure without clipping the draft', (tester) async {
    _size(tester, const Size(390, 844));
    final rig = Rig(settings: const VoiceSettings(), pendingTextLimit: 20);
    await rig.controller.start();
    await tester.pump();
    addTearDown(rig.controller.dispose);
    await tester.pumpWidget(_app(VoiceScreen(controller: rig.controller, attached: true)));
    const draft = 'The original words beyond the limit, hold on';
    _prompt(rig.backend, draft);
    await tester.pump();
    _expectCopy(tester, 'Waiting for continuation', draft, enabled: false);
    expect(tester.widget<Text>(find.byKey(const Key('voice-problem'))).data,
        'Unsent speech limit');
    expect(find.byTooltip(_submission), findsOneWidget);
    expect(rig.session.sent, isEmpty);
  });

  testWidgets('a pending draft remains independent of the agent status', (
    tester,
  ) async {
    _size(tester, const Size(390, 844));
    final rig = await _start(tester);
    await tester.pumpWidget(
      _app(VoiceScreen(controller: rig.controller, attached: true)),
    );
    _prompt(rig.backend, 'Check the build, hold on');
    await tester.pump();
    rig.session.working = true;
    rig.session.changed();
    await tester.pump();
    expect(find.text('Thinking'), findsOneWidget);
    _expectCopy(tester, 'Waiting for continuation', 'Check the build, hold on');
  });

  testWidgets('a short full call keeps large pending text and call controls accessible', (
    tester,
  ) async {
    _size(tester, const Size(320, 640));
    final rig = await _start(tester);
    final draft = '${List.filled(8, 'The original words,').join(' ')} hold on';
    _prompt(rig.backend, draft);
    await tester.pump();
    await tester.pumpWidget(
      _app(
        VoiceScreen(controller: rig.controller, attached: true),
        textScale: 2,
      ),
    );
    _expectCopy(tester, 'Waiting for continuation', draft);
    expect(find.byKey(const Key('voice-pending-call-scroll')), findsOneWidget);
    expect(tester.getTopLeft(find.byKey(_send)).dy, greaterThanOrEqualTo(0));
    expect(tester.getBottomRight(find.byKey(_send)).dy, lessThan(640));
    expect(
      tester.getBottomRight(find.byKey(const Key('voice-end'))).dy,
      lessThan(640),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a narrow compact draft scrolls without hiding its action or status', (
    tester,
  ) async {
    _size(tester, const Size(280, 520));
    final rig = await _start(tester);
    await tester.pumpWidget(
      _app(
        Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(12),
            child: VoicePendingSpeech(controller: rig.controller, compact: true),
          ),
        ),
        textScale: 2,
      ),
    );
    final draft = '${List.filled(20, 'The original words,').join(' ')} hold on';
    _prompt(rig.backend, draft);
    await tester.pump();
    _expectCopy(tester, 'Waiting for continuation', draft);
    final button = tester.getRect(find.byKey(_send));
    final scroll = tester.state<ScrollableState>(
      find.descendant(
        of: find.byKey(const Key('voice-pending-scroll')),
        matching: find.byType(Scrollable),
      ),
    );
    expect(scroll.position.maxScrollExtent, greaterThan(0));
    await tester.drag(find.byKey(const Key('voice-pending-scroll')), const Offset(0, -160));
    await tester.pump();
    expect(scroll.position.pixels, greaterThan(0));
    expect(tester.getRect(find.byKey(_send)), button);
    expect(find.text('Waiting for continuation'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final buddy in [false, true]) {
    testWidgets('${buddy ? 'buddy glance' : 'workspace bar'} exposes its unsent turn', (
      tester,
    ) async {
      _size(tester, buddy ? const Size(920, 700) : const Size(320, 640));
      final rig = BuddyRig();
      rig.host.voiceSettings = const VoiceSettings();
      await tester.runAsync(rig.start);
      addTearDown(rig.controller.dispose);
      final surface = buddy
          ? Align(
              alignment: Alignment.topRight,
              child: WorkspaceBuddy(
                controller: rig.controller,
                onOpenWorkspace: () {},
                onOpenSettings: () {},
              ),
            )
          : WorkspaceCallBar(
              controller: rig.controller,
              visible: true,
              onOpenCallView: () {},
            );
      await tester.pumpWidget(
        buddy
            ? _app(Scaffold(body: surface))
            : _app(
                const Scaffold(),
                builder: (context, child) => Column(
                  children: [
                    surface,
                    Expanded(child: Semantics(container: true, child: child!)),
                  ],
                ),
              ),
      );
      _prompt(rig.backends.single, 'Check the build, hold on');
      await tester.pump();
      _expectCopy(tester, 'Waiting for continuation', 'Check the build, hold on');
      if (buddy) {
        expect(tester.widget<Tooltip>(find.byKey(_tooltip)).message, _submission);
        tester.state<TooltipState>(find.byKey(_tooltip)).ensureTooltipVisible();
        await tester.pump(const Duration(milliseconds: 200));
        expect(find.text(_submission), findsOneWidget);
        Tooltip.dismissAllToolTips();
        await tester.pump(const Duration(milliseconds: 200));
      } else {
        expect(
          tester.getSemantics(find.byKey(_tooltip)).tooltip,
          _submission,
          reason: 'the call bar has no navigator overlay above it',
        );
      }
      if (buddy) expect(find.text('Details'), findsOneWidget);
      await tester.tap(find.byKey(_send));
      await tester.pump();
      expect(rig.host.session.sent.map((prompt) => prompt.text), ['Check the build, hold on']);
      expect(find.byKey(_pending), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('live final captions also expose the pending thought', (tester) async {
    _size(tester, const Size(390, 844));
    final rig = Rig(
      settings: const VoiceSettings(
        provider: VoiceProvider.live,
        realtimeEndpoint: 'https://voice.test/v1',
        realtimeModel: 'test-live',
      ),
    );
    await rig.controller.start();
    await tester.pump();
    addTearDown(rig.controller.dispose);
    await tester.pumpWidget(
      _app(VoiceScreen(controller: rig.controller, attached: true)),
    );
    rig.backend.emit(
      const VoiceCaptionEvent(
        VoiceSpeaker.you,
        'Check the build, hold on',
        finalized: true,
        segmentId: 'live-1',
      ),
    );
    await tester.pump();
    _expectCopy(
      tester,
      'Waiting for continuation',
      'Check the build, hold on',
      enabled: false,
    );
    expect(rig.session.sent, isEmpty);
    expect(find.byTooltip(_submission), findsOneWidget);
    await tester.tap(find.byKey(_send));
    await tester.pump();
    expect(rig.session.sent, isEmpty);
  });
}
