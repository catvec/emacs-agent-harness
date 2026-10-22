import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/app.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:harness_client/src/ui/screens/usage_screen.dart';
import 'package:harness_client/src/ui/widgets/message_composer.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';

class _Rig {
  _Rig(this.settings, this.harness, this.app);
  final SettingsController settings;
  final FakeHarness harness;
  final AppController app;
}

Future<_Rig> _rig({
  bool enhanced = true,
  String? token,
  bool connect = true,
  String connectionToken = '',
  bool reducedBeforeAuth = false,
  bool signIn = false,
  String? oidcUrl,
  String? issueSecret,
  Set<String>? knownSecrets,
  List<Uri>? opened,
  bool worktrees = false,
  bool scratch = false,
  bool projectMains = true,
  bool tidyProjects = true,
}) async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsController();
  await settings.load();
  final harness = FakeHarness(
    enhanced: enhanced,
    token: token,
    reducedBeforeAuth: reducedBeforeAuth,
    signIn: signIn,
    oidcUrl: oidcUrl,
    issueSecret: issueSecret,
    knownSecrets: knownSecrets,
    projectMains: projectMains,
    tidyProjects: tidyProjects,
  );
  if (worktrees) harness.seedWorktreeSessions();
  if (scratch) harness.seedScratchSessions();
  final app = AppController(
    settings: settings,
    connector: harness.connector,
    urlOpener: (url) async {
      opened?.add(url);
      return true;
    },
  );
  if (connect) {
    await app.connect('ws://memory/acp', token: connectionToken);
  }
  return _Rig(settings, harness, app);
}

Future<void> _pump(WidgetTester tester, _Rig rig, {int rounds = 8}) async {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    HarnessApp(settings: rig.settings, appController: rig.app),
  );
  await tester.pump();
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

Future<void> _settle(WidgetTester tester, [int rounds = 10]) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

