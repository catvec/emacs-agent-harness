// Scripted unsent turns on the real full and compact voice surfaces.
//
//   HARNESS_SHOTS=/some/directory flutter test test/voice_pending_speech_screenshots_test.dart
//
// The controller receives fixture transcripts, not microphone or paid API
// input. Without HARNESS_SHOTS every case still draws and checks its copy.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
import 'support/real_fonts.dart';
import 'support/voice_fakes.dart';

enum _Surface { full, compact, workspace, buddy }

class _Case {
  const _Case(
    this.file,
    this.surface,
    this.draft,
    this.status, {
    this.size = const Size(390, 844),
    this.scale = 1,
  });

  final String file;
  final _Surface surface;
  final String draft;
  final String status;
  final Size size;
  final double scale;
}

const _cases = [
  _Case(
    'voice-pending-grace',
    _Surface.full,
    'Check the current build.',
    'Finishing thought',
  ),
  _Case(
    'voice-pending-continuation',
    _Surface.full,
    'Check the current build, hold on',
    'Waiting for continuation',
  ),
  _Case(
    'voice-pending-cut-off',
    _Surface.full,
    'Compare the current build with',
    'Possible cut-off',
  ),
  _Case(
    'voice-pending-full-narrow',
    _Surface.full,
    'Compare the current build with',
    'Possible cut-off',
    size: Size(320, 640),
  ),
  _Case(
    'voice-pending-full-large-text',
    _Surface.full,
    'Compare the current build with',
    'Possible cut-off',
    size: Size(320, 640),
    scale: 2,
  ),
  _Case(
    'voice-pending-compact-narrow',
    _Surface.compact,
    'Compare the two release candidates, hold on',
    'Waiting for continuation',
    size: Size(280, 400),
    scale: 1.5,
  ),
  _Case(
    'workspace-pending-narrow',
    _Surface.workspace,
    'Compare the two release candidates, hold on',
    'Waiting for continuation',
    size: Size(320, 640),
    scale: 1.25,
  ),
  _Case(
    'workspace-buddy-pending',
    _Surface.buddy,
    'Compare the current build with',
    'Possible cut-off',
    size: Size(344, 460),
  ),
];

Widget _app(Widget home, _Case shot, {TransitionBuilder? builder}) => HarnessStyle(
  style: HarnessPlatformStyle.material,
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: HarnessTheme.material(Brightness.dark),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(shot.scale),
        disableAnimations: true,
      ),
      child: builder == null ? child! : builder(context, child),
    ),
    home: home,
  ),
);

void _transcript(FakeBackend backend, String draft) {
  backend.emit(
    const VoiceCaptionEvent(
      VoiceSpeaker.agent,
      'The last build passed.',
      finalized: true,
    ),
  );
  backend.emit(
    const VoiceSegmentEvent(
      id: 'pending-1',
      stage: VoiceSegmentStage.accepted,
      duration: Duration(milliseconds: 1800),
    ),
  );
  backend.emit(
    const VoiceSegmentEvent(
      id: 'pending-1',
      stage: VoiceSegmentStage.transcribing,
    ),
  );
  backend.emit(
    VoiceCaptionEvent(
      VoiceSpeaker.you,
      draft,
      finalized: true,
      segmentId: 'pending-1',
    ),
  );
  backend.emit(
    VoiceSegmentEvent(
      id: 'pending-1',
      stage: VoiceSegmentStage.transcribed,
      text: draft,
    ),
  );
  backend.emit(
    VoicePromptEvent(
      VoicePrompt(id: 'pending-1', segmentId: 'pending-1', text: draft),
    ),
  );
}

Future<void> _write(WidgetTester tester, GlobalKey boundary, String path) async {
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
      tester.view.physicalSize = shot.size * 2;
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final boundary = GlobalKey();
      late final FakeBackend backend;
      late final FakeSession session;
      late final Widget app;
      late final Future<void> Function() endCall;
      late final VoidCallback dispose;
      if (shot.surface == _Surface.full || shot.surface == _Surface.compact) {
        final rig = Rig(settings: const VoiceSettings());
        await rig.controller.start();
        await tester.pump();
        addTearDown(rig.controller.dispose);
        endCall = rig.controller.stop;
        dispose = rig.controller.dispose;
        backend = rig.backend;
        session = rig.session;
        app = _app(
          shot.surface == _Surface.full
              ? VoiceScreen(controller: rig.controller, attached: true)
              : Scaffold(
                  body: Padding(
                    padding: const EdgeInsets.all(12),
                    child: VoicePendingSpeech(
                      controller: rig.controller,
                      compact: true,
                    ),
                  ),
                ),
          shot,
        );
      } else {
        final rig = BuddyRig();
        rig.host.voiceSettings = const VoiceSettings();
        await tester.runAsync(rig.start);
        addTearDown(rig.controller.dispose);
        endCall = rig.controller.end;
        dispose = rig.controller.dispose;
        backend = rig.backends.single;
        session = rig.host.session;
        app = shot.surface == _Surface.workspace
            ? _app(
                Scaffold(
                  appBar: AppBar(title: const Text('Workspace')),
                  body: const Center(child: Text('No messages')),
                ),
                shot,
                builder: (context, child) => Column(
                  children: [
                    WorkspaceCallBar(
                      controller: rig.controller,
                      visible: true,
                      onOpenCallView: () {},
                    ),
                    Expanded(child: Semantics(container: true, child: child!)),
                  ],
                ),
              )
            : _app(
                Scaffold(
                  body: Align(
                    alignment: Alignment.topCenter,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: WorkspaceBuddy(
                        controller: rig.controller,
                        onOpenWorkspace: () {},
                        onOpenSettings: () {},
                      ),
                    ),
                  ),
                ),
                shot,
              );
      }
      _transcript(backend, shot.draft);
      await tester.pump();
      await tester.pumpWidget(RepaintBoundary(key: boundary, child: app));
      await tester.pump(const Duration(milliseconds: 40));
      final pending = find.byKey(const Key('voice-pending-speech'));
      expect(pending, findsOneWidget);
      expect(
        tester
            .widgetList<Text>(find.descendant(of: pending, matching: find.byType(Text)))
            .map((text) => text.data),
        ['Unsent speech', 'Submission', shot.status, shot.draft],
      );
      expect(tester.widget<TextButton>(find.byKey(const Key('voice-pending-send'))).onPressed, isNotNull);
      expect(session.sent, isEmpty);
      expect(tester.takeException(), isNull);
      if (shots != null) {
        await _write(
          tester,
          boundary,
          '$shots/${shot.file}${real ? '' : '-ahem'}.png',
        );
      }
      // Capture first, then cancel grace before testWidgets checks for timers.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(endCall);
      dispose();
    });
  }
}
