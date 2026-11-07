import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/app.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:harness_client/src/state/workspace_buddy_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';
import 'support/voice_fakes.dart';

Future<AppController> _rig({WorkspaceBuddyBackendFactory? buddyFactory}) async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsController();
  await settings.load();
  final harness = FakeHarness(workspace: true);
  final app = AppController(
    settings: settings,
    connector: harness.connector,
    workspaceBuddyBackendFactory: buddyFactory,
  );
  await app.connect('ws://memory/acp');
  return app;
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 160));
  }
}

void main() {
  testWidgets('the workspace tab opens on a phone', (tester) async {
    final app = await _rig();
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      HarnessApp(settings: app.settings, appController: app),
    );
    await _settle(tester);
    expect(find.text('Workspace'), findsWidgets);
    await tester.tap(find.text('Workspace').last);
    await _settle(tester);
    expect(find.text('Home'), findsWidgets);
    expect(find.text('The tile is matte.'), findsOneWidget);
  });

  testWidgets('the workspace tab opens on a desktop', (tester) async {
    final app = await _rig();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      HarnessApp(settings: app.settings, appController: app),
    );
    await _settle(tester);
    await tester.tap(find.text('Workspace').last);
    await _settle(tester);
    expect(find.text('Threads'), findsOneWidget);
    expect(find.text('Computer'), findsOneWidget);
    expect(find.text('Concepts'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a desktop shows the away card only while the window is away', (
    tester,
  ) async {
    final app = await _rig();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      HarnessApp(settings: app.settings, appController: app),
    );
    await _settle(tester);
    await tester.tap(find.text('Workspace').last);
    await _settle(tester);

    expect(app.workspaceBuddy, isNotNull);
    expect(find.byKey(const Key('workspace-buddy-action')), findsOneWidget);
    expect(find.byTooltip('Call'), findsOneWidget);

    await tester.tap(find.byKey(const Key('workspace-buddy-action')));
    await _settle(tester);
    // Focused: the workspace itself, with no card over it.
    expect(find.byKey(const Key('workspace-buddy')), findsNothing);
    expect(find.byKey(const Key('workspace-call-bar')), findsNothing);
    expect(find.byTooltip('Call'), findsOneWidget);
    expect(app.workspaceBuddy!.voice, isNull, reason: 'no call was started');
    expect(app.settings.isWorkspaceBuddyEnabled('w1'), isTrue);
    addTearDown(() {
      // The app disposes its own notifier with the tree; a failing test must
      // not also fail in its tear-down.
      try {
        app.windowActive.value = true;
      } catch (_) {}
    });

    // Away: the compact card is the presence, and no call was started.
    app.windowActive.value = false;
    await _settle(tester);
    expect(find.byKey(const Key('workspace-buddy')), findsOneWidget);
    expect(find.text('Off'), findsOneWidget);
    expect(find.text('Mic off'), findsOneWidget);
    expect(find.byTooltip('Call'), findsOneWidget);

    await tester.tap(find.byKey(const Key('buddy-off')));
    await _settle(tester);
    expect(find.byKey(const Key('workspace-buddy')), findsNothing);
    expect(find.byTooltip('Call'), findsOneWidget);
    expect(app.settings.isWorkspaceBuddyEnabled('w1'), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a phone keeps its Call action and offers no buddy', (
    tester,
  ) async {
    final app = await _rig();
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      HarnessApp(settings: app.settings, appController: app),
    );
    await _settle(tester);
    await tester.tap(find.text('Workspace').last);
    await _settle(tester);

    expect(find.byKey(const Key('workspace-buddy-action')), findsNothing);
    expect(find.byKey(const Key('workspace-buddy')), findsNothing);
    expect(find.byTooltip('Call'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a phone keeps the call in a bar at the top when it minimizes', (
    tester,
  ) async {
    final backends = <FakeBackend>[];
    final app = await _rig(
      buddyFactory: (settings, address, bridge) {
        final backend = FakeBackend();
        backends.add(backend);
        return backend;
      },
    );
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      HarnessApp(settings: app.settings, appController: app),
    );
    await _settle(tester);
    await tester.tap(find.text('Workspace').last);
    await _settle(tester);

    await tester.tap(find.byTooltip('Call'));
    await _settle(tester);
    // The full call view is the main surface, and it is the workspace call.
    expect(find.text('Voice'), findsOneWidget);
    expect(find.byTooltip('Minimize'), findsOneWidget);
    expect(backends.single.started, isTrue);
    expect(app.workspaceBuddy!.running, isTrue);

    // Minimizing does not end the call: the bar at the top is its surface,
    // with the microphone state and End in sight.
    await tester.tap(find.byKey(const Key('voice-close')));
    await _settle(tester);
    expect(find.text('Voice'), findsNothing);
    expect(find.byKey(const Key('workspace-call-bar')), findsOneWidget);
    expect(find.text('In a call'), findsOneWidget);
    expect(find.text('Listening'), findsOneWidget);
    expect(find.text('Mic live'), findsOneWidget);
    expect(find.byKey(const Key('call-bar-view')), findsOneWidget);
    expect(app.workspaceBuddy!.running, isTrue);
    expect(backends.single.stopped, isFalse);

    // Opening the view again is the same call, not a second one.
    await tester.tap(find.byKey(const Key('call-bar-view')));
    await _settle(tester);
    expect(find.text('Voice'), findsOneWidget);
    expect(backends.length, 1);
    await tester.tap(find.byKey(const Key('voice-close')));
    await _settle(tester);
    expect(find.text('Voice'), findsNothing);

    // End is the control that ends it; the bar then has nothing to show.
    await tester.tap(find.byKey(const Key('call-bar-end')));
    await tester.runAsync(() async {
      for (var i = 0; i < 20 && app.workspaceBuddy!.running; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    });
    await _settle(tester);
    expect(find.byKey(const Key('workspace-call-bar')), findsNothing);
    expect(find.text('In a call'), findsNothing);
    expect(app.workspaceBuddy!.running, isFalse);
    expect(backends.single.stopped, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrowing the desktop leaves the call in the bar', (
    tester,
  ) async {
    final backends = <FakeBackend>[];
    final app = await _rig(
      buddyFactory: (settings, address, bridge) {
        final backend = FakeBackend();
        backends.add(backend);
        return backend;
      },
    );
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      HarnessApp(settings: app.settings, appController: app),
    );
    await _settle(tester);
    await tester.tap(find.text('Workspace').last);
    await _settle(tester);
    await tester.tap(find.byTooltip('Call'));
    await _settle(tester);
    await tester.tap(find.byKey(const Key('voice-close')));
    await _settle(tester);
    expect(find.byKey(const Key('workspace-call-bar')), findsOneWidget);
    expect(app.workspaceBuddy!.running, isTrue);

    tester.view.physicalSize = const Size(390, 844);
    await _settle(tester);
    expect(find.byKey(const Key('workspace-call-bar')), findsOneWidget);
    expect(find.text('In a call'), findsOneWidget);
    expect(find.text('Mic live'), findsOneWidget);
    expect(app.workspaceBuddy!.running, isTrue);
    expect(backends.single.stopped, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a desktop call hands over between the bar and the away card', (
    tester,
  ) async {
    final backends = <FakeBackend>[];
    final app = await _rig(
      buddyFactory: (settings, address, bridge) {
        final backend = FakeBackend();
        backends.add(backend);
        return backend;
      },
    );
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      HarnessApp(settings: app.settings, appController: app),
    );
    await _settle(tester);
    await tester.tap(find.text('Workspace').last);
    await _settle(tester);
    await tester.tap(find.byKey(const Key('workspace-buddy-action')));
    await _settle(tester);
    await tester.tap(find.byTooltip('Call'));
    await _settle(tester);
    await tester.tap(find.byKey(const Key('voice-close')));
    await _settle(tester);
    expect(find.byKey(const Key('workspace-call-bar')), findsOneWidget);
    expect(find.byKey(const Key('workspace-buddy')), findsNothing);

    // Behind another window: the away card joins the bar, so the call has
    // both its compact presence and its top-of-app controls.
    app.windowActive.value = false;
    await _settle(tester);
    expect(find.byKey(const Key('workspace-call-bar')), findsOneWidget);
    expect(find.byKey(const Key('workspace-buddy')), findsOneWidget);
    expect(find.text('Listening'), findsWidgets);
    expect(find.text('Mic live'), findsWidgets);
    expect(app.workspaceBuddy!.running, isTrue);

    // Back in use: the card goes, the bar stays, the same call.
    app.windowActive.value = true;
    await _settle(tester);
    expect(find.byKey(const Key('workspace-buddy')), findsNothing);
    expect(find.byKey(const Key('workspace-call-bar')), findsOneWidget);
    expect(backends.length, 1);
    expect(backends.single.stopped, isFalse);

    await tester.tap(find.byKey(const Key('call-bar-end')));
    await tester.runAsync(() async {
      for (var i = 0; i < 20 && app.workspaceBuddy!.running; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    });
    await _settle(tester);
    expect(app.workspaceBuddy!.running, isFalse);
    expect(backends.single.stopped, isTrue);
    expect(tester.takeException(), isNull);
  });
}