void main() {
  testWidgets('connect flow discovers the harness and opens Sessions', (
    tester,
  ) async {
    final rig = await _rig(connect: false);
    await _pump(tester, rig);
    expect(find.textContaining('within reach'), findsOneWidget);
    await tester.enterText(find.byType(TextField).at(0), 'ws://memory/acp');
    await tester.tap(find.text('Connect'));
    await _settle(tester, 12);
    expect(find.text('Sessions'), findsWidgets);
    expect(find.text('Design the merge queue'), findsOneWidget);
  });

  testWidgets('auth flow unlocks with the shared token', (tester) async {
    final rig = await _rig(connect: false, token: 's3cret');
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      HarnessApp(settings: rig.settings, appController: rig.app),
    );
    await tester.pump();
    await tester.enterText(find.byType(TextField).at(0), 'ws://memory/acp');
    await tester.tap(find.text('Connect'));
    await _settle(tester, 8);
    expect(find.text('Sign in to this harness'), findsOneWidget);
    await tester.enterText(find.byType(TextField).at(1), 's3cret');
    await tester.ensureVisible(find.text('Unlock with the token above'));
    await tester.tap(find.text('Unlock with the token above'));
    await _settle(tester, 12);
    expect(find.text('Design the merge queue'), findsOneWidget);
  });

  testWidgets('the client signs in by an approval in Emacs, inside the app', (
    tester,
  ) async {
    final rig = await _rig(
      connect: false,
      signIn: true,
      issueSecret: 'hs1_session',
    );
    await _pump(tester, rig);
    await tester.enterText(find.byType(TextField).at(0), 'ws://memory:4276/acp');
    await tester.tap(find.text('Connect'));
    await _settle(tester, 8);
    // The harness listed how to sign in: the user chooses, nothing is typed.
    expect(find.text('Sign in to this harness'), findsOneWidget);
    expect(find.byKey(const Key('signin-emacs-approval')), findsOneWidget);
    expect(find.text('Approve in Emacs'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('signin-emacs-approval')));
    await tester.tap(find.byKey(const Key('signin-emacs-approval')));
    await _settle(tester, 6);
    // It waits for the person at Emacs, and shows the code to compare.
    expect(rig.harness.waitingForApproval, isTrue);
    expect(find.text('Waiting for approval in Emacs'), findsOneWidget);
    expect(find.byKey(const Key('signin-code')), findsOneWidget);
    expect(find.text('4719'), findsOneWidget);
    rig.harness.approve();
    await _settle(tester, 14);
    expect(find.text('Design the merge queue'), findsOneWidget);
    // What the harness handed over is what is remembered, with the
    // address: never anything the user had to type.
    expect(rig.settings.address, 'ws://memory:4276/acp');
    expect(rig.settings.token, 'hs1_session');
  });

  testWidgets('a refusal in Emacs is shown, and the user may choose again', (
    tester,
  ) async {
    final rig = await _rig(connect: false, signIn: true);
    await _pump(tester, rig);
    await tester.enterText(find.byType(TextField).at(0), 'ws://memory:4276/acp');
    await tester.tap(find.text('Connect'));
    await _settle(tester, 8);
    await tester.ensureVisible(find.byKey(const Key('signin-emacs-approval')));
    await tester.tap(find.byKey(const Key('signin-emacs-approval')));
    await _settle(tester, 4);
    rig.harness.deny();
    await _settle(tester, 8);
    expect(
      find.textContaining('refused this device', findRichText: true),
      findsOneWidget,
    );
    expect(rig.app.phase, ConnectionPhase.needsAuth);
    expect(find.byKey(const Key('signin-emacs-approval')), findsOneWidget);
    expect(rig.settings.token, isEmpty);
  });

  testWidgets('a pasted connection link brings its own secret', (tester) async {
    final rig = await _rig(connect: false, token: 'hs1_session');
    await _pump(tester, rig);
    await tester.enterText(
      find.byType(TextField).at(0),
      'ws://memory:4276/acp?token=hs1_session',
    );
    await tester.tap(find.text('Connect'));
    await _settle(tester, 12);
    expect(find.text('Design the merge queue'), findsOneWidget);
    expect(rig.settings.address, 'ws://memory:4276/acp');
    expect(rig.settings.token, 'hs1_session');
  });

  test('plain TCP asks for the full capabilities once it is let in', () async {
    final rig = await _rig(
      connect: false,
      token: 'hs1_session',
      reducedBeforeAuth: true,
    );
    await rig.app.connect('tcp://memory:4276', token: 'hs1_session');
    expect(rig.app.phase, ConnectionPhase.connected);
    expect(rig.app.capability!.has('task/list'), isTrue);
    expect(rig.app.capability!.isHarness, isTrue);
    expect(
      rig.harness.requestsByClient.where((m) => m == 'initialize').length,
      2,
    );
  });

  test('a refused upgrade says why and to wait', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsController();
    await settings.load();
    final app = AppController(
      settings: settings,
      connector: (target, token) async => throw Exception(
        "WebSocketChannelException: WebSocketException: Connection to "
        "'http://h:4276/acp#' was not upgraded to websocket",
      ),
    );
    await app.connect('ws://h:4276/acp', token: 'hs1_old');
    expect(app.phase, ConnectionPhase.failed);
    expect(app.error, contains('too many devices'));
    expect(app.error, contains('Wait a minute'));
    await app.connect('ws://h:4276/acp');
    expect(app.error, startsWith('The harness refused this connection'));
  });

  test('a wrong secret leaves the connection waiting for a session', () async {
    final rig = await _rig(
      connect: false,
      token: 'hs1_session',
      reducedBeforeAuth: true,
    );
    await rig.app.connect('tcp://memory:4276', token: 'hs1_wrong');
    expect(rig.app.phase, ConnectionPhase.needsAuth);
    expect(rig.app.error, contains('Sign in again'));
  });

  testWidgets('talk, stream, approve a permission, and answer a question', (
    tester,
  ) async {
    final rig = await _rig();
    await _pump(tester, rig);
    expect(find.text('Design the merge queue'), findsOneWidget);
    await tester.tap(find.text('Design the merge queue'));
    await _settle(tester, 6);
    expect(
      find.textContaining('The merge queue has three', findRichText: true),
      findsOneWidget,
    );
    expect(
      find.textContaining('Give me the tour', findRichText: true),
      findsOneWidget,
    );

    final composer = find.descendant(
      of: find.byType(MessageComposer),
      matching: find.byType(TextField),
    );
    expect(composer, findsOneWidget);
    await tester.enterText(composer, 'Run the tests with permission');
    await tester.pump();
    await tester.tap(find.byKey(const Key('composer-send')));
    await _settle(tester, 14);
    expect(find.text('PERMISSION'), findsOneWidget);
    expect(find.textContaining('Run the full test suite'), findsWidgets);
    await tester.tap(find.text('Allow'));
    await _settle(tester, 12);
    expect(rig.harness.permissionAnswers, isNotEmpty);
    final outcome = rig.harness.permissionAnswers.last['outcome'] as Map;
    expect(outcome['optionId'], 'allow-once');

    await tester.enterText(composer, 'Ask me a question');
    await tester.pump();
    await tester.tap(find.byKey(const Key('composer-send')));
    await _settle(tester, 16);
    expect(
      find.text('Which layout should the tablet session view use?'),
      findsOneWidget,
    );
    expect(find.text('Split: list and transcript'), findsOneWidget);
    await tester.tap(find.text('Split: list and transcript'));
    await _settle(tester, 3);
    await tester.ensureVisible(find.text('Send answer'));
    await tester.tap(find.text('Send answer'));
    await _settle(tester, 8);
    expect(rig.harness.questionAnswers, isNotEmpty);
    expect(
      rig.harness.questionAnswers.last['answer'],
      'Split: list and transcript',
    );
  });

  testWidgets('creates a session from the sheet', (tester) async {
    final rig = await _rig();
    await _pump(tester, rig);
    await tester.tap(find.byIcon(Icons.add_rounded));
    await _settle(tester, 4);
    expect(find.text('Start session'), findsOneWidget);
    await tester.tap(find.text('Start session'));
    await _settle(tester, 10);
    expect(find.text('The line is open'), findsOneWidget);
    expect(rig.harness.sessions.length, 5);
  });

  testWidgets('opens the new task sheet and submits through the API', (
    tester,
  ) async {
    final rig = await _rig();
    await _pump(tester, rig);
    await tester.tap(find.text('Tasks'));
    await _settle(tester, 5);
    await tester.tap(find.byIcon(Icons.add_rounded));
    await _settle(tester, 4);
    expect(find.text('Submit task'), findsOneWidget);
    final task = await rig.app.tasks!.submit(
      cwd: rig.app.selectedProject!,
      prompt: 'Write the migration notes',
      priority: 'medium',
    );
    expect(task, isNotNull);
    expect(rig.harness.tasks.length, 7);
  });

  testWidgets('task board opens a task and verifies it', (tester) async {
    final rig = await _rig();
    await _pump(tester, rig);
    await tester.tap(find.text('Tasks'));
    await _settle(tester, 6);
    expect(find.text('Answer the permission'), findsOneWidget);
    await tester.ensureVisible(find.text('Review'));
    await tester.tap(find.text('Review'));
    await _settle(tester, 4);
    expect(find.text('Review the emulator screenshots'), findsOneWidget);
    await tester.tap(find.text('Review the emulator screenshots'));
    await _settle(tester, 6);
    expect(find.text('Verify and merge'), findsOneWidget);
    await tester.tap(find.text('Verify and merge'));
    await _settle(tester, 8);
    expect(rig.harness.tasks['task-2']!['state'], 'done');
  });

  testWidgets('usage and server views expose the harness extensions', (
    tester,
  ) async {
    final rig = await _rig();
    await _pump(tester, rig);
    await tester.tap(find.text('Usage'));
    await _settle(tester, 6);
    expect(find.text('Spend'.toUpperCase()), findsOneWidget);
    expect(find.text(r'$1.24'), findsOneWidget);
    final usageList = find
        .descendant(
          of: find.byType(UsageScreen),
          matching: find.byType(ListView),
        )
        .first;
    await tester.scrollUntilVisible(
      find.text('MODELS'),
      300,
      scrollable: find
          .descendant(of: usageList, matching: find.byType(Scrollable))
          .first,
    );
    expect(find.text('MODELS'), findsOneWidget);
    await tester.tap(find.text('Server'));
    await _settle(tester, 6);
    expect(find.text('emacs-agent-harness'), findsOneWidget);
    expect(find.text('Task board'), findsOneWidget);
  });

  testWidgets('plain ACP gets the chat and hides enhanced tabs', (
    tester,
  ) async {
    final rig = await _rig(enhanced: false);
    await _pump(tester, rig);
    final nav = tester.widget<NavigationBar>(find.byType(NavigationBar));
    expect(nav.destinations, hasLength(3));
    expect(find.text('Tasks'), findsNothing);
    expect(
      find.text(
        'Standard ACP agent · the task board and usage views are hidden.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Design the merge queue'));
    await _settle(tester, 6);
    await tester.enterText(
      find.descendant(
        of: find.byType(MessageComposer),
        matching: find.byType(TextField),
      ),
      'hello',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('composer-send')));
    await _settle(tester, 10);
    expect(
      find.textContaining('I’m on it', findRichText: true),
      findsOneWidget,
    );
  });

  testWidgets('apple platform style renders Cupertino navigation', (
    tester,
  ) async {
    final rig = await _rig();
    await rig.settings.setPreviewPlatform(PreviewPlatform.cupertino);
    await _pump(tester, rig);
    expect(find.byType(CupertinoTabBar), findsOneWidget);
    expect(find.byType(CupertinoNavigationBar), findsWidgets);
  });

  testWidgets('session search filters the list', (tester) async {
    final rig = await _rig();
    await _pump(tester, rig);
    await tester.enterText(find.byKey(const Key('session-search')), 'cache');
    await _settle(tester, 4);
    expect(find.text('Investigate cache misses'), findsOneWidget);
    expect(find.text('Design the merge queue'), findsNothing);
  });

  testWidgets('the project filter lists checkouts, not worktrees', (
    tester,
  ) async {
    final rig = await _rig(worktrees: true);
    await _pump(tester, rig);
    // A session working in a git worktree is shown for its project, not
    // under the name of the worktree.
    expect(find.textContaining('task-fix-titles'), findsNothing);
    expect(find.textContaining('task-old-layout'), findsNothing);
    await tester.tap(find.text('All projects'));
    await _settle(tester, 4);
    final sheet = find.byType(BottomSheet);
    expect(sheet, findsOneWidget);
    expect(
      find.descendant(of: sheet, matching: find.text('emacs-agent-harness')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: sheet, matching: find.text('other-project')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: sheet, matching: find.textContaining('task-')),
      findsNothing,
    );
    await tester.tap(
      find.descendant(of: sheet, matching: find.text('emacs-agent-harness')),
    );
    await _settle(tester, 4);
    // What was done for the project is in it, in a worktree or not.
    for (final title in [
      'Design the merge queue',
      'Fix duplicate task titles',
      'Review the title change',
      'Resolve the merge conflict',
      'Port the old board',
    ]) {
      expect(find.text(title), findsOneWidget, reason: title);
    }
    expect(find.text('Investigate cache misses'), findsNothing);
    expect(find.text('Profile the model cache'), findsNothing);
    expect(find.textContaining('task-'), findsNothing);
  });

  testWidgets(
    'the new task sheet offers projects, not the worktrees and scratch '
    'directories an older harness lists',
    (tester) async {
      // What the app showed: a worktree a task was made in, the scratch
      // directories sub-agents were given, and the worktrees of sessions,
      // each as a project, from a harness that says nothing of them.
      final rig = await _rig(
        worktrees: true,
        scratch: true,
        tidyProjects: false,
        projectMains: false,
      );
      expect(
        rig.harness.listedProjects(),
        containsAll([
          '/Users/noah/Code/emacs-agent-harness-worktrees/task-old-layout/',
          '/tmp/harness-1000/${FakeHarness.scratchOwner}/client-1/',
          '/tmp/harness-1000/${FakeHarness.goneOwner}/wt/core/',
        ]),
      );
      await _pump(tester, rig);
      await tester.tap(find.text('Tasks'));
      await _settle(tester, 5);
      await tester.tap(find.byIcon(Icons.add_rounded));
      await _settle(tester, 4);
      final sheet = find.byType(BottomSheet);
      expect(
        find.descendant(of: sheet, matching: find.text('PROJECT')),
        findsOneWidget,
      );
      final chips = find.descendant(
        of: sheet,
        matching: find.byIcon(Icons.folder_outlined),
      );
      expect(chips, findsNWidgets(2));
      for (final name in ['emacs-agent-harness', 'other-project']) {
        expect(
          find.descendant(of: sheet, matching: find.text(name)),
          findsOneWidget,
          reason: name,
        );
      }
      for (final junk in [
        'task-old-layout',
        'client-1',
        'client-2',
        'core',
        'task-fix-titles',
      ]) {
        expect(
          find.descendant(of: sheet, matching: find.text(junk)),
          findsNothing,
          reason: junk,
        );
      }
    },
  );

  testWidgets('usage by project has a row for a project, not a worktree', (
    tester,
  ) async {
    final rig = await _rig(worktrees: true);
    await _pump(tester, rig);
    await tester.tap(find.text('Usage'));
    await _settle(tester, 6);
    final usageList = find
        .descendant(
          of: find.byType(UsageScreen),
          matching: find.byType(ListView),
        )
        .first;
    Future<void> toTheEnd() async {
      await tester.drag(usageList, const Offset(0, -1500));
      await tester.pump(const Duration(milliseconds: 250));
    }

    // What is in the list, which is under the scope bar: the bar says which
    // project the page is about, and the list is what it adds up.
    Finder inList(String text) =>
        find.descendant(of: usageList, matching: find.text(text));

    // The project the app opens on: one row, which adds up what was spent
    // in the checkout, in task-flutter's worktree and in task-fix-titles'.
    await toTheEnd();
    expect(find.text('PROJECTS'), findsOneWidget);
    expect(inList('emacs-agent-harness'), findsOneWidget);
    expect(find.text(r'$1.33'), findsOneWidget);
    expect(find.textContaining('task-'), findsNothing);

    // Every project: a row each, still none for a worktree.
    rig.app.selectProject(null);
    await _settle(tester, 6);
    await toTheEnd();
    expect(inList('emacs-agent-harness'), findsOneWidget);
    expect(inList('other-project'), findsOneWidget);
    expect(find.text(r'$1.33'), findsOneWidget);
    expect(find.textContaining('task-'), findsNothing);
  });

  testWidgets('the server view lists the projects, not their worktrees', (
    tester,
  ) async {
    final rig = await _rig(worktrees: true);
    await _pump(tester, rig);
    await tester.tap(find.text('Server'));
    await _settle(tester, 6);
    final serverList = find.descendant(
      of: find.byType(ListView),
      matching: find.text('Projects'.toUpperCase()),
    );
    final list = find.byType(ListView).first;
    await tester.scrollUntilVisible(
      serverList,
      300,
      scrollable: find
          .descendant(of: list, matching: find.byType(Scrollable))
          .first,
    );
    expect(find.text('/Users/noah/Code/emacs-agent-harness/'), findsOneWidget);
    expect(find.text('/Users/noah/Code/other-project/'), findsOneWidget);
    expect(find.textContaining('.worktrees'), findsNothing);
    expect(find.textContaining('task-old-layout'), findsNothing);
  });
}
