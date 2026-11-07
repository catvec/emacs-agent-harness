import 'package:flutter/material.dart';

import '../../models/chat_thread.dart';
import '../theme/harness_theme.dart';
import 'markdown_view.dart';

/// The replies in threads of one message, drawn as cards.
///
/// A card says what the reply answers -- the quote, and whose words they
/// are -- and the words under the quote.  A long quote folds after a few
/// lines, and a long answer after some of it, both with a button that draws
/// the rest; the reply's own action starts a reply in its thread.
class ChatThreadList extends StatelessWidget {
  const ChatThreadList({
    super.key,
    required this.threads,
    this.keyPrefix,
    this.onReply,
    this.onShowRef,
    this.onOpenThread,
  });

  final List<ChatThread> threads;

  /// What names the cards in the tree: a message's key, so that two messages
  /// with a thread of the same id are told apart.
  final String? keyPrefix;

  /// Answers the thread of the card with the next message.
  final void Function(ChatThread thread)? onReply;

  /// Shows the message a quote is of.
  final void Function(ChatThreadRef ref)? onShowRef;

  /// Opens the thread in the task's review, when the app can.
  final void Function(ChatThread thread)? onOpenThread;

  @override
  Widget build(BuildContext context) {
    if (threads.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var index = 0; index < threads.length; index++)
          Padding(
            padding: EdgeInsets.only(top: index == 0 ? 8 : 6),
            child: ChatThreadCard(
              key: ValueKey(
                '${keyPrefix ?? 'thread'}-${threads[index].id ?? index}',
              ),
              thread: threads[index],
              onReply: onReply == null ? null : () => onReply!(threads[index]),
              onShowRef: onShowRef,
              onOpenThread: onOpenThread == null || !threads[index].hasId
                  ? null
                  : () => onOpenThread!(threads[index]),
            ),
          ),
      ],
    );
  }
}

/// One reply in a thread, as the chat draws it.
class ChatThreadCard extends StatefulWidget {
  const ChatThreadCard({
    super.key,
    required this.thread,
    this.onReply,
    this.onShowRef,
    this.onOpenThread,
  });

  final ChatThread thread;
  final VoidCallback? onReply;
  final void Function(ChatThreadRef ref)? onShowRef;
  final VoidCallback? onOpenThread;

  @override
  State<ChatThreadCard> createState() => _ChatThreadCardState();
}

class _ChatThreadCardState extends State<ChatThreadCard> {
  /// How much of the answer is shown: a long one folds, and this says the
  /// rest is wanted.
  bool _expanded = false;

  static const _answerPage = 1200;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final thread = widget.thread;
    final answer = thread.response.trim();
    final folded = answer.length > _answerPage && !_expanded;
    final shown = folded ? _cut(answer, _answerPage) : answer;
    return Semantics(
      container: true,
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHigh.withValues(alpha: 0.5),
          border: Border(
            left: BorderSide(
              color: theme.colorScheme.primary.withValues(alpha: 0.65),
              width: 3,
            ),
          ),
          borderRadius: const BorderRadius.only(
            topRight: Radius.circular(12),
            bottomRight: Radius.circular(12),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(10, 6, 6, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                // Large text leaves no room for the actions beside the name:
                // they take a line of their own rather than squeeze it.
                final large = MediaQuery.textScalerOf(context).scale(14) > 18.2;
                final stacked = large || constraints.maxWidth < 250;
                final title = Row(
                  children: [
                    Icon(
                      Icons.subdirectory_arrow_right_rounded,
                      size: 15,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 4),
                    if (stacked)
                      Expanded(
                        child: Text(
                          thread.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: HarnessText.meta(context).copyWith(
                            fontWeight: FontWeight.w700,
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                      )
                    else
                      Flexible(
                        child: Text(
                          thread.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: HarnessText.meta(context).copyWith(
                            fontWeight: FontWeight.w700,
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                      ),
                    if (thread.hasStatus) ...[
                      const SizedBox(width: 6),
                      _StatusChip(closed: thread.isClosed),
                    ],
                    if (!stacked) const Spacer(),
                  ],
                );
                final actions = Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (widget.onOpenThread != null)
                      _CardAction(
                        key: ValueKey('open-thread-${thread.id ?? 'new'}'),
                        icon: Icons.open_in_new_rounded,
                        label: 'Open thread',
                        onTap: widget.onOpenThread!,
                      ),
                    if (widget.onReply != null)
                      _CardAction(
                        key: ValueKey('reply-thread-${thread.id ?? 'new'}'),
                        icon: Icons.reply_rounded,
                        label: 'Reply to thread',
                        onTap: widget.onReply!,
                      ),
                  ],
                );
                if (stacked) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      title,
                      if (widget.onOpenThread != null || widget.onReply != null)
                        Align(alignment: Alignment.centerRight, child: actions),
                    ],
                  );
                }
                return Row(
                  children: [
                    Expanded(child: title),
                    actions,
                  ],
                );
              },
            ),
            if (thread.quote?.trim().isNotEmpty ?? false)
              Padding(
                padding: const EdgeInsets.only(top: 3, right: 4),
                child: _QuotePart(
                  label: null,
                  text: thread.quote!.trim(),
                  onShow: null,
                ),
              ),
            for (final ref in thread.refs)
              if (ref.text.trim().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 3, right: 4),
                  child: _QuotePart(
                    label: ref.sourceLabel,
                    place: ref.placeLabel,
                    text: ref.text.trim(),
                    onShow: widget.onShowRef == null
                        ? null
                        : () => widget.onShowRef!(ref),
                  ),
                ),
            if (shown.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6, right: 4),
                child: HarnessMarkdown(text: shown),
              ),
            if (folded)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => setState(() => _expanded = true),
                  style: TextButton.styleFrom(
                    minimumSize: const Size(44, 40),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    visualDensity: VisualDensity.compact,
                  ),
                  child: Text(
                    'Show more',
                    style: HarnessText.caption(context).copyWith(
                      fontWeight: FontWeight.w700,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ),
              )
            else if (_expanded)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => setState(() => _expanded = false),
                  style: TextButton.styleFrom(
                    minimumSize: const Size(44, 40),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    visualDensity: VisualDensity.compact,
                  ),
                  child: Text(
                    'Show less',
                    style: HarnessText.caption(context).copyWith(
                      fontWeight: FontWeight.w700,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Cut a long answer at a line or a word near [limit], so that the fold
  /// does not leave a word in half.
  static String _cut(String text, int limit) {
    if (text.length <= limit) return text;
    final window = text.substring(0, limit);
    final line = window.lastIndexOf('\n');
    if (line > limit ~/ 2) return window.substring(0, line).trimRight();
    final space = window.lastIndexOf(' ');
    if (space > limit ~/ 2) return window.substring(0, space).trimRight();
    return window;
  }
}

/// A quote in a card: whose words, where they are from, and the words.
/// A long quote folds to four lines with `Show more`.
class _QuotePart extends StatefulWidget {
  const _QuotePart({required this.text, this.label, this.place, this.onShow});

  final String text;
  final String? label;
  final String? place;
  final VoidCallback? onShow;

  @override
  State<_QuotePart> createState() => _QuotePartState();
}

class _QuotePartState extends State<_QuotePart> {
  bool _expanded = false;

  static const _foldedChars = 240;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final long = widget.text.length > _foldedChars;
    final shown = long && !_expanded
        ? '${widget.text.substring(0, _foldedChars).trimRight()}…'
        : widget.text;
    final header = [
      if (widget.label != null) widget.label!,
      if (widget.place != null) widget.place!,
    ].join(' · ');
    return Semantics(
      button: widget.onShow != null,
      label: widget.onShow == null ? null : 'Show message',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onShow,
        child: Container(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 5),
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                color: theme.colorScheme.outlineVariant,
                width: 2,
              ),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (header.isNotEmpty)
                Text(
                  header,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: HarnessText.caption(context).copyWith(
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              const SizedBox(height: 2),
              Text(
                shown,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.35,
                ),
              ),
              if (long)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: () => setState(() => _expanded = !_expanded),
                    style: TextButton.styleFrom(
                      minimumSize: const Size(44, 40),
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      visualDensity: VisualDensity.compact,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text(
                      _expanded ? 'Show less' : 'Show more',
                      style: HarnessText.caption(context).copyWith(
                        fontWeight: FontWeight.w700,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.closed});

  final bool closed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = closed
        ? theme.colorScheme.onSurfaceVariant
        : theme.colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        closed ? 'Closed' : 'Open',
        style: HarnessText.caption(context)
            .copyWith(fontWeight: FontWeight.w700, color: color, fontSize: 10),
      ),
    );
  }
}

