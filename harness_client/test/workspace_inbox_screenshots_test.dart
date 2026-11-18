// Pictures of a workspace inbox and of the provenance a moved message
// carries: the sheet that shows what waits in each thread, and the lines
// that say where a message came from and where a reassignment sent it.
//
//   HARNESS_SHOTS=/some/directory flutter test test/workspace_inbox_screenshots_test.dart
//
// writes `workspace-inbox.png`, `workspace-inbox-all.png`,
// `workspace-inbox-empty.png` and `workspace-provenance.png`.  Without
// HARNESS_SHOTS the cases still draw and check that nothing overflows, and
// write nothing.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/models/workspace.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:harness_client/src/state/workspace_controller.dart';
import 'package:harness_client/src/ui/adaptive/platform_style.dart';
import 'package:harness_client/src/ui/screens/workspace_screen.dart';
import 'package:harness_client/src/ui/theme/harness_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';
import 'support/phone_fonts.dart';
import 'support/real_fonts.dart';

WorkspaceSummary _workspace() => const WorkspaceSummary(
  id: 'w1',
  name: 'Home',
  lastThread: 't1',
  threads: [
    WorkspaceThread(id: 't1', title: 'Kitchen renovation', state: 'live'),
    WorkspaceThread(id: 't2', title: 'Harness memory'),
  ],
);

/// A workspace whose timeline holds a routed message, a reassignment line
/// and a message a reassignment moved, so every provenance label is drawn.
WorkspaceController _preview() => WorkspaceController.preview(
  workspace: _workspace(),
  entries: const [
    WorkspaceEntry(
      kind: 'divider',
      thread: 't1',
      title: 'Kitchen renovation',
      reason: 'new-thread',
    ),
    WorkspaceEntry(
      kind: 'message',
      thread: 't1',
      role: 'user',
      text: 'The tile is matte.',
    ),
    WorkspaceEntry(
      kind: 'message',
      thread: 't1',
      role: 'assistant',
      text: 'Noted: matte tile, and the grout to match.',
    ),
    WorkspaceEntry(
      kind: 'reassignment',
      thread: 't2',
      origin: 't1',
      handling: 't2',
      delivery: 'queued',
    ),
    WorkspaceEntry(
      kind: 'message',
      thread: 't2',
      role: 'user',
      text: 'Remember the grout.',
      origin: 't1',
      handling: 't2',
      profile: 'voice',
      reassignedTo: 't2',
      reassignedBy: 'mediator',
    ),
  ],
);

WorkspaceInbox _inbox() => WorkspaceInbox.fromWire({
  'workspace': 'w1',
  'name': 'Home',
  'scope': 'workspace',
  'items': [
    {
      'session': 's1',
      'workspace': 'w1',
      'workspace-name': 'Home',
      'thread': 't1',
      'title': 'Kitchen renovation',
      'text': 'Try the slate.',
      'state': 'queued',
    },
    {
      'session': 's1',
      'workspace': 'w1',
      'workspace-name': 'Home',
      'thread': 't1',
      'title': 'Kitchen renovation',
      'text': 'And the grout.',
      'state': 'waiting',
    },
    {
      'session': 's9',
      'workspace': 'w1',
      'workspace-name': 'Home',
      'thread': 't2',
      'title': 'Harness memory',
      'text': '',
      'state': 'unavailable',
      'why': 'Session unavailable',
    },
  ],
  'counts': {'queued': 1, 'waiting': 1, 'unavailable': 1},
});

class _Rig {
  _Rig(this.settings, this.app);
  final SettingsController settings;
  final AppController app;
}

Future<_Rig> _connected() async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsController();
  await settings.load();
  final harness = FakeHarness(workspace: true);
  final app = AppController(settings: settings, connector: harness.connector);
  addTearDown(app.dispose);
  await app.connect('ws://memory/acp');
  return _Rig(settings, app);
}

Future<void> _settle(WidgetTester tester, [int rounds = 20]) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

