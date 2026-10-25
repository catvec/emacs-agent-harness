// The quick search on the phone: the button in every header, the page it
// opens, and what it does with what the harness answers -- an answer in
// words, actions to run, sessions and tasks to open, orders to say yes to --
// and with the harness that is slow, fails, cannot search, or is out of
// reach.  The harness is the fake one, with the search scripted
// (`SearchingHarness`); the app is the whole app.
import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/app.dart';
import 'package:harness_client/src/acp/acp_message.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/quick_search_catalogue.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:harness_client/src/ui/adaptive/platform_style.dart';
import 'package:harness_client/src/ui/adaptive/adaptive_widgets.dart';
import 'package:harness_client/src/ui/screens/quick_search_screen.dart';
import 'package:harness_client/src/ui/screens/session_screen.dart';
import 'package:harness_client/src/ui/widgets/quick_search_entry.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';
import 'support/quick_search_harness.dart';
import 'support/real_fonts.dart';

const _main = '/Users/noah/Code/emacs-agent-harness/';
const _other = '/Users/noah/Code/other-project/';

class _Rig {
  _Rig(this.settings, this.search, this.app);
  final SettingsController settings;
  final SearchingHarness search;
  final AppController app;

  FakeHarness get harness => search.harness;
}

Future<_Rig> _rig({
  bool offersSearch = true,
  void Function(FakeHarness harness)? arrange,
  PreviewPlatform platform = PreviewPlatform.material,
}) async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsController();
  await settings.load();
  await settings.setPreviewPlatform(platform);
  final search = SearchingHarness(offersSearch: offersSearch);
  arrange?.call(search.harness);
  final app = AppController(
    settings: settings,
    connector: search.connector,
    reconnectDelays: const [Duration(milliseconds: 5)],
    handshakeTimeout: const Duration(seconds: 2),
    probeTimeout: const Duration(milliseconds: 150),
  );
  await app.connect('ws://memory/acp');
  return _Rig(settings, search, app);
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
  await _settle(tester, 8);
}

Future<void> _settle(WidgetTester tester, [int rounds = 10]) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

final _button = find.byKey(QuickSearchEntry.buttonKey);
final _field = find.byKey(const Key('quick-search-field'));
final _page = find.byType(QuickSearchScreen);

/// Open the quick search from the screen that is open.
Future<void> _open(WidgetTester tester) async {
  await tester.tap(_button);
  await _settle(tester, 6);
  expect(_page, findsOneWidget);
}

/// Type [line] in the box and send it.
Future<void> _ask(WidgetTester tester, String line) async {
  await tester.enterText(_field, line);
  await tester.pump();
  await tester.tap(find.byKey(const Key('quick-search-submit')));
  await _settle(tester, 6);
}

Future<void> _tab(WidgetTester tester, String label) async {
  await tester.tap(
    find.descendant(of: find.byType(NavigationBar), matching: find.text(label)),
  );
  await _settle(tester, 4);
}

/// Which tab of the navigation bar is the one shown.
String _shown(WidgetTester tester) {
  const tabs = ['Sessions', 'Tasks', 'Usage', 'Server', 'Settings'];
  if (find.byType(CupertinoTabBar).evaluate().isNotEmpty) {
    return tabs[tester
        .widget<CupertinoTabBar>(find.byType(CupertinoTabBar))
        .currentIndex];
  }
  return tabs[tester
      .widget<NavigationBar>(find.byType(NavigationBar))
      .selectedIndex];
}

Future<void> _close(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('quick-search-close')));
  await _settle(tester, 6);
}

String _from(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const Key('quick-search-from'))).data!;

