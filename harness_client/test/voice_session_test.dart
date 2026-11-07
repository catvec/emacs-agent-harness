// What voice mode puts on the wire, through the session and the harness it
// belongs to: a spoken message as a text block, a clip as an ACP audio block,
// a spoken correction while the agent is working, what the screen hears back,
// and the microphone in the conversation that opens it all.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/session_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:harness_client/src/ui/adaptive/platform_style.dart';
import 'package:harness_client/src/ui/app_scope.dart';
import 'package:harness_client/src/ui/screens/session_screen.dart';
import 'package:harness_client/src/ui/theme/harness_theme.dart';
import 'package:harness_client/src/voice/voice_backend.dart';
import 'package:harness_client/src/voice/voice_controller.dart';
import 'package:harness_client/src/voice/voice_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';
import 'support/voice_fakes.dart';

class _Rig {
  _Rig(this.settings, this.harness, this.app);
  final SettingsController settings;
  final FakeHarness harness;
  final AppController app;
}

Future<_Rig> _rig() async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsController();
  await settings.load();
  final harness = FakeHarness();
  final app = AppController(
    settings: settings,
    connector: harness.connector,
    reconnectDelays: const [Duration(milliseconds: 5)],
    handshakeTimeout: const Duration(seconds: 2),
  );
  await app.connect('ws://memory/acp');
  return _Rig(settings, harness, app);
}

Future<void> _until(bool Function() done, String what) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) fail('Timed out waiting for $what.');
    await Future<void>.delayed(const Duration(milliseconds: 4));
  }
}

/// Let the events the app handles on the next frames land, and the timers it
/// schedules for them fire.
Future<void> _settle(WidgetTester tester, [int rounds = 6]) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
  // The last event schedules a refresh of its own; it must fire too.
  await tester.pump(const Duration(milliseconds: 500));
}

Future<SessionController> _open(_Rig rig, [String id = 's1']) async {
  final controller = rig.app.openSession(id);
  await _until(() => !controller.loading, 'the transcript');
  return controller;
}

/// The content blocks of every prompt the client sent in this session, in
/// order.
List<List<Object?>> _prompts(_Rig rig, [String id = 's1']) => [
  for (final (method, params) in rig.harness.requests)
    if (method == 'session/prompt' && params['sessionId'] == id)
      [for (final block in params['prompt'] as List) block],
];

