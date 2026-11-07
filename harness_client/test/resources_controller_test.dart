import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/resources_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';

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

void main() {
  test('the resources page reads the browser, wallet and access', () async {
    final (_, _, controller) = await _rig();
    expect(controller.resources!.ready, isTrue);
    expect(controller.resources!.browser!.sites.length, 2);
    expect(controller.resources!.browser!.logins.single.id, 'lg-1');
    expect(controller.resources!.wallet!.cards.single.last4, '4242');
    expect(controller.resources!.wallet!.authorizations.single.remaining, 60);
    expect(controller.resources!.access, isNotEmpty);
    expect(controller.resources!.audit, isNotEmpty);
    expect(controller.canManage, isTrue);
  });

  test('clearing a site sends its scope and kinds and takes the login', () async {
    final (_, harness, controller) = await _rig();
    await controller.clearSite('https://stoneco.example', const ['cookies']);
    final site = controller.resources!.browser!.sites
        .firstWhere((item) => item.host == 'stoneco.example');
    expect(site.cookies, 0);
    expect(site.auth, 'signed-out');
    expect(controller.resources!.browser!.logins, isEmpty);
    expect(controller.notice, 'Cleared');
    final call = harness.resourcesCalls.last;
    expect(call['method'], '_harness/workspace/browser/clear');
    expect((call['params'] as Map)['scope'], 'site');
    expect((call['params'] as Map)['origin'], 'https://stoneco.example');
    expect((call['params'] as Map)['kinds'], ['cookies']);
  });

  test('forgetting a login removes only that login', () async {
    final (_, harness, controller) = await _rig();
    await controller.forgetLogin('lg-1');
    expect(controller.resources!.browser!.logins, isEmpty);
    expect(controller.resources!.browser!.sites, isNotEmpty);
    expect(controller.notice, 'Login forgotten');
    expect(harness.resourcesCalls.last['method'], '_harness/workspace/browser/login/forget');
  });

  test('a bounded authorization is created with its cap and expiry', () async {
    final (_, harness, controller) = await _rig();
    final problem = await controller.createAuthorization(
      card: 'card-1',
      amount: 1000,
      merchant: 'stoneco.example',
      capKind: 'cumulative',
      expiry: '24h',
      fees: 'included',
    );
    expect(problem, isNull);
    expect(controller.resources!.wallet!.authorizations.length, 2);
    expect(controller.notice, 'Authorization created');
    final params = harness.resourcesCalls.last['params'] as Map;
    expect(params['amount'], 1000);
    expect(params['currency'], 'USD');
    expect(params['cap-kind'], 'cumulative');
    expect(params['merchant-scope'], ['stoneco.example']);
    expect(params['expires'], '24h');
    expect(params['fees'], 'included');
  });

  test('an empty amount or merchant is refused before the harness', () async {
    final (_, harness, controller) = await _rig();
    final before = harness.resourcesCalls.length;
    expect(
      await controller.createAuthorization(
        card: 'card-1',
        amount: 0,
        merchant: 'stoneco.example',
        capKind: 'cumulative',
        expiry: '24h',
        fees: 'included',
      ),
      'Amount',
    );
    expect(
      await controller.createAuthorization(
        card: 'card-1',
        amount: 100,
        merchant: '  ',
        capKind: 'cumulative',
        expiry: '24h',
        fees: 'included',
      ),
      'Merchant',
    );
    expect(harness.resourcesCalls.length, before);
  });

  test('revoking removes the authorization access, not its history', () async {
    final (_, _, controller) = await _rig();
    await controller.revokeAuthorization('auth-1');
    expect(controller.resources!.wallet!.authorizations.single.status, 'revoked');
    expect(controller.resources!.wallet!.purchases, isNotEmpty);
    expect(controller.notice, 'Authorization revoked');
  });

  test('a purchase is allowed or denied, never silently', () async {
    final (_, harness, controller) = await _rig();
    await controller.decidePurchase('buy-1', allow: true);
    expect(controller.resources!.wallet!.purchases.single.status, 'approved');
    expect(controller.notice, 'Allowed');
    expect(
      (harness.resourcesCalls.last['params'] as Map)['decision'],
      'allow',
    );
    await controller.decidePurchase('buy-1', allow: false);
    expect(controller.resources!.wallet!.purchases.single.status, 'declined');
    expect(controller.notice, 'Denied');
  });

  test('a refused request keeps the old state and says why', () async {
    final (_, harness, controller) = await _rig();
    harness.resourcesFail = true;
    await controller.clearSite('https://stoneco.example', const ['cookies']);
    expect(controller.resources!.ready, isTrue);
    expect(
      controller.resources!.browser!.sites
          .firstWhere((item) => item.host == 'stoneco.example')
          .cookies,
      12,
    );
    expect(controller.error, contains('box refused'));
    expect(controller.notice, isNull);
  });

  test('a harness without the contract opens on the blocked answer', () async {
    final (_, harness, controller) = await _rig(resources: false);
    expect(controller.resources!.status, 'unavailable');
    expect(controller.resources!.reason, 'box-staged');
    expect(controller.canManage, isFalse);
    await controller.clearSite('https://stoneco.example', const ['cookies']);
    expect(harness.resourcesCalls, isEmpty);
  });

  test('a credentials-only answer still opens, with its actions blocked', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsController();
    await settings.load();
    final harness = FakeHarness(workspace: true, resources: true, resourcesCredentialsOnly: true);
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
    expect(controller.resources!.credentialsReady, isTrue);
    expect(controller.resources!.credentials.length, 2);
    expect(controller.resources!.browser, isNull);
    expect(controller.resources!.wallet, isNull);
    expect(controller.resources!.statusLabel, 'Partial');
    expect(controller.canManageBrowser, isFalse);
    expect(controller.canManageWallet, isFalse);
  });

  test('a preview never reports a change', () async {
    final controller = ResourcesController.preview();
    addTearDown(controller.dispose);
    expect(controller.preview, isTrue);
    expect(controller.resources!.browser!.sites, isNotEmpty);
    expect(controller.canManage, isFalse);
    await controller.clearSite('https://stoneco.example', const ['cookies']);
    expect(controller.resources!.browser!.sites.first.cookies, 12);
    expect(controller.notice, isNull);
  });
}
