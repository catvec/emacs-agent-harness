import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/tool_display.dart';
import '../../models/transcript.dart';
import '../adaptive/adaptive_widgets.dart';
import '../adaptive/layout_widgets.dart';
import '../format.dart';
import '../theme/harness_theme.dart';
import 'markdown_view.dart';

// The pieces a tool call is made of once it is opened: what it was given, what
// it said, and, for the call that hands a task's work in, the report.  They
// are used by the card in the transcript and by the page that shows a call
// whole, so a call reads the same in both.

/// The color of a call's state: moss when it went well, red when it failed,
/// amber when the permission system refused it, the accent while it runs.
Color toolColor(BuildContext context, ToolView tool) {
  if (tool.isDenied) return HarnessColors.amber;
  if (tool.isFailed) return Theme.of(context).colorScheme.error;
  if (tool.isRunning) return Theme.of(context).colorScheme.primary;
  return HarnessColors.moss;
}

/// The icon of a call: what the tool is when it is one of the few that are
/// more than their kind, else the kind of work it does.
IconData toolIcon(ToolView tool) {
  switch (baseToolName(tool.tool)) {
    case 'hand_in':
      return Icons.assignment_turned_in_outlined;
    case 'ask_user':
      return Icons.help_outline_rounded;
    case 'todo_write':
      return Icons.checklist_rounded;
    case 'spawn_agent':
      return Icons.account_tree_outlined;
  }
  return switch (tool.kind) {
    'read' => Icons.description_outlined,
    'edit' => Icons.edit_outlined,
    'delete' => Icons.delete_outline_rounded,
    'move' => Icons.drive_file_move_outline,
    'search' => Icons.search_rounded,
    'execute' => Icons.terminal_rounded,
    'fetch' => Icons.public_rounded,
    'think' => Icons.psychology_outlined,
    'meta' => Icons.shield_outlined,
    _ => Icons.build_outlined,
  };
}

/// What kind of call it is, in a word for the line under its title.
String toolLabel(ToolView tool) => switch (baseToolName(tool.tool)) {
  'hand_in' => 'Hand-in',
  'ask_user' => 'Question',
  'todo_write' => 'Plan',
  'spawn_agent' => 'Sub-agent',
  _ => toolKindIconLabel(tool.kind),
};

/// A heading in capitals, what is said after it, and what can be done with
/// the section at the far end; then the section.
class ToolSection extends StatelessWidget {
  const ToolSection({
    super.key,
    required this.label,
    required this.child,
    this.detail,
    this.color,
    this.trailing,
  });

