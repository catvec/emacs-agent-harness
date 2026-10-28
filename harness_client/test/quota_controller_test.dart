import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/models/quota.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';

class _Rig {
  _Rig(this.harness, this.app);
  final FakeHarness harness;
  final AppController app;

  /// The providers `provider/quota` was asked about, in order.
  List<String> get asked => [
    for (final (method, params) in harness.requests)
      if (method == '_harness/provider/quota') '${params['providerId']}',
  ];
}

/// An app connected to a fake harness, once its plan quota has arrived.
Future<_Rig> _rig({bool quota = true, bool enhanced = true}) async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsController();
  await settings.load();
  final harness = FakeHarness(quota: quota, enhanced: enhanced);
  final app = AppController(
    settings: settings,
    connector: harness.connector,
    reconnectDelays: const [Duration(milliseconds: 5)],
  );
  addTearDown(app.dispose);
  await app.connect('ws://memory/acp');
  if (quota && enhanced) {
    await _until(() => app.quota?.lastLoaded != null, what: 'the plan quota');
  }
  return _Rig(harness, app);
}

Future<void> _until(bool Function() done, {String? what}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for ${what ?? 'the app'}.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 4));
  }
}

/// What the harness says Claude's plan is now, with its 5-hour window [used].
Map<String, Object?> _claude(double used, {Map<String, Object?>? more}) => {
  'billing': 'subscription',
  'plan': 'max',
  'plan-label': 'Claude Max',
  'windows': [
    {'name': '5h', 'label': 'Current session (5 hours)', 'used': used},
  ],
  ...?more,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the plan quota of the providers', () {
    test('is asked of the providers that report one, and no others', () async {
      final rig = await _rig();
      final quota = rig.app.quota!;
      expect(rig.asked.toSet(), {'claude', 'copilot'});
      expect(quota.quotas.map((q) => q.provider), ['claude', 'copilot']);
      expect(quota.of('deepseek'), isNull);
      expect(quota.of(null), isNull);
      // Asked for what it knows, not to ask its source again.
      expect(rig.harness.quotaRefreshes, 0);
      expect([
        for (final (method, params) in rig.harness.requests)
          if (method == '_harness/provider/quota') params['refresh'],
      ], everyElement(false));
    });

    test('is the quota of the provider of a session\'s model', () async {
      final rig = await _rig();
      final quota = rig.app.quota!;
      expect(
        quota.forModel('claude:claude-fable-5-1')!.planLabel,
        'Claude Max',
      );
      expect(
        quota.forModel('copilot:gpt-5.2-codex')!.planLabel,
        'GitHub Copilot Pro',
      );
      expect(quota.forModel('deepseek:deepseek-chat'), isNull);
      expect(quota.forModel('no-provider'), isNull);
      expect(quota.forModel(null), isNull);
    });

    test('has each provider named as the harness names it', () async {
      final rig = await _rig();
      final quota = rig.app.quota!;
      expect(quota.labelOf('claude'), 'Claude');
      expect(quota.labelOf('copilot'), 'GitHub Copilot');
      // One it was not told about is made readable.
      expect(quota.labelOf('mystery'), 'Mystery');
    });

    test('is asked again by the providers when the user asks again', () async {
      final rig = await _rig();
      final quota = rig.app.quota!;
      await quota.load(refresh: true);
      expect(rig.harness.quotaRefreshes, 2);
    });

    test('follows what a provider announces', () async {
      final rig = await _rig();
      final quota = rig.app.quota!;
      var changes = 0;
      quota.addListener(() => changes++);
      expect(quota.of('claude')!.windows.first.percent, 23);

      rig.harness.updateQuota('claude', _claude(0.96));
      await _until(
        () => quota.of('claude')!.windows.first.percent == 96,
        what: 'the announcement',
      );
      expect(quota.of('claude')!.windows.first.level, QuotaLevel.critical);
      expect(changes, 1);

      // Saying the same again is no change.
      rig.harness.updateQuota('claude', _claude(0.96));
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(changes, 1);

      // The app is told too, so the screens that show it draw it again.
      var appChanges = 0;
      rig.app.addListener(() => appChanges++);
      rig.harness.updateQuota('claude', _claude(0.97));
      await _until(() => appChanges > 0, what: 'the app to be told');
    });

    test('learns of a provider that did not report one before', () async {
      final rig = await _rig();
      final quota = rig.app.quota!;
      rig.harness.updateQuota('deepseek', {
        'billing': 'api',
        'auth': 'DEEPSEEK_API_KEY',
      });
      await _until(() => quota.of('deepseek') != null, what: 'the quota');
      expect(quota.of('deepseek')!.billsPerToken, isTrue);
      expect(quota.quotas.map((q) => q.provider), [
        'claude',
        'copilot',
        'deepseek',
      ]);
    });

    test('forgets a quota a provider takes back', () async {
      final rig = await _rig();
      final quota = rig.app.quota!;
      rig.harness.announce('provider/quota-updated', ['copilot', null]);
      await _until(() => quota.of('copilot') == null, what: 'it to go');
      expect(quota.quotas.map((q) => q.provider), ['claude']);
    });

    test('keeps what it knows when a provider fails to answer', () async {
      final rig = await _rig();
      final quota = rig.app.quota!;
      rig.harness.failQuota = true;
      await quota.load(refresh: true);
      expect(quota.of('claude')!.planLabel, 'Claude Max');
      expect(quota.of('copilot')!.planLabel, 'GitHub Copilot Pro');
      expect(quota.loading, isFalse);
    });

    test('is read again once the connection is back', () async {
      final rig = await _rig();
      final quota = rig.app.quota!;
      final before = rig.asked.length;
      // The plan filled up while the app was out of touch.
      rig.harness.quotas['claude'] = _claude(0.88);
      await rig.harness.dropConnection('The connection dropped.');
      await _until(() => rig.harness.connects == 2 && rig.app.isConnected);
      await _until(
        () => quota.of('claude')!.windows.first.percent == 88,
        what: 'the plan quota to be read again',
      );
      expect(rig.asked.length, greaterThan(before));
      // It is the same controller: what showed it need not look elsewhere.
      expect(rig.app.quota, same(quota));
    });

    test('is asked again when the harness reloads', () async {
      final rig = await _rig();
      final quota = rig.app.quota!;
      rig.harness.quotas['claude'] = _claude(0.5);
      rig.harness.announce('harness/reloaded');
      await _until(
        () => quota.of('claude')!.windows.first.percent == 50,
        what: 'the plan quota to be read again',
      );
    });

    test(
      'fetches a newly signed-in ChatGPT provider without reconnect',
      () async {
        final rig = await _rig();
        final quota = rig.app.quota!;
        expect(quota.of('chatgpt'), isNull);
        expect(rig.harness.connects, 1);
        rig.harness.chatgptProvider = true;
        rig.harness.quotas['chatgpt'] = {
          'billing': 'subscription',
          'plan': 'plus',
          'plan-label': 'ChatGPT Plus',
          'windows': [
            {'name': '5h', 'used': 0.34},
            {'name': '7d', 'used': 0.61},
          ],
        };
        // Provider registration announces models, not necessarily quota.
        rig.harness.announce('provider/models-updated');
        await _until(
          () => quota.of('chatgpt') != null,
          what: 'the new provider',
        );
        expect(rig.harness.connects, 1);
        expect(quota.labelOf('chatgpt'), 'ChatGPT plan');
        expect(quota.forModel('chatgpt:gpt-6-sol')!.planLabel, 'ChatGPT Plus');
        expect(quota.of('chatgpt')!.windows.map((w) => w.percent), [34, 61]);
        expect(rig.asked, contains('chatgpt'));
      },
    );

    test('says it is loading while it is asked', () async {
      final rig = await _rig();
      final quota = rig.app.quota!;
      final states = <bool>[];
      quota.addListener(() => states.add(quota.loading));
      final done = quota.load(showSpinner: true);
      expect(quota.loading, isTrue);
      await done;
      expect(quota.loading, isFalse);
      expect(states.first, isTrue);
      expect(states.last, isFalse);
    });
  });

  group('a harness without provider/quota', () {
    test(
      'is never asked for one, and shows the plan its sessions name',
      () async {
        final rig = await _rig(quota: false);
        expect(rig.app.quota, isNull);
        expect(rig.app.hasQuota, isFalse);
        expect(rig.asked, isEmpty);
        // A session still says who paid, from the billing it recorded.
        final session = rig.app.summaryFor('s1');
        final status = rig.app.spendOf(session);
        expect(status.text, 'Max');
        expect(status.planned, isTrue);
        expect(status.windows, isEmpty);
        expect(
          status.help,
          'Covered by the Max plan, not billed per token. '
          'This session at API prices: \$3.25.',
        );
      },
    );

    test('a plain ACP agent has none either', () async {
      final rig = await _rig(enhanced: false);
      expect(rig.app.quota, isNull);
      expect(rig.asked, isEmpty);
    });
  });

  group('the cost of sessions and tasks', () {
    test('a session reads as its plan, with its quota', () async {
      final rig = await _rig();
      final status = rig.app.spendOf(rig.app.summaryFor('s1'));
      expect(status.text, 'Max');
      expect(status.line, 'Max · 5h 23% · 7d 41%');
      expect(rig.app.providerLabelOf(status), 'Claude');
    });

    test('a session billed beyond its plan reads as both', () async {
      final rig = await _rig();
      final status = rig.app.spendOf(rig.app.summaryFor('s2'));
      expect(status.line, '\$0.12+Max · 5h 23% · 7d 41%');
    });

    test(
      'a session on a provider that bills per token reads as a price',
      () async {
        final rig = await _rig();
        final status = rig.app.spendOf(rig.app.summaryFor('s4'));
        expect(status.text, '\$0.21');
        expect(status.planned, isFalse);
        expect(rig.app.providerLabelOf(status), isNull);
      },
    );

    test('the tasks of a board read together, as the plan pays', () async {
      final rig = await _rig();
      await rig.app.tasks!.load(project: rig.app.selectedProject);
      final status = rig.app.spendOfTasks(
        rig.app.tasks!.tasks,
        model: 'claude:claude-fable-5-1',
      );
      // task-4's session was billed beyond the plan, task-1's is covered.
      expect(status.line, '\$0.12+Max · 5h 23% · 7d 41%');
      expect(status.help, startsWith('\$0.12 billed; '));
      expect(status.help, contains('covered by Claude Max'));
    });

    test('a board with no tasks yet is paid by its model\'s account', () async {
      final rig = await _rig();
      final status = rig.app.spendOfTasks(
        const [],
        model: 'claude:claude-fable-5-1',
      );
      expect(status.line, 'Max · 5h 23% · 7d 41%');
      expect(status.help, startsWith('Covered by Claude Max, not billed'));
      expect(status.help, contains('These tasks at API prices: \$0.00.'));
      // A provider that bills per token has nothing to say of no tasks.
      expect(
        rig.app
            .spendOfTasks(const [], model: 'deepseek:deepseek-chat')
            .worthShowing,
        isFalse,
      );
    });
  });
}
