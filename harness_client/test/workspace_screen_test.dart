import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/models/workspace.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:harness_client/src/state/workspace_controller.dart';
import 'package:harness_client/src/ui/adaptive/platform_style.dart';
import 'package:harness_client/src/ui/screens/workspace_screen.dart';
import 'package:harness_client/src/ui/theme/harness_theme.dart';
import 'package:harness_client/src/ui/widgets/markdown_view.dart';
import 'package:harness_client/src/ui/widgets/vnc_takeover.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';

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
        live: 's1',
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
      control: 'agent',
      preview: true,
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
            app: _app(),
            controller: controller,
            onOpenSession: (_) {},
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
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
    for (final size in const [Size(1024, 768), Size(1440, 900), Size(1920, 1080)]) {
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

    await tester.tap(find.byTooltip('Computer'));
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
    final painter = tester
        .widget<CustomPaint>(find.byKey(const ValueKey('vnc-border')))
        .painter! as VncBorderPainter;
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
      'Kitchen renovation · Live · 12 notes',
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
      'Preview',
      'Take over',
      'Control · agent',
      'Sandbox staged · preview',
      'Details',
      'Workspace message',
    ]) {
      expect(find.text(copy), findsWidgets, reason: copy);
    }
    // "New thread" is the page's button and the rail's, one each.
    for (final (tooltip, count) in const [
      ('New thread', 2),
      ('Threads', 1),
      ('Call', 1),
      ('Memory', 2),
      ('Computer', 1),
      ('Open episode', 1),
      ('Refresh', 1),
    ]) {
      expect(find.byTooltip(tooltip), findsNWidgets(count), reason: tooltip);
    }
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
    ]) {
      expect(find.text(copy), findsWidgets, reason: copy);
    }
    for (final tooltip in const ['New thread', 'Threads', 'Call', 'Computer']) {
      expect(find.byTooltip(tooltip), findsOneWidget, reason: tooltip);
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
    expect(find.textContaining('Send failed'), findsOneWidget);
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
    expect(find.textContaining('Send failed'), findsOneWidget);
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
}