  final String label;
  final String? detail;
  final Color? color;
  final Widget? trailing;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final style = HarnessText.label(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 32),
          child: Row(
            children: [
              // The label, and what is said after it, take the room there is;
              // what can be done with the section is at the far end.
              Expanded(
                child: Row(
                  children: [
                    Text(
                      label,
                      style: color == null
                          ? style
                          : style.copyWith(color: color),
                    ),
                    if (detail != null && detail!.isNotEmpty)
                      Flexible(
                        child: Text(
                          '  ·  $detail',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: style.copyWith(
                            fontWeight: FontWeight.w500,
                            letterSpacing: 0.2,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (trailing != null) trailing!,
            ],
          ),
        ),
        child,
      ],
    );
  }
}

/// A small button that puts [text] on the clipboard and says so for a
/// moment: a check and "Copied", in place of the icon.
class CopyButton extends StatefulWidget {
  const CopyButton({super.key, required this.text, this.label = 'Copy'});

  final String text;
  final String label;

  @override
  State<CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<CopyButton> {
  Timer? _timer;
  bool _copied = false;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.text));
    if (!mounted) return;
    setState(() => _copied = true);
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      label: _copied ? 'Copied' : widget.label,
      excludeSemantics: true,
      child: HarnessTap(
        onTap: _copy,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _copied ? Icons.check_rounded : Icons.copy_rounded,
                size: 15,
                color: _copied
                    ? HarnessColors.moss
                    : theme.colorScheme.onSurfaceVariant,
              ),
              if (_copied) ...[
                const SizedBox(width: 5),
                Text(
                  'Copied',
                  style: HarnessText.meta(context)
                      .copyWith(color: HarnessColors.moss),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A block of text a person selects from and copies: a command, a result, a
/// file.  Long text is cut to a screenful with a way to show the rest, in
/// the card itself and not in a box that scrolls inside the page.  Text too
/// long to show in the page at all ends in a way to the page of its own
/// ([onOpenFull]).
class ToolText extends StatefulWidget {
  const ToolText(
    this.text, {
    super.key,
    this.collapsedLines = 12,
    this.collapsedChars = 1400,
    this.inlineChars = 24000,
    this.tint,
    this.prompt,
    this.onOpenFull,
    this.expanded = false,
  });

  final String text;

  /// How many lines, and how many characters, show before "Show all".
  final int collapsedLines;
  final int collapsedChars;

  /// The most that is shown in the page when everything is asked for.
  final int inlineChars;

  /// The color of the block, for text that says something went wrong (red),
  /// was refused (amber), is taken out (red) or put in (green).
  final Color? tint;

  /// What stands before the text, not selected with it: a shell's `$`.
  final String? prompt;

  /// Where the text can be read whole, for what is too long to show here.
  final VoidCallback? onOpenFull;

  /// Show everything from the start: the page of its own, not the card.
  final bool expanded;

  @override
  State<ToolText> createState() => _ToolTextState();
}

class _ToolTextState extends State<ToolText> {
  bool _all = false;

  /// How much of [text] shows while it is cut: its first lines and
  /// characters, or all of it when it is short.
  ({String shown, bool cut}) _collapsed(List<String> lines) {
    final buffer = StringBuffer();
    var chars = 0;
    var count = 0;
    for (final line in lines) {
      if (count >= widget.collapsedLines) {
        return (shown: buffer.toString().trimRight(), cut: true);
      }
      final separator = count > 0 ? '\n' : '';
      if (chars + line.length > widget.collapsedChars) {
        final room = widget.collapsedChars - chars;
        if (room > 0) buffer.write('$separator${line.substring(0, room)}');
        return (shown: '${buffer.toString().trimRight()}…', cut: true);
      }
      buffer.write('$separator$line');
      chars += line.length + 1;
      count++;
    }
    return (shown: buffer.toString(), cut: false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = widget.text;
    final lines = toolTextLines(text);
    final collapsed = _collapsed(lines);
    final showAll = widget.expanded || _all || !collapsed.cut;
    // Only where there is a page to read the rest on is the text cut: the
    // page itself shows every character.
    final tooLong =
        showAll &&
        widget.onOpenFull != null &&
        text.length > widget.inlineChars;
    final shown = !showAll
        ? collapsed.shown
        : tooLong
        ? '${text.substring(0, widget.inlineChars).trimRight()}…'
        : text;
    final tint = widget.tint;
    final base = HarnessText.mono(context);
    final style = tint == null ? base : base.copyWith(color: tint);
    final body = SelectableText(shown, style: style);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(10, 9, 10, 9),
      decoration: BoxDecoration(
        color: tint == null
            ? theme.colorScheme.surfaceContainerHigh
            : tint.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(9),
        border: tint == null
            ? null
            : Border.all(color: tint.withValues(alpha: 0.24)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.prompt == null)
            body
          else
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.prompt!,
                  style: base.copyWith(color: theme.colorScheme.primary),
                ),
                Expanded(child: body),
              ],
            ),
          if (collapsed.cut && !widget.expanded)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: HarnessTextButton(
                label: _all
                    ? 'Show less'
                    : lines.length > widget.collapsedLines
                    ? 'Show all ${linesLabel(lines.length)}'
                    : 'Show all ${_size(text.length)}',
                icon: _all
                    ? Icons.unfold_less_rounded
                    : Icons.unfold_more_rounded,
                dense: true,
                onPressed: () => setState(() => _all = !_all),
              ),
            ),
          if (tooLong && widget.onOpenFull != null)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: HarnessTextButton(
                label: 'Read the rest in the full view',
                icon: Icons.open_in_full_rounded,
                dense: true,
                onPressed: widget.onOpenFull,
              ),
            ),
        ],
      ),
    );
  }

  String _size(int chars) => chars < 1000
      ? '$chars characters'
      : '${(chars / 1000).toStringAsFixed(1)}k characters';
}

/// A call's input as labelled fields: a command after its prompt, the text
/// an edit takes out and puts in, a long text with its line breaks, and
/// prose as the markdown it was written in.
class ToolFieldsView extends StatelessWidget {
  const ToolFieldsView({
    super.key,
    required this.fields,
    this.expanded = false,
    this.onOpenFull,
  });

