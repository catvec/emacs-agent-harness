import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/models/workspace.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/resources_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:harness_client/src/ui/adaptive/platform_style.dart';
import 'package:harness_client/src/ui/adaptive/adaptive_widgets.dart';
import 'package:harness_client/src/ui/screens/resources_screen.dart';
import 'package:harness_client/src/ui/theme/harness_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';

const _workspace = WorkspaceSummary(id: 'w1', name: 'Home');

Future<(AppController, FakeHarness, ResourcesController)> _rig({
  bool resources = true,
}) async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsController();
  await settings.load();
  final harness = FakeHarness(workspace: true, resources: resources);
  final app = AppController(
    settings: settings,
    connector: harness.connector,
    reconnectDelays: const [Duration(milliseconds: 5)],
  );
  addTearDown(app.dispose);
  await app.connect('ws://memory/acp');
  final controller = ResourcesController(app.harness, workspaceId: 'w1');
  addTearDown(controller.dispose);
  await controller.load();
  return (app, harness, controller);
}

Future<void> _pump(
  WidgetTester tester,
  AppController app,
  ResourcesController controller, {
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
        debugShowCheckedModeBanner: false,
        theme: HarnessTheme.material(Brightness.light),
        home: MediaQuery(
          data: MediaQueryData(
            size: size,
            textScaler: TextScaler.linear(textScale),
          ),
          child: ResourcesScreen(
            app: app,
            workspace: _workspace,
            controller: controller,
          ),
        ),
      ),
    ),
  );
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

Finder _dialogText(String text) =>
    find.descendant(of: find.byType(AlertDialog), matching: find.text(text));

