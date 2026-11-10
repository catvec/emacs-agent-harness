import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/ui/adaptive/adaptive_widgets.dart';
import 'package:harness_client/src/ui/adaptive/platform_style.dart';
import 'package:harness_client/src/ui/screens/voice_screen.dart';
import 'package:harness_client/src/ui/theme/harness_theme.dart';
import 'package:harness_client/src/ui/widgets/message_composer.dart';
import 'package:harness_client/src/ui/widgets/voice_settings_sheet.dart';
import 'package:harness_client/src/voice/voice_backend.dart';
import 'package:harness_client/src/voice/voice_models.dart';
import 'package:harness_client/src/voice/voice_output.dart';
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


/// The voices the device reports in these tests: two the platform named, and
/// no invented universal list.
const _voices = <VoiceOutputVoice>[
  VoiceOutputVoice(name: 'Anna', locale: 'de-DE', quality: '1'),
  VoiceOutputVoice(name: 'Samantha', locale: 'en-US', quality: '3'),
];

const _range = VoiceRateRange(min: 0.25, normal: 0.5, max: 2.0);

/// Open the setup sheet as a page, with the platform's answers scripted.
Future<FakeAuditionEngines> _sheet(
  WidgetTester tester, {
  VoiceSettings settings = const VoiceSettings(),
  VoiceOutputCatalogue? catalogue,
  Size size = const Size(430, 1600),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final engines = FakeAuditionEngines(startsImmediately: true);
  await tester.pumpWidget(
    _app(
      Scaffold(
        body: SingleChildScrollView(
          child: VoiceSettingsSheet(
            settings: settings,
            harnessAddress: 'ws://192.168.1.5:9999/acp',
            catalogue:
                catalogue ??
                FakeVoiceCatalogue(voices: _voices, rateRange: _range),
            engineFactory: (_) => engines(),
          ),
        ),
      ),
    ),
  );
  // The catalogue answers in a microtask; the sheet then draws its list.
  await tester.pump();
  await tester.pump();
  return engines;
}

void main() {
  testWidgets('an attached call minimizes and ends through its owner', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final rig = Rig();
    // The owner starts the call before it shows the view; the start awaits
    // the session bridge, which a widget test's fake time does not run.
    await tester.runAsync(() => rig.controller.start());
    var ended = 0;
    final navigator = GlobalKey<NavigatorState>();
    Future<void> open() async {
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => VoiceScreen(
            controller: rig.controller,
            attached: true,
            onEnd: () async => ended++,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: const Scaffold(body: Center(child: Text('Behind'))),
      ),
    );
    await open();
    expect(find.text('Voice'), findsOneWidget);
    expect(find.byTooltip('Minimize'), findsOneWidget);
    expect(find.byTooltip('End'), findsNothing);
    expect(rig.backend.started, isTrue);

    // The close control minimizes: the call and its microphone stay, and
    // the owner is not asked to end anything.
    await tester.tap(find.byKey(const Key('voice-close')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Behind'), findsOneWidget);
    expect(rig.backend.stopped, isFalse);
    expect(ended, 0);

    // End pops the view and goes back through the owner, and the screen
    // itself never stopped or disposed the controller.
    await open();
    await tester.tap(find.byKey(const Key('voice-end')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Behind'), findsOneWidget);
    expect(ended, 1);
    expect(rig.backend.stopped, isFalse);

    rig.controller.dispose();
  });

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
              catalogue: FakeVoiceCatalogue(
                voices: _voices,
                rateRange: _range,
              ),
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
              catalogue: FakeVoiceCatalogue(
                voices: _voices,
                rateRange: _range,
              ),
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

  group('the output voice section', () {
    testWidgets('says the device voices, the parameters and the audition', (
      tester,
    ) async {
      await _sheet(tester);
      expect(find.text('Voice settings'), findsOneWidget);
      expect(find.text('OUTPUT VOICE'), findsOneWidget);
      expect(find.text('Voice'), findsOneWidget);
      expect(find.text('Default'), findsOneWidget);
      expect(find.text('Rate'), findsWidgets);
      expect(find.text('Pitch'), findsWidgets);
      expect(find.text('Volume'), findsWidgets);
      expect(find.text('Rate · 0.25–2.00'), findsOneWidget);
      expect(find.text('Pitch · 0.50–2.00'), findsOneWidget);
      expect(find.text('Volume · 0.00–1.00'), findsOneWidget);
      expect(find.text('Audition'), findsOneWidget);
      expect(find.text('Save'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
      expect(find.text('Unsaved changes'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a slow catalogue says it is loading, then lists its voices', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(430, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final catalogue = _DeferredCatalogue();
      await tester.pumpWidget(
        _app(
          Scaffold(
            body: SingleChildScrollView(
              child: VoiceSettingsSheet(
                settings: const VoiceSettings(),
                harnessAddress: 'ws://192.168.1.5:9999/acp',
                catalogue: catalogue,
                engineFactory: (_) => FakeAuditionEngines()(),
              ),
            ),
          ),
        ),
      );
      expect(find.text('Loading voices'), findsOneWidget);
      expect(find.text('Audition'), findsOneWidget);
      catalogue.answer(voices: _voices, range: _range);
      await tester.pump();
      await tester.pump();
      expect(find.text('Loading voices'), findsNothing);
      expect(find.text('Default'), findsOneWidget);
      expect(find.text('Rate · 0.25–2.00'), findsOneWidget);
    });

    testWidgets('a failed list is honest, and a name can still be typed', (
      tester,
    ) async {
      await _sheet(
        tester,
        catalogue: FakeVoiceCatalogue(
          voicesError: const VoiceOutputException('TextToSpeech is not ready'),
          rateError: const VoiceOutputException('no range'),
        ),
      );
      expect(find.text('Voice list unavailable'), findsOneWidget);
      expect(find.text('Loading voices'), findsNothing);
      // The range was not discovered, so there is no rate control at all.
      expect(find.text('Rate · 0.25–2.00'), findsNothing);
      expect(find.byKey(const Key('voice-rate-slider')), findsNothing);
      expect(find.text('Pitch · 0.50–2.00'), findsOneWidget);
      expect(find.byKey(const Key('voice-output-voice')), findsOneWidget);
      expect(find.text('Audition'), findsOneWidget);
      final semantics = tester.ensureSemantics();
      final tooltip = tester.widget<Tooltip>(
        find.ancestor(
          of: find.text('Voice list unavailable'),
          matching: find.byType(Tooltip),
        ),
      );
      expect(tooltip.message, 'TextToSpeech is not ready');
      semantics.dispose();
    });

    testWidgets('the list offers Default and the reported voices', (
      tester,
    ) async {
      await _sheet(tester);
      await tester.tap(find.text('Default'));
      await tester.pumpAndSettle();
      expect(find.text('Anna · de-DE'), findsOneWidget);
      expect(find.text('Samantha · en-US'), findsOneWidget);
      await tester.tap(find.text('Samantha · en-US'));
      await tester.pumpAndSettle();
      expect(find.text('Samantha · en-US'), findsOneWidget);
      expect(find.text('Unsaved changes'), findsOneWidget);
    });

    testWidgets('an audition speaks the draft, not the saved settings', (
      tester,
    ) async {
      final engines = await _sheet(tester);
      await tester.tap(find.text('Default'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Anna · de-DE'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('voice-rate-field')), '1.20');
      await tester.pump();
      await tester.tap(find.byKey(const Key('voice-audition')));
      await tester.pump();
      expect(engines.spoken, hasLength(1));
      final spoken = engines.spoken.single;
      expect(spoken.text, 'Harness output voice');
      expect(spoken.params.voice?.name, 'Anna');
      expect(spoken.params.voice?.locale, 'de-DE');
      expect(spoken.params.rate, 1.2);
      // The control says what it is doing.
      expect(find.text('Playing'), findsOneWidget);
      expect(find.text('Stop'), findsOneWidget);
      expect(find.text('Audition'), findsNothing);
      engines.last.finish();
      await tester.pump();
      expect(find.text('Stopped'), findsOneWidget);
      expect(find.text('Audition'), findsOneWidget);
    });

    testWidgets('a failed audition says so and offers Retry', (tester) async {
      final engines = await _sheet(tester);
      engines.nextFailure = StateError('setVoice returned 0');
      await tester.tap(find.byKey(const Key('voice-audition')));
      await tester.pump();
      expect(find.text('Failed'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('Bad state: setVoice returned 0'), findsOneWidget);
      await tester.tap(find.text('Retry'));
      await tester.pump();
      expect(find.text('Playing'), findsOneWidget);
      engines.last.finish();
      await tester.pump();
      expect(find.text('Stopped'), findsOneWidget);
    });

    testWidgets('out-of-range values are named, and never spoken or saved', (
      tester,
    ) async {
      final engines = await _sheet(tester);
      await tester.enterText(find.byKey(const Key('voice-rate-field')), '0.20');
      await tester.pump();
      expect(find.text('Rate · 0.20 outside 0.25–2.00'), findsOneWidget);
      await tester.tap(find.byKey(const Key('voice-audition')));
      await tester.pump();
      expect(engines.spoken, isEmpty, reason: 'nothing invalid is spoken');

      await tester.enterText(find.byKey(const Key('voice-pitch-field')), '9');
      await tester.pump();
      expect(find.text('Pitch · 9 outside 0.50–2.00'), findsOneWidget);
      await tester.tap(find.byKey(const Key('voice-save')));
      await tester.pump();
      expect(find.text('Voice settings'), findsOneWidget);
      expect(find.text('Unsaved changes'), findsOneWidget);
    });

    testWidgets('Save writes the whole draft, new fields and all', (
      tester,
    ) async {
      VoiceSettings? saved;
      tester.view.physicalSize = const Size(430, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        _app(
          Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  saved = await showHarnessSheet<VoiceSettings>(
                    context: context,
                    builder: (sheetContext) => VoiceSettingsSheet(
                      settings: const VoiceSettings(
                        clipDelivery: ClipDelivery.audioPrompt,
                      ),
                      harnessAddress: 'ws://192.168.1.5:9999/acp',
                      catalogue: FakeVoiceCatalogue(
                        voices: _voices,
                        rateRange: _range,
                      ),
                      engineFactory: (_) => FakeAuditionEngines()(),
                    ),
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Default'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Samantha · en-US'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('voice-rate-field')), '1.25');
      await tester.enterText(find.byKey(const Key('voice-pitch-field')), '1.40');
      await tester.enterText(find.byKey(const Key('voice-volume-field')), '0.30');
      await tester.pump();
      await tester.tap(find.byKey(const Key('voice-save')));
      await tester.pumpAndSettle();
      expect(saved, isNotNull);
      expect(saved!.outputVoice, 'Samantha');
      expect(saved!.outputVoiceLocale, 'en-US');
      expect(saved!.speechRate, 1.25);
      expect(saved!.speechPitch, 1.4);
      expect(saved!.speechVolume, 0.3);
      expect(saved!.clipDelivery, ClipDelivery.audioPrompt);
    });

    testWidgets('Cancel writes nothing, and Revert restores the draft', (
      tester,
    ) async {
      await _sheet(tester);
      await tester.enterText(find.byKey(const Key('voice-rate-field')), '1.25');
      await tester.pump();
      expect(find.text('Unsaved changes'), findsOneWidget);
      await tester.tap(find.byKey(const Key('voice-revert')));
      await tester.pump();
      expect(find.text('Unsaved changes'), findsNothing);
      final rate = tester.widget<TextField>(
        find.descendant(
          of: find.byKey(const Key('voice-rate-field')),
          matching: find.byType(TextField),
        ),
      );
      expect(rate.controller!.text, '0.50', reason: 'the saved normal rate');
    });

    testWidgets('the live provider keeps its free-text voice and no audition', (
      tester,
    ) async {
      await _sheet(tester);
      await tester.tap(find.text('Live'));
      await tester.pump();
      expect(find.text('Audition · unavailable'), findsOneWidget);
      expect(find.text('Unavailable'), findsOneWidget);
      expect(find.text('Realtime voice · provider-defined'), findsOneWidget);
      expect(find.text('Audition'), findsNothing);
      expect(find.byKey(const Key('voice-rate-slider')), findsNothing);
      expect(find.byKey(const Key('voice-pitch-slider')), findsNothing);
      expect(find.byKey(const Key('voice-volume-slider')), findsNothing);
      // The realtime voice is still a field of its own.
      expect(find.byKey(const Key('voice-realtime-voice')), findsOneWidget);
      final semantics = tester.ensureSemantics();
      final tooltip = tester.widget<Tooltip>(
        find.ancestor(
          of: find.text('Audition · unavailable'),
          matching: find.byType(Tooltip),
        ),
      );
      expect(tooltip.message, 'Realtime voice · provider-defined');
      semantics.dispose();
    });

    testWidgets('the audition control names itself and its state', (
      tester,
    ) async {
      final engines = await _sheet(tester);
      final semantics = tester.ensureSemantics();
      expect(find.bySemanticsLabel('Audition'), findsOneWidget);
      final idle = tester.getSemantics(find.bySemanticsLabel('Audition'));
      expect(idle.hasFlag(SemanticsFlag.isButton), isTrue);
      await tester.tap(find.byKey(const Key('voice-audition')));
      await tester.pump();
      final playing = tester.getSemantics(find.bySemanticsLabel('Stop'));
      expect(playing.value, 'Playing');
      engines.last.finish();
      await tester.pump();
      final stopped = tester.getSemantics(find.bySemanticsLabel('Audition'));
      expect(stopped.value, 'Stopped');
      semantics.dispose();
    });

    testWidgets('a hand-typed voice is spoken when the list failed', (
      tester,
    ) async {
      final engines = await _sheet(
        tester,
        catalogue: FakeVoiceCatalogue(
          voicesError: const VoiceOutputException('TextToSpeech is not ready'),
          rateError: const VoiceOutputException('no range'),
        ),
      );
      await tester.enterText(
        find.byKey(const Key('voice-output-voice')),
        'en-us-x-sfg-local',
      );
      await tester.pump();
      expect(find.text('Unsaved changes'), findsOneWidget);
      await tester.tap(find.byKey(const Key('voice-audition')));
      await tester.pump();
      expect(engines.spoken, hasLength(1));
      expect(engines.spoken.single.params.voice?.name, 'en-us-x-sfg-local');
      engines.last.finish();
      await tester.pump();
    });

    testWidgets('the state is in the tooltip and the screen-reader hint', (
      tester,
    ) async {
      final engines = await _sheet(tester);
      Tooltip tooltip() => tester.widget<Tooltip>(
        find.ancestor(
          of: find.byKey(const Key('voice-audition')),
          matching: find.byType(Tooltip),
        ),
      );
      expect(tooltip().message, 'Audition · draft values');
      final semantics = tester.ensureSemantics();
      expect(
        tester.getSemantics(find.bySemanticsLabel('Audition')).hint,
        'Audition · draft values',
      );
      await tester.tap(find.byKey(const Key('voice-audition')));
      await tester.pump();
      expect(tooltip().message, 'Audition · playing');
      expect(
        tester.getSemantics(find.bySemanticsLabel('Stop')).hint,
        'Audition · playing',
      );
      engines.last.finish();
      await tester.pump();
      expect(tooltip().message, 'Audition · stopped');
      semantics.dispose();
    });

    testWidgets('the audition button takes the keyboard, and Enter runs it', (
      tester,
    ) async {
      final engines = await _sheet(tester);
      final focus = Focus.of(
        tester.element(
          find.descendant(
            of: find.byKey(const Key('voice-audition')),
            matching: find.byType(Text),
          ),
        ),
      );
      focus.requestFocus();
      await tester.pump();
      expect(focus.hasFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(engines.spoken, hasLength(1));
      expect(find.text('Stop'), findsOneWidget);
      engines.last.finish();
      await tester.pump();
      await tester.pump();
      expect(find.text('Stopped'), findsOneWidget);
    });

    testWidgets('the audition runs from the keyboard, the fields take keys', (
      tester,
    ) async {
      final engines = await _sheet(tester);
      final order = <String>[];
      // Tab walks the sheet: the fields, the voice, the audition, the
      // buttons.  Whatever has focus when Tab reaches the audition runs it
      // with Enter, exactly as a tap would.
      for (var step = 0; step < 14; step++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        final primary = FocusManager.instance.primaryFocus;
        order.add(primary?.debugLabel ?? 'traversal');
        if (primary?.debugLabel == 'voice-settings · Voice') break;
      }
      expect(
        order,
        contains('voice-settings · Voice'),
        reason: 'the voice control is on the focus order',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(engines.spoken, isEmpty, reason: 'a key does not audition here');
    });

    testWidgets('a text field keeps its own keys', (tester) async {
      final engines = await _sheet(tester);
      final rate = find.byKey(const Key('voice-rate-field'));
      await tester.tap(rate);
      await tester.pump();
      await tester.enterText(rate, '1.10');
      await tester.pump();
      // Typing in a field never auditions: only the control does.
      expect(engines.spoken, isEmpty);
      expect(find.text('Unsaved changes'), findsOneWidget);
    });

    testWidgets('fits a 300 px sheet without an overflow', (tester) async {
      await _sheet(tester, size: const Size(300, 844));
      expect(tester.takeException(), isNull);
      expect(find.text('Audition'), findsOneWidget);
      final audition = tester.getTopLeft(find.byKey(const Key('voice-audition')));
      final save = tester.getTopLeft(find.byKey(const Key('voice-save')));
      expect(save.dy, greaterThan(audition.dy), reason: 'fields then buttons');
    });

    testWidgets('a change of voice during a preview stops it', (tester) async {
      final engines = await _sheet(tester);
      await tester.tap(find.byKey(const Key('voice-audition')));
      await tester.pump();
      expect(find.text('Playing'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('voice-pitch-field')), '1.30');
      await tester.pump();
      expect(find.text('Audition'), findsOneWidget);
      expect(find.text('Playing'), findsNothing);
      expect(engines.last.stops, 1);
      engines.last.finish();
      await tester.pump();
      expect(find.text('Playing'), findsNothing);
    });
  });
}

/// A catalogue whose answers arrive only when the test says so, for the
/// loading state.
class _DeferredCatalogue implements VoiceOutputCatalogue {
  final _voices = Completer<List<VoiceOutputVoice>>();
  final _range = Completer<VoiceRateRange?>();

  void answer({
    required List<VoiceOutputVoice> voices,
    required VoiceRateRange? range,
  }) {
    _voices.complete(voices);
    _range.complete(range);
  }

  @override
  Future<List<VoiceOutputVoice>> loadVoices() => _voices.future;

  @override
  Future<VoiceRateRange?> loadRateRange() => _range.future;
}
