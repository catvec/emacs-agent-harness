// The page of a running demo: the workspace computer's screen (the real RFB
// client over a transport the test scripts), the takeover between the
// presenter and the person, and the presenter's voice and field.
//
// No network, no microphone: the RFB server is `FakeRfbTransport`, and the
// voice backend is a scripted one.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/models/demo_session.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:harness_client/src/ui/adaptive/platform_style.dart';
import 'package:harness_client/src/ui/app_scope.dart';
import 'package:harness_client/src/ui/screens/demo_screen.dart';
import 'package:harness_client/src/ui/theme/harness_theme.dart';
import 'package:harness_client/src/voice/voice_controller.dart';
import 'package:harness_client/src/voice/voice_settings.dart';
import 'package:harness_client/src/vnc/rfb.dart';
import 'package:harness_client/src/vnc/vnc_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';
import 'support/fake_rfb.dart';
import 'support/voice_fakes.dart';

Future<void> _settle(WidgetTester tester, [int rounds = 10]) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

/// The frames of the real RFB client decoded: the test engine decodes a
/// picture on real time, not on the test's clock.
Future<void> _settlePicture(WidgetTester tester) async {
  final picture = find.byKey(const Key('vnc-picture'));
  for (var i = 0; i < 120 && picture.evaluate().isEmpty; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
}

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
  harness.sessions['s-demo'] = {
    'id': 's-demo',
    'name': 'demo: A spinning top',
    'kind': 'main',
    'project': '/harness',
    'cwd': '/harness',
    'model': 'claude:claude-fable-5-1',
    'permissionMode': 'ask',
    'status': 'idle',
    'created': DateTime.now().millisecondsSinceEpoch / 1000,
    'updated': DateTime.now().millisecondsSinceEpoch / 1000,
    'contextWindow': 200000,
    'todos': [],
    'pending': [],
    'queue': [],
  };
  harness.nodes['s-demo'] = [
    {
      'id': 'a-demo-history',
      'kind': 'assistant',
      'content': 'Welcome to the top.',
      'ts': DateTime.now().millisecondsSinceEpoch / 1000,
    },
  ];
  final app = AppController(settings: settings, connector: harness.connector);
  await app.connect('ws://memory/acp');
  return _Rig(settings, harness, app);
}

const _vnc = {
  'url': 'http://127.0.0.1:6080/vnc.html',
  'socket': 'ws://127.0.0.1:5901/websockify',
  'state': 'agent',
  'available': true,
  'reason': null,
};

DemoSession _session({
  String state = 'running',
  Object? vnc = _vnc,
  String? placement = 'workspace',
  Map<String, Object?>? launch,
  String? commit = 'abc1234',
  bool? commitVerified = true,
  Object? presenter = const {
    'session': 's-demo',
    'name': 'demo: A spinning top',
  },
}) => DemoSession.fromWire({
  'state': state,
  'run': 'run-1',
  'task': 'task-1',
  'demo': 'demo-1',
  'title': 'A spinning top',
  'control': 'agent',
  if (commit != null) 'commit': commit,
  if (commitVerified != null) 'commit-verified': commitVerified,
  if (placement != null) 'placement': placement,
  if (vnc != null) 'vnc': vnc,
  if (launch != null) 'launch': launch,
  if (presenter != null) 'presenter': presenter,
});

/// The page, on a phone of 360 by 800 points, opened as a tap on a report
/// opens it: a route over the page it was come from.
Future<void> _open(
  WidgetTester tester,
  _Rig rig,
  DemoSession session, {
  VoiceBackendFactory? voiceBackendFactory,
  RfbTransport Function(String url)? vncTransportFactory,
}) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    HarnessScope(
      app: rig.app,
      settings: rig.settings,
      child: HarnessStyle(
        style: HarnessPlatformStyle.material,
        child: MaterialApp(
          theme: HarnessTheme.material(Brightness.light),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  key: const Key('open-demo'),
                  onPressed: () => DemoScreen.show(
                    context,
                    session,
                    voiceBackendFactory: voiceBackendFactory,
                    vncTransportFactory: vncTransportFactory,
                  ),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const Key('open-demo')));
  await _settle(tester, 20);
}

