// A run of tool calls as the person sees it: one line that says how many calls
// there were and of what, how many went wrong, and whether one still runs; a
// tap opens it to its calls, each closed as anywhere else in the transcript.
// Which calls fold is the harness's allow list and the rules of the Emacs chat
// (see tool_runs_test.dart); these are about what is drawn, and what is kept
// when the transcript grows or is grouped anew while a run is open.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/models/tool_catalogue.dart';
import 'package:harness_client/src/ui/adaptive/adaptive_widgets.dart';
import 'package:harness_client/src/ui/adaptive/platform_style.dart';
import 'package:harness_client/src/ui/theme/harness_theme.dart';
import 'package:harness_client/src/ui/widgets/tool_card.dart';
import 'package:harness_client/src/ui/widgets/tool_run_card.dart';
import 'package:harness_client/src/ui/widgets/transcript_view.dart';

import 'support/harness_tools.dart';
import 'support/transcript_log.dart';

/// The tools of the harness as `tools/list` serves them.
final _tools = ToolCatalogue.fromWire(harnessToolSpecs());

/// The same tree every time, so that drawing it again with more in the
/// transcript is the app's own update, and keeps what the person opened.
Widget _app(
  TranscriptLog log, {
  ToolCatalogue? tools,
  Set<String> waiting = const {},
  bool showThinking = true,
  HarnessPlatformStyle style = HarnessPlatformStyle.material,
  double scale = 1,
}) => HarnessStyle(
  style: style,
  child: MaterialApp(
    theme: HarnessTheme.material(Brightness.light),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    home: Scaffold(
      body: TranscriptView(
        items: log.items,
        showThinking: showThinking,
        tools: tools ?? _tools,
        waiting: waiting,
      ),
    ),
  ),
);

/// Time passes, in the steps an animation takes: a first frame starts it.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 300));
}

/// Draw the transcript on a phone, 390 × 844 points (or [width] wide).
Future<void> _show(
  WidgetTester tester,
  TranscriptLog log, {
  ToolCatalogue? tools,
  Set<String> waiting = const {},
  bool showThinking = true,
  HarnessPlatformStyle style = HarnessPlatformStyle.material,
  double width = 390,
  double scale = 1,
}) async {
  tester.view.physicalSize = Size(width * 3, 2532);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    _app(
      log,
      tools: tools,
      waiting: waiting,
      showThinking: showThinking,
      style: style,
      scale: scale,
    ),
  );
  await _settle(tester);
}

/// The same transcript, grown or with other calls waiting, drawn again.
Future<void> _update(
  WidgetTester tester,
  TranscriptLog log, {
  Set<String> waiting = const {},
  bool showThinking = true,
}) async {
  await tester.pumpWidget(
    _app(log, waiting: waiting, showThinking: showThinking),
  );
  await _settle(tester);
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await _settle(tester);
}

/// The summary line of a run, by what it says first ("3 tool calls").
Finder _run(String heading) =>
    find.ancestor(of: find.text(heading), matching: find.byType(ToolRunCard));

/// The calls of the transcript that are drawn as cards of their own.
Finder get _cards => find.byType(ToolCard);

/// A look around: a read, a search, another read.
TranscriptLog _lookAround() => TranscriptLog()
  ..user('Look around')
  ..call('c1', 'read_file', title: 'Read file: lib/a.dart')
  ..call('c2', 'grep', title: 'Search files: _open')
  ..call('c3', 'read_file', title: 'Read file: lib/b.dart')
  ..say('That is all of it');

