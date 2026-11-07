// The workspace shows what its live episode waits on, as a chat does: a
// permission prompt or a question, answered where it is read.  These tests
// drive a connected app over the fake harness, so the request comes from the
// harness's pending list (the state a phone or Emacs finds after connecting),
// is answered through the same decision workflow as a conversation's, and is
// reconciled when another client answers it, the thread changes or the
// connection is lost and comes back.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:harness_client/src/ui/adaptive/platform_style.dart';
import 'package:harness_client/src/ui/screens/workspace_screen.dart';
import 'package:harness_client/src/ui/theme/harness_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';

class _Rig {
  _Rig(this.settings, this.harness, this.app);
  final SettingsController settings;
  final FakeHarness harness;
  final AppController app;
}

Future<_Rig> _rig() async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsController();
  await settings.load();
  final harness = FakeHarness(workspace: true);
  final app = AppController(
    settings: settings,
    connector: harness.connector,
    reconnectDelays: const [Duration(milliseconds: 5)],
    handshakeTimeout: const Duration(seconds: 2),
    probeTimeout: const Duration(milliseconds: 150),
  );
  await app.connect('ws://memory/acp');
  return _Rig(settings, harness, app);
}

Future<void> _pump(
  WidgetTester tester,
  _Rig rig, {
  Size size = const Size(1440, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    HarnessStyle(
      style: HarnessPlatformStyle.material,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: HarnessTheme.material(Brightness.light),
        home: MediaQuery(
          data: MediaQueryData(size: size),
          child: WorkspaceScreen(
            app: rig.app,
            controller: rig.app.workspace,
            onOpenSession: (_) {},
          ),
        ),
      ),
    ),
  );
  await _settle(tester);
}

Future<void> _settle(WidgetTester tester, [int rounds = 20]) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _until(
  WidgetTester tester,
  bool Function() done, {
  String? what,
  int rounds = 120,
}) async {
  for (var i = 0; i < rounds; i++) {
    if (done()) return;
    await tester.pump(const Duration(milliseconds: 50));
  }
  fail('Timed out waiting for ${what ?? 'the workspace'}.');
}

/// The workspace's view says its live thread is [status] and waits on
/// [pending], as the harness's workspace/get does.
void _workspaceSays(
  _Rig rig,
  String status, {
  List<Map<String, Object?>> pending = const [],
}) {
  rig.harness.setWorkspaceThread(
    'th-1',
    status: status,
    pending: pending,
  );
}

