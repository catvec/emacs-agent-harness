// Pictures of the workspace's speech floor where a person meets it: the real
// workspace page, with its thread rail, its conversation, the speech band and
// the composer under it, on a desktop and on a phone.
//
//   HARNESS_SHOTS=/some/directory flutter test test/workspace_speech_screenshots_test.dart
//
// writes a PNG for each case there.  Without HARNESS_SHOTS the cases still
// draw, check that nothing overflows, and write nothing.
//
// These are pages, not widgets: the band is drawn by WorkspaceScreen exactly
// as the app draws it, so a picture shows where the speech floor sits and how
// much room it takes from the conversation -- which a picture of the band on
// its own cannot.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/models/workspace.dart';
import 'package:harness_client/src/models/workspace_speech.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:harness_client/src/state/workspace_controller.dart';
import 'package:harness_client/src/ui/adaptive/platform_style.dart';
import 'package:harness_client/src/ui/app_scope.dart';
import 'package:harness_client/src/ui/screens/workspace_screen.dart';
import 'package:harness_client/src/ui/theme/harness_theme.dart';

import 'support/fake_rfb.dart';
import 'support/real_fonts.dart';

WorkspaceSpeechEntry _entry({
  required String id,
  required String thread,
  required String title,
  required String preview,
  String state = 'queued',
  String? held,
  double? played,
}) => WorkspaceSpeechEntry(
  id: id,
  workspace: 'w1',
  thread: thread,
  threadTitle: title,
  state: state,
  preview: preview,
  text: preview,
  held: held,
  played: played,
);

WorkspaceSpeech _floor({
  WorkspaceSpeechEntry? speaking,
  List<WorkspaceSpeechEntry> waiting = const [],
  String? solo,
  String? soloTitle,
  bool hold = false,
  int revision = 3,
}) => WorkspaceSpeech(
  workspace: 'w1',
  revision: revision,
  hold: hold,
  solo: solo,
  soloTitle: soloTitle,
  speaking: speaking,
  waiting: waiting,
  count: waiting.length,
  active: speaking?.thread ?? solo,
);

/// The workspace a picture shows: three threads, one of them live, and a
/// conversation with enough in it that the page reads as a page.
WorkspaceController _controller(WorkspaceSpeech floor) {
  final workspace = WorkspaceSummary(
    id: 'w1',
    name: 'Home',
    lastThread: 'th-1',
    model: 'claude:claude-fable-5-1',
    permissionMode: 'auto',
    threads: [
      const WorkspaceThread(
        id: 'th-1',
        title: 'Kitchen renovation',
        state: 'live',
        episodeStatus: 'running',
        live: 's1',
        model: 'claude:claude-fable-5-1',
        permissionMode: 'auto',
        tags: ['Kitchen', 'Budget'],
      ),
      const WorkspaceThread(
        id: 'th-2',
        title: 'Garden lights',
        model: 'claude:claude-haiku-4-5',
        tags: ['Garden'],
      ),
      const WorkspaceThread(
        id: 'th-3',
        title: 'Harness memory',
        tags: ['Harness'],
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
    ),
    speech: floor,
    entries: const [
      WorkspaceEntry(
        kind: 'divider',
        thread: 'th-1',
        title: 'Kitchen renovation',
        reason: 'new-thread',
      ),
      WorkspaceEntry(kind: 'brief', thread: 'th-1', tokens: 1840),
      WorkspaceEntry(
        kind: 'message',
        thread: 'th-1',
        role: 'user',
        text: 'Let us go with quartz for the countertop.',
      ),
      WorkspaceEntry(
        kind: 'message',
        thread: 'th-1',
        role: 'assistant',
        text:
            'Noted. I updated Decision/Countertop and opened the quote task. '
            'The fabricator can template on Tuesday.',
      ),
      WorkspaceEntry(
        kind: 'message',
        thread: 'th-1',
        role: 'user',
        text: 'What did we decide about the backsplash?',
      ),
      WorkspaceEntry(
        kind: 'message',
        thread: 'th-1',
        role: 'assistant',
        text:
            'White subway tile, matte, 3x6. Decided 12 Oct, and the journal '
            'entry links the sample.',
      ),
      WorkspaceEntry(
        kind: 'message',
        thread: 'th-2',
        role: 'user',
        text: 'How are the garden lights doing?',
      ),
    ],
  );
}

final GlobalKey _boundary = GlobalKey();

/// Write the page as a PNG when `HARNESS_SHOTS` says where.
///
/// The image is encoded on the real event loop: a picture taken inside the
/// test's own clock never completes, and the case waits for ever.
Future<void> _write(WidgetTester tester, String name) async {
  final directory = Platform.environment['HARNESS_SHOTS'];
  if (directory == null || directory.isEmpty) return;
  await tester.runAsync(() async {
    final object =
        _boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await object.toImage(pixelRatio: 2);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('$directory/$name.png');
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(data!.buffer.asUint8List());
    image.dispose();
  });
}

/// Draw the real workspace page at [size], with [floor] on it.
Future<void> _shot(
  WidgetTester tester,
  String name, {
  required Size size,
  required WorkspaceSpeech floor,
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 24);
  tester.view.padding = tester.view.viewPadding;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPadding);
  addTearDown(tester.view.resetViewPadding);
  addTearDown(tester.view.resetViewInsets);

  final settings = SettingsController();
  final app = AppController(settings: settings);
  final controller = _controller(floor);
  await tester.pumpWidget(
    RepaintBoundary(
      key: _boundary,
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
                size: size,
                textScaler: TextScaler.linear(textScale),
              ),
              child: WorkspaceScreen(
                app: app,
                controller: controller,
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
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 120)),
  );
  await tester.pump();
  expect(tester.takeException(), isNull);
  await _write(tester, name);
}

