// Pictures of the voice screen, drawn with the fonts of a phone.
//
//   HARNESS_SHOTS=/some/directory flutter test test/voice_screenshots_test.dart
//
// writes a PNG for each case there.  Without HARNESS_SHOTS the cases still
// run (they draw, and check that the screen is whole), and write nothing.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:harness_client/src/ui/adaptive/platform_style.dart';
import 'package:harness_client/src/ui/app_scope.dart';
import 'package:harness_client/src/ui/screens/session_screen.dart';
import 'package:harness_client/src/ui/screens/voice_screen.dart';
import 'package:harness_client/src/ui/theme/harness_theme.dart';
import 'package:harness_client/src/ui/widgets/voice_settings_sheet.dart';
import 'package:harness_client/src/voice/voice_backend.dart';
import 'package:harness_client/src/voice/voice_models.dart';
import 'package:harness_client/src/voice/voice_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';
import 'support/real_fonts.dart';
import 'support/voice_fakes.dart';

class _Case {
  const _Case(
    this.file,
    this.width,
    this.height, {
    this.live = false,
    this.captions = const [],
    this.phase,
    this.approval = false,
    this.settings = false,
    this.paused = false,
  });

  final String file;
  final double width;
  final double height;
  final bool live;
  final List<(VoiceSpeaker, String, bool)> captions;
  final VoicePhase? phase;
  final bool approval;
  final bool settings;
  final bool paused;
}

const _cases = [
  _Case(
    'voice-listening',
    390,
    844,
    captions: [
      (VoiceSpeaker.you, 'open the task about the merge queue', true),
      (
        VoiceSpeaker.agent,
        'It is in review. The tests passed on the last run.',
        true,
      ),
      (VoiceSpeaker.you, 'what is left', true),
    ],
  ),
  _Case(
    'voice-hearing',
    390,
    844,
    phase: VoicePhase.hearing,
    captions: [
      (VoiceSpeaker.agent, 'The merge queue has two tasks waiting.', true),
      (VoiceSpeaker.you, 'and the one I just', false),
    ],
  ),
  _Case(
    'voice-speaking',
    390,
    844,
    phase: VoicePhase.speaking,
    captions: [
      (VoiceSpeaker.you, 'what is the client doing', true),
      (
        VoiceSpeaker.agent,
        'The Flutter client is drawing the voice screen now, and the',
        false,
      ),
    ],
  ),
  _Case(
    'voice-approval',
    390,
    844,
    approval: true,
    captions: [
      (VoiceSpeaker.you, 'run the tests', true),
      (VoiceSpeaker.agent, 'I need your approval for the command.', true),
    ],
  ),
  _Case(
    'voice-paused',
    390,
    844,
    paused: true,
    captions: [
      (VoiceSpeaker.you, 'pause while I answer the door', true),
      (
        VoiceSpeaker.agent,
        'Paused. The merge queue has two tasks waiting.',
        true,
      ),
    ],
  ),
  _Case(
    'voice-live',
    390,
    844,
    live: true,
    captions: [
      (VoiceSpeaker.you, 'check the failing task', true),
      (
        VoiceSpeaker.agent,
        'One task failed its build. I can send it back.',
        true,
      ),
    ],
  ),
  _Case('voice-settings', 430, 932, live: true, settings: true),
  _Case(
    'voice-wide',
    900,
    700,
    captions: [
      (VoiceSpeaker.you, 'what changed', true),
      (
        VoiceSpeaker.agent,
        'The client has a voice screen, a clip path and a live path.',
        true,
      ),
    ],
  ),
];

Widget _app(Widget home) => HarnessStyle(
  style: HarnessPlatformStyle.material,
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: HarnessTheme.material(Brightness.light),
    home: home,
  ),
);

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

  for (final shot in _cases) {
    testWidgets('draws ${shot.file}', (tester) async {
      const ratio = 2.0;
      tester.view.physicalSize = Size(shot.width * ratio, shot.height * ratio);
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
      addTearDown(tester.view.resetViewInsets);

      final boundary = GlobalKey();
      if (shot.settings) {
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: _app(
              Scaffold(
                body: SafeArea(
                  child: VoiceSettingsSheet(
                    settings: VoiceSettings(
                      provider: shot.live
                          ? VoiceProvider.live
                          : VoiceProvider.clip,
                      realtimeEndpoint: 'https://api.openai.com/v1',
                      realtimeModel: 'gpt-live-1',
                    ),
                    harnessAddress: 'ws://192.168.1.5:9999/acp',
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
      } else {
        final rig = Rig(
          settings: shot.live
              ? const VoiceSettings(
                  provider: VoiceProvider.live,
                  realtimeEndpoint: 'https://api.openai.com/v1',
                  realtimeModel: 'gpt-live-1',
                )
              : const VoiceSettings(clipDelivery: ClipDelivery.audioPrompt),
        );
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: _app(VoiceScreen(controller: rig.controller)),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 40));
        for (final caption in shot.captions) {
          rig.backend.emit(
            VoiceCaptionEvent(caption.$1, caption.$2, finalized: caption.$3),
          );
        }
        if (shot.phase != null) {
          rig.backend.emit(VoicePhaseEvent(shot.phase!));
        }
        if (shot.paused) {
          await rig.controller.pause();
          await tester.pump(const Duration(milliseconds: 300));
          await tester.pump(const Duration(milliseconds: 220));
        }
        if (shot.approval) {
          rig.session.blocked = true;
          rig.session.changed();
        }
        await tester.pump(const Duration(milliseconds: 40));
      }

      expect(tester.takeException(), isNull);
      if (shots != null) {
        await _write(
          tester,
          boundary,
          '$shots/${shot.file}${real ? '' : '-ahem'}.png',
        );
      }
    });
  }

  // Where voice mode is entered from: the microphone in the box.
  testWidgets('draws the conversation that offers voice', (tester) async {
    const ratio = 2.0;
    const width = 390.0;
    const height = 844.0;
    tester.view.physicalSize = const Size(width * ratio, height * ratio);
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
    addTearDown(tester.view.resetViewInsets);

    SharedPreferences.setMockInitialValues({});
    final settings = SettingsController();
    await settings.load();
    final harness = FakeHarness();
    final app = AppController(
      settings: settings,
      connector: harness.connector,
      handshakeTimeout: const Duration(seconds: 2),
    );
    await app.connect('ws://memory/acp');
    final boundary = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: HarnessStyle(
          style: HarnessPlatformStyle.material,
          child: HarnessScope(
            app: app,
            settings: settings,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: HarnessTheme.material(Brightness.light),
              home: SessionScreen(sessionId: 's1'),
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }

    expect(find.byKey(const Key('composer-voice')), findsOneWidget);
    expect(tester.takeException(), isNull);
    if (shots != null) {
      await _write(tester, boundary, '$shots/voice-entry.png');
    }
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 400));
    }
  });
}
