// Pictures of the workspace on a phone and a desktop.
//
//   HARNESS_SHOTS=/some/directory flutter test test/workspace_screenshots_test.dart
//
// writes a PNG for each case there.  Without HARNESS_SHOTS the cases still
// draw, check that nothing overflows, and write nothing.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/models/workspace.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/interaction.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:harness_client/src/state/workspace_controller.dart';
import 'package:harness_client/src/ui/adaptive/platform_style.dart';
import 'package:harness_client/src/ui/app_scope.dart';
import 'package:harness_client/src/ui/screens/workspace_screen.dart';
import 'package:harness_client/src/ui/theme/harness_theme.dart';

import 'support/fake_rfb.dart';
import 'support/real_fonts.dart';

/// What a screenshot shows the live episode waiting on.
InteractionRequest _pendingPermission() => InteractionRequest(
  method: 'session/request_permission',
  params: {
    'sessionId': 's1',
    'toolCall': {
      'toolCallId': 'c-p1',
      'title': 'Read tasks.json',
      'kind': 'read',
      'rawInput': {
        'path': '/home/noah/documents/ai/emacs-agent-harness/.git/harness/tasks.json',
      },
    },
    'options': const [
      {'optionId': 'allow-once', 'name': 'Allow once', 'kind': 'allow_once'},
      {'optionId': 'deny-once', 'name': 'Deny', 'kind': 'reject_once'},
    ],
    '_harness': {'pendingId': 'p1', 'tool': 'read_file'},
  },
  sessionId: 's1',
  synthetic: true,
  pendingId: 'p1',
);

InteractionRequest _pendingQuestion() => InteractionRequest(
  method: '_harness/ask_user',
  params: {
    'sessionId': 's1',
    'requestId': 'q1',
    'question': 'The fabricator can template on Tuesday or Thursday. Which?',
    'options': const ['Tuesday', 'Thursday'],
  },
  sessionId: 's1',
  synthetic: true,
  pendingId: 'q1',
);

WorkspaceController _controller({
  List<InteractionRequest> pending = const [],
  String status = 'running',
}) {
  final workspace = WorkspaceSummary(
    id: 'w1',
    name: 'Home',
    lastThread: 't1',
    threads: [
      WorkspaceThread(
        id: 't1',
        title: 'Kitchen renovation',
        state: 'live',
        episodeStatus: status,
        live: 's1',
        pending: [
          for (final request in pending)
            WorkspacePendingRequest(
              id: request.pendingId ?? '',
              kind: request.isQuestion ? 'question' : 'permission',
              title: request.title,
            ),
        ],
        tags: const ['Kitchen', 'Budget'],
      ),
      const WorkspaceThread(
        id: 't2',
        title: 'Harness memory',
        tags: ['Harness', 'Memory'],
      ),
      const WorkspaceThread(
        id: 't3',
        title: 'Kitchen budget',
        tags: ['Kitchen', 'Budget'],
      ),
    ],
  );
  return WorkspaceController.preview(
    workspace: workspace,
    memory: const WorkspaceMemoryStatus(notes: 12, fullText: true),
    computer: const WorkspaceComputerStatus(
      available: true,
      running: true,
      state: 'running',
      control: 'agent',
      backend: 'local',
      socket: 'ws://memory/websockify',
      url: 'http://memory/vnc_lite.html',
      width: 1280,
      height: 800,
      isolation: 'local display and process',
      display: ':99',
      home: '/home/noah/.harness/workspace-box/w1/home',
      profile: '/home/noah/.harness/workspace-box/w1/browser',
      disk: 1572864,
    ),
    pending: pending,
    entries: const [
      WorkspaceEntry(
        kind: 'divider',
        thread: 't1',
        title: 'Kitchen renovation',
        reason: 'new-thread',
      ),
      WorkspaceEntry(kind: 'brief', thread: 't1', tokens: 1840),
      WorkspaceEntry(
        kind: 'message',
        thread: 't1',
        role: 'user',
        text: 'Let us go with quartz for the countertop.',
      ),
      WorkspaceEntry(
        kind: 'message',
        thread: 't1',
        role: 'assistant',
        text:
            'Noted. I updated Decision/Countertop and opened the quote task. '
            'The fabricator can template on Tuesday.',
      ),
      WorkspaceEntry(
        kind: 'message',
        thread: 't1',
        role: 'user',
        text: 'What did we decide about the backsplash?',
      ),
      WorkspaceEntry(
        kind: 'message',
        thread: 't1',
        role: 'assistant',
        text:
            'White subway tile, matte, 3x6. Decided 12 Oct, and the journal '
            'entry links the sample.',
      ),
      WorkspaceEntry(
        kind: 'message',
        thread: 't2',
        role: 'user',
        text: 'How is the memory task doing?',
      ),
    ],
  );
}

Future<(GlobalKey, WorkspaceController)> _show(
  WidgetTester tester, {
  required double width,
  required double height,
  double textScale = 1,
  WorkspaceController? controller,
}) async {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 24);
  tester.view.padding = tester.view.viewPadding;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPadding);
  addTearDown(tester.view.resetViewPadding);
  addTearDown(tester.view.resetViewInsets);

  final boundary = GlobalKey();
  final settings = SettingsController();
  final app = AppController(settings: settings);
  final shown = controller ?? _controller();
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
            home: MediaQuery(
              data: MediaQueryData(
                size: Size(width, height),
                textScaler: TextScaler.linear(textScale),
              ),
              child: WorkspaceScreen(
                app: app,
                controller: shown,
                onOpenSession: (_) {},
                vncTransportFactory: (_) =>
                    FakeRfbTransport(width: 640, height: 400),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  // The RFB client decodes the frame off the test's clock; let that image
  // arrive before a picture is taken, so the desk shows the screen.
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 120)),
  );
  await tester.pump();
  return (boundary, shown);
}

