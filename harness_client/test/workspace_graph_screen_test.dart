import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/models/workspace.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:harness_client/src/state/workspace_graph_controller.dart';
import 'package:harness_client/src/ui/adaptive/platform_style.dart';
import 'package:harness_client/src/ui/screens/workspace_graph_screen.dart';
import 'package:harness_client/src/ui/theme/harness_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';

const _workspace = WorkspaceSummary(id: 'w1', name: 'Home');

Future<(AppController, FakeHarness, WorkspaceGraphController)> _rig() async {
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
  await app.connect('ws://graph/acp');
  final controller = WorkspaceGraphController(
    app.harness,
    workspaceId: 'w1',
    threadId: 'th1',
  );
  addTearDown(controller.dispose);
  await controller.load();
  return (app, harness, controller);
}

Future<void> _pump(
  WidgetTester tester,
  AppController app,
  WorkspaceGraphController controller, {
  Size size = const Size(390, 844),
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    HarnessStyle(
      style: HarnessPlatformStyle.material,
      child: MaterialApp(
        theme: HarnessTheme.material(Brightness.light),
        home: MediaQuery(
          data: MediaQueryData(
            size: size,
            textScaler: TextScaler.linear(textScale),
          ),
          child: WorkspaceGraphScreen(
            app: app,
            workspace: _workspace,
            threadId: 'th1',
            controller: controller,
          ),
        ),
      ),
    ),
  );
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  test('the graph loads a thread, a node and a linked page', () async {
    final (_, harness, controller) = await _rig();
    expect(harness.graphRequests, ['thread']);
    expect(controller.graph!.ready, isTrue);
    expect(controller.graph!.pageName, 'Threads/Kitchen renovation');
    expect(controller.graph!.blocks.first.roleLabel, 'Note');
    expect(
      controller.graph!.page!.properties['summary'],
      'The tile is matte; the Stone Co sample is still open.',
    );

    await controller.openNode('b1');
    expect(harness.graphRequests.last, 'node:b1');
    expect(controller.view.kind, 'node');
    expect(controller.graph!.block!.text, contains('grout'));
    expect(controller.canGoBack, isTrue);
    await controller.back();
    expect(harness.graphRequests.last, 'thread');
    expect(controller.canGoBack, isFalse);

    await controller.openPage('Stone Co');
    expect(harness.graphRequests.last, 'page:Stone Co');
    expect(controller.graph!.pageName, 'Stone Co');
    expect(controller.graph!.blocks.single.text, contains('sample'));
    await controller.back();
    expect(controller.canGoBack, isFalse);
  });

  testWidgets('the graph page says what the thread knows', (tester) async {
    final (app, _, controller) = await _rig();
    await _pump(tester, app, controller);
    expect(find.text('Graph'), findsWidgets);
    expect(find.textContaining('Thread · Kitchen renovation'), findsWidgets);
    expect(
      find.textContaining('The tile is matte; the Stone Co sample'),
      findsWidgets,
    );
    expect(find.text('Next action'), findsNothing);
    expect(find.text('next-action'), findsOneWidget);
    expect(find.text('Wait for the Stone Co sample.'), findsOneWidget);
    expect(
      find.text('The tile is matte and the grout is warm grey.'),
      findsOneWidget,
    );
    expect(find.text('Backlinks'), findsOneWidget);
    expect(find.textContaining('The tile is matte. The grout'), findsWidgets);
    expect(find.text('Stone Co'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a node opens with its children, and back returns', (
    tester,
  ) async {
    final (app, _, controller) = await _rig();
    await _pump(tester, app, controller);
    await tester.tap(find.byKey(const ValueKey('graph-node-b1')));
    await tester.pumpAndSettle();
    expect(controller.view.kind, 'node');
    expect(find.text('Children'), findsOneWidget);
    expect(find.text('No children'), findsOneWidget);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(controller.view.kind, 'thread');
    expect(find.text('Backlinks'), findsOneWidget);
  });

  testWidgets('a linked page opens by name', (tester) async {
    final (app, _, controller) = await _rig();
    await _pump(tester, app, controller);
    await tester.tap(find.byKey(const ValueKey('graph-page-Stone Co')).first);
    await tester.pumpAndSettle();
    expect(controller.view.kind, 'page');
    expect(find.textContaining('Page · Stone Co'), findsWidgets);
    expect(find.text('Ask Stone Co for a sample.'), findsOneWidget);
    expect(find.text('No backlinks'), findsOneWidget);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(controller.view.kind, 'thread');
  });

  testWidgets('the graph holds at desktop widths and larger text', (
    tester,
  ) async {
    final (app, _, controller) = await _rig();
    for (final size in const [Size(390, 844), Size(1440, 900)]) {
      for (final scale in const [1.0, 1.5, 2.0]) {
        await _pump(tester, app, controller, size: size, textScale: scale);
        expect(tester.takeException(), isNull, reason: '$size at $scale');
        expect(find.text('Graph'), findsWidgets);
      }
    }
  });

  testWidgets('a missing node says so', (tester) async {
    final (app, _, controller) = await _rig();
    await _pump(tester, app, controller);
    await controller.openNode('gone');
    await _pump(tester, app, controller);
    expect(find.textContaining('No node'), findsWidgets);
    expect(find.text('No node'), findsWidgets);
  });
}
