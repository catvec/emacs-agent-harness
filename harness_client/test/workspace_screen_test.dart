import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/models/workspace.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:harness_client/src/state/workspace_controller.dart';
import 'package:harness_client/src/ui/adaptive/platform_style.dart';
import 'package:harness_client/src/ui/screens/workspace_screen.dart';
import 'package:harness_client/src/ui/theme/harness_theme.dart';
import 'package:harness_client/src/ui/widgets/vnc_takeover.dart';

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
      ('Memory', 1),
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
}
