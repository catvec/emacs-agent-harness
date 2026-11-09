import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/models/activity.dart';
import 'package:harness_client/src/models/workspace.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/interaction.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:harness_client/src/state/workspace_controller.dart';
import 'package:harness_client/src/ui/adaptive/layout_widgets.dart';
import 'package:harness_client/src/ui/adaptive/platform_style.dart';
import 'package:harness_client/src/ui/screens/workspace_screen.dart';
import 'package:harness_client/src/ui/theme/harness_theme.dart';
import 'package:harness_client/src/ui/widgets/markdown_view.dart';
import 'package:harness_client/src/ui/widgets/vnc_takeover.dart';
import 'package:harness_client/src/vnc/rfb.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';
import 'support/fake_rfb.dart';

WorkspaceController _preview() {
  final workspace = WorkspaceSummary(
    id: 'w1',
    name: 'Home',
    lastThread: 't1',
    threads: const [
      WorkspaceThread(
        id: 't1',
        title: 'Kitchen renovation',
        state: 'live',
        episodeStatus: 'running',
        live: 's1',
        model: 'demo:scripted',
        activity: TurnActivity(phase: 'waiting'),
        tags: ['Kitchen', 'Budget'],
      ),
      WorkspaceThread(
        id: 't2',
        title: 'Harness memory',
        tags: ['Harness', 'Memory'],
      ),
      WorkspaceThread(
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
    entries: [
      const WorkspaceEntry(
        kind: 'divider',
        thread: 't1',
        title: 'Kitchen renovation',
        reason: 'new-thread',
      ),
      const WorkspaceEntry(kind: 'brief', thread: 't1', tokens: 120),
      const WorkspaceEntry(
        kind: 'message',
        thread: 't1',
        role: 'user',
        text: 'The tile is matte.',
      ),
      const WorkspaceEntry(
        kind: 'message',
        thread: 't1',
        role: 'assistant',
        text: 'Noted. The quote is open.',
      ),
      const WorkspaceEntry(
        kind: 'message',
        thread: 't1',
        role: 'assistant',
        text: '**Matte** finish, [the sample](https://example.com/sample) and `3x6`.',
      ),
      const WorkspaceEntry(
        kind: 'message',
        thread: 't2',
        role: 'user',
        text: 'How is the memory index?',
      ),
    ],
  );
}

AppController _app() => AppController(settings: SettingsController());

Future<void> _pump(
  WidgetTester tester,
  WorkspaceController controller, {
  Size size = const Size(1440, 900),
  double textScale = 1,
  bool cupertino = false,
  AppController? app,
  RfbTransport Function(String url)? vncTransportFactory,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    HarnessStyle(
      style: cupertino
          ? HarnessPlatformStyle.cupertino
          : HarnessPlatformStyle.material,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: HarnessTheme.material(Brightness.light),
        home: MediaQuery(
          data: MediaQueryData(
            size: size,
            textScaler: TextScaler.linear(textScale),
          ),
          child: WorkspaceScreen(
            app: app ?? _app(),
            controller: controller,
            onOpenSession: (_) {},
            vncTransportFactory:
                vncTransportFactory ??
                (_) => FakeRfbTransport(width: 640, height: 400),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

InteractionRequest _permissionRequest({
  String id = 'p1',
  String title = 'Read tasks.json',
  String sessionId = 's1',
}) => InteractionRequest(
  method: 'session/request_permission',
  params: {
    'sessionId': sessionId,
    'toolCall': {
      'toolCallId': 'c-$id',
      'title': title,
      'kind': 'read',
      'rawInput': {'path': '/home/noah/documents/ai/emacs-agent-harness/.git/harness/tasks.json'},
    },
    'options': const [
      {'optionId': 'allow-once', 'name': 'Allow once', 'kind': 'allow_once'},
      {'optionId': 'deny-once', 'name': 'Deny', 'kind': 'reject_once'},
    ],
    '_harness': {'pendingId': id, 'tool': 'read_file'},
  },
  sessionId: sessionId,
  synthetic: true,
  pendingId: id,
);

InteractionRequest _questionRequest({
  String id = 'q1',
  String question = 'Which database?',
  String sessionId = 's1',
}) => InteractionRequest(
  method: '_harness/ask_user',
  params: {
    'sessionId': sessionId,
    'requestId': id,
    'question': question,
    'options': const ['sqlite', 'postgres'],
  },
  sessionId: sessionId,
  synthetic: true,
  pendingId: id,
);

/// A preview workspace with [status] on its live thread, and [pending]
/// requests waiting on its episode.
WorkspaceController _previewStatus(
  String status, {
  List<InteractionRequest> pending = const [],
  String title = 'Kitchen renovation',
  String? model = 'demo:scripted',
  TurnActivity? activity,
}) {
  final workspace = WorkspaceSummary(
    id: 'w1',
    name: 'Home',
    lastThread: 't1',
    threads: [
      WorkspaceThread(
        id: 't1',
        title: title,
        state: status == 'parked' ? 'parked' : 'live',
        episodeStatus: status,
        live: status == 'parked' ? null : 's1',
        model: model,
        activity: activity,
        pending: [
          for (final request in pending)
            WorkspacePendingRequest(
              id: request.pendingId ?? '',
              kind: request.isQuestion ? 'question' : 'permission',
              title: request.title,
            ),
        ],
      ),
    ],
  );
  return WorkspaceController.preview(workspace: workspace, pending: pending);
}

Future<(AppController, FakeHarness, WorkspaceController)> _connectedWorkspace() async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsController();
  await settings.load();
  final harness = FakeHarness(workspace: true);
  final app = AppController(
    settings: settings,
    connector: harness.connector,
    reconnectDelays: const [Duration(milliseconds: 5)],
  );
  addTearDown(app.dispose);
  await app.connect('ws://memory/acp');
  final controller = WorkspaceController(app.harness);
  addTearDown(controller.dispose);
  await controller.load();
  return (app, harness, controller);
}

void main() {
  testWidgets('workspace adapts from a phone to a desktop', (tester) async {
    final controller = _preview();
    await _pump(tester, controller, size: const Size(390, 844));
    expect(find.text('Kitchen renovation'), findsWidgets);
    expect(find.text('The tile is matte.'), findsOneWidget);
    expect(find.text('Computer'), findsNothing);

    await _pump(tester, controller, size: const Size(1024, 768));
    expect(find.text('Threads'), findsOneWidget);
    expect(find.text('Computer'), findsNothing);
    expect(find.text('The tile is matte.'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await _pump(tester, controller, size: const Size(1440, 900));
    expect(find.text('Threads'), findsOneWidget);
    expect(find.text('Computer'), findsOneWidget);
    expect(find.text('Concepts'), findsOneWidget);
    expect(find.byType(VncTakeover), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('workspace keeps its layout at desktop widths and text scales', (
    tester,
  ) async {
    final controller = _preview();
    for (final size in const [
      Size(1024, 768),
      Size(1440, 900),
      Size(1920, 1080),
    ]) {
      for (final scale in const [1.0, 1.5, 2.0]) {
        await _pump(tester, controller, size: size, textScale: scale);
        expect(tester.takeException(), isNull, reason: '$size at $scale');
        expect(find.text('Home'), findsWidgets);
        expect(find.text('Kitchen renovation'), findsWidgets);
      }
    }
  });

  testWidgets('a concept at the edge narrows the threads and the timeline', (
    tester,
  ) async {
    final controller = _preview();
    await _pump(tester, controller, size: const Size(1440, 900));
    expect(find.byKey(const ValueKey('concept-Kitchen')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('concept-Kitchen')));
    await tester.pumpAndSettle();
    expect(controller.selectedTag, 'Kitchen');
    expect(controller.shownThreads.length, 2);
    expect(find.text('Tag · Kitchen'), findsOneWidget);
    expect(find.text('Harness memory'), findsNothing);
    expect(find.text('How is the memory index?'), findsNothing);
  });

  testWidgets('the phone opens its threads and its computer in sheets', (
    tester,
  ) async {
    final controller = _preview();
    await _pump(tester, controller, size: const Size(390, 844));
    await tester.tap(find.byTooltip('Threads'));
    await tester.pumpAndSettle();
    expect(find.text('Threads'), findsWidgets);
    await tester.tap(find.text('Harness memory').last);
    await tester.pumpAndSettle();
    expect(controller.selectedThread, 't2');

    await tester.tap(find.byTooltip('Computer').first);
    await tester.pumpAndSettle();
    expect(find.text('Take over'), findsOneWidget);
    await tester.tap(find.text('Take over'));
    await tester.pumpAndSettle();
    expect(find.text('Return control'), findsOneWidget);
    expect(controller.computer.userControl, isTrue);
  });

  testWidgets('takeover moves the pill and wraps the window edge', (
    tester,
  ) async {
    var active = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: HarnessTheme.material(Brightness.light),
        home: StatefulBuilder(
          builder: (context, setState) => Scaffold(
            body: Center(
              child: SizedBox(
                width: 420,
                height: 280,
                child: VncTakeover(
                  active: active,
                  preview: true,
                  onTakeOver: () => setState(() => active = true),
                  onReturnControl: () => setState(() => active = false),
                  child: const ColoredBox(color: Colors.black12),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final idle = tester.getTopLeft(find.byKey(const ValueKey('vnc-pill')));
    expect(find.text('Take over'), findsOneWidget);
    await tester.tap(find.text('Take over'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 340));
    final moving = tester.getTopLeft(find.byKey(const ValueKey('vnc-pill')));
    expect(moving.dy, lessThan(idle.dy));
    final painter =
        tester
                .widget<CustomPaint>(find.byKey(const ValueKey('vnc-border')))
                .painter!
            as VncBorderPainter;
    expect(painter.progress, greaterThan(0.2));
    await tester.pumpAndSettle();
    expect(find.text('Return control'), findsOneWidget);
    expect(
      (tester
                  .widget<CustomPaint>(find.byKey(const ValueKey('vnc-border')))
                  .painter!
              as VncBorderPainter)
          .progress,
      1,
    );
  });

  testWidgets('takeover honours reduced motion', (tester) async {
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: MaterialApp(
          theme: HarnessTheme.material(Brightness.light),
          home: StatefulBuilder(
            builder: (context, setState) => Scaffold(
              body: Center(
                child: SizedBox(
                  width: 360,
                  height: 240,
                  child: VncTakeover(
                    active: false,
                    preview: true,
                    onTakeOver: () => setState(() {}),
                    onReturnControl: () {},
                    child: const ColoredBox(color: Colors.black12),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.text('Take over'), findsOneWidget);
    expect(
      (tester
                  .widget<CustomPaint>(find.byKey(const ValueKey('vnc-border')))
                  .painter!
              as VncBorderPainter)
          .progress,
      0,
    );
  });

  testWidgets('the desktop draws exactly the words the guide lists', (
    tester,
  ) async {
    final controller = _preview();
    await _pump(tester, controller, size: const Size(1440, 900));
    for (final copy in const [
      'Home',
      'Kitchen renovation · Running · scripted · 12 notes',
      'Threads',
      'Concepts',
      'Shared tags',
      'Budget',
      'Kitchen',
      'Harness',
      'Memory',
      'Memory · 12 notes',
      'Brief · 120 tokens',
      'New thread · Kitchen renovation',
      'You',
      'Agent',
      'Computer',
      'Live',
      'Take over',
      'Control · agent',
      'Box · local',
      'Details',
      'Workspace message',
      'Waiting for the model',
    ]) {
      expect(find.text(copy), findsWidgets, reason: copy);
    }
    // "New thread" is the page's button and the rail's, one each.
    for (final (tooltip, count) in const [
      ('New thread', 2),
      ('Threads', 1),
      ('Call', 1),
      ('Memory', 2),
      ('Graph', 1),
      ('Computer', 1),
      ('Hide computer', 1),
      ('Episode', 1),
      ('Refresh', 1),
    ]) {
      expect(find.byTooltip(tooltip), findsNWidgets(count), reason: tooltip);
    }
  });

  testWidgets('a computer that is off has no preview, only Start', (
    tester,
  ) async {
    final controller = _preview();
    controller.computer = const WorkspaceComputerStatus(
      backend: 'local',
      reason: 'Computer tools',
    );
    await _pump(tester, controller, size: const Size(1440, 900));
    expect(find.text('Computer off'), findsOneWidget);
    expect(find.text('Start'), findsOneWidget);
    expect(find.text('Computer tools'), findsWidgets);
    expect(find.text('Preview'), findsNothing);
    expect(find.textContaining('Sandbox staged'), findsNothing);
    expect(find.textContaining('Quartz'), findsNothing);
  });

  testWidgets('the computer screen folds to a rail and comes back', (
    tester,
  ) async {
    final controller = _preview();
    await _pump(tester, controller, size: const Size(1440, 900));
    expect(find.byType(VncTakeover), findsOneWidget);
    expect(find.byTooltip('Hide computer'), findsOneWidget);

    await tester.tap(find.byTooltip('Hide computer'));
    await tester.pumpAndSettle();

    expect(find.byType(VncTakeover), findsNothing);
    expect(find.byKey(const ValueKey('computer-rail')), findsOneWidget);
    expect(find.byTooltip('Details'), findsOneWidget);
    // The rail says what it holds and its state, in words.
    expect(find.text('Computer · Live'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('computer-rail')));
    await tester.pumpAndSettle();

    expect(find.byType(VncTakeover), findsOneWidget);
    expect(find.byTooltip('Hide computer'), findsOneWidget);
    expect(find.byKey(const ValueKey('computer-rail')), findsNothing);
    expect(find.text('Live'), findsOneWidget);
  });

  testWidgets('the folded rail opens the details', (tester) async {
    final controller = _preview();
    await _pump(tester, controller, size: const Size(1440, 900));
    await tester.tap(find.byTooltip('Hide computer'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Details'));
    await tester.pumpAndSettle();

    final details = find.byKey(const ValueKey('computer-details-sheet'));
    expect(details, findsOneWidget);
    expect(
      find.descendant(of: details, matching: find.text('Backend')),
      findsOneWidget,
    );
  });

  testWidgets('Details shows the computer, not its screen again', (
    tester,
  ) async {
    final controller = _preview();
    await _pump(tester, controller, size: const Size(1440, 900));
    await tester.tap(find.text('Details'));
    await tester.pumpAndSettle();

    final details = find.byKey(const ValueKey('computer-details-sheet'));
    expect(details, findsOneWidget);
    expect(
      find.descendant(of: details, matching: find.byType(VncTakeover)),
      findsNothing,
    );
    for (final copy in const [
      'Control',
      'Backend',
      'Isolation',
      'Display',
      'Screen',
      'Home',
      'Profile',
      'Disk',
      'Desktop',
      'Socket',
      'Resources',
    ]) {
      expect(
        find.descendant(of: details, matching: find.text(copy)),
        findsOneWidget,
        reason: copy,
      );
    }
    for (final value in const [
      'Agent',
      'local',
      'local display and process',
      ':99',
      '1280 × 800',
      '/home/noah/.harness/workspace-box/w1/home',
      '/home/noah/.harness/workspace-box/w1/browser',
      '1.5 MB',
      'http://memory/vnc_lite.html',
      'ws://memory/websockify',
    ]) {
      expect(
        find.descendant(of: details, matching: find.text(value)),
        findsOneWidget,
        reason: value,
      );
    }

    await tester.tap(
      find.descendant(of: details, matching: find.text('Take over')),
    );
    await tester.pumpAndSettle();
    expect(controller.computer.userControl, isTrue);
    expect(
      find.descendant(of: details, matching: find.text('You')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: details, matching: find.text('Return control')),
      findsOneWidget,
    );
  });

  testWidgets('details of a box that is off name what is missing', (
    tester,
  ) async {
    final controller = _preview();
    controller.computer = const WorkspaceComputerStatus(
      available: false,
      state: 'failed',
      backend: 'local',
      reason: 'Computer tools missing: Xvfb',
      missing: ['Xvfb', 'x11vnc'],
      home: '/home/noah/.harness/workspace-box/w1/home',
    );
    await _pump(tester, controller, size: const Size(1440, 900));
    await tester.tap(find.text('Details'));
    await tester.pumpAndSettle();

    final details = find.byKey(const ValueKey('computer-details-sheet'));
    expect(details, findsOneWidget);
    for (final copy in const [
      'Off',
      'Computer tools missing: Xvfb',
      'Xvfb · x11vnc',
    ]) {
      expect(
        find.descendant(of: details, matching: find.text(copy)),
        findsOneWidget,
        reason: copy,
      );
    }
    expect(
      find.descendant(of: details, matching: find.text('Start')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: details, matching: find.text('Screen')),
      findsOneWidget,
    );
    // A stopped box has no endpoints: its details say so rather than
    // remembering an old one.
    expect(
      find.descendant(of: details, matching: find.text('—')),
      findsWidgets,
    );
  });

  testWidgets('the computer sheet opens the details, not a second screen', (
    tester,
  ) async {
    final controller = _preview();
    await _pump(tester, controller, size: const Size(1440, 900));
    await tester.tap(find.byTooltip('Computer').first);
    await tester.pumpAndSettle();

    final screen = find.byKey(const ValueKey('computer-screen-sheet'));
    expect(screen, findsOneWidget);
    expect(
      find.descendant(of: screen, matching: find.byType(VncTakeover)),
      findsOneWidget,
    );
    await tester.tap(
      find.descendant(of: screen, matching: find.text('Details')),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('computer-screen-sheet')), findsNothing);
    expect(
      find.byKey(const ValueKey('computer-details-sheet')),
      findsOneWidget,
    );
  });

  testWidgets('the phone reaches the details from its computer sheet', (
    tester,
  ) async {
    final controller = _preview();
    await _pump(tester, controller, size: const Size(390, 844));
    await tester.tap(find.byTooltip('Computer').first);
    await tester.pumpAndSettle();
    expect(find.byType(VncTakeover), findsOneWidget);

    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('computer-screen-sheet')),
        matching: find.text('Details'),
      ),
    );
    await tester.pumpAndSettle();

    final details = find.byKey(const ValueKey('computer-details-sheet'));
    expect(details, findsOneWidget);
    expect(find.byType(VncTakeover), findsNothing);
    expect(
      find.descendant(of: details, matching: find.text('1280 × 800')),
      findsOneWidget,
    );
  });

  testWidgets('the details sheet holds at twice the text on a phone', (
    tester,
  ) async {
    final controller = _preview();
    await _pump(tester, controller, size: const Size(390, 844), textScale: 2);
    await tester.tap(find.byTooltip('Computer').first);
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('computer-screen-sheet')),
        matching: find.text('Details'),
      ),
    );
    await tester.pumpAndSettle();

    final details = find.byKey(const ValueKey('computer-details-sheet'));
    expect(details, findsOneWidget);
    expect(
      find.descendant(of: details, matching: find.text('Isolation')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a chosen concept has its own words', (tester) async {
    final semantics = tester.ensureSemantics();
    final controller = _preview();
    await _pump(tester, controller, size: const Size(1440, 900));
    await tester.tap(find.byKey(const ValueKey('concept-Kitchen')));
    await tester.pumpAndSettle();
    expect(find.text('Tag · Kitchen'), findsOneWidget);
    expect(find.text('Threads · 2'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Concept Kitchen')), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('the phone says what it offers', (tester) async {
    final controller = _preview();
    await _pump(tester, controller, size: const Size(390, 844));
    expect(find.text('Near'), findsOneWidget);
    for (final copy in const [
      'Home',
      'Kitchen renovation',
      'Budget',
      'Kitchen',
      'Brief · 120 tokens',
      'New thread · Kitchen renovation',
      'Workspace message',
      'Waiting for the model',
    ]) {
      expect(find.text(copy), findsWidgets, reason: copy);
    }
    for (final tooltip in const ['New thread', 'Threads', 'Call', 'Computer']) {
      expect(find.byTooltip(tooltip), findsWidgets, reason: tooltip);
    }
  });


  testWidgets('a typed draft stays with its own thread', (tester) async {
    final (_, _, controller) = await _connectedWorkspace();
    await _pump(tester, controller, size: const Size(1440, 900));
    await tester.enterText(find.byType(TextField).last, 'for kitchen');
    await tester.pump();
    await tester.tap(find.text('Harness memory'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField).last).controller!.text, isEmpty);
    await tester.enterText(find.byType(TextField).last, 'for memory');
    await tester.pump();
    await tester.tap(find.text('Kitchen renovation'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField).last).controller!.text,
      'for kitchen',
    );
    await tester.tap(find.text('Harness memory'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField).last).controller!.text,
      'for memory',
    );
  });

  testWidgets('retry keeps the originating thread after navigation', (tester) async {
    final (_, harness, controller) = await _connectedWorkspace();
    await _pump(tester, controller, size: const Size(1440, 900));
    await tester.enterText(find.byType(TextField).last, 'quote-for-kitchen');
    await tester.pump();
    harness.workspacePromptFail = true;
    await tester.tap(find.byKey(const Key('composer-send')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Send failure ·'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField).last).controller!.text, 'quote-for-kitchen');
    await tester.tap(find.text('Harness memory'));
    await tester.pumpAndSettle();
    harness.workspacePromptFail = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    final last = harness.workspacePromptParams.last;
    expect((last['opts'] as Map)['thread'], 'th-1');
    expect(last['text'], 'quote-for-kitchen');
  });

  testWidgets('rapid Retry sends exactly one retry', (tester) async {
    final (_, harness, controller) = await _connectedWorkspace();
    await _pump(tester, controller, size: const Size(1440, 900));
    await tester.enterText(find.byType(TextField).last, 'quote-for-kitchen');
    await tester.pump();
    harness.workspacePromptFail = true;
    await tester.tap(find.byKey(const Key('composer-send')));
    await tester.pumpAndSettle();
    harness.workspacePromptFail = false;
    harness.workspacePromptGate = Completer<void>();
    await tester.tap(find.text('Retry'));
    await tester.tap(find.text('Retry'));
    await tester.pump();
    await tester.pump();
    expect(
      harness.workspacePromptParams.where((p) => p['text'] == 'quote-for-kitchen').length,
      2,
    );
    harness.workspacePromptGate!.complete();
    await tester.pumpAndSettle();
    expect(
      harness.workspacePromptParams.where((p) => p['text'] == 'quote-for-kitchen').length,
      2,
    );
  });

  testWidgets('a newer draft is not overwritten by retry', (tester) async {
    final (_, harness, controller) = await _connectedWorkspace();
    await _pump(tester, controller, size: const Size(1440, 900));
    await tester.enterText(find.byType(TextField).last, 'quote-for-kitchen');
    await tester.pump();
    harness.workspacePromptFail = true;
    await tester.tap(find.byKey(const Key('composer-send')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'a newer draft');
    await tester.pump();
    harness.workspacePromptFail = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField).last).controller!.text, 'a newer draft');
  });

  testWidgets('the failed draft comes back when its thread is reopened', (tester) async {
    final (_, harness, controller) = await _connectedWorkspace();
    await _pump(tester, controller, size: const Size(1440, 900));
    await tester.enterText(find.byType(TextField).last, 'quote-for-kitchen');
    await tester.pump();
    harness.workspacePromptFail = true;
    await tester.tap(find.byKey(const Key('composer-send')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Harness memory'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Kitchen renovation'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Send failure ·'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField).last).controller!.text, 'quote-for-kitchen');
  });

  test('a retry can name its origin thread and overlaps are refused', () async {
    final (_, harness, controller) = await _connectedWorkspace();
    harness.workspacePromptFail = false;
    final first = controller.send('quote-for-kitchen', thread: 'th-1');
    final second = controller.send('quote-for-kitchen', thread: 'th-2');
    expect(await first, isTrue);
    expect(await second, isFalse, reason: 'an overlapping send is refused');
    expect(harness.workspacePromptParams.length, 1);
    expect((harness.workspacePromptParams.single['opts'] as Map)['thread'], 'th-1');
    expect(harness.workspacePromptParams.single['text'], 'quote-for-kitchen');
  });

  testWidgets('the empty, failed and no-workspace pages say what they are', (
    tester,
  ) async {
    final empty = WorkspaceController.preview(
      workspace: _preview().current!,
      memory: const WorkspaceMemoryStatus(notes: 12, fullText: true),
    );
    await _pump(tester, empty, size: const Size(1440, 900));
    expect(find.text('No messages'), findsOneWidget);

    final failed = _preview();
    failed.entries = const [];
    failed.error = 'Connection refused';
    await _pump(tester, failed, size: const Size(1440, 900));
    expect(find.text('Workspace unavailable'), findsOneWidget);
    expect(find.text('Connection refused'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);

    final none = _preview();
    none.current = null;
    none.threads = const [];
    none.entries = const [];
    await _pump(tester, none, size: const Size(1440, 900));
    expect(find.text('No workspace'), findsOneWidget);
    expect(find.text('One chat, its threads and its memory'), findsOneWidget);
    expect(find.text('New workspace'), findsOneWidget);
  });

  testWidgets('a running episode says its model and what it is doing', (
    tester,
  ) async {
    final controller = _previewStatus(
      'running',
      activity: const TurnActivity(phase: 'thinking'),
    );
    await _pump(tester, controller, size: const Size(1440, 900));
    // The model is a fact of the subtitle, beside the episode's state; what
    // the turn does is its own line above the composer, as in a chat.
    expect(find.textContaining('scripted'), findsWidgets);
    expect(find.text('Thinking'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a phone says the model and the activity too', (tester) async {
    final controller = _previewStatus(
      'running',
      activity: const TurnActivity(
        phase: 'tool',
        tool: 'read_file',
        title: 'Read file',
      ),
    );
    await _pump(tester, controller, size: const Size(390, 844));
    expect(
      tester.widget<Text>(find.byKey(const Key('workspace-model'))).data,
      'scripted',
    );
    expect(find.text('Running Read file'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the workspace shows its model and permission mode under the box', (
    tester,
  ) async {
    final controller = _previewStatus('running');
    await _pump(tester, controller, size: const Size(1440, 900));
    final model = tester.widget<HarnessPicker>(
      find.byKey(const Key('workspace-model-picker')),
    );
    final mode = tester.widget<HarnessPicker>(
      find.byKey(const Key('workspace-mode-picker')),
    );
    expect(model.label, 'scripted');
    expect(mode.label, 'Ask');
    // A preview has no harness behind it: the values only show.
    expect(model.onTap, isNull);
    expect(mode.onTap, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets("the pickers change the live episode's model and mode", (
    tester,
  ) async {
    final (app, harness, controller) = await _connectedWorkspace();
    await _pump(tester, controller, app: app, size: const Size(1440, 900));

    await tester.tap(find.byKey(const Key('workspace-model-picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Claude Haiku 4.5'));
    await tester.pumpAndSettle();
    expect(harness.sessions['s1']?['model'], 'claude:claude-haiku-4-5');
    expect(
      tester
          .widget<HarnessPicker>(find.byKey(const Key('workspace-model-picker')))
          .label,
      'claude-haiku-4-5',
    );

    await tester.tap(find.byKey(const Key('workspace-mode-picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('YOLO'));
    await tester.pumpAndSettle();
    expect(harness.sessions['s1']?['permissionMode'], 'yolo');
    expect(
      tester
          .widget<HarnessPicker>(find.byKey(const Key('workspace-mode-picker')))
          .label,
      'YOLO',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('the pickers change the defaults when no episode runs', (
    tester,
  ) async {
    final (app, harness, controller) = await _connectedWorkspace();
    await _pump(tester, controller, app: app, size: const Size(1440, 900));
    await tester.tap(find.text('Harness memory'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('workspace-model-picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Claude Haiku 4.5'));
    await tester.pumpAndSettle();
    expect(harness.workspaceUpdates.last['model'], 'claude:claude-haiku-4-5');
    expect(
      tester
          .widget<HarnessPicker>(find.byKey(const Key('workspace-model-picker')))
          .label,
      'claude-haiku-4-5',
    );

    await tester.tap(find.byKey(const Key('workspace-mode-picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('YOLO'));
    await tester.pumpAndSettle();
    expect(harness.workspaceUpdates.last['permission-mode'], 'yolo');
    expect(
      tester
          .widget<HarnessPicker>(find.byKey(const Key('workspace-mode-picker')))
          .label,
      'YOLO',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a send whose model has not answered says it is loading', (
    tester,
  ) async {
    final controller = _previewStatus('idle');
    controller.sending = true;
    await _pump(tester, controller, size: const Size(1440, 900));
    expect(find.text('Waiting for the model'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a running, blocked, idle or failed episode says so', (
    tester,
  ) async {
    for (final status in const ['running', 'blocked', 'idle', 'failed']) {
      final controller = _previewStatus(status);
      await _pump(tester, controller, size: const Size(1440, 900));
      final word = switch (status) {
        'running' => 'Running',
        'blocked' => 'Blocked',
        'idle' => 'Idle',
        'failed' => 'Failed',
        _ => 'Parked',
      };
      expect(find.text(word), findsOneWidget, reason: status);
      expect(
        find.textContaining('Kitchen renovation · $word'),
        findsOneWidget,
        reason: status,
      );
      if (status == 'blocked') {
        // With no request known yet, a blocked episode still says what it
        // waits on rather than nothing.
        expect(
          find.textContaining('Blocked · Permission'),
          findsOneWidget,
        );
      }
      expect(tester.takeException(), isNull, reason: status);
    }
  });

  testWidgets('a phone says what its episode is doing', (tester) async {
    final controller = _previewStatus(
      'blocked',
      pending: [_questionRequest()],
    );
    await _pump(tester, controller, size: const Size(390, 844));
    // The desktop header shows the state beside the thread; a phone's
    // narrower one puts it above the chat, in the same words.
    expect(find.text('Blocked · Question'), findsOneWidget);
    expect(find.text('QUESTION'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a blocked episode names its pending request', (tester) async {
    final controller = _previewStatus(
      'blocked',
      pending: [_permissionRequest()],
    );
    await _pump(tester, controller, size: const Size(1440, 900));
    expect(find.text('PERMISSION'), findsOneWidget);
    expect(find.text('Read tasks.json'), findsOneWidget);
    expect(find.text('Allow once'), findsOneWidget);
    expect(find.text('Deny'), findsOneWidget);
    expect(find.textContaining('Blocked · Permission'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the permission card answers the request it shows', (
    tester,
  ) async {
    final controller = _previewStatus(
      'blocked',
      pending: [_permissionRequest()],
    );
    await _pump(tester, controller, size: const Size(1440, 900));
    await tester.tap(find.text('Allow once'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('PERMISSION'), findsNothing);
    expect(controller.previewPending, isEmpty);
  });

  testWidgets('a question is answered on its card, not in the composer', (
    tester,
  ) async {
    final controller = _previewStatus(
      'blocked',
      pending: [_questionRequest()],
    );
    await _pump(tester, controller, size: const Size(1440, 900));
    expect(find.text('QUESTION'), findsOneWidget);
    expect(find.text('Which database?'), findsOneWidget);
    expect(find.text('sqlite'), findsOneWidget);
    expect(find.text('postgres'), findsOneWidget);
    expect(find.text('Send answer'), findsOneWidget);
    await tester.tap(find.text('sqlite'));
    await tester.pump();
    await tester.tap(find.text('Send answer'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('QUESTION'), findsNothing);
    expect(controller.previewPending, isEmpty);
  });

  testWidgets('a thread switch shows only the selected episode card', (
    tester,
  ) async {
    final workspace = WorkspaceSummary(
      id: 'w1',
      name: 'Home',
      lastThread: 't1',
      threads: const [
        WorkspaceThread(
          id: 't1',
          title: 'First topic',
          state: 'live',
          episodeStatus: 'blocked',
          live: 's1',
        ),
        WorkspaceThread(
          id: 't2',
          title: 'Second topic',
          state: 'live',
          episodeStatus: 'blocked',
          live: 's2',
        ),
      ],
    );
    final controller = WorkspaceController.preview(
      workspace: workspace,
      pending: [
        _permissionRequest(id: 'p1', title: 'First call', sessionId: 's1'),
        _permissionRequest(id: 'p2', title: 'Second call', sessionId: 's2'),
      ],
    );
    await _pump(tester, controller, size: const Size(1440, 900));
    expect(find.text('First call'), findsOneWidget);
    expect(find.text('Second call'), findsNothing);
    await tester.tap(find.text('Second topic'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Second call'), findsOneWidget);
    expect(find.text('First call'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a concept keeps its full name and a 44px target', (tester) async {
    final controller = _preview();
    await _pump(tester, controller, size: const Size(390, 844), textScale: 1.5);
    expect(find.byWidgetPredicate((widget) => widget is Tooltip && widget.message == 'Kitchen'), findsOneWidget);
    final tag = find.byKey(const ValueKey('concept-Kitchen'));
    expect(tag, findsOneWidget);
    final size = tester.getSize(tag);
    expect(size.height, greaterThanOrEqualTo(43));
    await tester.ensureVisible(tag);
    await tester.pumpAndSettle();
    await tester.tap(tag);
    await tester.pumpAndSettle();
    expect(controller.selectedTag, 'Kitchen');
    await tester.tap(tag);
    await tester.pumpAndSettle();
    expect(controller.selectedTag, isNull);
  });

  testWidgets('a formatted message renders without its syntax', (tester) async {
    final controller = _preview();
    await _pump(tester, controller, size: const Size(390, 844));
    expect(find.byType(HarnessMarkdown), findsWidgets);
    final text = tester
        .widgetList<Text>(find.byType(Text))
        .map((widget) => widget.data ?? '')
        .join(' ');
    expect(text, isNot(contains('**Matte**')));
    expect(text, isNot(contains('](https://'))); 
    expect(find.textContaining('the sample'), findsOneWidget);
  });

  testWidgets('reading older messages is not interrupted by new ones', (tester) async {
    final controller = _preview();
    controller.entries = [
      for (var i = 0; i < 30; i++)
        WorkspaceEntry(
          kind: 'message',
          thread: 't1',
          role: i.isEven ? 'user' : 'assistant',
          text: 'Message $i',
        ),
    ];
    await _pump(tester, controller, size: const Size(390, 844));
    final timeline = find.byKey(const PageStorageKey('workspace-timeline'));
    final scrollable = find.descendant(of: timeline, matching: find.byType(Scrollable)).first;
    await tester.drag(scrollable, const Offset(0, 900));
    await tester.pumpAndSettle();
    final before = tester.state<ScrollableState>(scrollable).position.pixels;
    await controller.send('A new message');
    await tester.pumpAndSettle();
    expect(find.text('Latest'), findsOneWidget);
    expect(tester.state<ScrollableState>(scrollable).position.pixels, moreOrLessEquals(before, epsilon: 1));
    await tester.tap(find.text('Latest'));
    await tester.pumpAndSettle();
    expect(find.text('Latest'), findsNothing);
  });

  test('a refused send is reported and can be retried once', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsController();
    await settings.load();
    final harness = FakeHarness(workspace: true)..workspacePromptFail = true;
    final app = AppController(
      settings: settings,
      connector: harness.connector,
      reconnectDelays: const [Duration(milliseconds: 5)],
    );
    addTearDown(app.dispose);
    await app.connect('ws://memory/acp');
    final controller = WorkspaceController(app.harness);
    addTearDown(controller.dispose);
    await controller.load();
    final sent = await controller.send('a refused message');
    expect(sent, isFalse);
    expect(controller.error, isNotNull);
    expect(harness.prompts, isEmpty);
  });

  test('a box status carries the facts the details sheet shows', () {
    final status = WorkspaceComputerStatus.fromWire({
      'available': true,
      'running': true,
      'state': 'running',
      'control': 'user',
      'backend': 'local',
      'socket': 'ws://memory/websockify',
      'url': 'http://memory/vnc_lite.html',
      'width': 1280,
      'height': 800,
      'isolation': 'local display and process',
      'display': ':99',
      'home': '/home/noah/.harness/workspace-box/w1/home',
      'profile': '/home/noah/.harness/workspace-box/w1/browser',
      'disk': 1572864,
      'missing': ['Xvfb', 'x11vnc'],
    });
    expect(status.userControl, isTrue);
    expect(status.live, isTrue);
    expect(status.isolation, 'local display and process');
    expect(status.display, ':99');
    expect(status.home, '/home/noah/.harness/workspace-box/w1/home');
    expect(status.profile, '/home/noah/.harness/workspace-box/w1/browser');
    expect(status.disk, 1572864);
    expect(status.missing, ['Xvfb', 'x11vnc']);
    expect(status.copyWith(control: 'agent').userControl, isFalse);
    expect(status.copyWith(control: 'agent').display, ':99');
  });
}
