import 'package:flutter/material.dart';

import '../../models/tool_display.dart';
import '../../models/transcript.dart';
import '../adaptive/adaptive_widgets.dart';
import '../adaptive/layout_widgets.dart';
import '../theme/harness_theme.dart';
import '../widgets/tool_body.dart';

/// A tool call on a page of its own: everything it was given and everything
/// it said, with nothing cut.  What the transcript holds in a card is a
/// screenful; this is where a long result, a file, a log or a report is read
/// to its end and copied.  The output is built a screenful at a time, so a
/// result of any length opens at once.
class ToolDetailScreen extends StatelessWidget {
  const ToolDetailScreen({super.key, required this.tool});

  final ToolView tool;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = toolColor(context, tool);
    final output = outputOf(tool).text;
    final lines = toolTextLines(output);
    final report = tool.isRunning || tool.isFailed || tool.isDenied
        ? null
        : HandInReport.of(tool);
    final fields = toolFields(tool.input);
    final status = tool.isRunning
        ? 'Running'
        : tool.isDenied
        ? 'Denied'
        : tool.isFailed
        ? 'Failed'
        : 'Done';
    final head = <Widget>[
      // The title is the whole of it here, not a line cut short.
      Padding(
        padding: const EdgeInsets.fromLTRB(
          HarnessSpace.gutter,
          HarnessSpace.sm,
          HarnessSpace.gutter,
          HarnessSpace.xs,
        ),
        child: SelectableText(
          tool.displayTitle,
          style: HarnessText.sheetTitle(context).copyWith(fontSize: 18),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(
          HarnessSpace.gutter,
          HarnessSpace.xs,
          HarnessSpace.gutter,
          HarnessSpace.sm,
        ),
        child: Row(
          children: [
            HarnessStatusLabel(
              label: status,
              color: color,
              icon: tool.isDenied
                  ? Icons.block_rounded
                  : tool.isFailed
                  ? Icons.error_outline_rounded
                  : tool.isRunning
                  ? Icons.hourglass_empty_rounded
                  : Icons.check_rounded,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: HarnessMetaLine(
                parts: [
                  toolLabel(tool),
                  tool.sender,
                  if (!tool.isRunning) durationLabel(tool.duration),
                ],
              ),
            ),
          ],
        ),
      ),
      if (report != null)
        _pad(HandInReportView(report: report, expanded: true))
      else ...[
        if (fields.isNotEmpty)
          _pad(
            ToolSection(
              label: 'INPUT',
              trailing: CopyButton(
                text: inputAsText(fields),
                label: 'Copy input',
              ),
              child: Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: ToolFieldsView(fields: fields, expanded: true),
              ),
            ),
          ),
        _pad(
          ToolSection(
            label: tool.isDenied
                ? 'REASON'
                : tool.isFailed
                ? 'ERROR'
                : 'OUTPUT',
            color: tool.isDenied || tool.isFailed ? color : null,
            detail: lines.isEmpty ? null : linesLabel(lines.length),
            trailing: lines.isEmpty
                ? null
                : CopyButton(text: output, label: 'Copy output'),
            child: lines.isEmpty
                ? Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      tool.isRunning
                          ? 'Waiting for the result…'
                          : '(no output)',
                      style: HarnessText.caption(context)
                          .copyWith(fontStyle: FontStyle.italic),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ),
      ],
    ];
    final chunks = report != null ? const <String>[] : toolTextChunks(output);
    final tint = tool.isDenied || tool.isFailed ? color : null;
    final label = toolLabel(tool);
    return HarnessPage(
      title: label == 'Tool' ? 'Tool call' : label,
      maxContentWidth: HarnessSpace.pageWidth,
      body: ListView.builder(
        key: const ValueKey('tool-detail'),
        padding: const EdgeInsets.only(bottom: HarnessSpace.xl),
        itemCount: head.length + chunks.length,
        itemBuilder: (context, index) {
          if (index < head.length) return head[index];
          final at = index - head.length;
          return _chunk(
            context,
            chunks[at],
            first: at == 0,
            last: at == chunks.length - 1,
            tint: tint,
            background: theme.colorScheme.surfaceContainerHigh,
          );
        },
      ),
    );
  }

  Widget _pad(Widget child) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: HarnessSpace.gutter),
    child: child,
  );

  /// A piece of the output, joined to the ones around it into one block.
  Widget _chunk(
    BuildContext context,
    String text, {
    required bool first,
    required bool last,
    required Color? tint,
    required Color background,
  }) {
    final base = HarnessText.mono(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: HarnessSpace.gutter),
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.fromLTRB(10, first ? 9 : 0, 10, last ? 9 : 0),
        decoration: BoxDecoration(
          color: tint == null ? background : tint.withValues(alpha: 0.08),
          borderRadius: BorderRadius.vertical(
            top: first ? const Radius.circular(9) : Radius.zero,
            bottom: last ? const Radius.circular(9) : Radius.zero,
          ),
        ),
        child: SelectableText(
          text,
          style: tint == null ? base : base.copyWith(color: tint),
        ),
      ),
    );
  }
}
