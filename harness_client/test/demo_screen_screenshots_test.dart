// Pictures of the demo a report hands in: the report page that starts it,
// and the page it opens on a phone and on a desktop, with the real RFB
// client over a synthetic server in memory.
//
//   HARNESS_SHOTS=/some/directory flutter test test/demo_screen_screenshots_test.dart
//
// writes a PNG for each case.  Without HARNESS_SHOTS the cases still run
// (they draw, and check that nothing overflows and that the page is whole on
// the screen), and write nothing.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/models/tool_display.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:harness_client/src/ui/adaptive/platform_style.dart';
import 'package:harness_client/src/ui/app_scope.dart';
import 'package:harness_client/src/ui/screens/demo_screen.dart';
import 'package:harness_client/src/ui/screens/hand_in_report_screen.dart';
import 'package:harness_client/src/ui/theme/harness_theme.dart';
import 'package:harness_client/src/vnc/rfb.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';
import 'support/fake_rfb.dart';
import 'support/handed_in_task.dart';
import 'support/real_fonts.dart';
import 'support/report_flows.dart';
import 'support/voice_fakes.dart';

const _phoneWidth = 360.0;
const _phoneHeight = 800.0;
const _desktopWidth = 1280.0;
const _desktopHeight = 900.0;

/// The phone's frame as a picture.
Future<ui.Image> _picture(WidgetTester tester, GlobalKey frame) async {
  final image = await tester.runAsync(() async {
    final boundary =
        frame.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    return boundary.toImage(pixelRatio: 1.5);
  });
  return image!;
}

Future<void> _write(WidgetTester tester, ui.Image image, String path) async {
  await tester.runAsync(() async {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File(path);
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(data!.buffer.asUint8List());
  });
}

/// A report with one demo, opened in the app's scope: the page a tap on
/// *View report* shows, and the demo its *Start demo* opens.
class _Rig {
  _Rig(this.settings, this.harness, this.app);

  final SettingsController settings;
  final FakeHarness harness;
  final AppController app;
}

Future<_Rig> _rig({List<Map<String, Object?>>? demoAnswers}) async {
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
  if (demoAnswers != null) harness.demoAnswers = demoAnswers;
  final app = AppController(settings: settings, connector: harness.connector);
  await app.connect('ws://memory/acp');
  return _Rig(settings, harness, app);
}

final _report = HandInReport.fromWire({
  'problem': 'The top spins the wrong way',
  'summary': 'It spins the right way now.',
  'evidence': [
    {
      'kind': 'demo',
      'id': 'demo-1',
      'title': 'A spinning top',
      'name': 'demo/index.html',
      'narration': 'Watch it spin.',
    },
  ],
});

/// [HandInReportScreen] in the scope of [rig]'s app, as a phone or a desktop
/// draws it.
Future<GlobalKey> _openReport(
  WidgetTester tester,
  _Rig rig, {
  required double width,
  required double height,
  RfbTransport Function(String url)? vncTransportFactory,
}) async {
  tester.view.physicalSize = Size(width * 2, height * 2);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final frame = GlobalKey();
  await tester.pumpWidget(
    RepaintBoundary(
      key: frame,
      child: HarnessScope(
        app: rig.app,
        settings: rig.settings,
        child: HarnessStyle(
          style: HarnessPlatformStyle.material,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: HarnessTheme.material(Brightness.light),
            home: HandInReportScreen(
              report: _report,
              sessionId: 's-task',
              voiceBackendFactory: (settings, address) => FakeBackend(),
              vncTransportFactory: vncTransportFactory,
            ),
          ),
        ),
      ),
    ),
  );
  await settle(tester, 6);
  return frame;
}