Future<void> _write(
  WidgetTester tester,
  GlobalKey boundary,
  String path,
) async {
  await tester.runAsync(() async {
    final object =
        boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await object.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File(path);
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  final shots = Platform.environment['HARNESS_SHOTS'];
  setUpAll(() async {
    await loadRealFonts();
  });

  testWidgets('workspace on a phone', (tester) async {
    final (boundary, _) = await _show(tester, width: 390, height: 844);
    expect(find.text('Kitchen renovation'), findsWidgets);
    expect(tester.takeException(), isNull);
    if (shots != null) {
      await _write(tester, boundary, '$shots/workspace-mobile.png');
    }
  });

  testWidgets('workspace computer on a phone', (tester) async {
    final (boundary, controller) = await _show(tester, width: 390, height: 844);
    await tester.tap(find.byTooltip('Computer'));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 80));
    }
    await tester.tap(find.text('Take over'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    if (shots != null) {
      await _write(tester, boundary, '$shots/workspace-mobile-takeover.png');
    }
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(controller.computer.userControl, isTrue);
    expect(find.text('Return control'), findsOneWidget);
  });

  testWidgets('workspace on a desktop', (tester) async {
    final (boundary, _) = await _show(tester, width: 1440, height: 900);
    expect(find.text('Threads'), findsOneWidget);
    expect(find.text('Computer'), findsOneWidget);
    expect(find.text('Concepts'), findsOneWidget);
    expect(tester.takeException(), isNull);
    if (shots != null) {
      await _write(tester, boundary, '$shots/workspace-desktop.png');
    }
  });

  testWidgets('workspace takeover on a desktop', (tester) async {
    final (boundary, controller) = await _show(
      tester,
      width: 1440,
      height: 900,
    );
    await tester.tap(find.text('Take over'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 380));
    if (shots != null) {
      await _write(tester, boundary, '$shots/workspace-desktop-takeover.png');
    }
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(controller.computer.userControl, isTrue);
    expect(find.text('Return control'), findsOneWidget);
    if (shots != null) {
      await _write(tester, boundary, '$shots/workspace-desktop-control.png');
    }
  });

  testWidgets('workspace blocked on a permission', (tester) async {
    final (boundary, _) = await _show(
      tester,
      width: 1440,
      height: 900,
      controller: _controller(
        status: 'blocked',
        pending: [_pendingPermission()],
      ),
    );
    expect(find.text('PERMISSION'), findsOneWidget);
    expect(find.text('Allow once'), findsOneWidget);
    expect(
      find.textContaining('Kitchen renovation · Blocked · Permission'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    if (shots != null) {
      await _write(tester, boundary, '$shots/workspace-blocked-permission.png');
    }
  });

  testWidgets('workspace blocked on a question, on a phone', (tester) async {
    final (boundary, _) = await _show(
      tester,
      width: 390,
      height: 844,
      controller: _controller(
        status: 'blocked',
        pending: [_pendingQuestion()],
      ),
    );
    expect(find.text('QUESTION'), findsOneWidget);
    expect(find.text('Tuesday'), findsOneWidget);
    // The desktop header says what the episode waits on; a phone's
    // narrower one keeps that line above the chat.
    expect(find.text('Blocked · Question'), findsOneWidget);
    expect(tester.takeException(), isNull);
    if (shots != null) {
      await _write(
        tester,
        boundary,
        '$shots/workspace-blocked-question-phone.png',
      );
    }
  });

  testWidgets('workspace on a wide desktop and at a larger text scale', (
    tester,
  ) async {
    final (wide, _) = await _show(tester, width: 1920, height: 1080);
    expect(tester.takeException(), isNull);
    if (shots != null) await _write(tester, wide, '$shots/workspace-wide.png');

    final (scaled, _) = await _show(
      tester,
      width: 1440,
      height: 900,
      textScale: 1.5,
    );
    expect(tester.takeException(), isNull);
    if (shots != null) {
      await _write(tester, scaled, '$shots/workspace-scale-150.png');
    }
  });

  testWidgets('workspace on a desktop with the computer hidden', (
    tester,
  ) async {
    final (boundary, _) = await _show(tester, width: 1440, height: 900);
    await tester.tap(find.byTooltip('Hide computer'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Show computer'), findsOneWidget);
    expect(find.text('Computer · Live'), findsOneWidget);
    expect(tester.takeException(), isNull);
    if (shots != null) {
      await _write(tester, boundary, '$shots/workspace-desktop-hidden.png');
    }
  });

  testWidgets('workspace computer details on a desktop', (tester) async {
    final (boundary, _) = await _show(tester, width: 1440, height: 900);
    await tester.tap(find.text('Details'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('computer-details-sheet')), findsOneWidget);
    expect(tester.takeException(), isNull);
    if (shots != null) {
      await _write(tester, boundary, '$shots/workspace-details.png');
    }
  });

  testWidgets('workspace computer details on a phone', (tester) async {
    final (boundary, _) = await _show(tester, width: 390, height: 844);
    await tester.tap(find.byTooltip('Computer'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('computer-screen-sheet')),
        matching: find.text('Details'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('computer-details-sheet')), findsOneWidget);
    expect(tester.takeException(), isNull);
    if (shots != null) {
      await _write(tester, boundary, '$shots/workspace-details-phone.png');
    }
  });
}
