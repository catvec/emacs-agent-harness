import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/models/quota.dart';
import 'package:harness_client/src/models/server_info.dart';
import 'package:harness_client/src/models/session.dart';

// The plan quota as the client reads it.  The wording and the arithmetic are
// Emacs's (`harness-ui-format-spend`, `harness-ui-spend-help` and the plan
// section of the usage dashboard), so most of these are its own tests: the
// same data must read the same in both.

/// When the quotas below are read: a Thursday, midday.
final _now = DateTime(2026, 10, 22, 12);

double _at(Duration after) =>
    _now.add(after).millisecondsSinceEpoch / Duration.millisecondsPerSecond;

/// A Claude Max quota as the provider reports it (Emacs's
/// `harness-ui-usage-test-max-quota`).
ProviderQuota _max({List<Map<String, Object?>>? windows}) =>
    ProviderQuota.fromWire('claude', {
      'billing': 'subscription',
      'plan': 'max',
      'plan-label': 'Claude Max',
      'account': {'email': 'user@example.com'},
      'auth': 'claude.ai',
      'windows':
          windows ??
          [
            {
              'name': '5h',
              'label': 'Current session (5 hours)',
              'used': 0.09,
              'resets': _at(const Duration(hours: 1)),
            },
            {
              'name': '7d',
              'label': 'This week, all models',
              'used': 0.57,
              'resets': _at(const Duration(seconds: 200000)),
            },
            {
              'name': '7d Fable',
              'label': 'This week, Fable',
              'used': 0.5,
              'resets': _at(const Duration(seconds: 200000)),
            },
          ],
      'extra': {
        'enabled': false,
        'used': 0.0,
        'limit': 50.0,
        'disabled-reason': 'out_of_credits',
      },
      'updated': _at(Duration.zero),
    });

SpendStatus _spend(Usage? usage, {ProviderQuota? quota, String? subject}) =>
    SpendStatus.of(
      usage: usage,
      quota: quota,
      subject: subject ?? 'This session',
      now: _now,
    );

