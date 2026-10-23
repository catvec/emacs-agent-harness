import 'package:flutter/material.dart';

import '../../models/tool_display.dart';
import '../../models/transcript.dart';
import '../adaptive/adaptive_widgets.dart';
import '../adaptive/layout_widgets.dart';
import '../navigation.dart';
import '../screens/tool_detail_screen.dart';
import '../theme/harness_theme.dart';
import 'tool_body.dart';

/// One tool call in the transcript: what it was, whether it worked, and,
/// once it is opened, what it was given and what it said.
///
/// A call is closed until the person opens it, and what is in it is built
/// then, not before: a transcript holds many calls, and some say a great
/// deal.  A call that failed or was refused says why in a line under its
/// title, so it needs no opening to be understood.  When a call is opened
/// the page scrolls to it, so that what opens is seen, below the fold or
/// not: the last call of a task, the one that hands its work in, is always
/// at the very end.
class ToolCard extends StatefulWidget {
  const ToolCard({super.key, required this.tool});

  final ToolView tool;

  @override
  State<ToolCard> createState() => _ToolCardState();
}

class _ToolCardState extends State<ToolCard>
    with AutomaticKeepAliveClientMixin {
  bool _open = false;

  /// A call that was opened stays as it was while the list scrolls past it
  /// and back: what was read in it is not shut behind the person.
  @override
  bool get wantKeepAlive => _open;

  /// The call was just opened: when it has grown, it is brought into view.
  bool _reveal = false;

  void _toggle() {
    setState(() {
      _open = !_open;
      _reveal = _open;
    });
    updateKeepAlive();
  }

  void _opened() {
    if (!_reveal) return;
    _reveal = false;
    // The animation ends at the start of a frame, before the card has been
    // laid out at the size it ends at, and a frame that takes long (a card
    // with a long result to build) has ended it altogether before the card
    // has grown: once the frame is drawn the card is as tall as it is.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_open) return;
      context.findRenderObject()?.showOnScreen(
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
      );
    });
  }

  void _openFull() {
    Navigator.of(
      context,
    ).push(harnessRoute(context, (_) => ToolDetailScreen(tool: widget.tool)));
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    final tool = widget.tool;
    final color = toolColor(context, tool);
    final problem = tool.isFailed || tool.isDenied;
    final preview = !_open && problem ? errorPreview(tool) : '';
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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              expanded: _open,
              child: HarnessTap(
                onTap: _toggle,
                borderRadius: BorderRadius.circular(14),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _header(context, tool, color),
                      if (preview.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(38, 6, 4, 0),
                          child: Text(
                            preview,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: HarnessText.caption(context)
                                .copyWith(color: color),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              onEnd: _opened,
              child: _open
                  ? _body(context, tool)
                  : const SizedBox(width: double.infinity),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context, ToolView tool, Color color) {
    final theme = Theme.of(context);
    final count = outputOf(tool).lines;
    return Row(
      children: [
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(toolIcon(tool), size: 15, color: color),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                tool.displayTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: HarnessText.rowTitle(context).copyWith(fontSize: 14),
              ),
              const SizedBox(height: 1),
              HarnessMetaLine(
                // What is worth a glance: how long a slow call took, and how
                // much a long one said.
                parts: [
                  toolLabel(tool),
                  tool.sender,
                  if (!tool.isRunning && (tool.duration ?? 0) >= 1)
                    durationLabel(tool.duration),
                  if (count >= 5) linesLabel(count),
                ],
                style: HarnessText.caption(context),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        // A call that went well needs no word: a check says it.  One that
        // did not is said in words, in the color of what happened to it.
        if (tool.isRunning)
          HarnessActivity(radius: 7, color: color)
        else if (tool.isDenied)
          HarnessStatusLabel(
            label: 'Denied',
            color: color,
            icon: Icons.block_rounded,
          )
        else if (tool.isFailed)
          HarnessStatusLabel(
            label: 'Failed',
            color: color,
            icon: Icons.error_outline_rounded,
          )
        else
          Icon(
            Icons.check_rounded,
            size: 17,
            color: color.withValues(alpha: 0.85),
            semanticLabel: 'Done',
          ),
        const SizedBox(width: 4),
        Icon(
          _open ? Icons.expand_less_rounded : Icons.expand_more_rounded,
          size: 18,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ],
    );
  }

  /// Whether the call has more than the card shows of it: a result or an
  /// input that is cut to a screenful.
  bool _hasMore(ToolView tool, List<ToolField> fields) {
    bool long(String text, int lines) => lines > 12 || text.length > 1400;
    final output = outputOf(tool);
    return long(output.text, output.lines) ||
        fields.any((field) => long(field.text, field.lineCount));
  }

  Widget _body(BuildContext context, ToolView tool) {
    final report = tool.isRunning || tool.isFailed || tool.isDenied
        ? null
        : HandInReport.of(tool);
    final fields = toolFields(tool.input);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (report != null)
            HandInReportView(report: report, onOpenFull: _openFull)
          else ...[
            if (fields.isNotEmpty)
              ToolSection(
                label: 'INPUT',
                trailing: CopyButton(
                  text: inputAsText(fields),
                  label: 'Copy input',
                ),
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: ToolFieldsView(fields: fields, onOpenFull: _openFull),
                ),
              ),
            ToolOutputView(tool: tool, onOpenFull: _openFull),
            if (tool.attachments.isNotEmpty)
              ToolAttachments(attachments: tool.attachments),
          ],
          if (report != null || _hasMore(tool, fields))
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: HarnessTextButton(
                label: 'Open full view',
                icon: Icons.open_in_full_rounded,
                dense: true,
                onPressed: _openFull,
              ),
            ),
        ],
      ),
    );
  }
}