void main() {
  group('a run of calls', () {
    testWidgets('is one line, and its calls are not drawn', (tester) async {
      await _show(tester, _lookAround());
      expect(find.text('3 tool calls'), findsOneWidget);
      expect(find.text('Read file ×2, Search files'), findsOneWidget);
      expect(_cards, findsNothing);
      // What is around it is as it was.
      expect(
        find.textContaining('Look around', findRichText: true),
        findsOneWidget,
      );
      expect(
        find.textContaining('That is all of it', findRichText: true),
        findsOneWidget,
      );
    });

    testWidgets('opens to its calls, each closed, and folds them again', (
      tester,
    ) async {
      await _show(tester, _lookAround());
      await _tap(tester, find.text('3 tool calls'));
      expect(_cards, findsNWidgets(3));
      expect(find.textContaining('Read file: lib/a.dart'), findsOneWidget);
      expect(find.textContaining('Search files: _open'), findsOneWidget);
      expect(find.textContaining('Read file: lib/b.dart'), findsOneWidget);
      // Each as closed as a call is anywhere else: nothing of it is built.
      expect(find.text('INPUT'), findsNothing);
      expect(find.text('OUTPUT'), findsNothing);
      // The line says it is open, and the way to close it.
      expect(
        find.descendant(
          of: _run('3 tool calls'),
          matching: find.byIcon(Icons.expand_less_rounded),
        ),
        findsOneWidget,
      );

      await _tap(tester, find.text('3 tool calls'));
      expect(_cards, findsNothing);
      expect(
        find.descendant(
          of: _run('3 tool calls'),
          matching: find.byIcon(Icons.expand_more_rounded),
        ),
        findsOneWidget,
      );
    });

    testWidgets('has calls that open one by one, without closing the run', (
      tester,
    ) async {
      await _show(tester, _lookAround());
      await _tap(tester, find.text('3 tool calls'));
      await _tap(tester, find.textContaining('Search files: _open'));
      // That call is open, the others are not, and the run is still open.
      expect(find.text('INPUT'), findsOneWidget);
      expect(find.text('OUTPUT'), findsOneWidget);
      expect(_cards, findsNWidgets(3));
      // Closed, the call is closed, and the run is still open.
      await _tap(tester, find.textContaining('Search files: _open'));
      expect(find.text('INPUT'), findsNothing);
      expect(_cards, findsNWidgets(3));
    });

    testWidgets('brings its first call into view when opened at the end', (
      tester,
    ) async {
      // A page that is long, and a run of calls that is the last of it: the
      // line is at the bottom of the screen, and its calls come out below.
      final log = TranscriptLog();
      for (var i = 0; i < 10; i++) {
        log
          ..user('Question $i')
          ..say('Answer $i, which takes a line or two to say');
      }
      log
        ..call('c1', 'read_file', title: 'Read file: lib/a.dart')
        ..call('c2', 'grep', title: 'Search files: _open')
        ..call('c3', 'read_file', title: 'Read file: lib/b.dart');
      await _show(tester, log);
      final page = tester.getRect(
        find.byKey(const ValueKey('transcript-list')),
      );
      expect(find.text('3 tool calls'), findsOneWidget);
      await _tap(tester, find.text('3 tool calls'));
      // The call that came out first is on the page, under its line.
      final first = tester.getRect(
        find.textContaining('Read file: lib/a.dart'),
      );
      expect(first.bottom, lessThanOrEqualTo(page.bottom));
      expect(first.top, greaterThanOrEqualTo(page.top));
      final line = tester.getRect(find.text('3 tool calls'));
      expect(line.bottom, lessThan(first.top));
      expect(line.top, greaterThanOrEqualTo(page.top));
    });

    testWidgets('has calls that are brought into view when they are opened', (
      tester,
    ) async {
      final log = TranscriptLog();
      for (var i = 0; i < 10; i++) {
        log
          ..user('Question $i')
          ..say('Answer $i, which takes a line or two to say');
      }
      log.call('c1', 'read_file', title: 'Read file: lib/a.dart');
      await _show(tester, log);
      final page = tester.getRect(
        find.byKey(const ValueKey('transcript-list')),
      );
      await _tap(tester, find.text('1 tool call'));
      // Opened at the foot of the page, the call is under its line, and a
      // call that is opened grows below the screen: it is brought into view.
      await _tap(tester, find.textContaining('Read file: lib/a.dart').last);
      // The card grows, and then the page scrolls to it: a second look.
      await _settle(tester);
      expect(find.text('INPUT'), findsOneWidget);
      expect(
        tester.getRect(find.text('OUTPUT')).bottom,
        lessThanOrEqualTo(page.bottom),
      );
    });

    testWidgets(
      'does not bring a call into view again when it is built again',
      (tester) async {
        final log = TranscriptLog();
        for (var i = 0; i < 10; i++) {
          log
            ..user('Question $i')
            ..say('Answer $i, which takes a line or two to say');
        }
        log
          ..call('c1', 'read_file', title: 'Read file: lib/a.dart')
          ..call('c2', 'grep', title: 'Search files: _open');
        await _show(tester, log);
        await _tap(tester, find.text('2 tool calls'));
        final scrollable = tester.state<ScrollableState>(
          find
              .descendant(
                of: find.byKey(const ValueKey('transcript-list')),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        final position = scrollable.position;
        // The person goes to the start of the page and comes back to a place
        // where the first call of the run is cut by the edge of the screen:
        // where they are is where they stay, whatever the list builds again.
        final back = position.maxScrollExtent - 150;
        position.jumpTo(0);
        await _settle(tester);
        position.jumpTo(back);
        await _settle(tester);
        expect(find.textContaining('Read file: lib/a.dart'), findsOneWidget);
        expect(position.pixels, back);
      },
    );

    testWidgets('sets its calls in from its own line', (tester) async {
      final log = _lookAround()..call('c4', 'edit_file', title: 'Edit file: a');
      await _show(tester, log);
      expect(find.byType(ToolRunMember), findsNothing);
      await _tap(tester, find.text('3 tool calls'));
      expect(find.byType(ToolRunMember), findsNWidgets(3));
      // The calls of the run are drawn under its line, further in than a
      // call that stands alone.
      final alone = find.ancestor(
        of: find.textContaining('Edit file: a'),
        matching: find.byType(ToolCard),
      );
      final inside = find.ancestor(
        of: find.textContaining('Read file: lib/a.dart'),
        matching: find.byType(ToolCard),
      );
      expect(
        tester.getTopLeft(inside).dx,
        greaterThan(tester.getTopLeft(alone).dx),
      );
    });

    testWidgets('is a run of one for a lone call, named as its card is', (
      tester,
    ) async {
      final log = TranscriptLog()
        ..user('Read it')
        ..call('c1', 'read_file', title: 'Read file: lib/a.dart')
        ..say('Done');
      await _show(tester, log);
      expect(find.text('1 tool call'), findsOneWidget);
      expect(find.text('Read file: lib/a.dart'), findsOneWidget);
      expect(_cards, findsNothing);
      await _tap(tester, find.text('1 tool call'));
      expect(_cards, findsOneWidget);
    });

    testWidgets('stops at a call of a tool that is not on the list', (
      tester,
    ) async {
      final log = TranscriptLog()
        ..call('c1', 'read_file', title: 'Read file: a')
        ..call('c2', 'grep', title: 'Search files: x')
        ..call('c3', 'edit_file', title: 'Edit file: a')
        ..call('c4', 'bash', title: 'Bash: ls')
        ..call('c5', 'write_file', title: 'Write file: b');
      await _show(tester, log);
      expect(find.text('2 tool calls'), findsOneWidget);
      expect(find.text('1 tool call'), findsOneWidget);
      // The two that write are cards of their own, between and after.
      expect(_cards, findsNWidgets(2));
      expect(find.textContaining('Edit file: a'), findsOneWidget);
      expect(find.textContaining('Write file: b'), findsOneWidget);
      // In the order they were made.
      final top = [
        for (final text in [
          '2 tool calls',
          'Edit file: a',
          '1 tool call',
          'Write file: b',
        ])
          tester.getTopLeft(find.textContaining(text)).dy,
      ];
      expect(top, orderedEquals([...top]..sort()));
    });

    testWidgets('folds nothing when the harness has no list of tools', (
      tester,
    ) async {
      await _show(tester, _lookAround(), tools: ToolCatalogue.empty);
      expect(find.textContaining('tool call'), findsNothing);
      expect(_cards, findsNWidgets(3));
    });

    testWidgets('folds only what the harness lists, whatever it is', (
      tester,
    ) async {
      // A harness whose allow list holds a tool of its own and not `grep`.
      final tools = ToolCatalogue.fromWire([
        {'name': 'read_file', 'label': 'Read file', 'coalescable': true},
        {'name': 'grep', 'label': 'Search files', 'coalescable': false},
      ]);
      await _show(tester, _lookAround(), tools: tools);
      // The search stands alone, between two runs of one.
      expect(find.text('1 tool call'), findsNWidgets(2));
      expect(_cards, findsOneWidget);
      expect(find.textContaining('Search files: _open'), findsOneWidget);
    });
  });

  group('the line of a run', () {
    testWidgets('counts the failed and the refused, closed', (tester) async {
      final log = TranscriptLog()
        ..call('c1', 'read_file', title: 'Read file: a')
        ..call('c2', 'bash', title: 'Bash: false', error: true)
        ..call('c3', 'bash', title: 'Bash: exit 2', error: true)
        ..call('c4', 'bash', title: 'Bash: rm', error: true, denied: true);
      await _show(tester, log);
      expect(find.text('4 tool calls'), findsOneWidget);
      expect(find.text('2 failed'), findsOneWidget);
      expect(find.text('1 denied'), findsOneWidget);
      // The check that says all went well is not there.
      expect(
        find.descendant(
          of: _run('4 tool calls'),
          matching: find.byIcon(Icons.check_rounded),
        ),
        findsNothing,
      );
      // And what failed is there to read once it is open.
      await _tap(tester, find.text('4 tool calls'));
      expect(find.text('Failed'), findsNWidgets(2));
      expect(find.text('Denied'), findsOneWidget);
    });

    testWidgets('says nothing of failures when there were none', (
      tester,
    ) async {
      await _show(tester, _lookAround());
      expect(find.textContaining('failed'), findsNothing);
      expect(find.textContaining('denied'), findsNothing);
      expect(
        find.descendant(
          of: _run('3 tool calls'),
          matching: find.byIcon(Icons.check_rounded),
        ),
        findsOneWidget,
      );
    });

    testWidgets('shows that a call of the run still runs', (tester) async {
      final log = TranscriptLog()
        ..call('c1', 'read_file', title: 'Read file: a')
        ..call('c2', 'bash', title: 'Bash: sleep 60', result: false);
      await _show(tester, log);
      expect(
        find.descendant(
          of: _run('2 tool calls'),
          matching: find.byType(HarnessActivity),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: _run('2 tool calls'),
          matching: find.byIcon(Icons.check_rounded),
        ),
        findsNothing,
      );
      // The result comes: it is done.
      log.result('c2');
      await _update(tester, log);
      expect(
        find.descendant(
          of: _run('2 tool calls'),
          matching: find.byType(HarnessActivity),
        ),
        findsNothing,
      );
    });

    testWidgets('counts the thinking folded in, when thinking is shown', (
      tester,
    ) async {
      final log = TranscriptLog()
        ..call('c1', 'read_file', title: 'Read file: a')
        ..think('Is it in b?')
        ..call('c2', 'read_file', title: 'Read file: b')
        ..think('Perhaps')
        ..call('c3', 'grep', title: 'Search files: x');
      await _show(tester, log);
      expect(find.text('3 tool calls'), findsOneWidget);
      expect(find.text('Read file ×2, Search files · thinking ×2'), findsOne);
      // Folded in: no thought is a card of its own.
      expect(find.text('Thought'), findsNothing);
    });

    testWidgets('does not count thinking that is not shown', (tester) async {
      final log = TranscriptLog()
        ..call('c1', 'read_file', title: 'Read file: a')
        ..think('Is it in b?')
        ..call('c2', 'read_file', title: 'Read file: b');
      await _show(tester, log, showThinking: false);
      expect(find.text('Read file ×2'), findsOneWidget);
      await _tap(tester, find.text('2 tool calls'));
      expect(_cards, findsNWidgets(2));
      expect(find.text('Thought'), findsNothing);
    });

    testWidgets('opens to the thoughts between its calls when they are shown', (
      tester,
    ) async {
      final log = TranscriptLog()
        ..call('c1', 'read_file', title: 'Read file: a')
        ..think('Is it in b?')
        ..call('c2', 'read_file', title: 'Read file: b');
      await _show(tester, log);
      expect(find.text('Thought'), findsNothing);
      await _tap(tester, find.text('2 tool calls'));
      expect(find.text('Thought'), findsOneWidget);
      expect(_cards, findsNWidgets(2));
      // In order: the call, the thought it was followed by, the next call.
      final order = [
        tester.getTopLeft(find.textContaining('Read file: a')).dy,
        tester.getTopLeft(find.text('Thought')).dy,
        tester.getTopLeft(find.textContaining('Read file: b')).dy,
      ];
      expect(order, orderedEquals([...order]..sort()));
    });

    testWidgets('leaves the thinking around a run where it was', (
      tester,
    ) async {
      final log = TranscriptLog()
        ..think('Where to start?')
        ..call('c1', 'read_file', title: 'Read file: a')
        ..think('Now what?');
      await _show(tester, log);
      expect(find.text('1 tool call'), findsOneWidget);
      // Before it and after it, each a thought of its own.
      expect(find.text('Thought'), findsNWidgets(2));
    });
  });

  group('a run that was opened', () {
    testWidgets('stays open as calls join it', (tester) async {
      final log = TranscriptLog()
        ..call('c1', 'read_file', title: 'Read file: a')
        ..call('c2', 'grep', title: 'Search files: x');
      await _show(tester, log);
      await _tap(tester, find.text('2 tool calls'));
      expect(_cards, findsNWidgets(2));

      log.call('c3', 'read_file', title: 'Read file: c', result: false);
      await _update(tester, log);
      expect(find.text('3 tool calls'), findsOneWidget);
      expect(_cards, findsNWidgets(3));

      log.result('c3');
      log.call('c4', 'bash', title: 'Bash: ls');
      await _update(tester, log);
      expect(find.text('4 tool calls'), findsOneWidget);
      expect(_cards, findsNWidgets(4));
    });

    testWidgets('stays folded as calls join it', (tester) async {
      final log = TranscriptLog()
        ..call('c1', 'read_file', title: 'Read file: a')
        ..call('c2', 'grep', title: 'Search files: x');
      await _show(tester, log);
      log.call('c3', 'read_file', title: 'Read file: c');
      await _update(tester, log);
      expect(find.text('3 tool calls'), findsOneWidget);
      expect(_cards, findsNothing);
    });

    testWidgets('does not open the next run along with it', (tester) async {
      final log = TranscriptLog()
        ..call('c1', 'read_file', title: 'Read file: a')
        ..call('c2', 'read_file', title: 'Read file: b')
        ..say('And then')
        ..call('c3', 'read_file', title: 'Read file: c');
      await _show(tester, log);
      await _tap(tester, find.text('2 tool calls'));
      expect(_cards, findsNWidgets(2));
      expect(find.text('1 tool call'), findsOneWidget);
    });

    testWidgets('stays open when a call leaves the run and comes back', (
      tester,
    ) async {
      final log = TranscriptLog()
        ..call('c1', 'read_file', title: 'Read file: a')
        ..call('c2', 'bash', title: 'Bash: make', result: false)
        ..call('c3', 'read_file', title: 'Read file: c');
      await _show(tester, log);
      await _tap(tester, find.text('3 tool calls'));
      expect(_cards, findsNWidgets(3));

      // The session waits for the person to allow the command: it is out
      // of the run, which is cut in two, and both parts are as open as the
      // run was.
      await _update(tester, log, waiting: {'c2'});
      expect(find.text('3 tool calls'), findsNothing);
      expect(find.text('1 tool call'), findsNWidgets(2));
      expect(_cards, findsNWidgets(3));

      // Allowed, it is back, and the run is open as before.
      await _update(tester, log);
      expect(find.text('3 tool calls'), findsOneWidget);
      expect(_cards, findsNWidgets(3));
    });

    testWidgets('stays open when a call that waited comes back at its head', (
      tester,
    ) async {
      final log = TranscriptLog()
        ..call('c1', 'bash', title: 'Bash: make', result: false)
        ..call('c2', 'read_file', title: 'Read file: b')
        ..call('c3', 'grep', title: 'Search files: x');
      await _show(tester, log, waiting: {'c1'});
      expect(find.text('2 tool calls'), findsOneWidget);
      await _tap(tester, find.text('2 tool calls'));
      expect(_cards, findsNWidgets(3));

      // Answered and finished, the command is the run's first call, and
      // the person never opened it: the run is what they opened all the same.
      log.result('c1');
      await _update(tester, log);
      expect(find.text('3 tool calls'), findsOneWidget);
      expect(_cards, findsNWidgets(3));
    });

    testWidgets('is the only one that opens when the run was cut in two', (
      tester,
    ) async {
      final log = TranscriptLog()
        ..call('c1', 'read_file', title: 'Read file: a')
        ..call('c2', 'read_file', title: 'Read file: b')
        ..say('Then')
        ..call('c3', 'read_file', title: 'Read file: c')
        ..call('c4', 'read_file', title: 'Read file: d');
      await _show(tester, log);
      expect(find.text('2 tool calls'), findsNWidgets(2));
      await _tap(tester, find.text('2 tool calls').first);
      expect(_cards, findsNWidgets(2));
      expect(find.textContaining('Read file: a'), findsOneWidget);
      expect(find.textContaining('Read file: c'), findsNothing);
    });
  });

  group('a call that waits for the person', () {
    testWidgets('is a card of its own, in the middle of the run it cuts', (
      tester,
    ) async {
      final log = TranscriptLog()
        ..call('c1', 'read_file', title: 'Read file: a')
        ..call('c2', 'bash', title: 'Bash: make test', result: false)
        ..call('c3', 'read_file', title: 'Read file: c', result: false);
      await _show(tester, log, waiting: {'c2'});
      expect(find.text('1 tool call'), findsNWidgets(2));
      expect(_cards, findsOneWidget);
      expect(find.textContaining('Bash: make test'), findsOneWidget);
    });

    testWidgets('folds with the others once it is answered', (tester) async {
      final log = TranscriptLog()
        ..call('c1', 'read_file', title: 'Read file: a')
        ..call('c2', 'bash', title: 'Bash: make test', result: false);
      await _show(tester, log, waiting: {'c2'});
      expect(_cards, findsOneWidget);
      log.result('c2');
      await _update(tester, log);
      expect(find.text('2 tool calls'), findsOneWidget);
      expect(_cards, findsNothing);
    });
  });

  group('a long run', () {
    testWidgets('builds only the calls that are near the screen when open', (
      tester,
    ) async {
      final log = TranscriptLog();
      for (var i = 0; i < 300; i++) {
        log.call('c$i', 'read_file', title: 'Read file: f$i.dart');
      }
      await _show(tester, log);
      expect(find.text('300 tool calls'), findsOneWidget);
      expect(find.text('Read file ×300'), findsOneWidget);
      await _tap(tester, find.text('300 tool calls'));
      expect(_cards, findsWidgets);
      expect(tester.widgetList(_cards).length, lessThan(40));
    });
  });

  group('a run on a small phone', () {
    for (final style in HarnessPlatformStyle.values) {
      for (final (width, scale) in [(320.0, 1.0), (320.0, 1.5), (390.0, 1.5)]) {
        testWidgets(
          'fits at $width points and $scale×, in ${style.name} style',
          (tester) async {
            final log = TranscriptLog()
              ..user('Look around')
              ..call(
                'c1',
                'read_file',
                title: 'Read file: lib/src/ui/widgets/a_very_long_file_name_indeed.dart',
              )
              ..think('Is it in the other file, the one with the long name?')
              ..call('c2', 'grep', title: 'Search files: some pattern')
              ..call('c3', 'emacs_find_definition', title: 'Find definition')
              ..call('c4', 'list_dir', title: 'List directory')
              ..call('c5', 'bash', title: 'Bash: false', error: true)
              ..call('c6', 'bash', title: 'Bash: rm', error: true, denied: true)
              ..call('c7', 'bash', title: 'Bash: sleep 60', result: false);
            await _show(tester, log, style: style, width: width, scale: scale);
            // The line, closed and then open: a failure here is the
            // framework's, a RenderFlex that overflows.
            expect(find.textContaining('7 tool calls'), findsOneWidget);
            expect(tester.takeException(), isNull);
            await _tap(tester, find.text('7 tool calls'));
            expect(tester.takeException(), isNull);
            expect(_cards, findsWidgets);
          },
        );
      }
    }

    testWidgets('is a button the framework knows to be open or closed', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _show(tester, _lookAround());
      final line = find.ancestor(
        of: find.text('3 tool calls'),
        matching: find.byType(ToolRunCard),
      );
      expect(
        tester.getSemantics(line),
        matchesSemantics(
          hasExpandedState: true,
          isExpanded: false,
          hasTapAction: true,
          isFocusable: true,
          hasFocusAction: true,
          isButton: true,
          label: '3 tool calls\nRead file ×2, Search files\nDone',
        ),
      );
      await _tap(tester, find.text('3 tool calls'));
      expect(
        tester.getSemantics(line),
        matchesSemantics(
          hasExpandedState: true,
          isExpanded: true,
          hasTapAction: true,
          isFocusable: true,
          hasFocusAction: true,
          isButton: true,
          label: '3 tool calls\nRead file ×2, Search files\nDone',
        ),
      );
      handle.dispose();
    });
  });
}
