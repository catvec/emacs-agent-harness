import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/app.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:harness_client/src/ui/widgets/message_composer.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';

class _Rig {
  _Rig(this.settings, this.harness, this.app);
  final SettingsController settings;
  final FakeHarness harness;
  final AppController app;
}

/// The app, on a fake harness that can drop the connection.  The app is
/// disposed with the widget tree, as in `widget_flows_test.dart`.
Future<_Rig> _rig({
  bool signIn = false,
  Set<String>? knownSecrets,
  String token = '',
  Duration retryAfter = const Duration(milliseconds: 5),
  Duration probeTimeout = const Duration(milliseconds: 150),
}) async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsController();
  await settings.load();
  final harness = FakeHarness(
    signIn: signIn,
    knownSecrets: knownSecrets,
    issueSecret: signIn ? 'hs1_issued' : null,
  );
  final app = AppController(
    settings: settings,
    connector: harness.connector,
    reconnectDelays: [retryAfter],
    handshakeTimeout: const Duration(seconds: 2),
    probeTimeout: probeTimeout,
  );
  await app.connect('ws://memory/acp', token: token);
  return _Rig(settings, harness, app);
}

Future<void> _pump(WidgetTester tester, _Rig rig) async {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    HarnessApp(settings: rig.settings, appController: rig.app),
  );
  await tester.pump();
  await _settle(tester, 8);
}

Future<void> _settle(WidgetTester tester, [int rounds = 10]) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

Finder get _composerField => find.descendant(
  of: find.byType(MessageComposer),
  matching: find.byType(TextField),
);