/// A floor with a speaker, two waiting threads and a solo on the speaker.
WorkspaceSpeech _soloFloor() => _floor(
  speaking: _entry(
    id: 'sp-1',
    thread: 'th-1',
    title: 'Kitchen renovation',
    preview: 'The tile quote is accepted, and the tiler starts Monday.',
    state: 'speaking',
    played: 4,
  ),
  waiting: [
    _entry(
      id: 'sp-2',
      thread: 'th-2',
      title: 'Garden lights',
      preview: 'The timer works, and the lights come on at dusk now.',
      held: 'Solo',
    ),
    _entry(
      id: 'sp-3',
      thread: 'th-3',
      title: 'Harness memory',
      preview: 'I remembered that you prefer the archive page folded.',
      held: 'Solo',
    ),
  ],
  solo: 'th-1',
  soloTitle: 'Kitchen renovation',
);

/// A floor with a speaker and a queue, and nothing held back.
WorkspaceSpeech _busyFloor() => _floor(
  speaking: _entry(
    id: 'sp-1',
    thread: 'th-1',
    title: 'Kitchen renovation',
    preview: 'The tile quote is accepted, and the tiler starts Monday.',
    state: 'speaking',
    played: 12,
  ),
  waiting: [
    _entry(
      id: 'sp-2',
      thread: 'th-2',
      title: 'Garden lights',
      preview: 'The timer works, and the lights come on at dusk now.',
    ),
    _entry(
      id: 'sp-3',
      thread: 'th-3',
      title: 'Harness memory',
      preview: 'I remembered that you prefer the archive page folded.',
    ),
  ],
);

/// A held floor: the words keep their place and the resume is offered.
WorkspaceSpeech _heldFloor() => _floor(
  speaking: _entry(
    id: 'sp-1',
    thread: 'th-1',
    title: 'Kitchen renovation',
    preview: 'The tile quote is accepted, and the tiler starts Monday.',
    state: 'held',
    played: 4,
  ),
  waiting: [
    _entry(
      id: 'sp-2',
      thread: 'th-2',
      title: 'Garden lights',
      preview: 'The timer works, and the lights come on at dusk now.',
    ),
  ],
  hold: true,
);