void main() {
  group('a quota window', () {
    test('reads as a percentage, rounded as Emacs rounds', () {
      expect(const QuotaWindow(name: '5h', used: 0.09).percent, 9);
      expect(const QuotaWindow(name: '7d', used: 0.57).percent, 57);
      // 0.57 * 100 is 56.99999999999999: still 57.
      expect(const QuotaWindow(name: '7d', used: 0.5).percent, 50);
      // Halves go to the even number, as `round` does in Emacs.
      expect(roundHalfEven(22.5), 22);
      expect(roundHalfEven(23.5), 24);
      expect(roundHalfEven(0.5), 0);
      expect(roundHalfEven(1.5), 2);
      expect(roundHalfEven(2.4), 2);
      expect(roundHalfEven(2.6), 3);
    });

    test('is a headline window when it is the session, the week or full', () {
      bool headline(String name, double used) =>
          QuotaWindow(name: name, used: used).headline;
      expect(headline('5h', 0.0), isTrue);
      expect(headline('7d', 0.1), isTrue);
      expect(headline('7d Fable', 0.5), isFalse);
      expect(headline('7d Fable', 0.69), isFalse);
      expect(headline('7d Fable', 0.7), isTrue);
      expect(headline('premium', 0.96), isTrue);
    });

    test('is coloured by how full it is: 70%, 85% and 95%', () {
      QuotaLevel level(double used) => quotaLevelOf(used);
      expect(level(0.0), QuotaLevel.calm);
      expect(level(0.69), QuotaLevel.calm);
      expect(level(0.70), QuotaLevel.warning);
      expect(level(0.84), QuotaLevel.warning);
      expect(level(0.85), QuotaLevel.urgent);
      expect(level(0.94), QuotaLevel.urgent);
      expect(level(0.95), QuotaLevel.critical);
      expect(level(1.0), QuotaLevel.critical);
    });

    test('says what it is, how much is used and when it resets', () {
      final window = _max().windows.first;
      expect(window.short, '5h 9%');
      expect(
        window.describe(now: _now),
        'Current session (5 hours): 9% used, resets in 1h00m (13:00)',
      );
      // Without a label the name stands in; without a reset time there is
      // nothing to say about one.
      expect(
        const QuotaWindow(name: '7d Fable', used: 0.96).describe(now: _now),
        '7d Fable: 96% used',
      );
    });

    test('is read from the wire, a missing field at a time', () {
      final window = QuotaWindow.fromWire({
        'name': '5h',
        'label': 'Current session (5 hours)',
        'used': 1,
        'resets': _at(const Duration(minutes: 5)),
        'model': 'Fable',
        'kind': 'session',
      });
      // A provider may send a whole number for a window that is full (or
      // empty): 1 is all of it, not a hundredth.
      expect(window.used, 1.0);
      expect(window.percent, 100);
      expect(QuotaWindow.fromWire({'name': 'x', 'used': 0}).percent, 0);
      expect(window.model, 'Fable');
      expect(window.kind, 'session');
      expect(window.resets, isNotNull);
      final bare = QuotaWindow.fromWire({'label': 'Chat messages this month'});
      expect(bare.name, 'Chat messages this month');
      expect(bare.used, 0);
      expect(bare.resets, isNull);
      expect(QuotaWindow.fromWire({'name': 'x', 'used': -3}).used, 0);
    });
  });

  group('when a window resets', () {
    test('is "now" once it has', () {
      expect(formatReset(_now, now: _now), 'now');
      expect(
        formatReset(_now.subtract(const Duration(hours: 2)), now: _now),
        'now',
      );
    });

    test('is a countdown with the clock within a day', () {
      expect(
        formatReset(_now.add(const Duration(hours: 3, minutes: 12)), now: _now),
        'in 3h12m (15:12)',
      );
      expect(
        formatReset(
          _now.add(const Duration(minutes: 59, seconds: 59)),
          now: _now,
        ),
        'in 59m59s (12:59)',
      );
      expect(
        formatReset(_now.add(const Duration(seconds: 42)), now: _now),
        'in 42.0s (12:00)',
      );
    });

    test('is a date from a day on', () {
      expect(
        formatReset(DateTime(2026, 10, 24, 19, 33), now: _now),
        'Sat Oct 24, 19:33',
      );
      expect(formatReset(null, now: _now), isNull);
    });

    test('counts down as Emacs does', () {
      expect(formatCountdown(const Duration(milliseconds: 250)), '250ms');
      expect(
        formatCountdown(const Duration(seconds: 5, milliseconds: 500)),
        '5.5s',
      );
      expect(formatCountdown(const Duration(minutes: 3, seconds: 7)), '3m07s');
      expect(formatCountdown(const Duration(hours: 1)), '1h00m');
      expect(formatCountdown(const Duration(hours: 23, minutes: 59)), '23h59m');
    });
  });

  group('a provider\'s quota', () {
    test('is read from what provider/quota returns', () {
      final quota = _max();
      expect(quota.provider, 'claude');
      expect(quota.billing, 'subscription');
      expect(quota.isPlan, isTrue);
      expect(quota.billsPerToken, isFalse);
      expect(quota.plan, 'max');
      expect(quota.planLabel, 'Claude Max');
      expect(quota.planName, 'Max');
      expect(quota.auth, 'claude.ai');
      expect(quota.email, 'user@example.com');
      expect(quota.windows.map((window) => window.name), [
        '5h',
        '7d',
        '7d Fable',
      ]);
      expect(quota.windows.map((window) => window.percent), [9, 57, 50]);
      // The 5-hour and weekly windows, not the quiet one for one model.
      expect(quota.headlineWindows.map((window) => window.short), [
        '5h 9%',
        '7d 57%',
      ]);
      expect(quota.updated, isNotNull);
      expect(quota.limitStatus, isNull);
      expect(quota.usingExtra, isFalse);
    });

    test('says how much extra usage the plan allows', () {
      expect(
        _max().extra!.describe(),
        'Extra usage: off (out of credits), \$0.00 used of \$50.0',
      );
      expect(
        const QuotaExtra(enabled: true, used: 1.5, limit: 20).describe(),
        'Extra usage: on, \$1.50 used of \$20.0',
      );
      // A reason only explains why it is off.
      expect(
        const QuotaExtra(enabled: true, disabledReason: 'x_y').describe(),
        'Extra usage: on',
      );
      expect(const QuotaExtra().describe(), 'Extra usage: off');
    });

    test('knows when the limit was reached and extra usage is drawn on', () {
      final quota = ProviderQuota.fromWire('claude', {
        'billing': 'extra-usage',
        'limit-status': 'rejected',
        'using-extra': true,
      });
      expect(quota.isPlan, isTrue);
      expect(quota.limitStatus, 'rejected');
      expect(quota.usingExtra, isTrue);
      expect(quota.windows, isEmpty);
      expect(quota.extra, isNull);
    });

    test('an API account bills per token and has no windows', () {
      final quota = ProviderQuota.fromWire('claude', {
        'billing': 'api',
        'auth': 'ANTHROPIC_API_KEY',
      });
      expect(quota.billsPerToken, isTrue);
      expect(quota.isPlan, isFalse);
      expect(quota.auth, 'ANTHROPIC_API_KEY');
      expect(quota.planName, isNull);
    });

    test('is the same when nothing in it changed', () {
      expect(_max().sameAs(_max()), isTrue);
      final other = _max(
        windows: [
          {'name': '5h', 'used': 0.2},
        ],
      );
      expect(_max().sameAs(other), isFalse);
      expect(_max().sameAs(null), isFalse);
    });

    test('names the plan: its label, else its id, else the subscription', () {
      expect(planNameOf('max'), 'Max');
      expect(planNameOf('claude_max'), 'Claude Max');
      expect(planNameOf('pro'), 'Pro');
      expect(planNameOf(''), isNull);
      expect(planNameOf(null), isNull);
      expect(planTitleOf(_max()), 'Claude Max');
      expect(planTitleOf(_max(), 'max'), 'Claude Max');
      // Another plan than the one the provider reports now.
      expect(planTitleOf(_max(), 'pro'), 'the Pro plan');
      expect(planTitleOf(null, 'pro'), 'the Pro plan');
      expect(planTitleOf(null), 'the subscription');
    });

    test('belongs to the provider of a model', () {
      expect(providerOfModel('claude:claude-fable-5-1'), 'claude');
      expect(providerOfModel('copilot:gpt-5.2-codex'), 'copilot');
      expect(providerOfModel('claude-fable-5-1'), isNull);
      expect(providerOfModel(null), isNull);
    });

    test('a provider says whether it reports one in provider/list', () {
      final claude = ProviderInfo.fromWire({
        'id': 'claude',
        'label': 'Claude',
        'capabilities': {'quota': true, 'billing': true},
      });
      expect(claude.reportsQuota, isTrue);
      final deepseek = ProviderInfo.fromWire({
        'id': 'deepseek',
        'capabilities': {'quota': false},
      });
      expect(deepseek.reportsQuota, isFalse);
      expect(ProviderInfo.fromWire({'id': 'old'}).reportsQuota, isFalse);
    });
  });

  group('what a session cost and who pays', () {
    // Emacs's `harness-ui-spend-says-who-pays`.
    const api = Usage(input: 10, cost: 1.2, listCost: 1.2, billing: 'api');
    const plan = Usage(
      input: 100,
      cost: 0,
      listCost: 3.4,
      billing: 'subscription',
      plan: 'max',
    );
    const mixed = Usage(
      input: 100,
      cost: 0.4,
      listCost: 3.8,
      billing: 'extra-usage',
      plan: 'max',
    );
    const fresh = Usage();
    const old = Usage(input: 100, cost: 2);

    test('is the price when calls are billed per token', () {
      final status = _spend(api);
      expect(status.text, '\$1.20');
      expect(status.planned, isFalse);
      expect(status.windows, isEmpty);
      expect(status.worthShowing, isTrue);
      expect(status.help, 'This session cost \$1.20, billed per token.');
    });

    test('says which credentials bill per token when it knows', () {
      final quota = ProviderQuota.fromWire('claude', {
        'billing': 'api',
        'auth': 'ANTHROPIC_API_KEY',
      });
      expect(
        _spend(api, quota: quota).help,
        'This session cost \$1.20, billed per token (ANTHROPIC_API_KEY).',
      );
    });

    test('is the plan\'s name when a subscription pays', () {
      final status = _spend(plan);
      expect(status.text, 'Max');
      expect(status.planned, isTrue);
      expect(status.worthShowing, isTrue);
      expect(status.covered, closeTo(3.4, 1e-9));
    });

    test('is the plan after what was billed as extra usage', () {
      expect(_spend(mixed).text, '\$0.40+Max');
    });

    test('is no plan when a cost and its list price differ by rounding', () {
      // Added in another order, 0.1 + 0.2 is not quite 0.3.
      const noise = Usage(
        input: 10,
        cost: 0.30000000000000004,
        listCost: 0.3,
        billing: 'api',
      );
      expect(_spend(noise).planned, isFalse);
      expect(_spend(noise).covered, 0);
      const other = Usage(input: 10, cost: 0.3, listCost: 0.30000000000000004);
      expect(_spend(other).planned, isFalse);
      expect(_spend(other).text, '\$0.30');
      // A real difference still is one.
      const covered = Usage(input: 10, cost: 0.3, listCost: 0.31);
      expect(_spend(covered).planned, isTrue);
    });

    test('has nothing to say of a session that cost nothing, per token', () {
      final status = _spend(fresh);
      expect(status.text, '\$0.00');
      expect(status.planned, isFalse);
      expect(status.worthShowing, isFalse);
      expect(_spend(null).worthShowing, isFalse);
    });

    test('goes by its provider\'s account before its first call', () {
      expect(_spend(fresh, quota: _max()).text, 'Max');
      expect(_spend(fresh, quota: _max()).planned, isTrue);
      expect(_spend(null, quota: _max()).text, 'Max');
      // An API account has no plan to name.
      final account = ProviderQuota.fromWire('claude', {'billing': 'api'});
      expect(_spend(fresh, quota: account).planned, isFalse);
      // What it spent without a billing stays as recorded.
      expect(_spend(old, quota: _max()).text, '\$2.00');
      expect(_spend(old, quota: _max()).planned, isFalse);
    });

    test('adds the plan\'s session and weekly windows, not a quiet one', () {
      final status = _spend(plan, quota: _max());
      expect(status.windows.map((window) => window.short), ['5h 9%', '7d 57%']);
      expect(status.line, 'Max · 5h 9% · 7d 57%');
      // Billed per token, there is no plan's quota to add.
      expect(_spend(api, quota: _max()).windows, isEmpty);
    });

    test('adds a window that is close to its limit', () {
      final status = _spend(
        plan,
        quota: _max(
          windows: [
            {'name': '5h', 'used': 0.2},
            {'name': '7d Fable', 'used': 0.96},
          ],
        ),
      );
      expect(status.line, 'Max · 5h 20% · 7d Fable 96%');
      expect(status.windows.last.level, QuotaLevel.critical);
      expect(status.windows.first.level, QuotaLevel.calm);
    });

    test('explains who pays, what it came to and what is left', () {
      final help = _spend(plan, quota: _max()).details;
      expect(
        help.first,
        'Covered by Claude Max, not billed per token. '
        'This session at API prices: \$3.40.',
      );
      expect(
        help,
        contains('Current session (5 hours): 9% used, resets in 1h00m (13:00)'),
      );
      expect(
        help,
        contains('This week, Fable: 50% used, resets Sat Oct 24, 19:33'),
      );
      expect(
        help.last,
        'Extra usage: off (out of credits), \$0.00 used of \$50.0',
      );
      // Billed per token there are no windows to list.
      expect(_spend(api, quota: _max()).details, hasLength(1));
    });

    test('explains what was billed beyond the plan', () {
      final help = _spend(mixed, quota: _max()).details.first;
      expect(
        help,
        '\$0.40 billed as extra usage; '
        '\$3.40 more at API prices covered by Claude Max.',
      );
      // A mix of the two kinds of billing is not extra usage.
      expect(
        _spend(
          const Usage(
            input: 5,
            cost: 1.5,
            listCost: 4.9,
            billing: 'subscription',
            plan: 'max',
          ),
          quota: _max(),
        ).details.first,
        '\$1.50 billed; \$3.40 more at API prices covered by Claude Max.',
      );
    });

    test('names the plan from the session when the provider is silent', () {
      final help = _spend(plan).details.first;
      expect(
        help,
        'Covered by the Max plan, not billed per token. '
        'This session at API prices: \$3.40.',
      );
      expect(_spend(plan).windows, isEmpty);
    });

    test('names what cost it', () {
      expect(
        _spend(api, subject: 'These tasks').help,
        'These tasks cost \$1.20, billed per token.',
      );
    });
  });

  group('several sessions taken together', () {
    // Emacs's `harness-ui-sessions-total-reads-as-one-session`.
    final api = SessionSummary(
      id: 'a',
      model: 'demo:scripted',
      updatedAt: DateTime.fromMillisecondsSinceEpoch(1000),
      usage: const Usage(input: 10, cost: 1.2, listCost: 1.2, billing: 'api'),
    );
    final old = SessionSummary(
      id: 'b',
      model: 'demo:scripted',
      updatedAt: DateTime.fromMillisecondsSinceEpoch(3000),
      usage: const Usage(input: 5, cost: 0.3),
    );
    final plan = SessionSummary(
      id: 'c',
      model: 'claude:claude-opus-5-5',
      updatedAt: DateTime.fromMillisecondsSinceEpoch(2000),
      usage: const Usage(
        input: 20,
        cost: 0,
        listCost: 3.4,
        billing: 'subscription',
        plan: 'max',
      ),
    );

    test('cost what they add up to, billed as the latest says', () {
      final total = combineUsage([api, old]);
      expect(total.input, 15);
      expect(total.cost, closeTo(1.5, 1e-9));
      final status = _spend(total, subject: 'These tasks');
      expect(status.text, '\$1.50');
      expect(
        status.help,
        startsWith('These tasks cost \$1.50, billed per token.'),
      );
    });

    test('are paid by the plan of the one updated last that had a billing', () {
      final total = combineUsage([api, plan, old]);
      expect(total.billing, 'subscription');
      expect(total.plan, 'max');
      expect(total.listCost, closeTo(4.9, 1e-9));
      final status = _spend(total, quota: _max(), subject: 'These tasks');
      expect(status.line, '\$1.50+Max · 5h 9% · 7d 57%');
      // Billed per token and covered by the plan, not extra usage.
      expect(
        status.details.first,
        '\$1.50 billed; \$3.40 more at API prices covered by Claude Max.',
      );
    });

    test('with none, the provider\'s account says who will pay', () {
      final total = combineUsage(const []);
      expect(_spend(total, quota: _max()).text, 'Max');
      expect(_spend(total).worthShowing, isFalse);
    });

    test('skip a session that has no usage yet', () {
      final empty = SessionSummary(id: 'z');
      final total = combineUsage([empty, plan]);
      expect(total.listCost, closeTo(3.4, 1e-9));
      expect(total.billing, 'subscription');
    });
  });
}
