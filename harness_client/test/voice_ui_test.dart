import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/ui/adaptive/platform_style.dart';
import 'package:harness_client/src/ui/screens/voice_screen.dart';
import 'package:harness_client/src/ui/theme/harness_theme.dart';
import 'package:harness_client/src/ui/widgets/message_composer.dart';
import 'package:harness_client/src/ui/widgets/voice_settings_sheet.dart';
import 'package:harness_client/src/voice/voice_backend.dart';
import 'package:harness_client/src/voice/voice_models.dart';
import 'package:harness_client/src/voice/voice_settings.dart';

import 'support/voice_fakes.dart';

Widget _app(Widget home) => HarnessStyle(
  style: HarnessPlatformStyle.material,
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: HarnessTheme.material(Brightness.light),
    home: home,
  ),
);

Future<void> _open(WidgetTester tester, Rig rig) async {
  await tester.pumpWidget(_app(VoiceScreen(controller: rig.controller)));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 20));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the voice screen says what it is and offers the live controls', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final rig = Rig();
    await _open(tester, rig);

    expect(find.text('Voice'), findsOneWidget);
    expect(find.text('Clip'), findsOneWidget);
    expect(find.text('Listening'), findsOneWidget);
    expect(find.text('Transcript'), findsOneWidget);
    expect(find.text('No speech yet'), findsOneWidget);
    expect(find.text('Mute'), findsOneWidget);
    expect(find.text('Pause'), findsOneWidget);
    expect(find.text('Interrupt'), findsOneWidget);
    expect(find.text('End'), findsOneWidget);
    expect(find.byTooltip('End'), findsOneWidget);
    expect(find.byTooltip('Microphone · live'), findsOneWidget);
    expect(find.byTooltip('Conversation · live'), findsOneWidget);
    expect(find.byTooltip('Playback · interruption'), findsOneWidget);
    expect(find.byTooltip('Conversation · end'), findsOneWidget);
    expect(find.byTooltip('Voice settings'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
    expect(find.byKey(const Key('composer-voice')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('captions carry the speaker they belong to', (tester) async {
    tester.view.physicalSize = const Size(390, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final rig = Rig();
    await _open(tester, rig);
    rig.backend.emit(
      const VoiceCaptionEvent(
        VoiceSpeaker.you,
        'open the task',
        finalized: true,
      ),
    );
    rig.backend.emit(
      const VoiceCaptionEvent(
        VoiceSpeaker.agent,
        'it is open',
        finalized: true,
      ),
    );
    await tester.pump();
    expect(find.text('You'), findsOneWidget);
    expect(find.text('Agent'), findsOneWidget);
    expect(find.text('open the task'), findsOneWidget);
    expect(find.text('it is open'), findsOneWidget);
    expect(find.text('No speech yet'), findsNothing);
  });

  testWidgets(
    'mute, interrupt and a fatal end change the status and controls',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final rig = Rig();
      await _open(tester, rig);

      await tester.tap(find.byKey(const Key('voice-mute')));
      await tester.pump();
      expect(find.text('Muted'), findsOneWidget);
      expect(find.text('Unmute'), findsOneWidget);
      expect(find.byTooltip('Microphone · muted'), findsOneWidget);
      await tester.tap(find.byKey(const Key('voice-mute')));
      await tester.pump();
      expect(find.text('Listening'), findsOneWidget);
      expect(find.text('Mute'), findsOneWidget);

      await tester.tap(find.byKey(const Key('voice-pause')));
      await tester.pump();
      expect(find.text('Paused'), findsOneWidget);
      expect(find.text('Resume'), findsOneWidget);
      expect(find.byTooltip('Conversation · paused'), findsOneWidget);
      expect(rig.backend.pauses, 1);
      await tester.tap(find.byKey(const Key('voice-pause')));
      await tester.pump();
      expect(find.text('Listening'), findsOneWidget);
      expect(find.text('Pause'), findsOneWidget);
      expect(rig.backend.resumes, 1);

      await tester.tap(find.byKey(const Key('voice-interrupt')));
      await tester.pump();
      expect(find.text('Interrupted'), findsOneWidget);

      rig.backend.emit(
        const VoiceFailureEvent(
          VoiceProblem('Microphone unavailable', recoverable: false),
        ),
      );
      await tester.pump();
      expect(find.text('Failed'), findsOneWidget);
      expect(find.text('Microphone unavailable'), findsOneWidget);
      expect(find.text('Retry'), findsWidgets);
      expect(find.byTooltip('Conversation · retry'), findsOneWidget);
    },
  );

  testWidgets('an approval notice opens the conversation', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final rig = Rig();
    await _open(tester, rig);
    rig.session.blocked = true;
    rig.session.changed();
    await tester.pump();
    expect(find.text('Approval needed'), findsOneWidget);
    expect(find.text('Permission request'), findsOneWidget);
    expect(find.text('Open'), findsOneWidget);
  });

  testWidgets('the settings sheet says every field of a clip provider', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(430, 1500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      _app(
        Scaffold(
          body: SingleChildScrollView(
            child: VoiceSettingsSheet(
              settings: const VoiceSettings(),
              harnessAddress: 'ws://192.168.1.5:9999/acp',
            ),
          ),
        ),
      ),
    );
    expect(find.text('Voice settings'), findsOneWidget);
    expect(find.text('PROVIDER'), findsOneWidget);
    expect(find.text('Clip'), findsOneWidget);
    expect(find.text('Live'), findsOneWidget);
    expect(find.text('DELIVERY'), findsOneWidget);
    expect(find.text('Transcript'), findsOneWidget);
    expect(find.text('Audio prompt'), findsOneWidget);
    expect(find.text('SPEECH'), findsOneWidget);
    expect(find.text('Speech endpoint'), findsOneWidget);
    expect(find.text('Model'), findsOneWidget);
    expect(find.text('Token'), findsOneWidget);
    expect(find.text('Language'), findsOneWidget);
    expect(find.text('OUTPUT'), findsOneWidget);
    expect(find.text('Speak replies'), findsOneWidget);
    expect(find.text('Save'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the settings sheet switches to the realtime fields', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(430, 1500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      _app(
        Scaffold(
          body: SingleChildScrollView(
            child: VoiceSettingsSheet(
              settings: const VoiceSettings(),
              harnessAddress: 'ws://192.168.1.5:9999/acp',
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Live'));
    await tester.pump();
    expect(find.text('REALTIME'), findsOneWidget);
    expect(find.text('Realtime endpoint'), findsOneWidget);
    expect(find.text('Realtime model'), findsOneWidget);
    expect(find.text('Voice'), findsOneWidget);
    expect(find.text('SPEECH'), findsNothing);
    await tester.tap(find.byKey(const Key('voice-save')));
    await tester.pump();
    expect(find.text('Realtime endpoint required'), findsOneWidget);
  });

  testWidgets('the composer offers voice and calls back once', (tester) async {
    var tapped = 0;
    await tester.pumpWidget(
      _app(
        Scaffold(
          body: MessageComposer(
            onSend: (text, attachments) => true,
            onStop: () {},
            running: false,
            cancelling: false,
            canAttach: false,
            canVoice: true,
            onVoice: () => tapped++,
          ),
        ),
      ),
    );
    expect(find.byKey(const Key('composer-voice')), findsOneWidget);
    final semantics = tester.ensureSemantics();
    await tester.tap(find.byKey(const Key('composer-voice')));
    expect(tapped, 1);
    expect(find.bySemanticsLabel('Voice mode'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('voice is not offered when the composer cannot send', (
    tester,
  ) async {
    var tapped = 0;
    await tester.pumpWidget(
      _app(
        Scaffold(
          body: MessageComposer(
            onSend: (text, attachments) => true,
            onStop: () {},
            running: false,
            cancelling: false,
            canAttach: false,
            canVoice: true,
            enabled: false,
            onVoice: () => tapped++,
          ),
        ),
      ),
    );
    expect(find.byKey(const Key('composer-voice')), findsOneWidget);
    await tester.tap(find.byKey(const Key('composer-voice')));
    expect(tapped, 0);
  });

  testWidgets('keyboard and headset buttons reach mute and pause', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final rig = Rig();
    await _open(tester, rig);
    expect(rig.media.starts, 1);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    await tester.pump();
    expect(find.text('Unmute'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    await tester.pump();
    expect(find.text('Mute'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
    await tester.pump();
    expect(find.text('Paused'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
    await tester.pump();
    expect(find.text('Listening'), findsOneWidget);

    rig.media.press();
    await tester.pump();
    expect(find.text('Paused'), findsOneWidget);
    rig.media.press();
    await tester.pump();
    expect(find.text('Listening'), findsOneWidget);

    unawaited(rig.controller.stop());
    await tester.pump(const Duration(milliseconds: 100));
    expect(rig.media.stops, 1);
    expect(rig.media.toggle, isNull);
  });

  testWidgets('each control has a screen-reader name and a shortcut hint', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final rig = Rig();
    await _open(tester, rig);
    final semantics = tester.ensureSemantics();

    expect(find.bySemanticsLabel('Pause'), findsOneWidget);
    final pause = tester.getSemantics(find.bySemanticsLabel('Pause'));
    expect(pause.hint, 'Shortcut P');
    expect(pause.hasFlag(SemanticsFlag.isButton), isTrue);
    expect(find.bySemanticsLabel('Mute'), findsOneWidget);
    final mute = tester.getSemantics(find.bySemanticsLabel('Mute'));
    expect(mute.hint, 'Shortcut M');
    expect(find.bySemanticsLabel('End'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('all controls fit a phone and wrap on a narrow screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final rig = Rig();
    await _open(tester, rig);
    expect(tester.takeException(), isNull);
    final pause = tester.getTopLeft(find.byKey(const Key('voice-pause')));
    final interrupt = tester.getTopLeft(
      find.byKey(const Key('voice-interrupt')),
    );
    expect(pause.dy, interrupt.dy);

    tester.view.physicalSize = const Size(300, 844);
    await tester.pump();
    rig.backend.emit(
      const VoiceFailureEvent(
        VoiceProblem('Microphone unavailable', recoverable: false),
      ),
    );
    await tester.pump();
    expect(find.text('Retry'), findsWidgets);
    expect(tester.takeException(), isNull);
    final first = tester.getTopLeft(find.byKey(const Key('voice-pause')));
    final retry = tester.getTopLeft(find.byKey(const Key('voice-retry')));
    expect(retry.dy, greaterThan(first.dy), reason: 'the row wraps');
  });
}