class _CardAction extends StatelessWidget {
  const _CardAction({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return IconButton(
      onPressed: onTap,
      tooltip: label,
      icon: Icon(icon, size: 17),
      color: theme.colorScheme.onSurfaceVariant,
      constraints: const BoxConstraints(minWidth: 44, minHeight: 40),
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
    );
  }
}

/// The bar over the composer that says which message or thread the next
/// message answers, and lets it go.
class ChatReplyBar extends StatelessWidget {
  const ChatReplyBar({
    super.key,
    required this.draft,
    required this.onCancel,
    this.onShow,
    this.tight = false,
  });

  final ChatReplyDraft draft;
  final VoidCallback onCancel;
  final VoidCallback? onShow;

  /// A phone held upright at twice the text has a strip of a page left above
  /// the keyboard: the quote stays with the target, and this bar keeps its
  /// one line for the words being written.
  final bool tight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final source = draft.sourceLabel;
    final excerpt = draft.excerpt;
    return LayoutBuilder(
      builder: (context, constraints) {
        // Large text leaves no room for the three names on one line: what is
        // answered keeps its line, and the source opens the quote.
        final large = MediaQuery.textScalerOf(context).scale(11) > 15;
        final stacked = constraints.maxWidth < 300 || large;
        // When the names cannot share a line, the source opens the quote
        // rather than taking a line of its own.
        final quote = stacked && source != null
            ? '$source · $excerpt'
            : excerpt;
        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(12),
            border: Border(
              left: BorderSide(
                color: theme.colorScheme.primary.withValues(alpha: 0.75),
                width: 3,
              ),
            ),
          ),
          child: Row(
            children: [
              Icon(
                Icons.reply_rounded,
                size: 17,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 7),
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onShow,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // A row of names overflows at a large text size and a
                      // narrow screen: a Wrap puts what does not fit on a
                      // line of its own instead of cutting it off.
                      Wrap(
                        spacing: 6,
                        runSpacing: 2,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            'Reply',
                            style: HarnessText.meta(context).copyWith(
                              fontWeight: FontWeight.w700,
                              color: theme.colorScheme.onSurface,
                            ),
                          ),
                          Text(
                            '· ${draft.label}',
                            style: HarnessText.caption(context).copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          if (!stacked && source != null)
                            Text(
                              '· $source',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: HarnessText.caption(context).copyWith(
                                fontWeight: FontWeight.w600,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                        ],
                      ),
                      if (quote.isNotEmpty && !tight)
                        Text(
                          quote,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: HarnessText.caption(context).copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            height: 1.25,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              IconButton(
                onPressed: onCancel,
                tooltip: 'Cancel reply',
                icon: const Icon(Icons.close_rounded, size: 18),
                color: theme.colorScheme.onSurfaceVariant,
                constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        );
      },
    );
  }
}