void main() {
  testWidgets(
    'the conversation stays up, with what was typed, while the connection is got back',
    (tester) async {
      final rig = await _rig();
      await _pump(tester, rig);
      await tester.tap(find.text('Design the merge queue'));
      await _settle(tester, 6);
      await tester.enterText(_composerField, 'a long thought, half written');
      await tester.pump();
      expect(find.byKey(const Key('connection-banner')), findsNothing);

      // The connection goes, and the harness cannot be reached for a while.
      rig.harness.refuseConnects = 1000000;
      await rig.harness.dropConnection('The connection dropped.');
      await _settle(tester, 4);
      expect(rig.app.phase, ConnectionPhase.reconnecting);
      expect(find.byKey(const Key('connection-banner')), findsOneWidget);
      expect(find.text('Connection lost. Reconnecting…'), findsOneWidget);
      // Nothing was thrown away: the connection screen did not come up,
      // the conversation is where it was, and so is the message.
      expect(find.textContaining('within reach'), findsNothing);
      expect(find.byType(MessageComposer), findsOneWidget);
      expect(find.text('a long thought, half written'), findsOneWidget);
      expect(
        find.textContaining('The merge queue has three', findRichText: true),
        findsOneWidget,
      );

      // Sending waits for the connection, and the message stays in the field.
      await tester.tap(find.byKey(const Key('composer-send')));
      await _settle(tester, 2);
      expect(rig.harness.prompts, isEmpty);
      expect(find.text('a long thought, half written'), findsOneWidget);

      // The harness is back.
      rig.harness.refuseConnects = 0;
      await _settle(tester, 8);
      expect(rig.app.phase, ConnectionPhase.connected);
      expect(find.byKey(const Key('connection-banner')), findsNothing);
      expect(find.text('a long thought, half written'), findsOneWidget);

      // And it goes out.
      await tester.tap(find.byKey(const Key('composer-send')));
      await _settle(tester, 14);
      expect(rig.harness.prompts, ['a long thought, half written']);
      // Out of the field and into the conversation.
      expect(
        find.descendant(
          of: find.byType(MessageComposer),
          matching: find.text('a long thought, half written'),
        ),
        findsNothing,
      );
      expect(
        find.text('a long thought, half written', findRichText: true),
        findsOneWidget,
      );
    },
  );

  testWidgets('a message that never got through comes back to the box', (
    tester,
  ) async {
    final rig = await _rig();
    await _pump(tester, rig);
    await tester.tap(find.text('Design the merge queue'));
    await _settle(tester, 6);
    await tester.enterText(_composerField, 'Is anybody there?');
    await tester.pump();

    // The network died without a word, and the person presses send.
    rig.harness.silent = true;
    await tester.tap(find.byKey(const Key('composer-send')));
    await _settle(tester, 2);
    // It is on its way, shown in the conversation, and the box is empty.
    expect(rig.harness.prompts, isEmpty);
    expect(
      find.descendant(
        of: find.byType(MessageComposer),
        matching: find.text('Is anybody there?'),
      ),
      findsNothing,
    );
    expect(find.text('Is anybody there?', findRichText: true), findsOneWidget);

    // The app finds the connection dead (the person came back to it, say).
    unawaited(rig.app.checkConnection());
    await _settle(tester, 6);
    // The message is back in the box, not in the conversation, and the app
    // is connected again.
    expect(rig.app.phase, ConnectionPhase.connected);
    expect(
      find.descendant(
        of: find.byType(MessageComposer),
        matching: find.text('Is anybody there?'),
      ),
      findsOneWidget,
    );
    expect(find.text('Is anybody there?', findRichText: true), findsOneWidget);
    expect(rig.harness.prompts, isEmpty);

    // And it goes, this time.
    await tester.tap(find.byKey(const Key('composer-send')));
    await _settle(tester, 14);
    expect(rig.harness.prompts, ['Is anybody there?']);
  });

  testWidgets('the banner sits above the navigation bar and can be hurried', (
    tester,
  ) async {
    // The next attempt is an hour away unless the person says now.
    final rig = await _rig(retryAfter: const Duration(hours: 1));
    await _pump(tester, rig);
    rig.harness.refuseConnects = 1;
    await rig.harness.dropConnection();
    await _settle(tester, 4);
    final banner = find.byKey(const Key('connection-banner'));
    expect(banner, findsOneWidget);
    expect(find.byKey(const Key('connection-retry')), findsOneWidget);
    // It covers none of the page above it: it is in the layout, over the
    // tab bar, and not on top of the title.
    final bar = tester.getRect(find.byType(NavigationBar));
    expect(tester.getRect(banner).bottom, lessThanOrEqualTo(bar.top));
    final title = tester.getRect(find.text('Sessions').first);
    expect(tester.getRect(banner).top, greaterThan(title.bottom));

    await tester.tap(find.byKey(const Key('connection-retry')));
    await _settle(tester, 8);
    expect(rig.app.phase, ConnectionPhase.connected);
    expect(find.byKey(const Key('connection-banner')), findsNothing);
    expect(rig.harness.connects, 2);
  });

  testWidgets('Reconnect in Settings keeps the screens', (tester) async {
    final rig = await _rig();
    await _pump(tester, rig);
    await tester.tap(find.text('Settings'));
    await _settle(tester, 4);
    expect(find.text('Connected'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('settings-reconnect')));
    await tester.tap(find.byKey(const Key('settings-reconnect')));
    await _settle(tester, 10);
    expect(rig.harness.connects, 2);
    expect(rig.app.phase, ConnectionPhase.connected);
    // Still on Settings: no trip through the connection screen, which would
    // have put the app back on the sessions.
    expect(find.textContaining('within reach'), findsNothing);
    expect(find.byKey(const Key('settings-reconnect')), findsOneWidget);
    expect(find.text('Connected'), findsOneWidget);
  });

  testWidgets('Settings says the connection is out, and offers to try now', (
    tester,
  ) async {
    final rig = await _rig(retryAfter: const Duration(hours: 1));
    await _pump(tester, rig);
    await tester.tap(find.text('Settings'));
    await _settle(tester, 4);
    rig.harness.refuseConnects = 1;
    await rig.harness.dropConnection();
    await _settle(tester, 4);
    expect(find.text('Reconnecting'), findsOneWidget);
    expect(find.text('Retry now'), findsWidgets);
    await tester.ensureVisible(find.byKey(const Key('settings-reconnect')));
    await tester.tap(find.byKey(const Key('settings-reconnect')));
    await _settle(tester, 8);
    expect(find.text('Connected'), findsOneWidget);
    expect(find.text('Reconnect'), findsOneWidget);
  });

  testWidgets(
    'a task being described survives the harness turning the device away',
    (tester) async {
      final rig = await _rig(
        signIn: true,
        knownSecrets: {'hs1_device'},
        token: 'hs1_device',
      );
      await _pump(tester, rig);
      await tester.tap(find.text('Tasks'));
      await _settle(tester, 5);
      await tester.tap(find.byIcon(Icons.add_rounded));
      await _settle(tester, 4);
      expect(find.text('Submit task'), findsOneWidget);
      final prompt = find.ancestor(
        of: find.text('Describe the change, the bug, or the question…'),
        matching: find.byType(TextField),
      );
      await tester.enterText(prompt, 'Write the migration notes');
      await tester.pump();

      // The session was ended in Emacs while the sheet was open.  The sheet
      // and every screen under it go: the person has to sign in again.
      rig.harness.knownSecrets.clear();
      await rig.harness.dropConnection();
      await _settle(tester, 10);
      expect(rig.app.phase, ConnectionPhase.needsAuth);
      expect(find.byKey(const Key('signin-emacs-approval')), findsOneWidget);
      expect(find.text('Submit task'), findsNothing);

      await tester.ensureVisible(
        find.byKey(const Key('signin-emacs-approval')),
      );
      await tester.tap(find.byKey(const Key('signin-emacs-approval')));
      await _settle(tester, 6);
      rig.harness.approve();
      await _settle(tester, 14);
      expect(rig.app.phase, ConnectionPhase.connected);

      // The description is there to carry on from.
      await tester.tap(find.text('Tasks'));
      await _settle(tester, 5);
      await tester.tap(find.byIcon(Icons.add_rounded));
      await _settle(tester, 4);
      expect(find.text('Write the migration notes'), findsOneWidget);

      // Submitting it is what clears it.
      final before = rig.harness.tasks.length;
      await tester.ensureVisible(find.text('Submit task'));
      await tester.tap(find.text('Submit task'));
      await _settle(tester, 10);
      expect(rig.harness.tasks.length, before + 1);
      expect(rig.app.drafts.task.prompt, isEmpty);
    },
  );

  testWidgets('a new task keeps its description when the sheet is closed', (
    tester,
  ) async {
    final rig = await _rig();
    await _pump(tester, rig);
    await tester.tap(find.text('Tasks'));
    await _settle(tester, 5);
    await tester.tap(find.byIcon(Icons.add_rounded));
    await _settle(tester, 4);
    final prompt = find.ancestor(
      of: find.text('Describe the change, the bug, or the question…'),
      matching: find.byType(TextField),
    );
    await tester.enterText(prompt, 'Rework the sign-in page');
    await tester.pump();
    // Closed without sending, by accident.
    Navigator.of(tester.element(find.text('Submit task'))).pop();
    await _settle(tester, 6);
    expect(find.text('Submit task'), findsNothing);
    expect(rig.app.drafts.task.prompt, 'Rework the sign-in page');

    await tester.tap(find.byIcon(Icons.add_rounded));
    await _settle(tester, 4);
    expect(find.text('Rework the sign-in page'), findsOneWidget);
  });

  testWidgets('on a wide screen it is over the page, which keeps its state', (
    tester,
  ) async {
    final rig = await _rig(retryAfter: const Duration(hours: 1));
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      HarnessApp(settings: rig.settings, appController: rig.app),
    );
    await tester.pump();
    await _settle(tester, 8);
    expect(find.byType(NavigationBar), findsNothing, reason: 'the sidebar');

    await tester.enterText(find.byKey(const Key('session-search')), 'cache');
    await _settle(tester, 4);
    expect(find.text('Investigate cache misses'), findsOneWidget);
    expect(find.text('Design the merge queue'), findsNothing);
    final fieldTop = tester
        .getRect(find.byKey(const Key('session-search')))
        .top;

    rig.harness.refuseConnects = 1;
    await rig.harness.dropConnection();
    await _settle(tester, 4);
    final banner = find.byKey(const Key('connection-banner'));
    expect(banner, findsOneWidget);
    // Above the page: the page gave way to it, and is under it.
    final fieldUnder = tester.getRect(find.byKey(const Key('session-search')));
    expect(tester.getRect(banner).bottom, lessThanOrEqualTo(fieldUnder.top));
    expect(fieldUnder.top, greaterThan(fieldTop));
    // The page under it is the same page: what was typed is there, and the
    // list is still the one that was asked for.
    expect(find.text('cache'), findsOneWidget);
    expect(find.text('Investigate cache misses'), findsOneWidget);
    expect(find.text('Design the merge queue'), findsNothing);
    // The sidebar says so too.
    expect(find.text('Reconnecting…'), findsWidgets);

    rig.app.retryNow();
    await _settle(tester, 8);
    expect(banner, findsNothing);
    expect(find.text('cache'), findsOneWidget);
    expect(find.text('Design the merge queue'), findsNothing);
    expect(
      tester.getRect(find.byKey(const Key('session-search'))).top,
      fieldTop,
      reason: 'the page is where it was',
    );
  });

  testWidgets('the banner is there on Apple platforms too', (tester) async {
    final rig = await _rig(retryAfter: const Duration(hours: 1));
    await rig.settings.setPreviewPlatform(PreviewPlatform.cupertino);
    await _pump(tester, rig);
    rig.harness.refuseConnects = 1;
    await rig.harness.dropConnection();
    await _settle(tester, 4);
    expect(find.byKey(const Key('connection-banner')), findsOneWidget);
    expect(find.text('Connection lost. Reconnecting…'), findsOneWidget);
    rig.app.retryNow();
    await _settle(tester, 8);
    expect(find.byKey(const Key('connection-banner')), findsNothing);
  });
}