void main() {
  testWidgets('a held permission is shown, never approved by itself', (
    tester,
  ) async {
    final rig = await _rig();
    rig.harness.leavePendingPermission(
      's1',
      requestId: 'p-held',
      title: 'Read tasks.json',
    );
    _workspaceSays(rig, 'blocked', pending: [
      {
        'id': 'p-held',
        'kind': 'permission',
        'payload': {'title': 'Read tasks.json', 'tool': 'read_file'},
      },
    ]);
    await _pump(tester, rig);
    await _until(tester, () => find.text('PERMISSION').evaluate().isNotEmpty,
        what: 'the permission card');
    expect(find.text('Read tasks.json'), findsOneWidget);
    expect(find.text('Allow'), findsOneWidget);
    expect(find.text('Deny'), findsOneWidget);
    // Nothing was answered for the person.
    expect(rig.harness.permissionAnswers, isEmpty);

    await tester.tap(find.text('Allow'));
    await _until(tester, () => find.text('PERMISSION').evaluate().isEmpty,
        what: 'the answered card to go');
    expect(rig.harness.permissionAnswers, hasLength(1));
    expect(rig.harness.permissionAnswers.last['behavior'], 'allow');
    expect(rig.harness.permissionAnswers.last['scope'], 'once');
    // The answer settles the harness's list after a moment; let the client
    // read it again so no timer outlives the test.
    await _settle(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a held question is read and answered on its card', (
    tester,
  ) async {
    final rig = await _rig();
    rig.harness.leavePendingQuestion(
      's1',
      question: 'Which database?',
      options: const ['sqlite', 'postgres'],
      requestId: 'q-held',
    );
    _workspaceSays(rig, 'blocked', pending: [
      {
        'id': 'q-held',
        'kind': 'question',
        'payload': {
          'question': 'Which database?',
          'options': ['sqlite', 'postgres'],
        },
      },
    ]);
    await _pump(tester, rig);
    await _until(tester, () => find.text('QUESTION').evaluate().isNotEmpty,
        what: 'the question card');
    expect(find.text('Which database?'), findsOneWidget);
    expect(find.text('sqlite'), findsOneWidget);
    expect(find.text('postgres'), findsOneWidget);
    await tester.tap(find.text('postgres'));
    await tester.pump();
    await tester.tap(find.text('Send answer'));
    await _until(tester, () => find.text('QUESTION').evaluate().isEmpty,
        what: 'the answered card to go');
    expect(rig.harness.questionAnswers.last['answer'], 'postgres');
    await _settle(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a request answered elsewhere leaves no stale card', (
    tester,
  ) async {
    final rig = await _rig();
    rig.harness.leavePendingPermission(
      's1',
      requestId: 'p-held',
      title: 'Read tasks.json',
    );
    _workspaceSays(rig, 'blocked');
    await _pump(tester, rig);
    await _until(tester, () => find.text('PERMISSION').evaluate().isNotEmpty,
        what: 'the permission card');
    rig.harness.permissionAnsweredElsewhere('s1', 'p-held');
    await _until(tester, () => find.text('PERMISSION').evaluate().isEmpty,
        what: 'the card another client answered');
    expect(rig.harness.permissionAnswers, isEmpty);
    await _settle(tester);
  });

  testWidgets('a thread switch shows only the selected episode card', (
    tester,
  ) async {
    final rig = await _rig();
    rig.harness.workspaceThreads[1]
      ..['live'] = 's2'
      ..['state'] = 'live'
      ..['episode-status'] = 'blocked'
      ..['pending'] = [
        {
          'id': 'p-s2',
          'kind': 'permission',
          'payload': {'title': 'Run the test suite', 'tool': 'bash'},
        },
      ];
    rig.harness.leavePendingPermission(
      's1',
      requestId: 'p-held',
      title: 'Read tasks.json',
    );
    _workspaceSays(rig, 'blocked');
    await _pump(tester, rig);
    await _until(tester, () => find.text('Read tasks.json').evaluate().isNotEmpty,
        what: 'the first thread card');
    expect(find.text('Run the test suite'), findsNothing);

    await tester.tap(find.text('Harness memory'));
    await _until(
      tester,
      () => find.text('Run the test suite').evaluate().isNotEmpty,
      what: 'the second thread card',
    );
    expect(find.text('Read tasks.json'), findsNothing);
    await _settle(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a reconnect reconciles what is still waited on', (
    tester,
  ) async {
    final rig = await _rig();
    rig.harness.leavePendingPermission(
      's1',
      requestId: 'p-drop',
      title: 'Drop me',
    );
    rig.harness.leavePendingPermission(
      's1',
      requestId: 'p-keep',
      title: 'Keep me',
    );
    _workspaceSays(rig, 'blocked');
    await _pump(tester, rig);
    await _until(tester, () => find.text('Drop me').evaluate().isNotEmpty,
        what: 'the first pending permission');

    // The connection goes; the card stays, since the request still waits.
    rig.harness.refuseConnects = 1000000;
    await rig.harness.dropConnection('The connection dropped.');
    await _until(tester, () => !rig.app.isConnected, what: 'the outage');
    expect(find.text('Drop me'), findsOneWidget);

    // While the app is out, another client answers the first request.
    rig.harness.permissionAnsweredElsewhere('s1', 'p-drop');
    rig.harness.refuseConnects = 0;
    await _until(tester, () => rig.app.isConnected, what: 'the connection');
    await _settle(tester, 20);
    await _until(tester, () => find.text('Keep me').evaluate().isNotEmpty,
        what: 'the request still waiting after reconnect');
    expect(find.text('Drop me'), findsNothing);
    await _settle(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the view says running, blocked, idle or failed', (
    tester,
  ) async {
    final rig = await _rig();
    await _pump(tester, rig);
    await _until(tester, () => find.text('Running').evaluate().isNotEmpty,
        what: 'the running status');
    expect(find.textContaining('Kitchen renovation · Running'), findsOneWidget);

    for (final (status, label) in const [
      ('idle', 'Idle'),
      ('failed', 'Failed'),
      ('running', 'Running'),
    ]) {
      _workspaceSays(rig, status);
      await _until(tester, () => find.text(label).evaluate().isNotEmpty,
          what: 'the $status status');
      expect(
        find.textContaining('Kitchen renovation · $label'),
        findsOneWidget,
      );
    }

    // Blocked names the request it waits on.
    rig.harness.leavePendingQuestion(
      's1',
      question: 'Which database?',
      options: const ['sqlite'],
      requestId: 'q-status',
    );
    _workspaceSays(rig, 'blocked', pending: [
      {
        'id': 'q-status',
        'kind': 'question',
        'payload': {'question': 'Which database?', 'options': ['sqlite']},
      },
    ]);
    await _until(
      tester,
      () => find.textContaining('Blocked · Question').evaluate().isNotEmpty,
      what: 'the blocked status',
    );
    await _settle(tester);
    expect(tester.takeException(), isNull);
  });
}
