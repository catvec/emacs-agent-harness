import 'package:flutter/material.dart';

import '../../models/tool_runs.dart';
import '../adaptive/adaptive_widgets.dart';
import '../adaptive/layout_widgets.dart';
import '../theme/harness_theme.dart';

/// A run of tool calls that fold together, as one line.
///
/// It says how many calls there were and of what ("3 tool calls", then "Read
/// file ×2, Search files · thinking"), how many of them failed or were
/// refused, and whether one still runs: a run that is closed hides its calls,
/// and what went wrong in one must not be hidden with it.  Tapping the line
/// opens the run to its calls, each of them closed as it is anywhere else in
/// the transcript, and tapping it again folds them away.
///
/// The Emacs chat folds the same calls under the same words, so that a
/// stretch of looking around is one line in both (see `tool_runs.dart`).
class ToolRunCard extends StatelessWidget {
  const ToolRunCard({
    super.key,
    required this.run,
    required this.open,
    required this.onToggle,
    this.showThinking = true,
  });

  final ToolRun run;
  final bool open;
  final VoidCallback onToggle;

  /// Whether the thoughts folded into the run are counted: they are not when
  /// the person turned thinking off, for none of them is shown.
  final bool showThinking;

  /// The color of how the run went: red when a call failed, amber when one
  /// was refused, the accent while one runs, moss when all went well.
  Color _color(BuildContext context) {
    if (run.failed > 0) return Theme.of(context).colorScheme.error;
    if (run.denied > 0) return HarnessColors.amber;
    if (run.running) return Theme.of(context).colorScheme.primary;
    return HarnessColors.moss;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = _color(context);
    final problem = run.failed > 0 || run.denied > 0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 4),
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: problem
                ? color.withValues(alpha: 0.35)
                : theme.colorScheme.outlineVariant,
          ),
        ),
        child: Semantics(
          button: true,
          expanded: open,
          child: HarnessTap(
            onTap: onToggle,
            borderRadius: BorderRadius.circular(14),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
              child: Row(
                children: [
                  Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(Icons.build_outlined, size: 15, color: color),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          run.heading,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: HarnessText.rowTitle(context)
                              .copyWith(fontSize: 14),
                        ),
                        const SizedBox(height: 1),
                        Text(
                          run.detail(thinking: showThinking),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: HarnessText.caption(context),
                        ),
                        if (problem)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Wrap(
                              spacing: 12,
                              runSpacing: 2,
                              children: [
                                if (run.failed > 0)
                                  HarnessStatusLabel(
                                    label: '${run.failed} failed',
                                    color: theme.colorScheme.error,
                                    icon: Icons.error_outline_rounded,
                                  ),
                                if (run.denied > 0)
                                  HarnessStatusLabel(
                                    label: '${run.denied} denied',
                                    color: HarnessColors.amber,
                                    icon: Icons.block_rounded,
                                  ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  // A run that went well needs no word, as a call does not:
                  // a check says it.  While one of its calls runs, the line
                  // says so, for the call itself is folded away.
                  if (run.running)
                    HarnessActivity(radius: 7, color: color)
                  else if (!problem)
                    Icon(
                      Icons.check_rounded,
                      size: 17,
                      color: color.withValues(alpha: 0.85),
                      semanticLabel: 'Done',
                    ),
                  const SizedBox(width: 4),
                  Icon(
                    open
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A call (or a thought) of an open run, set in from the summary line with a
/// rule down its side, so that what belongs to the run reads as its own.
///
/// [reveal] is set on the first call of a run that has just been opened: the
/// calls come out under the summary line, which may be at the bottom of the
/// screen, so it is brought into view, as a card that is opened is.  It is
/// done once, when the call is first drawn with the flag set, and not each
/// time the list builds it again as it is scrolled to.
class ToolRunMember extends StatefulWidget {
  const ToolRunMember({super.key, required this.child, this.reveal = false});

  final Widget child;
  final bool reveal;

  @override
  State<ToolRunMember> createState() => _ToolRunMemberState();
}

class _ToolRunMemberState extends State<ToolRunMember> {
  @override
  void initState() {
    super.initState();
    if (widget.reveal) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        context.findRenderObject()?.showOnScreen(
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 22),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(
              color: Theme.of(context).colorScheme.outlineVariant,
              width: 2,
            ),
          ),
        ),
        child: widget.child,
      ),
    );
  }
}