Finder _row(String key) => find.byKey(Key(key));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Text as wide as on a phone: the test font draws every letter as a square,
  // which overflows pages that are whole on a phone.
  setUpAll(loadRealFonts);

  group('the way in', () {
    testWidgets('is a button in the header of every main screen', (
      tester,
    ) async {
      final rig = await _rig();
      await _pump(tester, rig);
      for (final (tab, from) in [
        (
          'Sessions',
          'From the list of sessions · favours sessions, then actions',
        ),
        ('Tasks', 'From the task board · favours tasks'),
        ('Usage', 'From usage · favours actions, then sessions'),
        ('Server', 'From the server page · favours actions, then sessions'),
        ('Settings', 'From settings · favours actions, then sessions'),
      ]) {
        if (tab != 'Sessions') await _tab(tester, tab);
        expect(_shown(tester), tab);
        // One button, at the far end of the header, whatever the page holds.
        expect(_button, findsOneWidget, reason: tab);
        final bar = tester.getRect(find.byType(AppBar));
        final at = tester.getRect(_button);
        expect(bar.contains(at.center), isTrue, reason: '$tab: in the header');
        expect(
          at.right,
          greaterThan(bar.right - 60),
          reason: '$tab: at the far end',
        );
        await _open(tester);
        expect(_from(tester), from, reason: tab);
        expect(find.byKey(const Key('quick-search-hint')), findsOneWidget);
        // The box is ready for the words.
        expect(
          tester
              .widget<EditableText>(find.byType(EditableText))
              .focusNode
              .hasFocus,
          isTrue,
          reason: '$tab: typing starts at once',
        );
        await _close(tester);
        expect(_page, findsNothing);
        expect(_shown(tester), tab, reason: 'closing leaves the screen alone');
      }
    });

    testWidgets('has the same label wherever it is, for a screen reader', (
      tester,
    ) async {
      final rig = await _rig();
      await _pump(tester, rig);
      expect(find.byTooltip(QuickSearchEntry.buttonLabel), findsOneWidget);
      await _tab(tester, 'Tasks');
      expect(find.byTooltip(QuickSearchEntry.buttonLabel), findsOneWidget);
    });

    testWidgets('is in a conversation too, which the search knows it is in', (
      tester,
    ) async {
      final rig = await _rig();
      await _pump(tester, rig);
      await tester.tap(find.text('Design the merge queue'));
      await _settle(tester, 6);
      expect(find.byType(SessionScreen), findsOneWidget);
      await _open(tester);
      expect(
        _from(tester),
        'From the conversation “Design the merge queue” · favours actions, then sessions',
      );
      await _ask(tester, 'how do I answer a question?');
      expect(rig.search.lastContext, {
        'view': 'chat',
        'title': 'Design the merge queue',
        'client': 'phone app',
        'project': _main,
        'session': 's1',
      });
      expect(rig.search.lastOpts['bias'], 'commands');
      // Closing it leaves the conversation open.
      await _close(tester);
      expect(find.byType(SessionScreen), findsOneWidget);
      expect(_page, findsNothing);
    });

    testWidgets('is a row of the sidebar on a wide screen', (tester) async {
      final rig = await _rig();
      await _pump(tester, rig, size: const Size(3300, 1800));
      expect(find.byKey(const Key('sidebar-quick-search')), findsOneWidget);
      await tester.tap(find.byKey(const Key('sidebar-quick-search')));
      await _settle(tester, 6);
      expect(_page, findsOneWidget);
      expect(_from(tester), startsWith('From the list of sessions'));
      await _close(tester);
      expect(_page, findsNothing);
    });
  });

  group('the page', () {
    testWidgets('says what to say, with lines to try, the place first', (
      tester,
    ) async {
      final rig = await _rig();
      await _pump(tester, rig);
      await _tab(tester, 'Tasks');
      await _open(tester);
      final hint = find.byKey(const Key('quick-search-hint'));
      expect(
        find.descendant(
          of: hint,
          matching: find.text('Say what you want, in words, for instance:'),
        ),
        findsOneWidget,
      );
      // Favouring tasks, the line for a task comes first.
      final order = [
        'the task about the docs',
        'where did I debug the merge queue?',
        'how do I attach an image to a task?',
      ];
      final tops = [
        for (final line in order) tester.getTopLeft(find.text(line)).dy,
      ];
      expect(tops, [...tops]..sort());
      // The project it is about, and the model is warmed as it opens.
      expect(find.text('emacs-agent-harness'), findsOneWidget);
      expect(rig.search.warms.single['cwd'], _main);
    });

    testWidgets('a line to try is searched with a tap', (tester) async {
      final rig = await _rig();
      await _pump(tester, rig);
      await _open(tester);
      await tester.tap(find.text('the task about the docs'));
      await _settle(tester, 6);
      expect(rig.search.lastQuery, 'the task about the docs');
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'the task about the docs',
      );
    });

    testWidgets(
      'keeps the line in the box, to be refined, and clears it on request',
      (tester) async {
        final rig = await _rig();
        await _pump(tester, rig);
        await _open(tester);
        await _ask(tester, 'the merge queue');
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          'the merge queue',
        );
        // The keyboard gave way to what was found.
        expect(
          tester
              .widget<EditableText>(find.byType(EditableText))
              .focusNode
              .hasFocus,
          isFalse,
        );
        await tester.tap(find.byKey(const Key('quick-search-clear')));
        await tester.pump();
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          isEmpty,
        );
        expect(find.byKey(const Key('quick-search-clear')), findsNothing);
        // Nothing to ask of an empty box.
        final send = find.descendant(
          of: find.byKey(const Key('quick-search-submit')),
          matching: find.byType(IconButton),
        );
        expect(tester.widget<IconButton>(send).onPressed, isNull);
      },
    );

    testWidgets('can send the line from the keyboard', (tester) async {
      final rig = await _rig();
      await _pump(tester, rig);
      await _open(tester);
      await tester.enterText(_field, 'show me usage');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await _settle(tester, 6);
      expect(rig.search.lastQuery, 'show me usage');
    });

    testWidgets(
      'searches with Return and leaves with Escape, on a keyboard that has them',
      (tester) async {
        final rig = await _rig();
        await _pump(tester, rig);
        await _open(tester);
        await tester.enterText(_field, 'the merge queue');
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await _settle(tester, 6);
        expect(rig.search.lastQuery, 'the merge queue');
        expect(find.byKey(const Key('quick-search-found')), findsOneWidget);
        // Return over an empty box asks nothing, and breaks no line.
        await tester.enterText(_field, '   ');
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await _settle(tester, 2);
        expect(rig.search.asks, hasLength(1));
        // Escape leaves.
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await _settle(tester, 6);
        expect(_page, findsNothing);
        expect(find.byType(NavigationBar), findsOneWidget);
      },
    );

    testWidgets('can search a line the screen was opened with', (tester) async {
      final rig = await _rig();
      await _pump(tester, rig);
      await tester.pumpWidget(
        HarnessStyle(
          style: HarnessPlatformStyle.material,
          child: MaterialApp(
            home: QuickSearchScreen(
              app: rig.app,
              place: const QuickSearchPlace(SearchOrigin.settings),
              initialQuery: 'dark mode',
            ),
          ),
        ),
      );
      await _settle(tester, 6);
      expect(rig.search.lastQuery, 'dark mode');
      expect(rig.search.lastContext['view'], 'settings');
      expect(find.text('dark mode'), findsOneWidget);
    });
  });

  group('an answer', () {
    testWidgets(
      'in words comes first, drawn as Markdown, and the actions follow',
      (tester) async {
        final rig = await _rig();
        rig.search.onAsk = (_) => plan(
          query: 'how do I attach an image to a task?',
          answer:
              'Open **New task** with the **+** on the Tasks screen, then tap '
              '`Attach images`:\n\n1. Pick the pictures.\n2. Send the task.',
          commands: [
            foundCommand(
              'new-task',
              keys: 'Tasks tab › +',
              label: 'Submit a new task',
              doc: 'Describe the work, attach images, and send it.',
            ),
            foundCommand(
              'attach-images',
              keys: 'Tasks tab › + › Attach images',
              label: 'Attach images to a task or a message',
              doc: 'The image button sends pictures with the text.',
            ),
          ],
        );
        await _pump(tester, rig);
        await _open(tester);
        await _ask(tester, 'how do I attach an image to a task?');

        expect(find.byKey(const Key('quick-search-found')), findsOneWidget);
        final answer = find.byKey(const Key('quick-search-answer'));
        expect(answer, findsOneWidget);
        // Drawn, not typed: no asterisks or backticks, and a list.
        expect(
          find.descendant(
            of: answer,
            matching: find.textContaining('**', findRichText: true),
          ),
          findsNothing,
        );
        expect(
          find.descendant(
            of: answer,
            matching: find.textContaining(
              'Pick the pictures.',
              findRichText: true,
            ),
          ),
          findsOneWidget,
        );
        expect(find.text('ANSWER · claude-haiku-4-5'), findsOneWidget);
        // What it names, with the taps that reach it, below the answer.
        expect(find.text('Actions'.toUpperCase()), findsOneWidget);
        expect(find.text('Submit a new task'), findsOneWidget);
        expect(find.text('Tasks tab › +'), findsOneWidget);
        expect(
          find.text('Attach images to a task or a message'),
          findsOneWidget,
        );
        expect(
          tester.getTopLeft(answer).dy,
          lessThan(tester.getTopLeft(_row('quick-search-command-new-task')).dy),
        );
        // How much it found, in a line under the box.
        expect(
          find.descendant(
            of: find.byKey(const Key('quick-search-head')),
            matching: find.textContaining(
              '“how do I attach an image to a task?” · 2 actions',
            ),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'is asked of the harness with where it was typed and what the app can do',
      (tester) async {
        final rig = await _rig();
        await _pump(tester, rig);
        await _tab(tester, 'Usage');
        await _open(tester);
        await _ask(tester, 'where is the plan quota?');
        expect(rig.search.asks, hasLength(1));
        expect(rig.search.asks.single['cwd'], _main);
        expect(rig.search.lastOpts['bias'], 'commands');
        expect(rig.search.lastContext, {
          'view': 'buffer',
          'title': 'Usage',
          'client': 'phone app',
          'project': _main,
        });
        expect(
          rig.search.lastCommandNames,
          containsAll([
            'open-usage',
            'open-tasks',
            'new-task',
            'open-settings',
          ]),
        );
      },
    );

    testWidgets('runs an action of the app: the search closes and it is done', (
      tester,
    ) async {
      final rig = await _rig();
      rig.search.onAsk = (_) => plan(
        commands: [
          foundCommand(
            'new-task',
            keys: 'Tasks tab › +',
            label: 'Submit a new task',
            doc: 'Describe the work.',
          ),
        ],
      );
      await _pump(tester, rig);
      await _open(tester);
      await _ask(tester, 'submit a task');
      await tester.tap(_row('quick-search-command-new-task'));
      await _settle(tester, 8);
      expect(_page, findsNothing);
      expect(_shown(tester), 'Tasks');
    });

    testWidgets('a second tap in the same moment closes nothing more', (
      tester,
    ) async {
      final rig = await _rig();
      rig.search.onAsk = (_) => plan(
        commands: [
          foundCommand(
            'open-settings',
            keys: 'Settings tab',
            label: 'Open settings',
            doc: 'Connection, theme and the rest.',
          ),
        ],
      );
      await _pump(tester, rig);
      await _open(tester);
      await _ask(tester, 'settings');
      final row = _row('quick-search-command-open-settings');
      // The page is on its way out, and still there for one more tap in the
      // same frame: a thumb that taps twice.  (A pop of its own for each would
      // close the screens under it too.)
      final tap = tester
          .widget<HarnessTap>(
            find.descendant(of: row, matching: find.byType(HarnessTap)).first,
          )
          .onTap!;
      tap();
      tap();
      await _settle(tester, 8);
      expect(_page, findsNothing);
      // The screens are still there, and it is the settings that is shown.
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(_shown(tester), 'Settings');
    });

    testWidgets('changes a setting at once, from where it was found', (
      tester,
    ) async {
      final rig = await _rig();
      rig.search.onAsk = (_) => plan(
        commands: [
          foundCommand(
            'theme-dark',
            keys: 'Settings tab › Appearance › Theme',
            where: 'settings',
            label: 'Use the dark theme',
            doc: 'Dark colours, whatever the system uses.',
          ),
        ],
      );
      await _pump(tester, rig);
      await _open(tester);
      await _ask(tester, 'dark mode please');
      // The row says what a tap does.
      expect(
        find.descendant(
          of: _row('quick-search-command-theme-dark'),
          matching: find.text('Set'),
        ),
        findsOneWidget,
      );
      await tester.tap(_row('quick-search-command-theme-dark'));
      await _settle(tester, 8);
      expect(_page, findsNothing);
      expect(rig.settings.themeMode, ThemeMode.dark);
    });

    testWidgets('goes to a project, narrowing the board to it', (tester) async {
      final rig = await _rig(
        arrange: (harness) => harness.seedOtherProjectTasks(),
      );
      rig.search.onAsk = (_) => plan(
        commands: [
          foundCommand(
            'project-other-project',
            keys: 'Tasks tab › the project line',
            where: 'project',
            label: 'Show the other-project project’s tasks',
            doc: 'Narrows the task board, usage and new sessions.',
          ),
        ],
      );
      await _pump(tester, rig);
      await _open(tester);
      await _ask(tester, 'the other project');
      await tester.tap(_row('quick-search-command-project-other-project'));
      await _settle(tester, 10);
      expect(_shown(tester), 'Tasks');
      expect(rig.app.tasks!.project, _other);
      expect(rig.app.selectedProject, _other);
    });

    testWidgets(
      'an action the app never offered does nothing, and nothing breaks',
      (tester) async {
        final rig = await _rig();
        rig.search.onAsk = (_) => plan(
          commands: [
            foundCommand('no-such-thing', label: 'Not an action', doc: 'x'),
          ],
        );
        await _pump(tester, rig);
        await _open(tester);
        await _ask(tester, 'something odd');
        await tester.tap(find.text('Not an action'));
        await _settle(tester, 4);
        expect(
          _page,
          findsOneWidget,
          reason: 'nothing happened: it is still open',
        );
      },
    );
  });

  group('sessions and tasks', () {
    testWidgets(
      'a session found by what was said in it opens as a conversation',
      (tester) async {
        final rig = await _rig();
        rig.search.onAsk = (_) => plan(
          bias: 'sessions',
          sessions: [
            foundSession(
              's1',
              name: 'Design the merge queue',
              snippet: 'The merge queue has three moving parts',
              ranges: [
                [4, 15],
              ],
              node: 'n2',
            ),
            foundSession(
              's4',
              name: 'Investigate cache misses',
              kind: 'btw',
              status: 'inactive',
              project: 'other-project',
            ),
          ],
        );
        await _pump(tester, rig);
        await _open(tester);
        await _ask(tester, 'where did I design the merge queue');
        expect(find.text('Sessions'.toUpperCase()), findsOneWidget);
        expect(find.text('Design the merge queue'), findsWidgets);
        // The passage, with the words found marked.
        final passage = find.byWidgetPredicate(
          (widget) =>
              widget is RichText &&
              widget.text.toPlainText() ==
                  'The merge queue has three moving parts',
        );
        expect(passage, findsOneWidget);
        final spans = <String>[];
        (tester.widget<RichText>(passage).text as TextSpan).visitChildren((
          span,
        ) {
          if (span is TextSpan && span.style?.fontWeight == FontWeight.w700) {
            spans.add(span.text!);
          }
          return true;
        });
        expect(spans, ['merge queue']);
        // What kind it is, where, and how long ago.
        expect(find.textContaining('Side chat'), findsOneWidget);
        expect(find.textContaining('other-project'), findsWidgets);

        await tester.tap(_row('quick-search-session-s4'));
        await _settle(tester, 8);
        expect(_page, findsNothing);
        expect(find.byType(SessionScreen), findsOneWidget);
        expect(
          find.textContaining(
            'Why did the prompt cache miss twice?',
            findRichText: true,
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'a task with a conversation opens it; one without shows on the board',
      (tester) async {
        final rig = await _rig();
        rig.search.onAsk = (_) => plan(
          bias: 'tasks',
          tasks: [
            foundTask(
              'task-1',
              'Build the Flutter ACP client',
              'in progress: working',
              session: 's3',
            ),
            foundTask(
              'task-2',
              'Review the emulator screenshots',
              'review: finished, waits for your review',
            ),
          ],
        );
        await _pump(tester, rig);
        await _tab(tester, 'Tasks');
        await _open(tester);
        await _ask(tester, 'the flutter task');
        expect(find.text('Build the Flutter ACP client'), findsOneWidget);
        expect(find.text('in progress: working'), findsOneWidget);
        expect(find.text('task-1'), findsOneWidget);
        // What a tap does is said on the row.
        expect(
          find.descendant(
            of: _row('quick-search-task-task-1'),
            matching: find.text('Open'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: _row('quick-search-task-task-2'),
            matching: find.text('Board'),
          ),
          findsOneWidget,
        );
        await tester.tap(_row('quick-search-task-task-1'));
        await _settle(tester, 8);
        expect(find.byType(SessionScreen), findsOneWidget);
        expect(
          find.textContaining(
            'matching the sheet to the system motion',
            findRichText: true,
          ),
          findsOneWidget,
        );

        // From the conversation, the other one: it has none, so the board.
        await _open(tester);
        await _ask(tester, 'the screenshots task');
        await tester.tap(_row('quick-search-task-task-2'));
        await _settle(tester, 8);
        expect(find.byType(SessionScreen), findsNothing);
        expect(_shown(tester), 'Tasks');
      },
    );

    testWidgets('a task with a conversation can also be shown on the board', (
      tester,
    ) async {
      final rig = await _rig();
      rig.search.onAsk = (_) => plan(
        tasks: [
          foundTask(
            'task-1',
            'Build the Flutter ACP client',
            'in progress: working',
            session: 's3',
          ),
        ],
      );
      await _pump(tester, rig);
      await _open(tester);
      await _ask(tester, 'the flutter task');
      await tester.tap(find.byKey(const Key('quick-search-board-task-1')));
      await _settle(tester, 8);
      expect(find.byType(SessionScreen), findsNothing);
      expect(_shown(tester), 'Tasks');
    });

    testWidgets('lists what the place favours first', (tester) async {
      final rig = await _rig();
      rig.search.onAsk = (params) => plan(
        commands: [
          foundCommand(
            'open-tasks',
            label: 'Open the task board',
            doc: 'Tasks by column.',
          ),
        ],
        sessions: [foundSession('s1', name: 'Design the merge queue')],
        tasks: [
          foundTask(
            'task-1',
            'Build the Flutter ACP client',
            'in progress: working',
          ),
        ],
      );
      await _pump(tester, rig);
      await _tab(tester, 'Tasks');
      await _open(tester);
      await _ask(tester, 'merge');
      double top(String label) =>
          tester.getTopLeft(find.text(label.toUpperCase())).dy;
      expect(top('Tasks'), lessThan(top('Sessions')));
      expect(top('Sessions'), lessThan(top('Actions')));
      await _close(tester);
      await _tab(tester, 'Settings');
      await _open(tester);
      await _ask(tester, 'merge');
      expect(top('Actions'), lessThan(top('Sessions')));
      expect(top('Sessions'), lessThan(top('Tasks')));
    });

    testWidgets('says what the model looked at, and that it looked wider', (
      tester,
    ) async {
      final rig = await _rig();
      rig.search.onAsk = (_) => plan(
        bias: 'tasks',
        looked: 'searched the sessions for “merge queue”',
        widened: true,
        note: 'Nothing matched exactly; these come nearest.',
        sessions: [foundSession('s1', name: 'Design the merge queue')],
      );
      await _pump(tester, rig);
      await _tab(tester, 'Tasks');
      await _open(tester);
      await _ask(tester, 'merge queue task');
      expect(
        find.descendant(
          of: find.byKey(const Key('quick-search-head')),
          matching: find.textContaining(
            'searched the sessions for “merge queue”',
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('quick-search-note')),
          matching: find.text('Nothing matched exactly; these come nearest.'),
        ),
        findsOneWidget,
      );
    });
  });

  group('orders', () {
    testWidgets('are proposed, and done when a person says so', (tester) async {
      final rig = await _rig();
      rig.search.onAsk = (_) => plan(
        bias: 'tasks',
        tasks: [
          foundTask(
            'task-2',
            'Review the emulator screenshots',
            'review: finished, waits for your review',
          ),
        ],
        actions: [
          proposedAction(
            'task-2',
            'archive',
            title: 'Review the emulator screenshots',
          ),
        ],
      );
      await _pump(tester, rig);
      await _tab(tester, 'Tasks');
      await _open(tester);
      await _ask(tester, 'get rid of the screenshots task');
      expect(find.byKey(const Key('quick-search-proposal')), findsOneWidget);
      expect(
        find.text('Archive “Review the emulator screenshots”?'),
        findsOneWidget,
      );
      // Nothing is done until it is said.
      expect(rig.search.applies, isEmpty);
      await tester.tap(find.byKey(const Key('quick-search-do-it')));
      await _settle(tester, 6);
      expect(rig.search.applies, hasLength(1));
      expect(asMapList(rig.search.applies.single['actions']), [
        {
          'task': 'task-2',
          'action': 'archive',
          'title': 'Review the emulator screenshots',
          'confirm': false,
        },
      ]);
      expect(find.byKey(const Key('quick-search-proposal')), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const Key('quick-search-results')),
          matching: find.text('Archived “Review the emulator screenshots”'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('say what went wrong when the harness would not', (
      tester,
    ) async {
      final rig = await _rig();
      rig.search.onAsk = (_) => plan(
        actions: [
          proposedAction(
            'task-1',
            'stop',
            title: 'Build the Flutter ACP client',
            confirm: true,
          ),
        ],
      );
      rig.search.onApply = (_) => [
        {
          'task': 'task-1',
          'action': 'stop',
          'title': 'Build the Flutter ACP client',
          'ok': false,
          'error': 'it is not working',
        },
      ];
      await _pump(tester, rig);
      await _open(tester);
      await _ask(tester, 'stop the client task');
      await tester.tap(find.byKey(const Key('quick-search-do-it')));
      await _settle(tester, 6);
      expect(
        find.text(
          'Could not stop “Build the Flutter ACP client”: it is not working',
        ),
        findsOneWidget,
      );
    });

    testWidgets('are left undone when skipped', (tester) async {
      final rig = await _rig();
      rig.search.onAsk = (_) => plan(
        actions: [
          proposedAction(
            'task-1',
            'priority',
            title: 'Build the client',
            text: 'high',
          ),
        ],
      );
      await _pump(tester, rig);
      await _open(tester);
      await _ask(tester, 'make the client task high priority');
      expect(
        find.text('Make “Build the client” high priority?'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('quick-search-skip')));
      await _settle(tester, 4);
      expect(find.byKey(const Key('quick-search-proposal')), findsNothing);
      expect(rig.search.applies, isEmpty);
    });

    testWidgets(
      'wait for the answer of the harness, and say they are being done',
      (tester) async {
        final rig = await _rig();
        final gate = Completer<Object?>();
        rig.search.onAsk = (_) => plan(
          actions: [
            proposedAction('task-1', 'stop', title: 'Build the client'),
          ],
        );
        rig.search.onApply = (_) => gate.future;
        await _pump(tester, rig);
        await _open(tester);
        await _ask(tester, 'stop the client task');
        await tester.tap(find.byKey(const Key('quick-search-do-it')));
        await _settle(tester, 4);
        expect(find.byKey(const Key('quick-search-running')), findsOneWidget);
        expect(find.text('Doing it…'), findsOneWidget);
        expect(find.byKey(const Key('quick-search-do-it')), findsNothing);
        gate.complete([
          {
            'task': 'task-1',
            'action': 'stop',
            'title': 'Build the client',
            'ok': true,
          },
        ]);
        await _settle(tester, 4);
        expect(find.text('Stopped “Build the client”'), findsOneWidget);
      },
    );
  });

  group('the wait', () {
    testWidgets(
      'says the line and the model it is asked of, and can be stopped',
      (tester) async {
        final rig = await _rig();
        final gate = Completer<Object?>();
        rig.search.onAsk = (_) => gate.future;
        await _pump(tester, rig);
        await _open(tester);
        await _ask(tester, 'where did I debug the merge queue?');
        final waiting = find.byKey(const Key('quick-search-waiting'));
        expect(waiting, findsOneWidget);
        expect(
          find.descendant(
            of: waiting,
            matching: find.text('“where did I debug the merge queue?”'),
          ),
          findsOneWidget,
        );
        // The model the harness said answers, as the box opened.
        expect(
          find.descendant(
            of: waiting,
            matching: find.text('asking claude-haiku-4-5…'),
          ),
          findsOneWidget,
        );
        // Another line cannot be sent over this one while it waits...
        // ...but waiting can be given up.
        await tester.tap(find.byKey(const Key('quick-search-stop')));
        await _settle(tester, 4);
        expect(waiting, findsNothing);
        expect(find.byKey(const Key('quick-search-hint')), findsOneWidget);
        // What the harness says after that is not shown.
        gate.complete(plan(answer: 'Too late to matter.'));
        await _settle(tester, 6);
        expect(find.text('Too late to matter.'), findsNothing);
        expect(find.byKey(const Key('quick-search-hint')), findsOneWidget);
        // The line is still in the box, to be sent again.
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          'where did I debug the merge queue?',
        );
      },
    );

    testWidgets(
      'the way out of it is the way out of the page, and a late answer is harmless',
      (tester) async {
        final rig = await _rig();
        final gate = Completer<Object?>();
        rig.search.onAsk = (_) => gate.future;
        await _pump(tester, rig);
        await _open(tester);
        await _ask(tester, 'anything at all');
        expect(find.byKey(const Key('quick-search-waiting')), findsOneWidget);
        await _close(tester);
        expect(_page, findsNothing);
        gate.complete(
          plan(
            commands: [
              foundCommand(
                'open-tasks',
                label: 'Open the task board',
                doc: 'x',
              ),
            ],
          ),
        );
        await _settle(tester, 6);
        expect(_page, findsNothing);
        expect(_shown(tester), 'Sessions', reason: 'nothing was opened for it');
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'can be asked again, with the stop button gone, once answered',
      (tester) async {
        final rig = await _rig();
        await _pump(tester, rig);
        await _open(tester);
        await _ask(tester, 'first');
        await _ask(tester, 'second');
        expect(rig.search.asks.map((ask) => ask['query']), ['first', 'second']);
        expect(find.byKey(const Key('quick-search-stop')), findsNothing);
      },
    );
  });

  group('nothing, and failure', () {
    testWidgets('says nothing was found when nothing was', (tester) async {
      final rig = await _rig();
      rig.search.onAsk = (_) => plan(query: 'zzzz qqqq');
      await _pump(tester, rig);
      await _open(tester);
      await _ask(tester, 'zzzz qqqq');
      expect(find.byKey(const Key('quick-search-nothing')), findsOneWidget);
      expect(find.text('Nothing found'), findsOneWidget);
      expect(
        find.textContaining('No action, session or task for “zzzz qqqq”'),
        findsOneWidget,
      );
      // And a way to look elsewhere.
      expect(find.text('Search again, favouring'), findsOneWidget);
      expect(
        find.byKey(const Key('quick-search-reask-sessions')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('quick-search-reask-actions')),
        findsOneWidget,
      );
    });

    testWidgets('an answer in words with no list is an answer, not nothing', (
      tester,
    ) async {
      final rig = await _rig();
      rig.search.onAsk = (_) =>
          plan(answer: 'Verify merges the work of a task in review.');
      await _pump(tester, rig);
      await _open(tester);
      await _ask(tester, 'what does verify do?');
      expect(find.byKey(const Key('quick-search-nothing')), findsNothing);
      expect(
        find.textContaining('Verify merges the work', findRichText: true),
        findsOneWidget,
      );
    });

    testWidgets(
      'says why a search failed, in the harness’s words, and tries again',
      (tester) async {
        final rig = await _rig();
        rig.search.onAsk = (_) =>
            throw const SearchFailure('The model took longer than 45s');
        await _pump(tester, rig);
        await _open(tester);
        await _ask(tester, 'a slow one');
        expect(
          find.text('The search failed: The model took longer than 45s'),
          findsOneWidget,
        );
        expect(find.text('Retry'), findsOneWidget);
        rig.search.onAsk = (_) => plan(answer: 'It answers now.');
        await tester.tap(find.text('Retry'));
        await _settle(tester, 6);
        expect(find.byKey(const Key('quick-search-error')), findsNothing);
        expect(
          find.textContaining('It answers now.', findRichText: true),
          findsOneWidget,
        );
        expect(rig.search.asks.map((ask) => ask['query']), [
          'a slow one',
          'a slow one',
        ]);
      },
    );

    testWidgets('a harness without the search module is told as it is', (
      tester,
    ) async {
      final rig = await _rig(offersSearch: false);
      await _pump(tester, rig);
      await _open(tester);
      expect(find.byKey(const Key('quick-search-unsupported')), findsOneWidget);
      expect(find.text('This harness cannot search'), findsOneWidget);
      // Nothing can be sent, and nothing is.
      await tester.enterText(_field, 'how do I attach an image?');
      await tester.pump();
      final send = find.descendant(
        of: find.byKey(const Key('quick-search-submit')),
        matching: find.byType(IconButton),
      );
      expect(tester.widget<IconButton>(send).onPressed, isNull);
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await _settle(tester, 4);
      expect(rig.search.asks, isEmpty);
      expect(rig.search.warms, isEmpty);
      // The page still closes.
      await _close(tester);
      expect(_page, findsNothing);
    });

    testWidgets(
      'a harness out of reach is waited for, and the search works when it is back',
      (tester) async {
        final rig = await _rig();
        await _pump(tester, rig);
        await _open(tester);
        await tester.enterText(_field, 'the merge queue');
        await tester.pump();
        rig.harness.refuseConnects = 1000000;
        await rig.harness.dropConnection('The connection dropped.');
        await _settle(tester, 4);
        expect(rig.app.phase, ConnectionPhase.reconnecting);
        expect(_page, findsOneWidget, reason: 'the page is where it was');
        expect(
          find.byKey(const Key('quick-search-reconnecting')),
          findsOneWidget,
        );
        expect(find.text('Reconnecting to the harness…'), findsOneWidget);
        // What was typed is kept, and it cannot be sent yet.
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          'the merge queue',
        );
        final send = find.descendant(
          of: find.byKey(const Key('quick-search-submit')),
          matching: find.byType(IconButton),
        );
        expect(tester.widget<IconButton>(send).onPressed, isNull);
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await _settle(tester, 2);
        expect(rig.search.asks, isEmpty);

        // The harness is back.
        rig.harness.refuseConnects = 0;
        await _settle(tester, 10);
        expect(rig.app.phase, ConnectionPhase.connected);
        expect(
          find.byKey(const Key('quick-search-reconnecting')),
          findsNothing,
        );
        expect(tester.widget<IconButton>(send).onPressed, isNotNull);
        await tester.tap(find.byKey(const Key('quick-search-submit')));
        await _settle(tester, 6);
        expect(rig.search.lastQuery, 'the merge queue');
        expect(find.byKey(const Key('quick-search-error')), findsNothing);
      },
    );

    testWidgets(
      'a connection lost while it waits is a failure that can be retried',
      (tester) async {
        final rig = await _rig();
        final gate = Completer<Object?>();
        rig.search.onAsk = (_) => gate.future;
        await _pump(tester, rig);
        await _open(tester);
        await _ask(tester, 'the merge queue');
        expect(find.byKey(const Key('quick-search-waiting')), findsOneWidget);
        await rig.harness.dropConnection('The network went away.');
        await _settle(tester, 6);
        expect(find.byKey(const Key('quick-search-error')), findsOneWidget);
        expect(find.textContaining('The search failed:'), findsOneWidget);
        expect(find.byKey(const Key('quick-search-waiting')), findsNothing);
      },
    );
  });

  group('leaving', () {
    testWidgets(
      'is the back button, the way out of the header, or the system’s',
      (tester) async {
        final rig = await _rig();
        await _pump(tester, rig);
        await _open(tester);
        await _close(tester);
        expect(_page, findsNothing);
        await _open(tester);
        await tester.binding.handlePopRoute();
        await _settle(tester, 6);
        expect(_page, findsNothing);
        expect(find.byType(NavigationBar), findsOneWidget);
      },
    );

    testWidgets('keeps what was found when the page is not the one asked of', (
      tester,
    ) async {
      final rig = await _rig();
      await _pump(tester, rig);
      await _open(tester);
      await _ask(tester, 'the merge queue');
      await _close(tester);
      // Another time it starts empty, with the lines searched before.
      await _open(tester);
      expect(find.byKey(const Key('quick-search-found')), findsNothing);
      expect(find.byKey(const Key('quick-search-hint')), findsOneWidget);
      expect(find.text('RECENT'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
    });
  });

  group('the lines searched before', () {
    testWidgets('come back with a tap, newest first, each once', (
      tester,
    ) async {
      final rig = await _rig();
      await _pump(tester, rig);
      await _open(tester);
      await _ask(tester, 'one');
      await _ask(tester, 'two');
      await _ask(tester, 'one');
      await _close(tester);
      await _open(tester);
      final recent = find.byKey(const Key('quick-search-hint'));
      final lines = [
        for (final line in ['one', 'two'])
          tester
              .getTopLeft(
                find.descendant(of: recent, matching: find.text(line)),
              )
              .dy,
      ];
      expect(lines.first, lessThan(lines.last));
      rig.search.asks.clear();
      await tester.tap(find.descendant(of: recent, matching: find.text('two')));
      await _settle(tester, 6);
      expect(rig.search.lastQuery, 'two');
      expect(rig.app.quickSearchHistory.lines, ['two', 'one']);
    });
  });

  group('asking again', () {
    testWidgets(
      'favouring sessions, or actions, with the buttons under what was found',
      (tester) async {
        final rig = await _rig();
        await _pump(tester, rig);
        await _tab(tester, 'Tasks');
        await _open(tester);
        await _ask(tester, 'the merge queue');
        expect(rig.search.lastOpts['bias'], 'tasks');
        await tester.ensureVisible(
          find.byKey(const Key('quick-search-reask-sessions')),
        );
        await tester.tap(find.byKey(const Key('quick-search-reask-sessions')));
        await _settle(tester, 6);
        expect(rig.search.lastOpts['bias'], 'sessions');
        expect(rig.search.lastQuery, 'the merge queue');
        expect(
          _from(tester),
          'From the task board · favours sessions, then actions',
        );
        await tester.ensureVisible(
          find.byKey(const Key('quick-search-reask-actions')),
        );
        await tester.tap(find.byKey(const Key('quick-search-reask-actions')));
        await _settle(tester, 6);
        expect(rig.search.lastOpts['bias'], 'commands');
        expect(
          _from(tester),
          'From the task board · favours actions, then sessions',
        );
        expect(rig.search.asks, hasLength(3));
      },
    );
  });

  group('the project', () {
    testWidgets(
      'is the one the app is on, and another can be picked when there is one',
      (tester) async {
        final rig = await _rig(
          arrange: (harness) => harness.seedOtherProjectTasks(),
        );
        await _pump(tester, rig);
        await _open(tester);
        expect(find.text('emacs-agent-harness'), findsOneWidget);
        await tester.tap(find.byKey(const Key('quick-search-project')));
        await _settle(tester, 6);
        expect(find.text('Search in a project'), findsOneWidget);
        await tester.tap(find.text('other-project'));
        await _settle(tester, 6);
        expect(find.text('other-project'), findsOneWidget);
        // The model of that project is warmed, and the line is searched there.
        expect(rig.search.warms.last['cwd'], _other);
        await _ask(tester, 'the cluster alerts');
        expect(rig.search.asks.single['cwd'], _other);
        expect(rig.search.lastContext['project'], _other);
      },
    );

    testWidgets('is only said, when the harness has just the one', (
      tester,
    ) async {
      final rig = await _rig(
        arrange: (harness) {
          harness.projectList = [_main];
          // The one session of another project.
          harness.sessions.remove('s4');
          harness.nodes.remove('s4');
        },
      );
      await _pump(tester, rig);
      await _open(tester);
      // Said, and nothing to choose among: a tap on it opens nothing.
      await tester.tap(find.text('emacs-agent-harness'));
      await _settle(tester, 4);
      expect(find.text('Search in a project'), findsNothing);
    });
  });

  group('on a small phone, at one and a half times the text', () {
    for (final apple in [false, true]) {
      testWidgets('nothing overflows, ${apple ? 'Apple' : 'Android'} style', (
        tester,
      ) async {
        final rig = await _rig(
          arrange: (harness) => harness.seedOtherProjectTasks(),
          platform: apple
              ? PreviewPlatform.cupertino
              : PreviewPlatform.material,
        );
        rig.search.onAsk = (_) => plan(
          answer:
              'Open **New task** with the **+** on the Tasks screen, then tap '
              '`Attach images` and pick the pictures, up to four of them, '
              'whatever size they are:\n\n1. Tap the image button.\n2. Pick.\n'
              '3. Send the message or the task.\n\n'
              '| Where | Button |\n|---|---|\n| Task | Attach images |\n'
              '| Message | The image button next to the box |',
          note: 'Nothing matched exactly; these come nearest.',
          widened: true,
          looked: 'searched the sessions for “attach image to the task”',
          commands: [
            foundCommand(
              'attach-images',
              keys: 'Tasks tab › + › Attach images; in a conversation › image button',
              label: 'Attach images to a task or a message',
              doc: 'The image button of the new-task sheet and of a conversation’s message box sends pictures along with the text.',
            ),
          ],
          sessions: [
            foundSession(
              's1',
              name: 'A session with a name that is a good deal longer than a line of this phone',
              project: 'a-project-with-a-long-name-as-well',
              snippet:
                  'attach the screenshots to the task as images, and attach the logs too, '
                  'so that whoever reads the task sees what the agent saw',
              ranges: [
                [0, 6],
                [11, 22],
              ],
            ),
          ],
          tasks: [
            foundTask(
              'task-1',
              'A task with a title that is a good deal longer than a line',
              'needs input: asks you: which of the two directories should it write the generated files in?',
              session: 's3',
            ),
          ],
          actions: [
            proposedAction(
              'task-1',
              'message',
              title:
                  'A task with a title that is a good deal longer than a line',
              text: 'use the first directory, and say what you changed when you are done',
            ),
          ],
        );
        tester.platformDispatcher.textScaleFactorTestValue = 1.5;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await _pump(tester, rig, size: const Size(960, 1900));
        await tester.tap(_button);
        await _settle(tester, 6);
        // The hint, the wait, the answer, the failure: each as whole as the next.
        expect(find.byKey(const Key('quick-search-hint')), findsOneWidget);
        await _ask(
          tester,
          'how do I attach an image to a task, and where did I say it?',
        );
        expect(find.byKey(const Key('quick-search-found')), findsOneWidget);
        expect(find.byKey(const Key('quick-search-proposal')), findsOneWidget);
        rig.search.onAsk = (_) => throw const SearchFailure(
          'The model took longer than 45 seconds to answer',
        );
        await _ask(tester, 'a slow one');
        expect(find.byKey(const Key('quick-search-error')), findsOneWidget);
        // Whatever it was, the Apple style's hero fight aside, nothing broke.
        if (apple) tester.takeException();
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('on an Apple phone', () {
    testWidgets('it is drawn in the same words, and does the same', (
      tester,
    ) async {
      final rig = await _rig(platform: PreviewPlatform.cupertino);
      rig.search.onAsk = (_) => plan(
        answer: 'Open **Settings** and tap **Disconnect**.',
        commands: [
          foundCommand(
            'disconnect',
            keys: 'Settings tab › Disconnect',
            label: 'Disconnect from the harness',
            doc: 'Leaves this harness.',
          ),
        ],
        sessions: [foundSession('s1', name: 'Design the merge queue')],
      );
      await _pump(tester, rig);
      await tester.tap(find.byKey(QuickSearchEntry.buttonKey));
      await _settle(tester, 8);
      // The home screens each have a navigation bar, and a page pushed on
      // them makes the Cupertino ones fight for one hero: the same on every
      // page of the app (see question_screenshots_test.dart), not what is
      // drawn.
      tester.takeException();
      expect(_page, findsOneWidget);
      await _ask(tester, 'how do I disconnect?');
      expect(find.text('Disconnect from the harness'), findsOneWidget);
      expect(find.text('Design the merge queue'), findsOneWidget);
      expect(
        find.textContaining(
          'tap Disconnect'.replaceAll('tap ', ''),
          findRichText: true,
        ),
        findsWidgets,
      );
      await tester.tap(_row('quick-search-command-disconnect'));
      await _settle(tester, 8);
      tester.takeException();
      expect(_page, findsNothing);
      expect(_shown(tester), 'Settings');
    });
  });
}
