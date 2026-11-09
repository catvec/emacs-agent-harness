// Starting a demo from a task's report: what is sent, what a run that does
// not start says on the page, and the page a run that does start opens.
//
// The harness is the in-memory one; nothing here opens a socket or a
// microphone.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/models/tool_display.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:harness_client/src/ui/adaptive/platform_style.dart';
import 'package:harness_client/src/ui/app_scope.dart';
import 'package:harness_client/src/ui/screens/demo_screen.dart';
import 'package:harness_client/src/ui/screens/hand_in_report_screen.dart';
import 'package:harness_client/src/ui/theme/harness_theme.dart';
import 'package:harness_client/src/voice/voice_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';
import 'support/voice_fakes.dart';

/// Time passes, [rounds] frames of 120 ms.
Future<void> _settle(WidgetTester tester, [int rounds = 12]) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

class _Rig {
  _Rig(this.settings, this.harness, this.app);

  final SettingsController settings;
  final FakeHarness harness;
  final AppController app;
}

Future<_Rig> _rig({bool demo = true}) async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsController();
  await settings.load();
  final harness = FakeHarness(demo: demo);
  _seedPresenter(harness);
  final app = AppController(settings: settings, connector: harness.connector);
  await app.connect('ws://memory/acp');
  return _Rig(settings, harness, app);
}

/// The session the demo answers say presents it, with a line the agent wrote
/// before the page opened.
void _seedPresenter(FakeHarness harness, {String id = 's-demo'}) {
  harness.sessions[id] = {
    'id': id,
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
  harness.nodes[id] = [
    {
      'id': 'a-demo-history',
      'kind': 'assistant',
      'content': 'Welcome to the top.',
      'ts': DateTime.now().millisecondsSinceEpoch / 1000,
    },
  ];
}

HandInReport _report({List<Map<String, Object?>>? evidence}) =>
    HandInReport.fromWire({
      'problem': 'The top spins the wrong way',
      'summary': 'It spins the right way now.',
      'evidence':
          evidence ??
          [
            {
              'kind': 'demo',
              'id': 'demo-1',
              'title': 'A spinning top',
              'name': 'demo/index.html',
              'narration': 'Watch it spin.',
            },
            {'kind': 'note', 'text': 'A note beside the demo.'},
          ],
    });

Future<void> _pumpReport(
  WidgetTester tester,
  _Rig rig,
  HandInReport report, {
  String? sessionId = 's-task',
  VoiceBackendFactory? voiceBackendFactory,
}) async {
  tester.view.physicalSize = const Size(1170, 2532);
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
          home: HandInReportScreen(
            report: report,
            sessionId: sessionId,
            voiceBackendFactory: voiceBackendFactory,
          ),
        ),
      ),
    ),
  );
  await _settle(tester, 4);
}

