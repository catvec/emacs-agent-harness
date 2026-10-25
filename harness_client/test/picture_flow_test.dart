// The pictures of the harness's machine, through the whole client: the
// screenshots a task handed in, the image a `read_file` call read, and the
// report in the task's sheet, asked of the harness by the path they are named
// by (`_harness/session/image`) and drawn where they are named.  A harness
// that gives no pictures, and a picture that is gone, leave the page readable.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/app.dart';
import 'package:harness_client/src/acp/acp_message.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';
import 'support/tool_showcase.dart';
import 'support/transcript_log.dart';

Future<void> _settle(WidgetTester tester, [int rounds = 12]) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

/// Time passes in the real world, as decoding a picture takes: a picture has
/// no size until its first frame is decoded.
Future<void> _decoded(WidgetTester tester) async {
  for (var i = 0; i < 120; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump();
    if (find.byKey(const ValueKey('picture-loading')).evaluate().isEmpty) {
      return;
    }
  }
}

/// A screenshot of the app: a real picture of a real size, that the harness
/// can give.
final _screenshot = File('screenshots/android-tool-call.png').readAsBytesSync();

const _shots = toolShowcasePictures;

Future<AppController> _open(
  WidgetTester tester,
  FakeHarness harness, {
  String session = toolShowcaseName,
  bool openSession = true,
  double width = 1170,
}) async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsController();
  await settings.load();
  final app = AppController(settings: settings, connector: harness.connector);
  await app.connect('ws://memory/acp');
  tester.view.physicalSize = Size(width, 2532);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(HarnessApp(settings: settings, appController: app));
  await tester.pump();
  await _settle(tester);
  if (openSession) {
    await tester.tap(find.text(session));
    await _settle(tester, 30);
  }
  return app;
}

final _drawn = find.byKey(const ValueKey('picture-drawn'));
final _failed = find.byKey(const ValueKey('picture-failed'));