  final List<ToolField> fields;
  final bool expanded;
  final VoidCallback? onOpenFull;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var index = 0; index < fields.length; index++) ...[
          if (index > 0) const SizedBox(height: 8),
          _field(context, fields[index]),
        ],
      ],
    );
  }

  Widget _field(BuildContext context, ToolField field) {
    final theme = Theme.of(context);
    final caption = HarnessText.caption(context);
    Widget named(Widget child, {Color? color}) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (field.name.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              field.name,
              style: caption.copyWith(
                color: color,
                fontFamily: 'monospace',
                fontSize: 11.5,
              ),
            ),
          ),
        child,
      ],
    );
    switch (field.style) {
      case ToolFieldStyle.scalar:
        return SelectableText.rich(
          TextSpan(
            children: [
              if (field.name.isNotEmpty)
                TextSpan(
                  text: '${field.name}  ',
                  style: caption.copyWith(fontFamily: 'monospace'),
                ),
              TextSpan(text: field.text, style: HarnessText.mono(context)),
            ],
          ),
        );
      case ToolFieldStyle.command:
        return ToolText(
          field.text,
          prompt: r'$ ',
          expanded: expanded,
          onOpenFull: onOpenFull,
        );
      case ToolFieldStyle.code:
        return named(
          ToolText(field.text, expanded: expanded, onOpenFull: onOpenFull),
        );
      case ToolFieldStyle.removed:
        final tint = theme.colorScheme.error;
        return named(
          ToolText(
            field.text,
            tint: tint,
            expanded: expanded,
            onOpenFull: onOpenFull,
          ),
          color: tint,
        );
      case ToolFieldStyle.added:
        return named(
          ToolText(
            field.text,
            tint: HarnessColors.moss,
            expanded: expanded,
            onOpenFull: onOpenFull,
          ),
          color: HarnessColors.moss,
        );
      case ToolFieldStyle.prose:
        return named(HarnessMarkdown(text: field.text, compact: true));
    }
  }
}

/// What a call said: its output as text (or why it failed, or why it was
/// refused), with the number of lines, a way to copy it, and what to show
/// when there is nothing to show.
class ToolOutputView extends StatelessWidget {
  const ToolOutputView({
    super.key,
    required this.tool,
    this.expanded = false,
    this.onOpenFull,
  });

  final ToolView tool;
  final bool expanded;
  final VoidCallback? onOpenFull;

  @override
  Widget build(BuildContext context) {
    final output = outputOf(tool);
    final text = output.text;
    final hasText = output.lines > 0;
    final color = toolColor(context, tool);
    final label = tool.isDenied
        ? 'REASON'
        : tool.isFailed
        ? 'ERROR'
        : 'OUTPUT';
    final tint = tool.isDenied || tool.isFailed ? color : null;
    return ToolSection(
      label: label,
      color: tint,
      detail: hasText ? linesLabel(output.lines) : null,
      trailing: hasText ? CopyButton(text: text, label: 'Copy output') : null,
      child: hasText
          ? ToolText(
              text,
              tint: tint,
              expanded: expanded,
              onOpenFull: onOpenFull,
            )
          : Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                tool.isRunning ? 'Waiting for the result…' : '(no output)',
                style: HarnessText.caption(context)
                    .copyWith(fontStyle: FontStyle.italic),
              ),
            ),
    );
  }
}

/// The files a call handed back, by name.
class ToolAttachments extends StatelessWidget {
  const ToolAttachments({super.key, required this.attachments});

  final List<Map<String, Object?>> attachments;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ToolSection(
      label: 'ATTACHMENTS',
      child: Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final attachment in attachments)
              HarnessStatusPill(
                label:
                    '${attachment['name'] ?? attachment['path'] ?? 'attachment'}',
                color: theme.colorScheme.primary,
                icon: Icons.attach_file_rounded,
              ),
          ],
        ),
      ),
    );
  }
}

/// What a `hand_in` call handed in, drawn as the report it is: the problem,
/// the summary as it was written, how to see it, and the evidence.
class HandInReportView extends StatelessWidget {
  const HandInReportView({
    super.key,
    required this.report,
    this.expanded = false,
    this.onOpenFull,
  });

  final HandInReport report;
  final bool expanded;
  final VoidCallback? onOpenFull;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget section(String label, Widget child, {String? detail}) => Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: ToolSection(label: label, detail: detail, child: child),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (report.cannotContinue || report.noMerge)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: HarnessStatusLabel(
              label: report.cannotContinue
                  ? 'This task cannot continue: it waits for you'
                  : 'Nothing to merge: verifying it completes the task',
              color: report.cannotContinue
                  ? HarnessColors.amber
                  : theme.colorScheme.onSurfaceVariant,
              icon: report.cannotContinue
                  ? Icons.pause_circle_outline_rounded
                  : Icons.info_outline_rounded,
            ),
          ),
        if (report.problem.isNotEmpty)
          section(
            'PROBLEM',
            HarnessMarkdown(text: report.problem, compact: true),
          ),
        if (report.summary.isNotEmpty)
          section(
            'SUMMARY',
            HarnessMarkdown(text: report.summary, compact: true),
          ),
        if ((report.reproduction ?? '').isNotEmpty)
          section(
            'TO REPRODUCE',
            HarnessMarkdown(text: report.reproduction!, compact: true),
          ),
        if (report.evidence.isNotEmpty)
          section(
            'EVIDENCE',
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final item in report.evidence)
                  EvidenceRow(
                    item: item,
                    expanded: expanded,
                    onOpenFull: onOpenFull,
                  ),
              ],
            ),
            detail: '${report.evidence.length}',
          ),
      ],
    );
  }
}

