// How a test reaches a task on the Flutter task board.
//
// The board is a swimlane board: the workflow stages are its columns, and
// the lanes are Needs input, then the priorities.  A phone shows the lanes
// as tabs and the stages as sections inside the lane shown; a wide board is
// a grid of stage columns by lane rows, with no tabs.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/models/task_chat.dart';
import 'package:harness_client/src/ui/adaptive/layout_widgets.dart';
import 'package:harness_client/src/ui/screens/tasks_screen.dart';

Future<void> _settle(WidgetTester tester, [int rounds = 4]) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

/// Choose the lane called [label]: a tab on a phone, whose strip builds the
/// tabs it shows.
Future<void> showLane(WidgetTester tester, String label) async {
  final tabs = find.byType(HarnessTabStrip<String>);
  final tab = find.descendant(of: tabs, matching: find.text(label));
  final strip = find
      .descendant(of: tabs, matching: find.byType(Scrollable))
      .first;
  // From the first tab on, whichever the strip showed.
  await tester.drag(strip, const Offset(2000, 0));
  await tester.pump();
  await tester.scrollUntilVisible(tab, 80, scrollable: strip);
  // All of it, not an edge of it that a tap would miss.
  await tester.ensureVisible(tab);
  await tester.pump();
  await tester.tap(tab);
  await _settle(tester);
}

/// Bring the card of [title] on the board: its lane, and its stage there.
/// A wide board is a grid, built whole, and its own scrolls bring the card
/// into view.
Future<void> showTask(WidgetTester tester, String title) async {
  final screen = tester.widget<TasksScreen>(find.byType(TasksScreen));
  final task = screen.app.tasks!.tasks.firstWhere(
    (task) => task.title == title,
  );
  if (MediaQuery.sizeOf(tester.element(find.byType(TasksScreen))).width >=
      920) {
    await tester.ensureVisible(find.text(title));
    await tester.pump();
    return;
  }
  await showLane(tester, taskLaneLabel(task.laneName));
  final lane = find
      .descendant(
        of: find.byType(RefreshIndicator),
        matching: find.byType(Scrollable),
      )
      .first;
  await tester.scrollUntilVisible(find.text(title), 100, scrollable: lane);
  await tester.ensureVisible(find.text(title));
  await tester.pump();
}
