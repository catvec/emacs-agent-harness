// The Computers page against a harness that answers its methods: the
// registry, a session's access, the resources, and the control toggle.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/models/computer.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/computers_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:harness_client/src/ui/adaptive/platform_style.dart';
import 'package:harness_client/src/ui/screens/computers_screen.dart';
import 'package:harness_client/src/ui/theme/harness_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';

Future<(AppController, ComputersController)> _rig({
  bool computers = true,
}) async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsController();
  await settings.load();
  final harness = FakeHarness(computers: computers);
  final app = AppController(settings: settings, connector: harness.connector);
  addTearDown(app.dispose);
  await app.connect('ws://memory/acp');
  final controller = ComputersController(app.harness, sessionId: 's1');
  addTearDown(controller.dispose);
  await controller.load();
  return (app, controller);
}

Future<void> _show(
  WidgetTester tester,
  AppController app,
  ComputersController controller, {
  Size size = const Size(390, 844),
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
          child: ComputersScreen(app: app, controller: controller),
        ),
      ),
    ),
  );
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}

void main() {
  test('the registry, the access and the resources are read', () async {
    final (_, controller) = await _rig();
    expect(controller.computers.map((computer) => computer.name), [
      'marcuse',
      'studio',
    ]);
    expect(controller.access?.policyLabel, 'The local computer');
    expect(controller.access?.preferred, 'local');
    expect(controller.preferred?.name, 'marcuse');
    expect(controller.access?.entry('local')?.allowed, isTrue);
    expect(controller.access?.entry('cmp-studio-a1b2c3')?.allowed, isFalse);
    expect(controller.resources.map((resource) => resource.name), [
      'harness',
      'atlas',
    ]);
    final local = controller.computers.first;
    expect(local.capabilityNames, [
      'view',
      'windows',
      'pointer',
      'keyboard',
      'sandbox',
    ]);
    expect(local.hasSocket, isTrue);
    expect(local.viewable, isTrue);
    expect(local.stateLabel, 'Connected');
    expect(local.kindLabel, 'Local');
    expect(local.controlLabel, 'Agent');
  });

  test('a harness without the module shows no machines', () async {
    final (_, controller) = await _rig(computers: false);
    expect(controller.computers, isEmpty);
    expect(controller.access, isNull);
    expect(controller.error, isNull);
  });

  testWidgets('the page names the machines and their controls', (tester) async {
    final (app, controller) = await _rig();
    await _show(tester, app, controller);
    expect(find.text('Computers'), findsOneWidget);
    expect(find.text('Computer use'), findsOneWidget);
    expect(find.text('marcuse'), findsWidgets);
    expect(find.text('Connected'), findsWidgets);
    expect(find.text('View'), findsWidgets);
    expect(find.text('Control'), findsWidgets);
    expect(find.text('Revocation'), findsOneWidget);
    expect(find.text('Preference'), findsWidgets);
    expect(find.textContaining('1 resource'), findsWidgets);
    await tester.drag(find.byType(ListView), const Offset(0, -700));
    await tester.pump();
    expect(find.text('studio'), findsWidgets);
    expect(find.text('Grant'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('this client card has noun-phrase copy', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsController();
    await settings.load();
    final app = AppController(settings: settings);
    addTearDown(app.dispose);
    tester.view.physicalSize = const Size(390, 844);
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
            data: const MediaQueryData(size: Size(390, 844)),
            child: ComputersScreen(app: app, controller: ComputersController.preview()),
          ),
        ),
      ),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 80));
    }
    for (var i = 0;
        i < 12 && find.text('THIS CLIENT').evaluate().isEmpty;
        i++) {
      await tester.drag(find.byType(ListView), const Offset(0, -400));
      await tester.pump();
    }
    expect(find.text('THIS CLIENT'), findsOneWidget);
    expect(find.text('This phone'), findsOneWidget);
    expect(find.text('Not registered'), findsOneWidget);
    expect(find.text('Registration'), findsOneWidget);
    expect(find.text('File import'), findsOneWidget);
    expect(find.text('Screen'), findsOneWidget);
    expect(find.text('Camera'), findsOneWidget);
    expect(find.text('Microphone'), findsOneWidget);
    expect(find.text('Files'), findsOneWidget);
    expect(find.text('Clipboard'), findsOneWidget);
    expect(find.text('Not checked'), findsNWidgets(5));
    expect(
      find.text('Capture only · no pointer or keyboard control'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a capability is granted and revoked from the page', (tester) async {
    final (app, controller) = await _rig();
    await _show(tester, app, controller);
    final local = controller.computers.first;
    expect(local.allows('view'), isTrue);
    await controller.toggleCapability(local, 'view');
    expect(controller.notice, 'Capability revoked');
    expect(controller.error, isNull);
  });

  testWidgets('control switches the page to a person', (tester) async {
    final (app, controller) = await _rig();
    await _show(tester, app, controller);
    final local = controller.computers.first;
    expect(local.control, 'agent');
    await controller.takeControl(local);
    expect(controller.notice, 'Watching');
    expect(controller.computers.first.control, 'user');
    await tester.pump();
    expect(find.text('Return'), findsWidgets);
    await controller.releaseControl(controller.computers.first);
    expect(controller.computers.first.control, 'agent');
  });

  testWidgets('a grant is sent with the session and the computer', (tester) async {
    final (_, controller) = await _rig();
    await controller.grant(controller.computers.last);
    expect(controller.notice, 'Granted');
    expect(controller.error, isNull);
    await controller.prefer(controller.computers.last);
    expect(controller.notice, 'Preferred');
    expect(controller.error, isNull);
  });

  test('a computer without a socket has no screen', () {
    final computer = Computer.fromWire(const {
      'id': 'box',
      'name': 'box',
      'vnc': 'http://box:6080/vnc_lite.html',
      'capability-names': ['view'],
    });
    expect(computer.viewable, isTrue);
    expect(computer.hasSocket, isFalse);
  });
}