void main() {
  testWidgets('Start demo sends the report\'s session and the demo id, and '
      'opens the run on its own page', (tester) async {
    final rig = await _rig();
    await _pumpReport(tester, rig, _report());
    expect(find.text('Start demo'), findsOneWidget);

    await tester.tap(find.byKey(const Key('report-start-demo')));
    await _settle(tester, 20);

    final start = rig.harness.requests
        .where((request) => request.$1 == '_harness/demo/start')
        .single;
    expect(start.$2, {'session': 's-task', 'demo': 'demo-1'});
    final screen = tester.widget<DemoScreen>(find.byType(DemoScreen));
    // What `demo/start` answered is what the page has: the run's screen and
    // the workspace it runs in.
    expect(screen.session.workspace, 'w-kitchen');
    expect(screen.session.run, 'run-1');
    expect(find.byKey(const Key('demo-screen')), findsOneWidget);
  });

  testWidgets('a second tap while a start is on its way starts nothing', (
    tester,
  ) async {
    final rig = await _rig();
    final gate = Completer<void>();
    rig.harness.demoStartGate = gate.future;
    await _pumpReport(tester, rig, _report());

    await tester.tap(find.byKey(const Key('report-start-demo')));
    await tester.pump();
    expect(find.text('Starting demo'), findsOneWidget);
    await tester.tap(find.byKey(const Key('report-start-demo')));
    await tester.pump();
    expect(
      rig.harness.calls('_harness/demo/start').length,
      1,
      reason: 'one request, however many taps',
    );

    gate.complete();
    await _settle(tester, 20);
    expect(find.byType(DemoScreen), findsOneWidget);
  });

  testWidgets('a demo that is missing says so on the page and stays there', (
    tester,
  ) async {
    final rig = await _rig();
    rig.harness.demoAnswers = [
      {
        'state': 'missing',
        'reason': {'code': 'no-demo', 'text': 'gone'},
      },
    ];
    await _pumpReport(tester, rig, _report());
    await tester.tap(find.byKey(const Key('report-start-demo')));
    await _settle(tester, 12);
    expect(find.byType(DemoScreen), findsNothing);
    expect(
      tester.widget<Text>(find.byKey(const Key('report-demo-state'))).data,
      'Demo not found',
    );
  });

  testWidgets('a demo that is not ready says so on the page and stays there', (
    tester,
  ) async {
    final rig = await _rig();
    rig.harness.demoAnswers = [
      {'state': 'not-ready'},
    ];
    await _pumpReport(tester, rig, _report());
    await tester.tap(find.byKey(const Key('report-start-demo')));
    await _settle(tester, 12);
    expect(find.byType(DemoScreen), findsNothing);
    expect(
      tester.widget<Text>(find.byKey(const Key('report-demo-state'))).data,
      'Not ready',
    );
  });

  testWidgets('a demo that is denied says so on the page and in a notice', (
    tester,
  ) async {
    final rig = await _rig();
    rig.harness.demoAnswers = [
      {
        'state': 'denied',
        'reason': {'code': 'denied', 'text': 'no leave'},
      },
    ];
    await _pumpReport(tester, rig, _report());
    await tester.tap(find.byKey(const Key('report-start-demo')));
    await _settle(tester, 12);
    expect(find.byType(DemoScreen), findsNothing);
    expect(find.byType(SnackBar), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('report-demo-state'))).data,
      'Access denied',
    );
    expect(find.text('Access denied'), findsNWidgets(2));
  });

  testWidgets('a demo that fails says so on the page and in a notice', (
    tester,
  ) async {
    final rig = await _rig();
    rig.harness.demoAnswers = [
      {
        'state': 'error',
        'reason': {'code': 'spawn-failed', 'text': 'no'},
      },
    ];
    await _pumpReport(tester, rig, _report());
    await tester.tap(find.byKey(const Key('report-start-demo')));
    await _settle(tester, 12);
    expect(find.byType(DemoScreen), findsNothing);
    expect(find.byType(SnackBar), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('report-demo-state'))).data,
      'Demo failure',
    );
    expect(find.text('Demo failure'), findsNWidgets(2));
  });

  testWidgets('a harness without demo/start offers no button', (tester) async {
    final rig = await _rig(demo: false);
    await _pumpReport(tester, rig, _report());
    expect(find.text('Start demo'), findsNothing);
    expect(find.byKey(const Key('report-start-demo')), findsNothing);
    expect(find.byKey(const Key('report-start-demo-menu')), findsNothing);
  });

  testWidgets('a report of no session offers no button', (tester) async {
    final rig = await _rig();
    await _pumpReport(tester, rig, _report(), sessionId: null);
    expect(find.byKey(const Key('report-start-demo')), findsNothing);
  });

  testWidgets('several demos are chosen by title from one menu', (
    tester,
  ) async {
    final rig = await _rig();
    await _pumpReport(
      tester,
      rig,
      _report(
        evidence: [
          {'kind': 'demo', 'title': 'A spinning top'},
          {'kind': 'demo', 'title': 'The report page'},
        ],
      ),
    );
    final menu = find.byKey(const Key('report-start-demo-menu'));
    expect(menu, findsOneWidget);
    expect(find.byKey(const Key('report-start-demo')), findsNothing);
    await tester.tap(menu);
    await _settle(tester, 6);
    await tester.tap(find.widgetWithText(ListTile, 'The report page'));
    await _settle(tester, 20);
    // A demo written without an id is named by its place among the demos.
    expect(rig.harness.calls('_harness/demo/start').single['demo'], 'demo-2');
    expect(find.byType(DemoScreen), findsOneWidget);
  });

  testWidgets('a voice backend of the page reaches the demo\'s presenter', (
    tester,
  ) async {
    final rig = await _rig();
    final backend = FakeBackend();
    await _pumpReport(
      tester,
      rig,
      _report(),
      voiceBackendFactory: (settings, address) => backend,
    );
    await tester.tap(find.byKey(const Key('report-start-demo')));
    await _settle(tester, 20);
    await tester.tap(find.byKey(const Key('demo-talk')));
    await _settle(tester, 4);
    expect(backend.started, isTrue);
  });
}
