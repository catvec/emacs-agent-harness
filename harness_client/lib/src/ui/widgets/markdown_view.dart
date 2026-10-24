import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:url_launcher/url_launcher.dart';

import '../theme/harness_theme.dart';

/// Markdown, drawn: headings, lists, bold, code, quotes, tables and links
/// (which open outside the app).  What a person or an agent writes for a
/// person is Markdown, so it is drawn with this wherever it is read.
class HarnessMarkdown extends StatelessWidget {
  const HarnessMarkdown({
    super.key,
    required this.text,
    this.compact = false,
    this.color,
    this.lineHeight,
    this.tight = false,
  });

  final String text;
  final bool compact;

  /// The color of the text, when it stands on a color of its own and the
  /// theme's would not read there: a message in a bubble.  Its links, quotes
  /// and lists take it too; code keeps its own, on a chip of its own.
  final Color? color;

  /// The height of a line of text, as a multiple of its size; 1.55 when not
  /// given.
  final double? lineHeight;

  /// No room under the last paragraph: the text is all there is of what it is
  /// in (a bubble with a padding of its own).  The space between the blocks
  /// stays.
  final bool tight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final ink = color ?? theme.colorScheme.onSurface;
    final base = MarkdownStyleSheet.fromTheme(theme).copyWith(
      p: theme.textTheme.bodyMedium?.copyWith(
        fontSize: compact ? 13.5 : 15,
        height: lineHeight ?? 1.55,
        color: ink,
      ),
      pPadding: tight ? EdgeInsets.zero : const EdgeInsets.only(bottom: 8),
      h1: theme.textTheme.headlineSmall?.copyWith(
        fontSize: compact ? 20 : 23,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.5,
      ),
      h2: theme.textTheme.titleLarge?.copyWith(fontSize: compact ? 18 : 20),
      h3: theme.textTheme.titleMedium?.copyWith(fontSize: compact ? 16 : 17),
      blockquote: theme.textTheme.bodyMedium?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
        fontStyle: FontStyle.italic,
      ),
      blockquoteDecoration: BoxDecoration(
        border: Border(
          left: BorderSide(color: theme.colorScheme.primary, width: 3),
        ),
      ),
      code: TextStyle(
        fontFamily: 'monospace',
        fontSize: compact ? 12 : 13,
        color: dark ? const Color(0xFFF0B49D) : const Color(0xFF9C3B1D),
        backgroundColor: dark
            ? const Color(0xFF222226)
            : const Color(0xFFF1ECE5),
      ),
      codeblockDecoration: BoxDecoration(
        color: dark ? const Color(0xFF1B1B1F) : const Color(0xFFF2EEE7),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      codeblockPadding: const EdgeInsets.all(12),
      blockSpacing: 8,
      listBullet: theme.textTheme.bodyMedium?.copyWith(
        color: theme.colorScheme.primary,
      ),
      listIndent: 20,
      a: TextStyle(
        color: theme.colorScheme.primary,
        decoration: TextDecoration.underline,
      ),
      strong: const TextStyle(fontWeight: FontWeight.w700),
      em: const TextStyle(fontStyle: FontStyle.italic),
      horizontalRuleDecoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      tableBorder: TableBorder.all(
        color: theme.colorScheme.outlineVariant,
        width: 0.7,
      ),
      tableHead: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
      tableBody: const TextStyle(fontSize: 13),
      tableCellsPadding: const EdgeInsets.symmetric(
        horizontal: 10,
        vertical: 6,
      ),
    );
    return MarkdownBody(
      data: text,
      selectable: true,
      softLineBreak: true,
      styleSheet: color == null ? base : _inked(base, color!),
      onTapLink: (text, href, title) async {
        if (href == null) return;
        final uri = Uri.tryParse(href);
        if (uri == null) return;
        try {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        } catch (_) {}
      },
    );
  }
}

/// [sheet] with its text in [ink], so that it reads on a color of its own.
/// A link keeps its underline and is told by that; a quote keeps its bar.
MarkdownStyleSheet _inked(MarkdownStyleSheet sheet, Color ink) {
  TextStyle? tint(TextStyle? style) => style?.copyWith(color: ink);
  return sheet.copyWith(
    h1: tint(sheet.h1),
    h2: tint(sheet.h2),
    h3: tint(sheet.h3),
    h4: tint(sheet.h4),
    h5: tint(sheet.h5),
    h6: tint(sheet.h6),
    a: tint(sheet.a),
    blockquote: tint(sheet.blockquote),
    blockquoteDecoration: BoxDecoration(
      border: Border(
        left: BorderSide(color: ink.withValues(alpha: 0.6), width: 3),
      ),
    ),
    listBullet: tint(sheet.listBullet),
    tableHead: tint(sheet.tableHead),
    tableBody: tint(sheet.tableBody),
    tableBorder: TableBorder.all(
      color: ink.withValues(alpha: 0.35),
      width: 0.7,
    ),
    horizontalRuleDecoration: BoxDecoration(
      border: Border(top: BorderSide(color: ink.withValues(alpha: 0.35))),
    ),
  );
}

class HarnessInlineMarkdown extends StatelessWidget {
  const HarnessInlineMarkdown({super.key, required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MarkdownBody(
      data: text,
      selectable: false,
      styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
        p: theme.textTheme.bodyMedium?.copyWith(height: 1.4),
        code: TextStyle(
          fontFamily: 'monospace',
          fontSize: 12,
          backgroundColor: HarnessColors.paper.withValues(alpha: 0.1),
        ),
      ),
    );
  }
}