void main() {
  testWidgets('the phone shows the browser, its sites and its logins', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final (app, _, controller) = await _rig();
    await _pump(tester, app, controller);
    expect(find.text('Resources'), findsOneWidget);
    expect(find.text('Browser'), findsOneWidget);
    expect(find.text('Wallet'), findsOneWidget);
    expect(find.text('Credentials'), findsWidgets);
    expect(find.text('Access'), findsOneWidget);
    expect(find.text('Profile · Home'), findsOneWidget);
    expect(find.text('Firefox'), findsOneWidget);
    expect(find.text('Primary'), findsOneWidget);
    expect(find.text('Chromium'), findsOneWidget);
    expect(find.text('Secondary'), findsOneWidget);
    expect(find.text('stoneco.example'), findsWidgets);
    await tester.drag(find.byType(ListView), const Offset(0, -700));
    await tester.pumpAndSettle();
    expect(find.text('Saved logins'), findsOneWidget);
    expect(find.text('j•••@example.com · Active · 12m ago'), findsOneWidget);
    expect(find.text('Export…'), findsOneWidget);
    expect(find.text('Later stage'), findsNWidgets(2));
    expect(find.text('No sites'), findsNothing);
    expect(tester.takeException(), isNull);
    // The wire carried a fake cookie value and password; neither is drawn.
    final text = tester
        .widgetList<Text>(find.byType(Text))
        .map((widget) => widget.data ?? '')
        .join(' ');
    expect(text, isNot(contains('SESSION-SECRET')));
    expect(text, isNot(contains('hunter2')));
    expect(
      find.bySemanticsLabel(RegExp('Site stoneco.example')),
      findsOneWidget,
    );
    semantics.dispose();
  });

  testWidgets('a site sheet clears only after the confirmation', (
    tester,
  ) async {
    final (app, harness, controller) = await _rig();
    await _pump(tester, app, controller);
    await tester.tap(find.text('stoneco.example').first);
    await tester.pumpAndSettle();
    expect(find.text('Site data deletion'), findsOneWidget);
    expect(find.text('Login removal'), findsOneWidget);
    expect(find.text('Cookies'), findsWidgets);
    expect(harness.resourcesCalls, isEmpty);

    // Cancel changes nothing and sends nothing.
    await tester.tap(find.text('Deletion').first);
    await tester.pumpAndSettle();
    expect(find.text('Cookie deletion'), findsOneWidget);
    await tester.tap(_dialogText('Cancel'));
    await tester.pumpAndSettle();
    expect(harness.resourcesCalls, isEmpty);
    expect(controller.resources!.browser!.sites.first.cookies, 12);

    // Confirming sends the scope and the kinds.
    await tester.tap(find.text('Deletion').first);
    await tester.pumpAndSettle();
    await tester.tap(_dialogText('Deletion'));
    await tester.pumpAndSettle();
    expect(controller.resources!.browser!.sites.first.cookies, 0);
    expect(controller.resources!.browser!.sites.first.auth, 'signed-out');
    expect(
      harness.resourcesCalls.last['method'],
      '_harness/workspace/browser/clear',
    );
    expect(controller.notice, 'Cleared');
  });

  testWidgets('a login is forgotten only after the confirmation', (
    tester,
  ) async {
    final (app, harness, controller) = await _rig();
    await _pump(tester, app, controller);
    await tester.drag(find.byType(ListView), const Offset(0, -700));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Removal'));
    await tester.pumpAndSettle();
    expect(find.text('Login removal'), findsWidgets);
    await tester.tap(_dialogText('Cancel'));
    await tester.pumpAndSettle();
    expect(harness.resourcesCalls, isEmpty);
    await tester.tap(find.text('Removal'));
    await tester.pumpAndSettle();
    await tester.tap(_dialogText('Removal'));
    await tester.pumpAndSettle();
    expect(controller.resources!.browser!.logins, isEmpty);
    expect(
      harness.resourcesCalls.last['method'],
      '_harness/workspace/browser/login/forget',
    );
  });

  testWidgets('the wallet shows the card, the bound and the purchase', (
    tester,
  ) async {
    final (app, harness, controller) = await _rig();
    await _pump(tester, app, controller, size: const Size(1440, 900));
    await tester.tap(find.text('Wallet'));
    await tester.pumpAndSettle();
    expect(find.text('Visa •••• 4242'), findsWidgets);
    expect(find.textContaining('09/2028'), findsOneWidget);
    expect(find.text('Purchase · \$9.40'), findsOneWidget);
    expect(find.textContaining('Cumulative'), findsWidgets);
    expect(find.textContaining('Remaining \$0.60'), findsWidgets);
    expect(find.text('Advisory · no broker'), findsWidgets);
    expect(find.text('Add card…'), findsOneWidget);
    expect(find.text('No wallet provider'), findsWidgets);

    await tester.ensureVisible(find.text('Allow'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Allow'));
    await tester.pumpAndSettle();
    expect(find.text('Allow purchase'), findsOneWidget);
    await tester.tap(_dialogText('Allow'));
    await tester.pumpAndSettle();
    expect(controller.resources!.wallet!.purchases.single.status, 'approved');
    expect(
      harness.resourcesCalls.last['method'],
      '_harness/workspace/wallet/purchase/decide',
    );
    expect(controller.notice, 'Allowed');
  });

  testWidgets('an authorization is bounded by a validated form', (
    tester,
  ) async {
    final (app, harness, controller) = await _rig();
    await _pump(tester, app, controller, size: const Size(1440, 900));
    await tester.tap(find.text('Wallet'));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -700));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New authorization'));
    await tester.pumpAndSettle();
    expect(find.text('New authorization'), findsWidgets);
    expect(find.text('Cap · USD'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('authorization-amount')),
      '5.00',
    );
    await tester.enterText(
      find.byKey(const ValueKey('authorization-merchant')),
      'stoneco.example',
    );
    await tester.pump();
    await tester.ensureVisible(find.text('Create'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(controller.resources!.wallet!.authorizations.length, 2);
    expect(controller.notice, 'Authorization created');
    final params = harness.resourcesCalls.last['params'] as Map;
    expect(params['amount'], 500);
    expect(params['merchant-scope'], ['stoneco.example']);
    expect(params['fees'], 'included');
  });

  testWidgets('credentials come from the secrets module, without values', (
    tester,
  ) async {
    final (app, _, controller) = await _rig();
    await _pump(tester, app, controller, size: const Size(1440, 900));
    await tester.ensureVisible(find.text('Credentials').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Credentials').last);
    await tester.pumpAndSettle();
    expect(find.text('Secrets module'), findsOneWidget);
    expect(find.text('deploy-key'), findsOneWidget);
    expect(find.text('npm-token'), findsOneWidget);
    expect(find.textContaining('SHA-256 4f9c2a1b'), findsOneWidget);
    expect(find.text('Ready'), findsOneWidget);
    expect(find.text('Unavailable'), findsWidgets);
    final text = tester
        .widgetList<Text>(find.byType(Text))
        .map((widget) => widget.data ?? '')
        .join(' ');
    expect(text, isNot(contains('SECRET-VALUE')));
    await tester.tap(find.text('deploy-key'));
    await tester.pumpAndSettle();
    expect(find.text('Sandbox only'), findsOneWidget);
    expect(controller.resources!.credentials.length, 2);
  });

  testWidgets('access and audit are one page', (tester) async {
    final semantics = tester.ensureSemantics();
    final (app, _, controller) = await _rig();
    await _pump(tester, app, controller);
    await tester.ensureVisible(find.text('Access'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Access'));
    await tester.pumpAndSettle();
    expect(find.text('Agent access'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Audit'), 200);
    expect(find.text('Audit'), findsOneWidget);
    expect(find.text('Allowed'), findsWidgets);
    expect(find.text('Ask'), findsWidgets);
    expect(find.text('Revocation'), findsWidgets);
    semantics.dispose();
  });

  testWidgets('a preview is labelled and its actions do nothing', (
    tester,
  ) async {
    final app = AppController(settings: SettingsController());
    addTearDown(app.dispose);
    final controller = ResourcesController.preview();
    addTearDown(controller.dispose);
    await _pump(tester, app, controller);
    expect(find.text('Preview · no changes'), findsOneWidget);
    expect(find.text('Deletion…'), findsOneWidget);
    final clearAll = tester.widget<HarnessTextButton>(
      find.widgetWithText(HarnessTextButton, 'Deletion…'),
    );
    expect(clearAll.onPressed, isNull);
    expect(controller.canManage, isFalse);
  });

  testWidgets('a harness without the box says so', (tester) async {
    final (app, _, controller) = await _rig(resources: false);
    await _pump(tester, app, controller);
    expect(find.text('Unavailable'), findsOneWidget);
    expect(find.text('Computer tools'), findsWidgets);
    expect(find.text('No browser data'), findsOneWidget);
  });

  testWidgets('the page holds at desktop widths and larger text', (
    tester,
  ) async {
    final (app, harness, controller) = await _rig();
    for (final size in const [
      Size(390, 844),
      Size(900, 700),
      Size(1440, 900),
    ]) {
      for (final scale in const [1.0, 1.5, 2.0]) {
        await _pump(tester, app, controller, size: size, textScale: scale);
        expect(tester.takeException(), isNull, reason: '$size at $scale');
        expect(find.text('Resources'), findsOneWidget);
        expect(find.text('Browser'), findsOneWidget);
      }
    }
    expect(harness.resourcesCalls, isEmpty);
  });

  testWidgets('a refused clear keeps the old state and says why', (
    tester,
  ) async {
    final (app, harness, controller) = await _rig();
    await _pump(tester, app, controller);
    harness.resourcesFail = true;
    await tester.tap(find.text('stoneco.example').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Deletion').first);
    await tester.pumpAndSettle();
    await tester.tap(_dialogText('Deletion'));
    await tester.pumpAndSettle();
    expect(find.textContaining('box refused'), findsWidgets);
    expect(controller.resources!.browser!.sites.first.cookies, 12);
  });
}