void main() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  final shots = Platform.environment['HARNESS_SHOTS'];
  final real = await loadRealFonts();
  String path(String name) => '$shots/$name${real ? '' : '-ahem'}.png';

  testWidgets('draws the report page with Start demo', (tester) async {
    final frame = await openApp(
      tester,
      seed: seedDesignReport,
      width: _phoneWidth,
      height: _phoneHeight,
      ratio: 2,
    );
    await viewReport(tester, handedInTaskName);
    expect(find.text('Start demo'), findsOneWidget);
    expect(find.byKey(const Key('report-start-demo')), findsOneWidget);
    expect(tester.takeException(), isNull);
    if (shots != null) {
      await _write(tester, await _picture(tester, frame), path('demo-report'));
    }
  });

  testWidgets('draws a demo on a phone: the screen and the presenter', (
    tester,
  ) async {
    final rig = await _rig();
    final frame = await _openReport(
      tester,
      rig,
      width: _phoneWidth,
      height: _phoneHeight,
      vncTransportFactory: (_) => FakeRfbTransport(),
    );
    await tester.tap(find.byKey(const Key('report-start-demo')));
    await settle(tester, 20);
    for (var i = 0; i < 120; i++) {
      if (find.byKey(const Key('vnc-picture')).evaluate().isNotEmpty) break;
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      });
      await tester.pump();
    }
    expect(find.byType(DemoScreen), findsOneWidget);
    expect(find.byKey(const Key('vnc-picture')), findsOneWidget);
    expect(find.byKey(const Key('demo-presenter')), findsOneWidget);
    expect(find.text('Screen'), findsOneWidget);
    expect(find.text('Talk'), findsOneWidget);
    expect(tester.takeException(), isNull);
    final screen = tester.getRect(find.byKey(const Key('demo-screen')));
    expect(screen.left, greaterThanOrEqualTo(0));
    expect(screen.right, lessThanOrEqualTo(_phoneWidth + 0.01));
    if (shots != null) {
      await _write(
        tester,
        await _picture(tester, frame),
        path('demo-screen-phone'),
      );
    }
  });

  testWidgets('draws a demo with no screen', (tester) async {
    final rig = await _rig(
      demoAnswers: [
        {
          'state': 'running',
          'run': 'run-1',
          'demo': 'demo-1',
          'title': 'A spinning top',
          'placement': 'workspace',
          'vnc': {
            'url': null,
            'socket': null,
            'available': false,
            'reason': {
              'code': 'vnc-unavailable',
              'text': 'workspace computer not running',
            },
          },
          'control': 'agent',
          'presenter': {'session': 's-demo', 'name': 'demo: A spinning top'},
        },
      ],
    );
    final frame = await _openReport(
      tester,
      rig,
      width: _phoneWidth,
      height: _phoneHeight,
    );
    await tester.tap(find.byKey(const Key('report-start-demo')));
    await settle(tester, 20);
    expect(find.text('No screen'), findsOneWidget);
    expect(find.text('workspace computer not running'), findsOneWidget);
    expect(tester.takeException(), isNull);
    if (shots != null) {
      await _write(
        tester,
        await _picture(tester, frame),
        path('demo-no-screen'),
      );
    }
  });

  testWidgets('draws a demo on a desktop: the presenter beside the screen', (
    tester,
  ) async {
    final rig = await _rig();
    final frame = await _openReport(
      tester,
      rig,
      width: _desktopWidth,
      height: _desktopHeight,
      vncTransportFactory: (_) => FakeRfbTransport(),
    );
    await tester.tap(find.byKey(const Key('report-start-demo')));
    await settle(tester, 20);
    for (var i = 0; i < 120; i++) {
      if (find.byKey(const Key('vnc-picture')).evaluate().isNotEmpty) break;
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      });
      await tester.pump();
    }
    expect(find.byKey(const Key('demo-presenter')), findsOneWidget);
    final screen = tester.getRect(find.byKey(const Key('demo-screen')));
    final panel = tester.getRect(find.byKey(const Key('demo-presenter')));
    expect(screen.right, lessThanOrEqualTo(panel.left + 0.01));
    expect(panel.width, greaterThanOrEqualTo(320));
    expect(screen.left, greaterThanOrEqualTo(0));
    expect(panel.right, lessThanOrEqualTo(_desktopWidth + 0.01));
    expect(tester.takeException(), isNull);
    if (shots != null) {
      await _write(
        tester,
        await _picture(tester, frame),
        path('demo-screen-desktop'),
      );
    }
  });
}
