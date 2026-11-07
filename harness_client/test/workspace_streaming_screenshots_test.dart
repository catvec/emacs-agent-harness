// Pictures of one workspace reply while it streams.
//
//   HARNESS_SHOTS=/some/directory flutter test test/workspace_streaming_screenshots_test.dart
//
// writes a PNG for each stage there.  Without HARNESS_SHOTS the cases still
// draw and check the words on screen, and write nothing.
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
import 'package:harness_client/src/ui/app_scope.dart';
import 'package:harness_client/src/ui/screens/workspace_screen.dart';
import 'package:harness_client/src/ui/theme/harness_theme.dart';

import 'support/real_fonts.dart';

WorkspaceController _controller() {
  const workspace = WorkspaceSummary(
    id: 'w1',
    name: 'Home',
    lastThread: 't1',
    threads: [
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
    ],
  );
  return WorkspaceController.preview(
    workspace: workspace,
    memory: const WorkspaceMemoryStatus(notes: 12, fullText: true),
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
        episode: 's1',
        role: 'user',
        text: 'How is the kitchen quote?',
      ),
      WorkspaceEntry(
        kind: 'message',
        thread: 't1',
        episode: 's1',
        role: 'assistant',
        node: 'a1',
        text: 'The ',
        streaming: true,
      ),
    ],
  );
}

Future<(GlobalKey, WorkspaceController)> _show(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 24);
  tester.view.padding = tester.view.viewPadding;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPadding);
  addTearDown(tester.view.resetViewPadding);

  final boundary = GlobalKey();
  final settings = SettingsController();
  final app = AppController(settings: settings);
  final controller = _controller();
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
              data: const MediaQueryData(size: Size(390, 844)),
              child: WorkspaceScreen(
                app: app,
                controller: controller,
                onOpenSession: (_) {},
              ),
            ),
          ),
        ),
      ),
    ),
  );
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
  return (boundary, controller);
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

Map<String, Object?> _chunk(String text) => {
  'sessionUpdate': 'agent_message_chunk',
  'content': {'type': 'text', 'text': text},
  '_harness': {'nodeId': 'a1'},
};

/// The words as the screen draws them: a reply is Markdown, which drops the
/// space at the end of a line that is still being written.
Finder _reply(String words) => find.text(words.trim());

void main() {
  final shots = Platform.environment['HARNESS_SHOTS'];
  setUpAll(() async {
    await loadRealFonts();
  });

  testWidgets('one reply arrives in visible pieces', (tester) async {
    final (boundary, controller) = await _show(tester);
    var frame = 0;
    Future<void> stage(String words) async {
      controller.applySessionUpdate('s1', _chunk(words));
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 80));
      }
      frame++;
      if (shots != null) {
        await _write(tester, boundary, '$shots/workspace-stream-$frame.png');
      }
    }

    expect(_reply('The '), findsOneWidget);
    frame++;
    if (shots != null) {
      await _write(tester, boundary, '$shots/workspace-stream-$frame.png');
    }

    await stage('quote ');
    expect(_reply('The quote '), findsOneWidget);
    await stage('is open. The ');
    expect(_reply('The quote is open. The '), findsOneWidget);
    await stage('fabricator ');
    expect(_reply('The quote is open. The fabricator '), findsOneWidget);
    await stage('can template Tuesday.');
    const whole = 'The quote is open. The fabricator can template Tuesday.';
    expect(find.text(whole), findsOneWidget);
    expect(find.textContaining('The The'), findsNothing);

    controller.applySessionUpdate('s1', {
      'sessionUpdate': '_harness/node',
      'node': {'id': 'a1', 'kind': 'assistant', 'content': whole},
    });
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 80));
    }
    expect(find.text(whole), findsOneWidget);
    expect(
      controller.entries.where((entry) => entry.node == 'a1'),
      hasLength(1),
    );
    if (shots != null) {
      await _write(tester, boundary, '$shots/workspace-stream-final.png');
    }
    expect(tester.takeException(), isNull);
  });
}
