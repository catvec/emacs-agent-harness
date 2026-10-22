import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/app.dart';
import 'package:harness_client/src/models/quota.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:harness_client/src/ui/screens/usage_screen.dart';
import 'package:harness_client/src/ui/widgets/quota_widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';

// The plan's quota on screen: in the status of a session and of the task
// board, and in the usage view, as Emacs shows it in its header lines and
// its usage dashboard.

class _Rig {
  _Rig(this.settings, this.harness, this.app);
  final SettingsController settings;
  final FakeHarness harness;
  final AppController app;
}

Future<_Rig> _rig({bool quota = true, bool enhanced = true}) async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsController();
  await settings.load();
  final harness = FakeHarness(quota: quota, enhanced: enhanced);
  final app = AppController(settings: settings, connector: harness.connector);
  await app.connect('ws://memory/acp');
  return _Rig(settings, harness, app);
}

Future<void> _pump(
  WidgetTester tester,
  _Rig rig, {
  Size size = const Size(1170, 2532),
  double ratio = 3.0,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = ratio;
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

Finder _rich(String text) => find.text(text, findRichText: true);

Future<void> _openSession(WidgetTester tester, String title) async {
  await tester.tap(find.text(title));
  await _settle(tester, 8);
}

Future<void> _toUsage(WidgetTester tester) async {
  await tester.tap(find.text('Usage'));
  await _settle(tester, 6);
}

Finder _usageScrollable() => find
    .descendant(
      of: find.descendant(
        of: find.byType(UsageScreen),
        matching: find.byType(ListView),
      ),
      matching: find.byType(Scrollable),
    )
    .first;

/// The colour [text] has among the spans of the chip [within].
Color? _colorOf(WidgetTester tester, Finder within, String text) {
  Color? found;
  for (final rich in tester.widgetList<RichText>(
    find.descendant(of: within, matching: find.byType(RichText)),
  )) {
    rich.text.visitChildren((span) {
      if (span is TextSpan && span.text == text) {
        found = span.style?.color;
        return false;
      }
      return true;
    });
  }
  return found;
}

Map<String, Object?> _claudeAt(double session, {Map<String, Object?>? more}) {
  final now = DateTime.now().millisecondsSinceEpoch / 1000;
  return {
    'billing': 'subscription',
    'plan': 'max',
    'plan-label': 'Claude Max',
    'account': {'email': 'noah@example.com'},
    'windows': [
      {
        'name': '5h',
        'label': 'Current session (5 hours)',
        'used': session,
        'resets': now + 3600,
      },
      {
        'name': '7d',
        'label': 'This week, all models',
        'used': 0.41,
        'resets': now + 300000,
      },
    ],
    'updated': now,
    ...?more,
  };
}

void main() {
  group('the status of a session', () {
    testWidgets('shows the plan with its quota, in its header', (tester) async {
      final rig = await _rig();
      await _pump(tester, rig);
      await _openSession(tester, 'Design the merge queue');
      final chip = find.byKey(const Key('session-spend'));
      expect(chip, findsOneWidget);
      // What Emacs's header line reads: the plan, then its 5-hour and weekly
      // windows, not the quiet one for a single model.
      expect(
        find.descendant(of: chip, matching: _rich('Max · 5h 23% · 7d 41%')),
        findsOneWidget,
      );
      expect(find.textContaining('7d Fable'), findsNothing);
      // It replaces the price of a session nothing was billed for.
      expect(find.textContaining(r'$0.00'), findsNothing);
    });

    testWidgets('shows the extra usage billed beyond the plan', (tester) async {
      final rig = await _rig();
      await _pump(tester, rig);
      await _openSession(tester, 'Fix duplicate task titles');
      expect(
        find.descendant(
          of: find.byKey(const Key('session-spend')),
          matching: _rich(r'$0.12+Max · 5h 23% · 7d 41%'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('shows the price when calls are billed per token', (
      tester,
    ) async {
      final rig = await _rig();
      await _pump(tester, rig);
      await _openSession(tester, 'Investigate cache misses');
      final chip = find.byKey(const Key('session-spend'));
      expect(
        find.descendant(of: chip, matching: _rich(r'$0.21')),
        findsOneWidget,
      );
      expect(find.textContaining('5h'), findsNothing);
      // It says who pays, too.
      await tester.tap(chip);
      await _settle(tester, 6);
      expect(find.byKey(const Key('plan-sheet')), findsOneWidget);
      expect(find.text(r'This session cost $0.21.'), findsOneWidget);
      expect(find.text('Current session (5 hours)'), findsNothing);
    });

    testWidgets('says more when it is tapped: who pays and what is left', (
      tester,
    ) async {
      final rig = await _rig();
      await _pump(tester, rig);
      await _openSession(tester, 'Design the merge queue');
      await tester.tap(find.byKey(const Key('session-spend')));
      await _settle(tester, 6);
      final sheet = find.byKey(const Key('plan-sheet'));
      expect(sheet, findsOneWidget);
      Finder inSheet(String text) =>
          find.descendant(of: sheet, matching: find.text(text));
      expect(inSheet('Claude Max'), findsOneWidget);
      expect(inSheet('Claude'), findsOneWidget);
      expect(
        inSheet(
          r'Covered by Claude Max, not billed per token. '
          r'This session at API prices: $3.25.',
        ),
        findsOneWidget,
      );
      // A meter for each window, with how much of it is used.
      expect(inSheet('Current session (5 hours)'), findsOneWidget);
      expect(inSheet('23%'), findsOneWidget);
      expect(inSheet('This week, all models'), findsOneWidget);
      expect(inSheet('41%'), findsOneWidget);
      expect(inSheet('This week, Fable'), findsOneWidget);
      expect(inSheet('18%'), findsOneWidget);
      expect(
        find.descendant(
          of: sheet,
          matching: find.textContaining('Resets in 3h1'),
        ),
        findsOneWidget,
      );
      expect(
        inSheet(r'Extra usage: off (out of credits), $0.00 used of $50.0'),
        findsOneWidget,
      );
    });

    testWidgets('fills up on screen as the work uses the plan', (tester) async {
      final rig = await _rig();
      await _pump(tester, rig);
      await _openSession(tester, 'Design the merge queue');
      final chip = find.byKey(const Key('session-spend'));
      final theme = Theme.of(tester.element(chip));
      expect(
        find.descendant(of: chip, matching: _rich('Max · 5h 23% · 7d 41%')),
        findsOneWidget,
      );
      expect(
        _colorOf(tester, chip, '5h 23%'),
        theme.colorScheme.onSurfaceVariant,
      );

      // The provider tells the harness a turn used most of the session
      // window: it arrives as an event, with no refresh of the screen.
      rig.harness.updateQuota('claude', _claudeAt(0.96));
      await _settle(tester, 6);
      expect(
        find.descendant(of: chip, matching: _rich('Max · 5h 96% · 7d 41%')),
        findsOneWidget,
      );
      expect(_colorOf(tester, chip, '5h 96%'), theme.colorScheme.error);

      // Between 70% and 85% it is amber, from 85% orange.
      rig.harness.updateQuota('claude', _claudeAt(0.72));
      await _settle(tester, 6);
      expect(_colorOf(tester, chip, '5h 72%'), const Color(0xFFC2871B));
      rig.harness.updateQuota('claude', _claudeAt(0.88));
      await _settle(tester, 6);
      expect(_colorOf(tester, chip, '5h 88%'), const Color(0xFFE8590C));
    });

    testWidgets('a session list row says who pays', (tester) async {
      final rig = await _rig();
      await _pump(tester, rig);
      // s1 and s3 are paid by the plan; s2 needs the user; s4 bills per
      // token.
      expect(find.byKey(const Key('session-row-spend')), findsNWidgets(3));
      expect(find.text('Max'), findsNWidgets(2));
      expect(find.text(r'$0.21'), findsOneWidget);
    });
  });

  group('the status of the task board', () {
    testWidgets('shows what the tasks cost and the plan that pays', (
      tester,
    ) async {
      final rig = await _rig();
      await _pump(tester, rig);
      await tester.tap(find.text('Tasks'));
      await _settle(tester, 6);
      final chip = find.byKey(const Key('tasks-spend'));
      expect(chip, findsOneWidget);
      expect(
        find.descendant(
          of: chip,
          matching: _rich(r'$0.12+Max · 5h 23% · 7d 41%'),
        ),
        findsOneWidget,
      );
      await tester.tap(chip);
      await _settle(tester, 6);
      final sheet = find.byKey(const Key('plan-sheet'));
      expect(sheet, findsOneWidget);
      expect(
        find.descendant(
          of: sheet,
          matching: find.textContaining(
            r'$0.12 billed; $1.18 more at API prices covered by Claude Max.',
          ),
        ),
        findsOneWidget,
      );
    });
  });

  group('the usage view', () {
    testWidgets('has a plan section: a meter for each window', (tester) async {
      final rig = await _rig();
      await _pump(tester, rig);
      await _toUsage(tester);
      expect(find.text('PLAN'), findsOneWidget);
      expect(find.text('Claude'), findsOneWidget);
      expect(find.text('Claude Max'), findsOneWidget);
      expect(find.text('noah@example.com'), findsOneWidget);
      expect(find.text('Current session (5 hours)'), findsOneWidget);
      expect(find.text('23%'), findsOneWidget);
      expect(find.text('This week, all models'), findsOneWidget);
      expect(find.text('41%'), findsOneWidget);
      expect(find.textContaining('Resets in 3h1'), findsOneWidget);
      expect(
        find.textContaining('Calls the plan covers are not billed'),
        findsWidgets,
      );
      // Four minutes before the harness started; a slow run may say five.
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Text &&
              RegExp(r'^Updated [45]m ago$').hasMatch(widget.data ?? ''),
        ),
        findsOneWidget,
      );
      await tester.scrollUntilVisible(
        find.text('GitHub Copilot'),
        200,
        scrollable: _usageScrollable(),
      );
      expect(find.text('GitHub Copilot Pro'), findsOneWidget);
      expect(
        find.text('Premium requests this month (93 of 300)'),
        findsOneWidget,
      );
      expect(find.text('31%'), findsOneWidget);
      // DeepSeek says nothing: no card for it.
      expect(find.text('DeepSeek'), findsNothing);
    });

    testWidgets('lists the extra usage a plan allows', (tester) async {
      final rig = await _rig();
      await _pump(tester, rig);
      await _toUsage(tester);
      await tester.scrollUntilVisible(
        find.textContaining('Extra usage'),
        200,
        scrollable: _usageScrollable(),
      );
      expect(
        find.text(r'Extra usage: off (out of credits), $0.00 used of $50.0'),
        findsOneWidget,
      );
    });

    testWidgets('warns when the plan\'s limit is near or reached', (
      tester,
    ) async {
      final rig = await _rig();
      await _pump(tester, rig);
      await _toUsage(tester);
      expect(find.textContaining("plan's limit"), findsNothing);

      rig.harness.updateQuota(
        'claude',
        _claudeAt(0.97, more: {'limit-status': 'allowed_warning'}),
      );
      await _settle(tester, 6);
      expect(find.text("Close to the plan's limit."), findsOneWidget);

      rig.harness.updateQuota(
        'claude',
        _claudeAt(1.0, more: {'limit-status': 'rejected', 'using-extra': true}),
      );
      await _settle(tester, 6);
      expect(
        find.text("The plan's limit is reached: calls fail until it resets."),
        findsOneWidget,
      );
      expect(
        find.text('Calls are drawing on extra usage, billed at API prices.'),
        findsOneWidget,
      );
      expect(find.text('100%'), findsOneWidget);
    });

    testWidgets('says when a provider bills per token', (tester) async {
      final rig = await _rig();
      await _pump(tester, rig);
      await _toUsage(tester);
      rig.harness.updateQuota('deepseek', {
        'billing': 'api',
        'auth': 'DEEPSEEK_API_KEY',
      });
      await _settle(tester, 6);
      await tester.scrollUntilVisible(
        find.textContaining('bills per token'),
        200,
        scrollable: _usageScrollable(),
      );
      expect(
        find.textContaining(
          'bills per token (DEEPSEEK_API_KEY): what it cost is what you pay.',
          findRichText: true,
        ),
        findsOneWidget,
      );
    });

    testWidgets('says when a provider has not said how it bills', (
      tester,
    ) async {
      final rig = await _rig();
      await _pump(tester, rig);
      await _toUsage(tester);
      // It reports a quota, but not how it bills: nothing to draw of it.
      rig.harness.updateQuota('deepseek', {
        'updated': DateTime.now().millisecondsSinceEpoch / 1000,
      });
      await _settle(tester, 6);
      await tester.scrollUntilVisible(
        find.textContaining('has not said how it bills yet'),
        200,
        scrollable: _usageScrollable(),
      );
      expect(
        find.textContaining(
          'DeepSeek has not said how it bills yet.',
          findRichText: true,
        ),
        findsOneWidget,
      );
    });

    testWidgets('asks the providers again when refreshed', (tester) async {
      final rig = await _rig();
      await _pump(tester, rig);
      await _toUsage(tester);
      expect(rig.harness.quotaRefreshes, 0);
      await tester.tap(find.byKey(const Key('plan-refresh')));
      await _settle(tester, 8);
      // Claude and Copilot report a plan; each is asked to ask its source.
      expect(rig.harness.quotaRefreshes, 2);
      expect(find.byKey(const Key('plan-refresh')), findsOneWidget);
    });

    testWidgets('reminds that a plan\'s calls spend no budget', (tester) async {
      final rig = await _rig();
      await _pump(tester, rig);
      await _toUsage(tester);
      await tester.scrollUntilVisible(
        find.text('BUDGETS'),
        300,
        scrollable: _usageScrollable(),
      );
      expect(
        find.text(
          'Budgets count billed cost; calls a plan covers do not spend them.',
        ),
        findsOneWidget,
      );
    });
  });

  group('a harness that cannot say', () {
    testWidgets('has no plan section, and the plan its sessions name', (
      tester,
    ) async {
      final rig = await _rig(quota: false);
      await _pump(tester, rig);
      await _toUsage(tester);
      expect(find.text('PLAN'), findsNothing);
      expect(find.byKey(const Key('plan-refresh')), findsNothing);
      await tester.tap(find.text('Sessions'));
      await _settle(tester, 4);
      await _openSession(tester, 'Design the merge queue');
      // Nothing is known of its windows, but it still says a plan paid.
      expect(
        find.descendant(
          of: find.byKey(const Key('session-spend')),
          matching: _rich('Max'),
        ),
        findsOneWidget,
      );
      expect(find.textContaining('5h'), findsNothing);
    });

    testWidgets('a plain ACP agent has no quota to show', (tester) async {
      final rig = await _rig(enhanced: false);
      await _pump(tester, rig);
      // Its sessions come without usage: nothing to say who pays.
      expect(find.byKey(const Key('session-row-spend')), findsNothing);
      expect(rig.app.quota, isNull);
      expect(find.text('Usage'), findsNothing);
    });
  });

  group('on an Apple platform', () {
    testWidgets('the status, its sheet and the plan section draw', (
      tester,
    ) async {
      final rig = await _rig();
      await rig.settings.setPreviewPlatform(PreviewPlatform.cupertino);
      // A wide window opens a conversation beside the list.
      await _pump(tester, rig, size: const Size(1400, 900), ratio: 1);
      await _toUsage(tester);
      expect(find.text('PLAN'), findsOneWidget);
      expect(find.text('Current session (5 hours)'), findsOneWidget);
      await tester.tap(find.text('Sessions'));
      await _settle(tester, 4);
      await _openSession(tester, 'Design the merge queue');
      final chip = find.byKey(const Key('session-spend'));
      expect(
        find.descendant(of: chip, matching: _rich('Max · 5h 23% · 7d 41%')),
        findsOneWidget,
      );
      await tester.tap(chip);
      await _settle(tester, 6);
      expect(find.byKey(const Key('plan-sheet')), findsOneWidget);
      expect(find.text('Claude Max'), findsOneWidget);
    });
  });

  group('a quota window\'s meter', () {
    testWidgets('fills as much as the window is used, up to full', (
      tester,
    ) async {
      Future<double?> filled(double used) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(useMaterial3: true),
            home: Scaffold(
              body: QuotaMeter(
                window: QuotaWindow(name: '5h', label: 'Session', used: used),
              ),
            ),
          ),
        );
        return tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value;
      }

      expect(await filled(0.0), 0.0);
      expect(await filled(0.37), 0.37);
      // A provider may report more than a window holds: the bar is full.
      expect(await filled(1.2), 1.0);
      expect(find.text('120%'), findsOneWidget);
    });
  });
}