Future<ui.Image> _picture(WidgetTester tester, GlobalKey frame) async {
  final image = await tester.runAsync(() async {
    final boundary =
        frame.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    return boundary.toImage(pixelRatio: 2);
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

Future<GlobalKey> _pump(
  WidgetTester tester,
  _Rig rig,
  WorkspaceController controller, {
  required double width,
  required double height,
  required double ratio,
}) async {
  tester.view.physicalSize = Size(width * ratio, height * ratio);
  tester.view.devicePixelRatio = ratio;
  tester.view.viewPadding = FakeViewPadding(
    top: 24 * ratio,
    bottom: 24 * ratio,
  );
  tester.view.padding = tester.view.viewPadding;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPadding);
  addTearDown(tester.view.resetViewPadding);
  final frame = GlobalKey();
  await tester.pumpWidget(
    RepaintBoundary(
      key: frame,
      child: HarnessStyle(
        style: HarnessPlatformStyle.material,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: phoneFonts(HarnessTheme.material(Brightness.light)),
          home: WorkspaceScreen(
            app: rig.app,
            controller: controller,
            onOpenSession: (_) {},
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await _settle(tester);
  return frame;
}

Future<void> _shot(
  WidgetTester tester,
  GlobalKey frame,
  String? directory,
  String name,
) async {
  if (directory == null) return;
  final image = await _picture(tester, frame);
  await _write(tester, image, '$directory/$name');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final shots = Platform.environment['HARNESS_SHOTS'];

  setUpAll(() async {
    await loadRealFonts();
  });

  testWidgets('draws the inbox with a queued, a waiting and an unavailable item', (
    tester,
  ) async {
    final rig = await _connected();
    final controller = _preview();
    controller.inbox = _inbox();
    final frame = await _pump(
      tester,
      rig,
      controller,
      width: 412,
      height: 915,
      ratio: 2.625,
    );
    await tester.tap(find.byKey(const ValueKey('inbox-header')));
    await tester.pumpAndSettle();
    expect(find.text('Inbox · Home'), findsOneWidget);
    expect(find.text('Queued'), findsOneWidget);
    expect(find.text('Waiting'), findsOneWidget);
    expect(find.text('Unavailable'), findsOneWidget);
    expect(find.text('Session unavailable'), findsOneWidget);
    expect(find.text('Try the slate.'), findsOneWidget);
    expect(find.text('1 queued · 1 waiting · 1 unavailable'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _shot(tester, frame, shots, 'workspace-inbox.png');
    await _settle(tester, 30);
  });

  testWidgets('draws an inbox with nothing waiting', (tester) async {
    final rig = await _connected();
    final controller = _preview();
    controller.inbox = const WorkspaceInbox();
    final frame = await _pump(
      tester,
      rig,
      controller,
      width: 412,
      height: 915,
      ratio: 2.625,
    );
    await tester.tap(find.byKey(const ValueKey('inbox-header')));
    await tester.pumpAndSettle();
    expect(find.text('No messages waiting'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _shot(tester, frame, shots, 'workspace-inbox-empty.png');
    await _settle(tester, 30);
  });

  testWidgets('draws the all scope, where a row names its workspace', (
    tester,
  ) async {
    final rig = await _connected();
    final controller = _preview();
    controller.inboxScope = 'all';
    controller.inbox = WorkspaceInbox.fromWire({
      'workspace': 'w1',
      'name': 'Home',
      'scope': 'all',
      'items': [
        {
          'session': 's1',
          'workspace': 'w1',
          'workspace-name': 'Home',
          'thread': 't1',
          'title': 'Kitchen renovation',
          'text': 'Try the slate.',
          'state': 'queued',
        },
        {
          'session': 's2',
          'workspace': 'w2',
          'workspace-name': 'Studio',
          'thread': 't3',
          'title': 'Harness memory',
          'text': 'Remember the grout.',
          'state': 'waiting',
        },
      ],
      'counts': {'queued': 1, 'waiting': 1, 'unavailable': 0},
    });
    final frame = await _pump(
      tester,
      rig,
      controller,
      width: 412,
      height: 915,
      ratio: 2.625,
    );
    await tester.tap(find.byKey(const ValueKey('inbox-header')));
    await tester.pumpAndSettle();
    expect(find.text('Inbox · Home'), findsOneWidget);
    expect(find.text('Kitchen renovation'), findsWidgets);
    expect(find.text('Home · Kitchen renovation'), findsNothing);
    expect(find.text('Studio · Harness memory'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _shot(tester, frame, shots, 'workspace-inbox-all.png');
    await _settle(tester, 30);
  });

  testWidgets('draws where a message came from and where it went', (
    tester,
  ) async {
    final rig = await _connected();
    final controller = _preview();
    final frame = await _pump(
      tester,
      rig,
      controller,
      width: 412,
      height: 915,
      ratio: 2.625,
    );
    expect(find.text('From Kitchen renovation · voice'), findsOneWidget);
    expect(
      find.text('Reassigned to Harness memory · mediator'),
      findsOneWidget,
    );
    expect(
      find.text(
        'Reassigned from Kitchen renovation to Harness memory · queued',
      ),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('reassign-message')), findsWidgets);
    expect(tester.takeException(), isNull);
    await _shot(tester, frame, shots, 'workspace-provenance.png');
    await _settle(tester, 30);
  });
}
