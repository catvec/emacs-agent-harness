// How a test reaches a task on the Flutter task board.
//
// The board is a swimlane board: the workflow stages are its columns, and
// the lanes are Needs input, then the priorities.  A wide board is a grid of
// stage columns by lane rows, with no tabs.  A phone draws one lane, what
// waits on the person, above one scroll of stage sections, every priority in
// each.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/ui/screens/tasks_screen.dart';

Future<void> _settle(WidgetTester tester, [int rounds = 4]) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

/// The one scroll of a phone's board: the stages, every priority in them.
Finder phoneBoardList() => find
    .descendant(
      of: find.byType(RefreshIndicator),
      matching: find.byType(Scrollable),
    )
    .first;

/// Bring the card of [title] on the board: its stage there.  A wide board is
/// a grid, built whole, and its own scrolls bring the card into view; a
/// phone's board is one scroll of the stages, which is taken back to the top
/// first, so that a card above the list's place is found too.
Future<void> showTask(WidgetTester tester, String title) async {
  final wide =
      MediaQuery.sizeOf(tester.element(find.byType(TasksScreen))).width >= 920;
  if (!wide) {
    final list = phoneBoardList();
    tester.state<ScrollableState>(list).position.jumpTo(0);
    await tester.pump();
    await tester.scrollUntilVisible(find.text(title), 100, scrollable: list);
  }
  await tester.ensureVisible(find.text(title));
  await tester.pump();
  await _settle(tester, 1);
}