/// A crowded floor: five threads waiting behind a long-named speaker.
WorkspaceSpeech _crowdedFloor() => _floor(
  speaking: _entry(
    id: 'sp-1',
    thread: 'th-1',
    title: 'Kitchen renovation, the tile quote and the fabricator visit',
    preview: 'The tile quote is accepted.',
    state: 'speaking',
    played: 4,
  ),
  waiting: [
    _entry(
      id: 'sp-2',
      thread: 'th-2',
      title: 'Garden lights and the irrigation controller',
      preview: 'The timer works, and the lights come on at dusk now.',
    ),
    _entry(
      id: 'sp-3',
      thread: 'th-3',
      title: 'Harness memory',
      preview: 'I remembered that you prefer the archive page folded.',
    ),
    _entry(
      id: 'sp-4',
      thread: 'th-4',
      title: 'Quarterly budget',
      preview: 'The overspend is in the tile line, not the labour.',
    ),
    _entry(
      id: 'sp-5',
      thread: 'th-5',
      title: 'School run',
      preview: 'The Thursday pickup moves to half past three.',
    ),
    _entry(
      id: 'sp-6',
      thread: 'th-6',
      title: 'Boiler service',
      preview: 'The engineer can come on the eighth or the ninth.',
    ),
  ],
);

void main() {
  setUpAll(loadRealFonts);

  testWidgets('a desktop with a speaker, a queue and a solo', (tester) async {
    await _shot(
      tester,
      'desktop-solo',
      size: const Size(1440, 900),
      floor: _soloFloor(),
    );
    // The band is the page's own, between the conversation and the field.
    expect(find.byKey(const Key('workspace-speech-panel')), findsOneWidget);
    expect(find.text('2 waiting'), findsOneWidget);
    expect(find.byKey(const Key('workspace-speech-skip')), findsOneWidget);
    expect(find.byKey(const Key('workspace-speech-hold')), findsOneWidget);
  });

  testWidgets('a desktop with a queue and nothing held back', (tester) async {
    await _shot(
      tester,
      'desktop-populated',
      size: const Size(1440, 900),
      floor: _busyFloor(),
    );
    expect(find.text('2 waiting'), findsOneWidget);
    expect(find.text('Solo'), findsNWidgets(2));
  });

  testWidgets('a desktop while the floor is held', (tester) async {
    await _shot(
      tester,
      'desktop-held',
      size: const Size(1440, 900),
      floor: _heldFloor(),
    );
    expect(find.text('Held · Kitchen renovation'), findsOneWidget);
    expect(find.text('Resume'), findsOneWidget);
    expect(find.byKey(const Key('workspace-speech-skip')), findsOneWidget);
  });

  testWidgets('a phone with a speaker, a queue and a solo', (tester) async {
    await _shot(
      tester,
      'phone-solo',
      size: const Size(390, 844),
      floor: _soloFloor(),
    );
    expect(find.byKey(const Key('workspace-speech-strip')), findsOneWidget);
    expect(
      find.byKey(const Key('workspace-speech-strip-waiting')),
      findsOneWidget,
    );
    expect(find.byTooltip('Call'), findsOneWidget);
  });

  testWidgets('a phone while the floor is held', (tester) async {
    await _shot(
      tester,
      'phone-held',
      size: const Size(390, 844),
      floor: _heldFloor(),
    );
    expect(find.text('Held · Kitchen renovation'), findsOneWidget);
  });

  testWidgets('a phone with its queue sheet open', (tester) async {
    await _shot(
      tester,
      'phone-sheet',
      size: const Size(390, 844),
      floor: _soloFloor(),
    );
    await tester.tap(find.byKey(const Key('workspace-speech-strip')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('workspace-speech-sheet-thread-sp-2')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await _write(tester, 'phone-sheet');
  });

  testWidgets('a narrow desktop, where the column still holds', (tester) async {
    await _shot(
      tester,
      'desktop-narrow',
      size: const Size(900, 760),
      floor: _busyFloor(),
    );
    expect(find.byKey(const Key('workspace-speech-panel')), findsOneWidget);
    final hold = tester.getRect(find.byKey(const Key('workspace-speech-hold')));
    final garden = tester.getRect(
      find.byKey(const Key('workspace-speech-solo-sp-2')),
    );
    expect(hold.right, garden.right);
    expect(hold.left, garden.left);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a crowded queue with long names', (tester) async {
    await _shot(
      tester,
      'desktop-crowded',
      size: const Size(1440, 900),
      floor: _crowdedFloor(),
    );
    expect(find.text('5 waiting'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the same page at a larger text scale', (tester) async {
    await _shot(
      tester,
      'desktop-scale-150',
      size: const Size(1440, 900),
      floor: _soloFloor(),
      textScale: 1.5,
    );
    expect(tester.takeException(), isNull);
  });
}
