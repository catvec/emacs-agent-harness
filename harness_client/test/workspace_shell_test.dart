import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/app.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:harness_client/src/desktop/buddy_window.dart';
import 'package:harness_client/src/state/workspace_buddy_controller.dart';
import 'package:harness_client/src/ui/theme/harness_theme.dart';
import 'package:harness_client/src/ui/widgets/buddy_window_host.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/buddy_window_fakes.dart';
import 'support/fake_harness.dart';
import 'support/voice_fakes.dart';

Future<AppController> _rig({
  WorkspaceBuddyBackendFactory? buddyFactory,
  BuddyWindowService? buddyWindow,
}) async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsController();
  await settings.load();
  final harness = FakeHarness(workspace: true);
  final app = AppController(
    settings: settings,
    connector: harness.connector,
    workspaceBuddyBackendFactory: buddyFactory,
    buddyWindow: buddyWindow,
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

  testWidgets('without a window the card stays over the page', (
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
    // The test engine has no native window.  The card is the only surface
    // that can be clicked, so it is here while the app is in use, not only
    // while it is away.
    expect(find.byKey(const Key('workspace-buddy')), findsOneWidget);
    expect(find.byKey(const Key('buddy-status-off')), findsOneWidget);
    expect(find.text('Mic off'), findsOneWidget);
    expect(find.byTooltip('Call'), findsOneWidget);
    expect(app.workspaceBuddy!.voice, isNull, reason: 'no call was started');
    expect(app.settings.isWorkspaceBuddyEnabled('w1'), isTrue);

    // A drag on the header moves the card and does not take it away.
    final before = tester.getTopLeft(find.byKey(const Key('workspace-buddy')));
    await tester.drag(
      find.byKey(const Key('buddy-drag-handle')),
      const Offset(-40, -30),
    );
    await _settle(tester);
    expect(find.byKey(const Key('workspace-buddy')), findsOneWidget);
    expect(
      tester.getTopLeft(find.byKey(const Key('workspace-buddy'))),
      isNot(before),
    );

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

  testWidgets('the bar and the fallback card are one call', (tester) async {
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
    // Without a native window the card is the clickable surface, so it is
    // here while the app is in use too.
    expect(find.byKey(const Key('workspace-buddy')), findsOneWidget);

    // The bar and the card are the same call: both show its state.
    expect(find.text('Listening'), findsWidgets);
    expect(find.text('Mic live'), findsWidgets);
    expect(app.workspaceBuddy!.running, isTrue);
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
  testWidgets('a desktop keeps the buddy in its own away window', (
    tester,
  ) async {
    final window = FakeBuddyWindowService();
    final app = await _rig(buddyWindow: window);
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      HarnessApp(settings: app.settings, appController: app),
    );
    await _settle(tester);
    // Opening the app asks a remembered harness for a connection, which
    // starts by dropping a window it does not have yet.  Only what the app
    // does on screen after that counts.
    final destroyedAtStart = window.destroyCalls;
    await tester.tap(find.text('Workspace').last);
    await _settle(tester);
    await tester.tap(find.byKey(const Key('workspace-buddy-action')));
    await _settle(tester);

    // The main window is the one in use: the separate window is not wanted,
    // and there is no in-app card to cover the page.
    expect(window.showCalls, 0);
    expect(find.byKey(const Key('workspace-buddy')), findsNothing);

    // Away from the app: the card is one view of the same call, and the
    // page under it is not built with a second copy.
    app.windowActive.value = false;
    await _settle(tester);
    expect(window.showCalls, 1);
    expect(window.requests.single.controller, same(app.workspaceBuddy));
    expect(find.byKey(const Key('workspace-buddy')), findsNothing);

    // Back in the app: the window goes, the call does not.
    app.windowActive.value = true;
    await _settle(tester);
    expect(window.hideCalls, greaterThanOrEqualTo(1));
    expect(app.workspaceBuddy!.running, isFalse);

    // Away again: the same window, not a second one.
    app.windowActive.value = false;
    await _settle(tester);
    expect(window.showCalls, 2);
    expect(window.destroyCalls, destroyedAtStart);
    expect(window.requests.length, 2);

    // The compositor gives the card window the click's focus.  The app
    // resumes, but the main window is still not the one in use, so the card
    // stays instead of hiding under the pointer.
    window.reportActivated(true);
    app.windowActive.value = true;
    await _settle(tester);
    expect(window.hideCalls, 1);

    // Clicking the main window takes the activation back; the card goes.
    window.reportActivated(false);
    await _settle(tester);
    expect(window.hideCalls, 2);

    app.windowActive.value = false;
    await _settle(tester);
    expect(window.showCalls, 3);

    // The call view is the large surface; the away card gives way to it.
    app.workspaceBuddy!.callViewOpen = true;
    await _settle(tester);
    expect(window.hideCalls, 3);
    app.workspaceBuddy!.callViewOpen = false;
    await _settle(tester);
    expect(window.showCalls, 4);

    // Turning the buddy off removes its window; the call is untouched.
    await app.workspaceBuddy!.disable();
    await _settle(tester);
    expect(window.destroyCalls, greaterThan(destroyedAtStart));
    expect(app.settings.isWorkspaceBuddyEnabled('w1'), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the buddy window draws the same card and drags itself', (
    tester,
  ) async {
    final window = FakeBuddyWindowService();
    final app = await _rig(buddyWindow: window);
    app.settings.setWorkspaceBuddyEnabled('w1', true);
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
    app.windowActive.value = false;
    await _settle(tester);
    final request = window.lastRequest;
    expect(request, isNotNull);

    var drags = 0;
    var openedWorkspace = 0;
    var openedSettings = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: HarnessTheme.material(Brightness.light),
        home: MediaQuery(
          data: const MediaQueryData(size: Size(360, 700)),
          child: BuddyWindowContent(
            buddy: app.workspaceBuddy!,
            width: 320,
            theme: HarnessTheme.material(Brightness.light),
            textScaler: TextScaler.noScaling,
            disableAnimations: false,
            startDrag: () => drags++,
            onActivated: (_) {},
            onOpenWorkspace: () => openedWorkspace++,
            onOpenSettings: () async => openedSettings++,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const Key('workspace-buddy')), findsOneWidget);
    expect(find.byKey(const Key('buddy-status-off')), findsOneWidget);

    await tester.drag(
      find.byKey(const Key('buddy-drag-handle')),
      const Offset(20, 12),
    );
    expect(drags, 1);

    await tester.tap(find.byKey(const Key('buddy-workspace')));
    await tester.pump();
    expect(openedWorkspace, 1);
    await tester.tap(find.byKey(const Key('buddy-settings')));
    await tester.pump();
    expect(openedSettings, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('without a native window the card stays and can be dragged', (
    tester,
  ) async {
    final window = FakeBuddyWindowService(available: false);
    final app = await _rig(buddyWindow: window);
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

    // No window to carry it: the card is on screen while the app is in use,
    // which is exactly when a person can click it.
    expect(find.byKey(const Key('workspace-buddy')), findsOneWidget);
    expect(window.showCalls, 0);
    final before = tester.getTopLeft(find.byKey(const Key('workspace-buddy')));
    await tester.drag(
      find.byKey(const Key('buddy-drag-handle')),
      const Offset(-40, -30),
    );
    await _settle(tester);
    final after = tester.getTopLeft(find.byKey(const Key('workspace-buddy')));
    expect(after, isNot(before));
    expect(find.byKey(const Key('workspace-buddy')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a window that cannot open leaves the persistent card', (
    tester,
  ) async {
    final window = FakeBuddyWindowService(failOnShow: true);
    final app = await _rig(buddyWindow: window);
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
    app.windowActive.value = false;
    await _settle(tester);

    expect(window.showCalls, 1);
    expect(window.available.value, isFalse);
    expect(find.byKey(const Key('workspace-buddy')), findsOneWidget);

    // The fallback card is not the away card: returning to the app does not
    // take away the only surface that can be clicked.
    app.windowActive.value = true;
    await _settle(tester);
    expect(find.byKey(const Key('workspace-buddy')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the workspace action asks the shell for the workspace page', (
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
    app.requestedTab.value = 'workspace';
    await _settle(tester);
    expect(find.text('Threads'), findsOneWidget);
    expect(app.requestedTab.value, isEmpty);
    expect(tester.takeException(), isNull);
  });

}