void main() {
  testWidgets('the screenshots a task handed in are drawn in its hand-in', (
    tester,
  ) async {
    final harness = FakeHarness()
      ..seedToolShowcase()
      ..seedShowcasePictures();
    await _open(tester, harness);
    expect(harness.imageRequests, isEmpty, reason: 'the call is closed');
    await tester.tap(find.textContaining('Hand in the finished work'));
    await _settle(tester, 20);
    // Each screenshot is asked of the session that handed it in, by the path
    // the report names it by.
    expect(harness.imageRequests, [
      (toolShowcaseId, '$_shots/android-tool-call.png'),
      (toolShowcaseId, '$_shots/android-hand-in.png'),
    ]);
    expect(_drawn, findsNWidgets(2));
    expect(_failed, findsNothing);
    await _decoded(tester);
    expect(find.byType(Image), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the image a read_file call read is drawn in its card', (
    tester,
  ) async {
    final log = TranscriptLog()
      ..user('What does the chat look like?')
      ..call(
        'c1',
        'read_file',
        title: 'Read file: shots/chat.png',
        input: {'path': 'shots/chat.png'},
        output: 'Image chat.png (image/png, 38 KiB, 390x844 px).',
        attachments: [
          {
            'path': '/work/shots/chat.png',
            'mime': 'image/png',
            'size': _screenshot.length,
            'name': 'chat.png',
          },
        ],
      );
    final harness = FakeHarness();
    harness.sessions['s-live'] = {
      ...toolShowcaseSession(),
      'id': 's-live',
      'name': 'Look at the chat',
    };
    harness.nodes['s-live'] = [...log.nodes];
    harness.pictureFiles['/work/shots/chat.png'] = (
      mime: 'image/png',
      bytes: _screenshot,
    );
    await _open(tester, harness, session: 'Look at the chat');
    // A call that brings a picture is a card of its own, not a line of a run.
    expect(find.textContaining('tool call'), findsNothing);
    await tester.tap(find.textContaining('Read file: shots/chat.png'));
    await _settle(tester, 20);
    expect(harness.imageRequests, [('s-live', '/work/shots/chat.png')]);
    expect(_drawn, findsOneWidget);
    expect(find.text('PICTURE'), findsOneWidget);
    expect(find.text('ATTACHMENTS'), findsNothing);
    // Tapped, it is shown larger, from the bytes it has.
    await _decoded(tester);
    await tester.tap(_drawn);
    await _settle(tester, 10);
    expect(find.byKey(const ValueKey('picture-viewer')), findsOneWidget);
    expect(harness.imageRequests.length, 1);
    await tester.tap(find.byIcon(Icons.close_rounded));
    await _settle(tester, 10);
    expect(find.byKey(const ValueKey('picture-viewer')), findsNothing);
    expect(_drawn, findsOneWidget);
  });

  testWidgets('what a real harness wrote of a read and a hand-in is drawn', (
    tester,
  ) async {
    // The nodes, and the task, of a live harness whose model read a
    // screenshot with read_file and handed the work in with hand_in: the
    // shapes the harness gives, not the ones a test would make up.
    final capture =
        jsonDecode(File('test/support/live_picture_nodes.json').readAsStringSync())
            as Map<String, Object?>;
    JsonMap map(Object? value) => (value as Map).cast<String, Object?>();
    final harness = FakeHarness();
    harness.sessions['s-live'] = {
      ...toolShowcaseSession(),
      'id': 's-live',
      'name': 'Show me the chat',
    };
    harness.nodes['s-live'] = [
      for (final node in capture['nodes'] as List) map(node),
    ];
    harness.tasks['t-live'] = {
      ...map(capture['task']),
      'project': harness.tasks['task-2']!['project'],
      'cwd': harness.tasks['task-2']!['cwd'],
    };
    harness.pictureFiles['/work/chat.png'] = (
      mime: 'image/png',
      bytes: _screenshot,
    );
    harness.pictureFiles['/work/diagram.svg'] = (
      mime: 'image/svg+xml',
      bytes: utf8.encode(
        '<svg xmlns="http://www.w3.org/2000/svg" width="120" height="60">'
        '<rect width="120" height="60" fill="#b5532f"/></svg>',
      ),
    );
    await _open(tester, harness, session: 'Show me the chat');

    // The read: a card of its own, with the picture it read.
    await tester.tap(find.textContaining('Read file: /work/chat.png'));
    await _settle(tester, 20);
    expect(harness.imageRequests, [('s-live', '/work/chat.png')]);
    expect(_drawn, findsOneWidget);
    expect(find.text('PICTURE'), findsOneWidget);
    await _decoded(tester);
    // Closed again, for the page is a screen high.
    await tester.tap(find.textContaining('Read file: /work/chat.png'));
    await _settle(tester, 10);
    expect(_drawn, findsNothing);

    // The hand-in: each screenshot under its line, the note as it was.  The
    // screenshot the call read is the one it handed in: the app has it.
    await tester.tap(find.textContaining('Hand in the finished work'));
    await _settle(tester, 20);
    expect(harness.imageRequests, [
      ('s-live', '/work/chat.png'),
      ('s-live', '/work/diagram.svg'),
    ]);
    expect(find.text('The chat, as the app draws it'), findsOneWidget);
    expect(find.text('A diagram'), findsOneWidget);
    expect(find.text('Checked on a live harness'), findsOneWidget);
    expect(_failed, findsNothing);
    await _decoded(tester);
    expect(_drawn, findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a task a real harness wrote shows its screenshots', (
    tester,
  ) async {
    final capture =
        jsonDecode(File('test/support/live_picture_nodes.json').readAsStringSync())
            as Map<String, Object?>;
    final harness = FakeHarness();
    harness.tasks['t-live'] = {
      ...(capture['task'] as Map).cast<String, Object?>(),
      'project': harness.tasks['task-2']!['project'],
      'cwd': harness.tasks['task-2']!['cwd'],
    };
    harness.pictureFiles['/work/chat.png'] = (
      mime: 'image/png',
      bytes: _screenshot,
    );
    harness.pictureFiles['/work/diagram.svg'] = (
      mime: 'image/svg+xml',
      bytes: utf8.encode(
        '<svg xmlns="http://www.w3.org/2000/svg" width="120" height="60">'
        '<rect width="120" height="60" fill="#b5532f"/></svg>',
      ),
    );
    await _open(tester, harness, openSession: false, width: 2100);
    await tester.tap(find.text('Tasks'));
    await _settle(tester, 6);
    await tester.ensureVisible(find.text('Review'));
    await tester.tap(find.text('Review'));
    await _settle(tester, 4);
    await tester.tap(find.text('Show the chat'));
    await _settle(tester, 12);
    expect(find.text('REPORT'), findsOneWidget);
    expect(find.text('Screenshot: The chat, as the app draws it'), findsOneWidget);
    expect(find.text('Screenshot: A diagram'), findsOneWidget);
    expect(harness.imageRequests, [
      ('s-live', '/work/chat.png'),
      ('s-live', '/work/diagram.svg'),
    ]);
    await _decoded(tester);
    expect(_drawn, findsNWidgets(2));
    expect(find.text('Checked on a live harness'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a report in the task sheet shows its screenshots', (
    tester,
  ) async {
    final harness = FakeHarness();
    // The task in review has a session, as every task does.
    harness.tasks['task-2']!['session'] = 's-review';
    harness.pictureFiles['screenshots/android-chat.png'] = (
      mime: 'image/png',
      bytes: _screenshot,
    );
    // On a tablet's width: the task board's header does not fit its spend on
    // a phone's in a test, whose font is wider than any real one.
    await _open(tester, harness, openSession: false, width: 2100);
    await tester.tap(find.text('Tasks'));
    await _settle(tester, 6);
    await tester.ensureVisible(find.text('Review'));
    await tester.tap(find.text('Review'));
    await _settle(tester, 4);
    await tester.tap(find.text('Review the emulator screenshots'));
    await _settle(tester, 12);
    expect(find.text('REPORT'), findsOneWidget);
    expect(find.text('Screenshot: Chat with a tool card'), findsOneWidget);
    expect(harness.imageRequests, [
      ('s-review', 'screenshots/android-chat.png'),
    ]);
    await _decoded(tester);
    expect(_drawn, findsOneWidget);
    // The rest of the evidence is as it was.
    expect(find.text('flutter test: 38 passing'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a harness that gives no pictures has the screenshots named', (
    tester,
  ) async {
    final harness = FakeHarness(sessionPictures: false)..seedToolShowcase();
    await _open(tester, harness);
    await tester.tap(find.textContaining('Hand in the finished work'));
    await _settle(tester, 20);
    expect(harness.imageRequests, isEmpty);
    expect(_drawn, findsNothing);
    expect(_failed, findsNothing);
    // As the app showed them before: by name, under the line.
    expect(find.text('android-tool-call.png'), findsOneWidget);
    expect(find.text('android-hand-in.png'), findsOneWidget);
    expect(find.textContaining('could not be loaded'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a screenshot that is gone says so, and can be asked for again', (
    tester,
  ) async {
    // The worktree of a finished task goes with the task: the files are gone.
    final harness = FakeHarness()..seedToolShowcase();
    await _open(tester, harness);
    await tester.tap(find.textContaining('Hand in the finished work'));
    await _settle(tester, 20);
    expect(_drawn, findsNothing);
    expect(_failed, findsNWidgets(2));
    expect(
      find.textContaining(
        'android-tool-call.png is gone from the harness’s machine',
      ),
      findsOneWidget,
    );
    // The report around them reads as it did.
    expect(find.text('PROBLEM'), findsOneWidget);
    expect(find.text('The analyzer'), findsOneWidget);
    // The file is back: the person asks again.
    harness.seedShowcasePictures();
    await tester.ensureVisible(find.text('Try again').first);
    await tester.pump();
    await tester.tap(find.text('Try again').first);
    await _settle(tester, 12);
    await _decoded(tester);
    expect(_drawn, findsOneWidget);
    expect(_failed, findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
