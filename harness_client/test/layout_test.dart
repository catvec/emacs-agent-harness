// How information is laid out: where each piece of text is, and how it
// relates to the pieces around it.  These tests assert on geometry (rects)
// and on what is *not* there (pills), because "it renders" would not catch a
// banner that sits on top of a title or a switch that floats in the middle of
// a row.  The test font draws every letter as a wide square, which makes it a
// harsh judge of overflow too.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/app.dart';
import 'package:harness_client/src/models/usage.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:harness_client/src/ui/adaptive/adaptive_widgets.dart';
import 'package:harness_client/src/ui/adaptive/layout_widgets.dart';
import 'package:harness_client/src/ui/screens/server_screen.dart';
import 'package:harness_client/src/ui/screens/settings_screen.dart';
import 'package:harness_client/src/ui/screens/tasks_screen.dart';
import 'package:harness_client/src/ui/screens/usage_screen.dart';
import 'package:harness_client/src/ui/theme/harness_theme.dart';
import 'package:harness_client/src/ui/widgets/message_composer.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';

class _Rig {
  _Rig(this.settings, this.harness, this.app);
  final SettingsController settings;
  final FakeHarness harness;
  final AppController app;
}

Future<_Rig> _rig() async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsController();
  await settings.load();
  final harness = FakeHarness();
  final app = AppController(settings: settings, connector: harness.connector);
  await app.connect('ws://memory/acp');
  return _Rig(settings, harness, app);
}

/// A phone, 390 × 844 points, with the app on it.
Future<void> _pump(WidgetTester tester, _Rig rig, {Size? size}) async {
  tester.view.physicalSize = size ?? const Size(1170, 2532);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    HarnessApp(settings: rig.settings, appController: rig.app),
  );
  await tester.pump();
  await _settle(tester);
}

Future<void> _settle(WidgetTester tester, [int rounds = 10]) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

/// A session needs an answer: the app has its controller, as it has once
/// a conversation was opened (and closed again).
Future<void> _needsAnswer(WidgetTester tester, _Rig rig) async {
  final blocked = rig.app.sessions.firstWhere((session) => session.isBlocked);
  rig.app.openSession(blocked.id);
  rig.app.closeSession();
  await _settle(tester);
  expect(rig.app.attentionCount, greaterThan(0));
}

Finder _title(String text) =>
    find.descendant(of: find.byType(AppBar), matching: find.text(text));

