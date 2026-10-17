import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:url_launcher/url_launcher.dart';

import '../theme/harness_theme.dart';

class HarnessMarkdown extends StatelessWidget {
  const HarnessMarkdown({super.key, required this.text, this.compact = false});

  final String text;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final base = MarkdownStyleSheet.fromTheme(theme).copyWith(
      p: theme.textTheme.bodyMedium?.copyWith(
        fontSize: compact ? 13.5 : 15,
        height: 1.55,
        color: theme.colorScheme.onSurface,
      ),
      pPadding: const EdgeInsets.only(bottom: 8),
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
      styleSheet: base,
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
