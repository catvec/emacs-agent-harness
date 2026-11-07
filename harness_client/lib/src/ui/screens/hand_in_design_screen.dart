import 'package:flutter/material.dart';

import '../../models/tool_display.dart';
import '../adaptive/adaptive_widgets.dart';
import '../adaptive/layout_widgets.dart';
import '../navigation.dart';
import '../theme/harness_theme.dart';
import '../widgets/markdown_view.dart';

/// The design document a task's work was written against, read whole.
///
/// The page is the text the report carries, the snapshot the harness kept
/// when the work was handed in: the document itself is on the harness's
/// machine, which this device cannot read, so nothing here is fetched.  The
/// path is said once, as where the document is, and is no part of what is
/// read.
class HandInDesignScreen extends StatelessWidget {
  const HandInDesignScreen({super.key, required this.design});

  final HandInDesign design;

  /// Open the design over the page [context] is on.
  static Future<void> show(BuildContext context, HandInDesign design) {
    return Navigator.of(context).push<void>(
      harnessRoute<void>(context, (_) => HandInDesignScreen(design: design)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final where = design.name ?? design.path;
    return HarnessPage(
      title: 'Design',
      maxContentWidth: HarnessSpace.pageWidth,
      body: ListView(
        key: const ValueKey('hand-in-design'),
        padding: const EdgeInsets.fromLTRB(
          HarnessSpace.gutter,
          HarnessSpace.sm,
          HarnessSpace.gutter,
          HarnessSpace.xl,
        ),
        children: [
          // The document's name as the task knows it, or where the harness
          // keeps it when it is not under the worktree.
          if (where != null)
            Padding(
              padding: const EdgeInsets.only(bottom: HarnessSpace.md),
              child: HarnessMetaLine(parts: [where]),
            ),
          HarnessMarkdown(text: design.text ?? ''),
        ],
      ),
    );
  }
}