Uint8List _wav() => Uint8List.fromList([
  ...'RIFF'.codeUnits,
  ...List<int>.filled(4, 0),
  ...'WAVEfmt '.codeUnits,
  ...[16, 0, 0, 0, 1, 0, 1, 0],
  ...[0x80, 0x3e, 0, 0],
  ...[0, 0x7d, 0, 0],
  ...[2, 0, 16, 0],
  ...'data'.codeUnits,
  ...[4, 0, 0, 0, 0, 0, 0, 0],
]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('what voice sends', () {
    test('a spoken message goes as a text block', () async {
      final rig = await _rig();
      final controller = await _open(rig);
      final sent = controller.sendVoice(text: '  open the merge queue task  ');
      expect(controller.voicePromptInFlight, isTrue);
      await sent;

      expect(_prompts(rig).single, [
        {'type': 'text', 'text': 'open the merge queue task'},
      ]);
      expect(controller.voicePromptInFlight, isFalse);
      expect(controller.error, isNull);
      // It is in the conversation as the person said it, before the agent
      // has answered.
      expect(
        controller.transcript.items.any(
          (item) => item.isUser && item.text.contains('merge queue task'),
        ),
        isTrue,
      );
    });

    test('a clip goes as an ACP audio block', () async {
      final rig = await _rig();
      final controller = await _open(rig);
      final audio = _wav();
      await controller.sendVoice(audio: audio);

      expect(_prompts(rig).single, [
        {'type': 'audio', 'mimeType': 'audio/wav', 'data': base64Encode(audio)},
      ]);
      // Nothing was said, so the conversation says a voice message was.
      expect(
        controller.transcript.items.any(
          (item) => item.isUser && item.text == '(voice message)',
        ),
        isTrue,
      );
    });

    test(
      'pending context travels, while the conversation shows what was said',
      () async {
        final rig = await _rig();
        final controller = await _open(rig);
        const shown = 'open the task';
        const wire =
            'open the task\n\n<voice-turn-context>\nheld_output:\n'
            '- The tests pass.\n</voice-turn-context>';
        final sending = controller.sendVoice(text: wire, displayText: shown);
        expect(
          controller.transcript.items.any(
            (item) => item.isUser && item.text == shown,
          ),
          isTrue,
          reason: 'the local echo is what the person said, not the context',
        );
        await sending;
        expect(_prompts(rig).single, [
          {'type': 'text', 'text': wire},
        ]);
        // The harness records the words the model read, context included.
        expect(
          controller.transcript.items.any(
            (item) => item.isUser && item.text.contains('voice-turn-context'),
          ),
          isTrue,
        );
      },
    );

    test('it is sent while the agent works, where typing would wait', () async {
      final rig = await _rig();
      final controller = await _open(rig);
      // A turn that takes a while: the harness streams it slowly.
      final turn = controller.send('Work slowly through the tests');
      await _until(() => controller.promptInFlight, 'the turn to start');

      // A message typed now is held by the composer; a spoken one goes.
      await controller.send('never arrives');
      final wait = controller.sendVoice(text: 'stop, wrong project');
      await wait;

      final prompts = _prompts(rig);
      expect(prompts, hasLength(2));
      expect(prompts.last, [
        {'type': 'text', 'text': 'stop, wrong project'},
      ]);
      expect(
        prompts
            .expand((blocks) => blocks)
            .any((block) => (block as Map)['text'] == 'never arrives'),
        isFalse,
      );
      await turn;
      await _until(() => !controller.promptInFlight, 'the turn to end');
    });

    test('nothing is sent when the connection is out', () async {
      final rig = await _rig();
      final controller = await _open(rig);
      await rig.harness.dropConnection();
      await _until(() => !controller.canSend, 'the connection to go');

      await controller.sendVoice(text: 'are you there');
      await controller.sendVoice(audio: _wav());

      expect(_prompts(rig), isEmpty);
      expect(
        controller.error,
        'Not connected to the harness: the message was not sent.',
      );
    });

    test('an empty prompt sends nothing at all', () async {
      final rig = await _rig();
      final controller = await _open(rig);
      await controller.sendVoice(text: '   ');
      await controller.sendVoice();
      expect(_prompts(rig), isEmpty);
      expect(controller.voicePromptInFlight, isFalse);
    });
  });

  group('what voice hears back', () {
    test('the bridge sends a clip, and says where it is', () async {
      final rig = await _rig();
      final controller = await _open(rig);
      final bridge = SessionVoiceBridge(controller);

      expect(bridge.sessionId, 's1');
      expect(bridge.sessionTitle, 'Design the merge queue');
      expect(bridge.cwd, '/Users/noah/Code/emacs-agent-harness/');
      expect(bridge.model, 'claude:claude-fable-5-1');
      expect(bridge.working, isFalse);
      expect(bridge.blocked, isFalse);
      expect(
        bridge.history,
        everyElement(anyOf(startsWith('Person: '), startsWith('Agent: '))),
      );

      await bridge.send(VoicePrompt(text: 'what is left', audio: _wav()));
      expect(_prompts(rig).single, [
        {'type': 'text', 'text': 'what is left'},
        {
          'type': 'audio',
          'mimeType': 'audio/wav',
          'data': base64Encode(_wav()),
        },
      ]);
    });

    test(
      'a finished reply is heard once, and not the ones before it',
      () async {
        final rig = await _rig();
        final controller = await _open(rig);
        final bridge = SessionVoiceBridge(controller);
        final heard = <String>[];
        bridge.addReplyListener(heard.add);

        await controller.send('Say something');
        await _until(() => heard.isNotEmpty, 'the reply');
        expect(heard.single, startsWith('I’m done with this step.'));
        // It is the agent's answer as the conversation shows it, streamed in
        // pieces and spoken once it is whole.
        expect(
          controller.transcript.items.where((i) => i.isAssistant),
          isNotEmpty,
        );

        bridge.removeReplyListener(heard.add);
        // What was said before the voice screen opened is history: it is not
        // read back as an answer to what is said now.
        bridge.addReplyListener(heard.add);
        expect(heard, hasLength(1));
        expect(heard.single.endsWith('one tap away.'), isTrue);
      },
    );

    test('an answer still streaming when voice opens is spoken', () async {
      final rig = await _rig();
      final controller = await _open(rig);
      final turn = controller.send('Work slowly through the tests');
      await _until(
        () => controller.transcript.items.any(
          (item) => item.isAssistant && item.streaming,
        ),
        'the answer to start',
      );

      // A walkthrough's conversation answers before voice attaches: an answer
      // that has not finished is no history, and is spoken when it is whole.
      final bridge = SessionVoiceBridge(controller);
      final heard = <String>[];
      bridge.addReplyListener(heard.add);

      await turn;
      await _until(() => heard.isNotEmpty, 'the answer spoken');
      expect(heard.single, startsWith('I’m done with this step.'));
      bridge.removeReplyListener(heard.add);
    });

    test('a permission waiting on the person shows as blocked', () async {
      final rig = await _rig();
      final controller = await _open(rig);
      final bridge = SessionVoiceBridge(controller);
      expect(bridge.blocked, isFalse);

      final turn = controller.send('Run the tests with permission');
      await _until(
        () => controller.currentInteraction != null,
        'the permission request',
      );
      expect(bridge.blocked, isTrue);
      expect(bridge.working, isTrue);

      // Voice never answers it: the person does, in the conversation.
      await controller.answerPermission('allow-once');
      await turn;
      await _until(() => !controller.isRunning, 'the turn to end');
      expect(bridge.blocked, isFalse);
    });
  });

  group('the conversation', () {
    Future<FakeBackend> pumpSession(WidgetTester tester, _Rig rig) async {
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final backend = FakeBackend();
      await tester.pumpWidget(
        HarnessStyle(
          style: HarnessPlatformStyle.material,
          child: HarnessScope(
            app: rig.app,
            settings: rig.settings,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: HarnessTheme.material(Brightness.light),
              home: SessionScreen(
                sessionId: 's1',
                voiceBackendFactory: (settings, address) => backend,
              ),
            ),
          ),
        ),
      );
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        if (rig.app.sessionController('s1').loading == false) break;
      }
      await tester.pump(const Duration(milliseconds: 200));
      return backend;
    }

    testWidgets('the microphone in the box opens voice mode', (tester) async {
      final rig = await _rig();
      final backend = await pumpSession(tester, rig);

      expect(find.byKey(const Key('composer-voice')), findsOneWidget);
      await tester.tap(find.byKey(const Key('composer-voice')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(backend.started, isTrue);
      expect(find.byKey(const Key('voice-status')), findsOneWidget);
      expect(find.text('Listening'), findsOneWidget);
      expect(find.text('Clip'), findsOneWidget);

      // Ending goes back to the conversation, and stops the microphone.
      await tester.tap(find.byKey(const Key('voice-close')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(backend.stopped, isTrue);
      expect(find.byKey(const Key('composer-voice')), findsOneWidget);
      expect(find.byKey(const Key('voice-status')), findsNothing);
    });

    testWidgets('what is said in voice mode reaches the conversation', (
      tester,
    ) async {
      final rig = await _rig();
      final backend = await pumpSession(tester, rig);
      await tester.tap(find.byKey(const Key('composer-voice')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      backend.emit(
        const VoicePromptEvent(VoicePrompt(text: 'open the merge queue task')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(_prompts(rig).single, [
        {'type': 'text', 'text': 'open the merge queue task'},
      ]);
      // It shows as a caption there, and as the person's message in the
      // conversation behind it.
      expect(find.text('open the merge queue task'), findsWidgets);
      expect(
        rig.app
            .sessionController('s1')
            .transcript
            .items
            .any(
              (item) => item.isUser && item.text == 'open the merge queue task',
            ),
        isTrue,
      );
      // The turn this started runs to its end before the test does.
      await _settle(tester);
    });
  });

  group('a conversation opened for a walkthrough', () {
    testWidgets('opens voice mode by itself, and once', (tester) async {
      final rig = await _rig();
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final backend = FakeBackend();
      await tester.pumpWidget(
        HarnessStyle(
          style: HarnessPlatformStyle.material,
          child: HarnessScope(
            app: rig.app,
            settings: rig.settings,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: HarnessTheme.material(Brightness.light),
              home: SessionScreen(
                sessionId: 's1',
                startVoice: true,
                voiceBackendFactory: (settings, address) => backend,
              ),
            ),
          ),
        ),
      );
      // The conversation loads, then voice mode opens by itself.
      for (var i = 0; i < 50; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        if (find.byKey(const Key('voice-status')).evaluate().isNotEmpty) {
          break;
        }
      }
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byKey(const Key('voice-status')), findsOneWidget);
      expect(backend.started, isTrue);
      // Voice mode says nothing of its own: the question of a walkthrough is
      // the report's, already on its way into this conversation.
      expect(_prompts(rig), isEmpty);

      // Ending goes back to the conversation, and voice mode stays closed:
      // it was opened once.
      await tester.tap(find.byKey(const Key('voice-close')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const Key('voice-status')), findsNothing);
      expect(_prompts(rig), isEmpty);
      await _settle(tester);
    });
  });
}