/// The run a page opened directly on is one the harness knows: `demo/status`
/// answers with what the page was opened on, as it would for a run it started.
void _seedRun(_Rig rig, DemoSession session) {
  final base = rig.harness.demoAnswers.first;
  final vnc = session.vnc;
  rig.harness.demoRuns[session.run!] = {
    ...base,
    'state': session.state,
    'run': session.run,
    'control': session.control ?? base['control'],
    if (vnc == null)
      'vnc': null
    else
      'vnc': {
        'url': vnc.url,
        'socket': vnc.socket,
        'state': vnc.state,
        'available': vnc.available,
        'reason': null,
      },
  };
}

void main() {
  testWidgets('a running demo draws the workspace computer\'s screen', (
    tester,
  ) async {
    final rig = await _rig();
    final transport = FakeRfbTransport();
    final urls = <String>[];
    await _open(
      tester,
      rig,
      _session(),
      vncTransportFactory: (url) {
        urls.add(url);
        return transport;
      },
    );
    await _settlePicture(tester);

    // The socket, put on the harness this device is signed in to: the page
    // of the box beside it is never opened as the screen.
    expect(urls.single, 'ws://memory/websockify');
    expect(find.byKey(const Key('demo-screen')), findsOneWidget);
    expect(find.byKey(const Key('vnc-picture')), findsOneWidget);
    expect(transport.sentFrame, isTrue);
    expect(find.text('Screen'), findsOneWidget);
    expect(find.text('Demo running'), findsOneWidget);
    expect(find.text('Control · agent'), findsOneWidget);
    expect(find.text('Presenter driving'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a run with no screen says so, in the harness\'s words', (
    tester,
  ) async {
    final rig = await _rig();
    await _open(
      tester,
      rig,
      _session(
        vnc: {
          'url': null,
          'available': false,
          'reason': {
            'code': 'vnc-unavailable',
            'text': 'workspace computer not running',
          },
        },
      ),
    );
    expect(find.text('No screen'), findsOneWidget);
    expect(find.text('workspace computer not running'), findsOneWidget);
    expect(find.byKey(const Key('vnc-picture')), findsNothing);
    expect(find.byKey(const Key('demo-control')), findsNothing);
  });

  testWidgets('a box that offers a page but no socket has no screen', (
    tester,
  ) async {
    final rig = await _rig();
    var asked = false;
    await _open(
      tester,
      rig,
      _session(
        vnc: {
          'url': 'http://127.0.0.1:6080/vnc.html',
          'socket': null,
          'available': true,
          'reason': null,
        },
      ),
      vncTransportFactory: (_) {
        asked = true;
        return FakeRfbTransport();
      },
    );
    expect(find.text('No screen'), findsOneWidget);
    expect(find.text('VNC unavailable'), findsOneWidget);
    expect(asked, isFalse, reason: 'a page is not a socket');
  });

  testWidgets('a demo on the harness\'s machine names it and its command', (
    tester,
  ) async {
    final rig = await _rig();
    await _open(
      tester,
      rig,
      _session(
        vnc: null,
        placement: 'host',
        launch: {
          'command': ['python3', 'serve.py'],
          'cwd': 'demo',
          'box-cwd': '/home/box/work/demo',
        },
      ),
    );
    expect(find.text('On the harness machine'), findsOneWidget);
    expect(find.text('python3 serve.py'), findsOneWidget);
    expect(find.text('No screen'), findsNothing);
  });

  testWidgets('names the commit only when the harness verified it', (
    tester,
  ) async {
    final rig = await _rig();
    await _open(
      tester,
      rig,
      _session(),
      vncTransportFactory: (_) => FakeRfbTransport(),
    );
    expect(find.text('Commit abc1234'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await _open(
      tester,
      rig,
      _session(commitVerified: false),
      vncTransportFactory: (_) => FakeRfbTransport(),
    );
    expect(find.text('Commit abc1234'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await _open(
      tester,
      rig,
      _session(commitVerified: null),
      vncTransportFactory: (_) => FakeRfbTransport(),
    );
    expect(find.text('Commit abc1234'), findsNothing);
  });

  testWidgets('the takeover pill gives control to the person and back', (
    tester,
  ) async {
    final rig = await _rig();
    await _open(tester, rig, _session());
    expect(find.text('Control · agent'), findsOneWidget);
    expect(find.text('Control · you'), findsNothing);

    await tester.tap(find.byKey(const Key('demo-control')));
    await _settle(tester, 4);
    expect(rig.harness.calls('_harness/demo/control').single, {
      'run': 'run-1',
      'control': 'user',
    });
    expect(find.text('Control · you'), findsOneWidget);
    expect(find.text('Presenter driving'), findsNothing);

    await tester.tap(find.byKey(const Key('demo-control')));
    await _settle(tester, 4);
    expect(rig.harness.calls('_harness/demo/control').last, {
      'run': 'run-1',
      'control': 'agent',
    });
    expect(find.text('Control · agent'), findsOneWidget);
    expect(find.text('Presenter driving'), findsOneWidget);
  });

  testWidgets('the computer takes no input while the presenter drives', (
    tester,
  ) async {
    final rig = await _rig();
    final transport = FakeRfbTransport();
    await _open(tester, rig, _session(), vncTransportFactory: (_) => transport);
    await _settlePicture(tester);
    int pointers() => transport.sent
        .where((message) => message.isNotEmpty && message[0] == 5)
        .length;
    final at = tester.getCenter(find.byType(VncView));

    await tester.tapAt(at);
    await _settle(tester, 2);
    expect(pointers(), 0, reason: 'the agent has the pointer');

    await tester.tap(find.byKey(const Key('demo-control')));
    await _settle(tester, 4);
    await tester.tapAt(at);
    await _settle(tester, 2);
    expect(pointers(), greaterThan(0));
  });

  testWidgets('the dock hears the presenter and interrupts it', (tester) async {
    final rig = await _rig();
    final backend = FakeBackend();
    await _open(
      tester,
      rig,
      _session(),
      voiceBackendFactory: (settings, address) => backend,
    );
    rig.harness.stream('s-demo', {
      'id': 'a-demo-1',
      'kind': 'assistant',
      'content': 'The top spins clockwise.',
      'ts': DateTime.now().millisecondsSinceEpoch / 1000,
    });
    await _settle(tester, 8);
    expect(find.textContaining('The top spins clockwise.'), findsOneWidget);
    expect(find.byKey(const Key('demo-presenter')), findsOneWidget);

    await tester.tap(find.byKey(const Key('demo-talk')));
    await _settle(tester, 4);
    expect(backend.started, isTrue);
    expect(find.text('Listening'), findsOneWidget);

    await tester.tap(find.byKey(const Key('demo-interrupt')));
    await _settle(tester, 4);
    expect(backend.interrupts, 1);
    expect(find.text('Interrupted'), findsOneWidget);
  });

  testWidgets('a presenter whose voice is not set up says so, and offers the '
      'way to set it up', (tester) async {
    final rig = await _rig();
    await rig.settings.setVoiceSettings(
      const VoiceSettings(provider: VoiceProvider.live),
    );
    await _open(tester, rig, _session());
    expect(find.text('Voice not set up'), findsOneWidget);
    expect(find.text('Set up'), findsOneWidget);
    expect(find.text('Narration'), findsNothing);
  });

  testWidgets('the field sends a direction to the presenter\'s session', (
    tester,
  ) async {
    final rig = await _rig();
    await _open(tester, rig, _session());
    await tester.enterText(
      find.byKey(const Key('demo-ask')),
      'Turn it to the left.',
    );
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await _settle(tester, 8);

    final prompt = rig.harness.requests
        .where(
          (request) =>
              request.$1 == 'session/prompt' &&
              request.$2['sessionId'] == 's-demo',
        )
        .single;
    expect(prompt.$2['prompt'], [
      {'type': 'text', 'text': 'Turn it to the left.'},
    ]);
    final field = tester.widget<TextField>(find.byKey(const Key('demo-ask')));
    expect(field.controller!.text, isEmpty);
  });

  testWidgets('Stop demo sends one stop, for this run, and leaves the page', (
    tester,
  ) async {
    final rig = await _rig();
    final gate = Completer<void>();
    rig.harness.demoStopGate = gate.future;
    await _open(tester, rig, _session());

    await tester.tap(find.byKey(const Key('demo-stop')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('demo-stop')));
    await tester.pump();
    expect(rig.harness.calls('_harness/demo/stop').length, 1);
    expect(rig.harness.calls('_harness/demo/stop').single, {'run': 'run-1'});

    gate.complete();
    await _settle(tester, 12);
    expect(find.byType(DemoScreen), findsNothing);
    expect(find.byKey(const Key('open-demo')), findsOneWidget);
  });

  testWidgets('leaving the page does not stop the demo', (tester) async {
    final rig = await _rig();
    await _open(tester, rig, _session());
    await tester.pageBack();
    await _settle(tester, 8);
    expect(find.byType(DemoScreen), findsNothing);
    expect(rig.harness.calls('_harness/demo/stop'), isEmpty);
  });

  testWidgets('a dropped screen says so, and a run that is gone is stopped', (
    tester,
  ) async {
    final rig = await _rig();
    final session = _session();
    _seedRun(rig, session);
    final transport = FakeRfbTransport();
    await _open(tester, rig, session, vncTransportFactory: (_) => transport);
    await _settlePicture(tester);

    transport.drop();
    await _settle(tester, 6);
    expect(find.text('Connection lost'), findsOneWidget);
    expect(find.text('Reconnecting'), findsWidgets);
    expect(find.byKey(const Key('demo-reconnect')), findsOneWidget);

    rig.harness.demoGone = true;
    await tester.tap(find.byKey(const Key('demo-reconnect')));
    await _settle(tester, 12);
    expect(rig.harness.calls('_harness/demo/status').single, {'run': 'run-1'});
    expect(find.text('Demo stopped'), findsWidgets);
    expect(find.byKey(const Key('demo-reconnect')), findsNothing);
    expect(find.text('No screen'), findsOneWidget);
  });

  testWidgets('a dropped screen comes back when the run does', (tester) async {
    final rig = await _rig();
    final session = _session();
    _seedRun(rig, session);
    final transports = <FakeRfbTransport>[];
    await _open(
      tester,
      rig,
      session,
      vncTransportFactory: (_) {
        final transport = FakeRfbTransport();
        transports.add(transport);
        return transport;
      },
    );
    await _settlePicture(tester);
    transports.single.drop();
    await _settle(tester, 6);
    expect(find.byKey(const Key('demo-reconnect')), findsOneWidget);

    await tester.tap(find.byKey(const Key('demo-reconnect')));
    await _settle(tester, 8);
    await _settlePicture(tester);
    expect(transports.length, 2);
    expect(transports.last.sentFrame, isTrue);
    expect(find.byKey(const Key('vnc-picture')), findsOneWidget);
    expect(find.text('Connection lost'), findsNothing);
  });

  testWidgets('a stop that fails says so and stays', (tester) async {
    final rig = await _rig();
    rig.harness.failDemoStop = 'the box did not answer';
    await _open(tester, rig, _session());
    await tester.tap(find.byKey(const Key('demo-stop')));
    await _settle(tester, 8);
    expect(find.byType(DemoScreen), findsOneWidget);
    expect(find.text('Stop failure'), findsOneWidget);
  });
}
