import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../models/tool_display.dart';
import '../adaptive/adaptive_widgets.dart';
import '../adaptive/layout_widgets.dart';
import '../navigation.dart';
import '../theme/harness_theme.dart';
import '../widgets/tool_body.dart';

/// A task's report on a page of its own, read to its end: the problem, the
/// summary as it was written, how to see it, and every piece of evidence,
/// the calls it quotes opened to what they said.
///
/// It is the one page a report is read on, whichever way it was come to: the
/// "Open full view" of the `hand_in` call in a session (`ToolDetailScreen`
/// is this page for that call) and the "View report" of a task on the task
/// board both open it, with the same [HandInReport], so a report looks the
/// same from both.  Nothing on it is about the way it was come to (the call
/// that carried it, the board it was listed on), only about the report.
///
/// The screenshots among the evidence are drawn on it, under their lines.
/// They are files on the harness's machine, which only the harness can
/// read, and it gives them to the session whose work they show: so both ways
/// to the page hand it [sessionId], the session of the task.  Without one,
/// or with a harness that does not give pictures, they are named.
class HandInReportScreen extends StatelessWidget {
  const HandInReportScreen({super.key, required this.report, this.sessionId});

  final HandInReport report;

  /// The session that handed the work in, whose harness gives the pictures
  /// of the evidence.  Null when it is not known.
  final String? sessionId;

  /// Open the page of [report] over the one [context] is on.
  static Future<void> show(
    BuildContext context,
    HandInReport report, {
    String? sessionId,
  }) {
    return Navigator.of(context).push<void>(
      harnessRoute<void>(
        context,
        (_) => HandInReportScreen(report: report, sessionId: sessionId),
      ),
    );
  }

  /// "Oct 23, 2:15 PM": when the report was written, with the year when it
  /// was not this year.
  static String whenLabel(DateTime when, {DateTime? now}) {
    final sameYear = (now ?? DateTime.now()).year == when.year;
    final day = sameYear ? DateFormat.MMMd() : DateFormat.yMMMd();
    return day.add_jm().format(when);
  }

  @override
  Widget build(BuildContext context) {
    final when = report.at;
    return HarnessPage(
      title: 'Hand-in report',
      maxContentWidth: HarnessSpace.pageWidth,
      body: ListView(
        key: const ValueKey('hand-in-report'),
        padding: const EdgeInsets.fromLTRB(
          HarnessSpace.gutter,
          HarnessSpace.sm,
          HarnessSpace.gutter,
          HarnessSpace.xl,
        ),
        children: [
          // A round that handed nothing in says so in the report itself.
          if (when != null && !report.missing)
            Padding(
              padding: const EdgeInsets.only(bottom: HarnessSpace.md),
              child: HarnessMetaLine(parts: ['Handed in ${whenLabel(when)}']),
            ),
          HandInReportView(
            report: report,
            sessionId: sessionId,
            expanded: true,
          ),
        ],
      ),
    );
  }
}