void main() {
  group('the notice that a session needs an answer', () {
    testWidgets('is under the header of a page, and the page is under it', (
      tester,
    ) async {
      final rig = await _rig();
      await _pump(tester, rig);
      await _needsAnswer(tester, rig);
      await tester.tap(find.text('Tasks'));
      await _settle(tester);

      final header = tester.getRect(find.byType(AppBar));
      final title = tester.getRect(_title('Tasks'));
      final notice = tester.getRect(find.byType(HarnessNotice));
      final scope = tester.getRect(find.byType(HarnessScopeBar));
      // It used to float over the app bar, on top of the title and the
      // buttons.  Now the header is where it always is, and the notice is
      // in the flow, between it and the page.
      expect(notice.top, greaterThanOrEqualTo(header.bottom));
      expect(notice.top, greaterThan(title.bottom));
      expect(scope.top, greaterThanOrEqualTo(notice.bottom));
      // The header does not move because of it.
      expect(title.left, closeTo(HarnessSpace.gutter, 0.5));
    });

    testWidgets('is left to the list on the Sessions page', (tester) async {
      final rig = await _rig();
      await _pump(tester, rig);
      await _needsAnswer(tester, rig);
      // "Needs you" is the first section of the list: it is not said twice.
      expect(find.byType(HarnessNotice), findsNothing);
      expect(find.text('NEEDS YOU'), findsOneWidget);
    });

    testWidgets('comes and goes without the page under it losing its place', (
      tester,
    ) async {
      final rig = await _rig();
      await _pump(tester, rig);
      await tester.tap(find.text('Usage'));
      await _settle(tester);
      final scrollable = find
          .descendant(
            of: find.byType(UsageScreen),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.drag(scrollable, const Offset(0, -300));
      await _settle(tester, 2);
      double offset() =>
          tester.state<ScrollableState>(scrollable).position.pixels;
      final before = offset();
      expect(before, greaterThan(0));

      // Something goes wrong: a notice comes in over the page, in its flow.
      await rig.app.openSessionById('there-is-no-such-session');
      await _settle(tester);
      expect(find.text('That session is not in the list.'), findsOneWidget);
      expect(offset(), before, reason: 'the page was not rebuilt from nothing');

      rig.app.clearActionError();
      await _settle(tester);
      expect(find.text('That session is not in the list.'), findsNothing);
      expect(offset(), before);
    });
  });

  group('the list of sessions', () {
    testWidgets('is a scope bar, a search field and tabs, all on the gutter', (
      tester,
    ) async {
      final rig = await _rig();
      await _pump(tester, rig);
      final scope = tester.getRect(find.byType(HarnessScopeBar));
      final search = tester.getRect(find.byKey(const Key('session-search')));
      final all = tester.getTopLeft(find.text('All'));
      // One edge down the page: the field starts on the gutter, and so does
      // the first tab's label (not its padding).
      expect(search.left, closeTo(HarnessSpace.gutter, 0.5));
      expect(all.dx, closeTo(HarnessSpace.gutter, 0.5));
      // And from the top: the project, the search, the tabs.
      expect(scope.bottom, lessThanOrEqualTo(search.top));
      expect(search.bottom, lessThanOrEqualTo(all.dy));
    });

    testWidgets('has no row of pills', (tester) async {
      final rig = await _rig();
      await _pump(tester, rig);
      expect(find.byType(HarnessPill), findsNothing);
      expect(find.byType(HarnessStatusPill), findsNothing);
    });

    testWidgets(
      'puts the cost of every row on one edge, its title on another',
      (tester) async {
        final rig = await _rig();
        await _pump(tester, rig);
        final costs = find.byWidgetPredicate(
          (widget) => widget is Text && (widget.data ?? '').startsWith(r'$'),
        );
        expect(costs, findsAtLeastNWidgets(3));
        final rights = {
          for (var i = 0; i < costs.evaluate().length; i++)
            tester.getTopRight(costs.at(i)).dx.round(),
        };
        expect(
          rights,
          hasLength(1),
          reason: 'every cost ends on the same edge',
        );

        final titles = [
          'Fix duplicate task titles',
          'Polish the iOS sheet',
          'Design the merge queue',
          'Investigate cache misses',
        ];
        final lefts = {
          for (final title in titles) tester.getTopLeft(find.text(title)).dx,
        };
        expect(lefts, hasLength(1), reason: 'every title starts at one place');
        // The gutter, the avatar and the gap after it.
        expect(lefts.single, closeTo(HarnessSpace.gutter + 40 + 12, 0.5));
      },
    );

    testWidgets('names a project in a row only where there are several', (
      tester,
    ) async {
      final rig = await _rig();
      await _pump(tester, rig);
      // Two projects: a row says which one it is of.
      expect(rig.app.projects.length, greaterThan(1));
      expect(
        find.textContaining('other-project', findRichText: true),
        findsWidgets,
      );
    });
  });

  group('the board of tasks', () {
    testWidgets('has its columns as tabs, from the gutter, in one row', (
      tester,
    ) async {
      final rig = await _rig();
      await _pump(tester, rig);
      await tester.tap(find.text('Tasks'));
      await _settle(tester);
      final first = tester.getTopLeft(find.text('Needs input'));
      final card = tester.getTopLeft(find.byType(TaskCard).first);
      // They used to wrap, centered, in two rows that began at a different
      // place than the cards under them.
      expect(first.dx, closeTo(HarnessSpace.gutter, 0.5));
      expect(card.dx, closeTo(HarnessSpace.gutter, 0.5));
      final tops = {
        for (final label in ['Needs input', 'Active', 'Review'])
          tester.getTopLeft(find.text(label)).dy.round(),
      };
      expect(tops, hasLength(1), reason: 'all on one row');
      expect(find.byType(HarnessPill), findsNothing);
    });

    testWidgets('says how the queue is doing in one line, with its controls '
        'in a sheet', (tester) async {
      final rig = await _rig();
      await _pump(tester, rig);
      await tester.tap(find.text('Tasks'));
      await _settle(tester);
      // Not a row of pills for the state and the controls alike.
      expect(find.text('2 of 3 working · 1 queued'), findsOneWidget);
      expect(find.text('Pause queue'), findsNothing);
      await tester.tap(find.text('2 of 3 working · 1 queued'));
      await _settle(tester);
      expect(find.text('Queue'), findsOneWidget);
      expect(find.text('Pause the queue'), findsOneWidget);
      expect(find.text('Queue the backlog automatically'), findsOneWidget);
      expect(find.byType(Switch), findsNWidgets(2));
    });

    testWidgets('has a sheet whose actions are equal parts of one width', (
      tester,
    ) async {
      final rig = await _rig();
      await _pump(tester, rig);
      await tester.tap(find.text('Tasks'));
      await _settle(tester);
      await tester.ensureVisible(find.text('Review'));
      await tester.tap(find.text('Review'));
      await _settle(tester);
      await tester.tap(find.text('Review the emulator screenshots'));
      await _settle(tester);
      final verify = tester.getRect(
        find.widgetWithText(FilledButton, 'Verify and merge'),
      );
      final back = tester.getRect(
        find.widgetWithText(OutlinedButton, 'Send back'),
      );
      final complete = tester.getRect(
        find.widgetWithText(OutlinedButton, 'Mark complete'),
      );
      // The one to take is full width; the others share a row, equally.
      expect(back.width, closeTo(complete.width, 0.5));
      expect(back.top, closeTo(complete.top, 0.5));
      expect(verify.left, closeTo(back.left, 0.5));
      expect(verify.right, closeTo(complete.right, 0.5));
      expect(verify.bottom, lessThanOrEqualTo(back.top));
    });
  });

  group('a conversation', () {
    Future<void> open(WidgetTester tester, _Rig rig, String title) async {
      await _pump(tester, rig);
      await tester.tap(find.text(title));
      await _settle(tester);
    }

    testWidgets('has no pills under its title', (tester) async {
      final rig = await _rig();
      await open(tester, rig, 'Design the merge queue');
      expect(find.byType(HarnessPill), findsNothing);
      expect(find.byType(HarnessStatusPill), findsNothing);
    });

    testWidgets('says what it is doing, in words, under its title', (
      tester,
    ) async {
      final rig = await _rig();
      await open(tester, rig, 'Design the merge queue');
      final title = tester.getRect(_title('Design the merge queue'));
      final state = find.descendant(
        of: find.byType(AppBar),
        matching: find.textContaining('Idle', findRichText: true),
      );
      expect(state, findsOneWidget);
      final line = tester.getRect(state);
      expect(line.top, greaterThanOrEqualTo(title.bottom - 1));
      expect(
        line.left,
        closeTo(title.left, 14),
        reason: 'the line starts where the title does (after its dot)',
      );
    });

    testWidgets('keeps the model and the mode under the message field', (
      tester,
    ) async {
      final rig = await _rig();
      await open(tester, rig, 'Design the merge queue');
      final field = tester.getRect(
        find.descendant(
          of: find.byType(MessageComposer),
          matching: find.byType(TextField),
        ),
      );
      final model = find.descendant(
        of: find.byType(MessageComposer),
        matching: find.text('claude-fable-5-1'),
      );
      expect(model, findsOneWidget);
      // Under the field, not in a strip of chips above the transcript.
      expect(tester.getRect(model).top, greaterThanOrEqualTo(field.bottom));
      // And a way to change it.
      await tester.tap(model);
      await _settle(tester);
      expect(find.text('Model'), findsOneWidget);
    });

    testWidgets('keeps a long footer inside the width of a narrow phone', (
      tester,
    ) async {
      final rig = await _rig();
      // 320 points wide: a small phone.
      tester.view.physicalSize = const Size(960, 2000);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        HarnessApp(settings: rig.settings, appController: rig.app),
      );
      await _settle(tester);
      await tester.tap(find.text('Design the merge queue'));
      await _settle(tester);
      // No overflow, which the test binding would have thrown: and the
      // model's name is still there to read.
      expect(tester.takeException(), isNull);
      expect(
        find.descendant(
          of: find.byType(MessageComposer),
          matching: find.byType(HarnessPicker),
        ),
        findsWidgets,
      );
    });
  });

  group('the server page', () {
    testWidgets('lists methods and events as text, not as pills', (
      tester,
    ) async {
      final rig = await _rig();
      await _pump(tester, rig);
      await tester.tap(find.text('Server'));
      await _settle(tester);
      await tester.scrollUntilVisible(
        find.text('toggle-queue'),
        300,
        scrollable: find
            .descendant(
              of: find.byType(ServerScreen),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await _settle(tester, 3);
      expect(find.byType(HarnessStatusPill), findsNothing);
      expect(find.byType(HarnessPill), findsNothing);
      // A group's name has its methods beside it, in a row.
      final card = find.ancestor(
        of: find.text('toggle-queue'),
        matching: find.byType(HarnessCard),
      );
      final group = tester.getRect(
        find.descendant(of: card, matching: find.text('task')),
      );
      final method = tester.getRect(find.text('toggle-queue'));
      expect(method.left, greaterThanOrEqualTo(group.right));
      // The group's name is level with the first row of its methods.
      expect(group.top, closeTo(tester.getRect(find.text('archive')).top, 4));
    });
  });

  group('the settings page', () {
    testWidgets('has its switches at the end of their rows', (tester) async {
      final rig = await _rig();
      await _pump(tester, rig);
      await tester.tap(find.text('Settings'));
      await _settle(tester);
      await tester.scrollUntilVisible(
        find.text('Show thinking'),
        200,
        scrollable: find
            .descendant(
              of: find.byType(SettingsScreen),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      final switchFinder = find.byType(Switch);
      expect(switchFinder, findsWidgets);
      for (var i = 0; i < switchFinder.evaluate().length; i++) {
        final card = find.ancestor(
          of: switchFinder.at(i),
          matching: find.byType(HarnessCard),
        );
        final inner =
            tester.getRect(card.first).right -
            tester.getRect(switchFinder.at(i)).right;
        // They sat in the middle of the row, because the row split its
        // width between the text and the control.
        expect(inner, lessThan(HarnessSpace.lg + 6));
      }
    });
  });

  group('with the text set larger', () {
    testWidgets('no page overflows at one and a half times the size', (
      tester,
    ) async {
      // What a person who reads large text sees: nothing is cut or hangs
      // over its edge, which the test binding would throw as an overflow.
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final rig = await _rig();
      await _pump(tester, rig);
      await _needsAnswer(tester, rig);
      expect(tester.takeException(), isNull, reason: 'Sessions');
      for (final tab in ['Tasks', 'Usage', 'Server', 'Settings']) {
        await tester.tap(find.text(tab));
        await _settle(tester);
        expect(tester.takeException(), isNull, reason: tab);
      }
      await tester.tap(find.text('Sessions'));
      await _settle(tester);
      await tester.tap(find.text('Design the merge queue'));
      await _settle(tester);
      expect(tester.takeException(), isNull, reason: 'a conversation');
    });
  });

  group('the pieces', () {
    testWidgets('a meta line drops the facts that do not fit, whole', (
      tester,
    ) async {
      Future<void> show(double width) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                child: const HarnessMetaLine(
                  dropWhatDoesNotFit: true,
                  style: TextStyle(fontSize: 10),
                  parts: [
                    HarnessMetaPart('Needs you', weight: FontWeight.w600),
                    'emacs-agent-harness',
                    'Task: Answer the permission',
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      Finder has(String text) => find.textContaining(text, findRichText: true);

      await show(700);
      expect(has('Task: Answer'), findsOneWidget);
      await show(400);
      expect(has('emacs-agent-harness'), findsOneWidget);
      expect(has('Task'), findsNothing, reason: 'the last fact goes whole');
      await show(110);
      expect(has('Needs you'), findsOneWidget);
      expect(has('emacs'), findsNothing);
    });

    testWidgets('a tab strip starts on the gutter and says which is shown', (
      tester,
    ) async {
      var chosen = 'a';
      await tester.pumpWidget(
        MaterialApp(
          theme: HarnessTheme.material(Brightness.light),
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => HarnessTabStrip<String>(
                value: chosen,
                onChanged: (value) => setState(() => chosen = value),
                tabs: const [
                  HarnessTab(value: 'a', label: 'First', count: 3),
                  HarnessTab(value: 'b', label: 'Second', count: 0),
                ],
              ),
            ),
          ),
        ),
      );
      expect(
        tester.getTopLeft(find.text('First')).dx,
        closeTo(HarnessSpace.gutter, 0.5),
      );
      await tester.tap(find.text('Second'));
      await tester.pump();
      expect(chosen, 'b');
    });

    test('money is written with its cents, and thousands are grouped', () {
      expect(formatMoney(0), r'$0.00');
      expect(formatMoney(1.239), r'$1.24');
      expect(formatMoney(25), r'$25.00');
      expect(formatMoney(80), r'$80.00');
      expect(formatMoney(1234.5), r'$1,234.50');
      expect(formatMoney(0.004), r'$0.0040');
    });
  });
}