/// One piece of evidence: what it is, in a line; a note, a code block or a
/// quoted call opens to what it holds.  A picture or a file is on the
/// harness's machine, so it is named, not drawn.
class EvidenceRow extends StatefulWidget {
  const EvidenceRow({
    super.key,
    required this.item,
    this.expanded = false,
    this.onOpenFull,
  });

  final EvidenceItem item;
  final bool expanded;
  final VoidCallback? onOpenFull;

  @override
  State<EvidenceRow> createState() => _EvidenceRowState();
}

class _EvidenceRowState extends State<EvidenceRow> {
  late bool _open = widget.expanded && _hasBody;

  EvidenceItem get item => widget.item;

  bool get _hasBody => switch (item.kind) {
    'code' => (item.text ?? '').isNotEmpty,
    // A note with a caption is the caption, which opens to the note.
    'note' => (item.caption ?? '').isNotEmpty && (item.text ?? '').isNotEmpty,
    'tool-call' =>
      (item.output ?? '').isNotEmpty || (item.input ?? '').isNotEmpty,
    _ => false,
  };

  IconData get _icon => switch (item.kind) {
    'image' => Icons.image_outlined,
    'video' => Icons.videocam_outlined,
    'file' => Icons.insert_drive_file_outlined,
    'code' => Icons.code_rounded,
    'note' => Icons.notes_rounded,
    _ => item.isError ? Icons.error_outline_rounded : Icons.terminal_rounded,
  };

  String? get _detail => switch (item.kind) {
    'image' ||
    'video' ||
    'file' => item.path == null ? null : baseName(item.path!),
    'code' => item.language,
    'tool-call' =>
      (item.title != null && item.title != item.label)
          ? item.title
          : item.reference,
    _ => null,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final color = item.isError ? theme.colorScheme.error : muted;
    final detail = _detail;
    final header = Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(_icon, size: 17, color: color),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (item.kind == 'note' && (item.caption ?? '').isEmpty)
                  HarnessMarkdown(text: item.text ?? '', compact: true)
                else
                  Text(
                    item.label,
                    style: HarnessText.body(context).copyWith(height: 1.35),
                  ),
                if (detail != null && detail.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      detail,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: HarnessText.caption(context)
                          .copyWith(fontFamily: 'monospace', fontSize: 11.5),
                    ),
                  ),
              ],
            ),
          ),
          if (_hasBody)
            Padding(
              padding: const EdgeInsets.only(left: 6, top: 1),
              child: Icon(
                _open ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                size: 18,
                color: muted,
              ),
            ),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _hasBody
            ? Semantics(
                button: true,
                expanded: _open,
                child: HarnessTap(
                  onTap: () => setState(() => _open = !_open),
                  borderRadius: BorderRadius.circular(8),
                  child: header,
                ),
              )
            : header,
        if (_open && _hasBody)
          Padding(
            padding: const EdgeInsets.only(left: 27, bottom: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (item.kind == 'note')
                  HarnessMarkdown(text: item.text!, compact: true)
                else if (item.kind == 'code')
                  ToolText(
                    item.text!,
                    expanded: widget.expanded,
                    onOpenFull: widget.onOpenFull,
                  )
                else ...[
                  if ((item.input ?? '').isNotEmpty) ...[
                    ToolSection(
                      label: 'INPUT',
                      child: ToolText(
                        item.input!,
                        collapsedLines: 6,
                        expanded: widget.expanded,
                        onOpenFull: widget.onOpenFull,
                      ),
                    ),
                    const SizedBox(height: 4),
                  ],
                  if ((item.output ?? '').isNotEmpty)
                    ToolSection(
                      label: item.isError ? 'ERROR' : 'OUTPUT',
                      color: item.isError ? theme.colorScheme.error : null,
                      detail: linesLabel(
                        toolTextLines(cleanToolText(item.output!)).length,
                      ),
                      trailing: CopyButton(
                        text: cleanToolText(item.output!),
                        label: 'Copy output',
                      ),
                      child: ToolText(
                        cleanToolText(item.output!),
                        tint: item.isError ? theme.colorScheme.error : null,
                        collapsedLines: 8,
                        expanded: widget.expanded,
                        onOpenFull: widget.onOpenFull,
                      ),
                    ),
                ],
              ],
            ),
          ),
        Divider(
          height: 1,
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
        ),
      ],
    );
  }
}
