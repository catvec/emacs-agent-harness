import 'package:flutter/material.dart';

import '../../models/review.dart';
import '../../state/review_controller.dart';
import '../adaptive/adaptive_widgets.dart';
import '../format.dart';
import '../theme/harness_theme.dart';
import 'markdown_view.dart';
import 'review_composer.dart';
import 'review_style.dart';

/// The threads of a review, filtered and grouped by the file they are on.
///
/// Every thread is here, closed ones too: a close is a point made, and its
/// conversation stays readable.  A thread the agent closed that the person
/// has not looked at says "To review", as the harness's own views say it.
class ReviewThreadsList extends StatelessWidget {
  const ReviewThreadsList({
    super.key,
    required this.controller,
    required this.onOpen,
    this.filePath,
    this.showFilters = true,
  });

  final ReviewController controller;
  final ValueChanged<ReviewThread> onOpen;

  /// Only the threads on this file, and on the change as a whole when it is
  /// null.
  final String? filePath;
  final bool showFilters;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final all = controller.set?.threads ?? const <ReviewThread>[];
        final scoped = filePath == null
            ? all
            : [
                for (final thread in all)
                  if (thread.file == filePath ||
                      thread.location?.oldFile == filePath)
                    thread,
              ];
        final filters = ReviewThreadFilter.values;
        final shown = [
          for (final thread in scoped)
            if (controller.threadFilter.matches(
              thread,
              hasDraft: thread.drafted > 0,
            ))
              thread,
        ];
        return Column(
          children: [
            if (showFilters)
              _FilterBar(controller: controller, threads: scoped),
            if (controller.lastClose != null && filePath == null)
              _LastCloseBanner(controller: controller),
            Expanded(
              child: shown.isEmpty
                  ? _empty(context)
                  : _groupedList(context, shown, filters),
            ),
          ],
        );
      },
    );
  }

  Widget _empty(BuildContext context) {
    final filter = controller.threadFilter;
    return HarnessEmptyState(
      icon: Icons.forum_outlined,
      title: filter == ReviewThreadFilter.all
          ? 'No threads'
          : 'No ${filter.label} threads',
      message: 'No comments',
    );
  }

  Widget _groupedList(
    BuildContext context,
    List<ReviewThread> threads,
    List<ReviewThreadFilter> filters,
  ) {
    final groups = <String, List<ReviewThread>>{};
    for (final thread in threads) {
      final file = thread.file;
      final key = file == null || file.isEmpty ? '' : file;
      groups.putIfAbsent(key, () => []).add(thread);
    }
    final keys = groups.keys.toList()
      ..sort((a, b) {
        if (a.isEmpty) return -1;
        if (b.isEmpty) return 1;
        final order = controller.changes?.files ?? const <ChangedFile>[];
        final ia = order.indexWhere((file) => file.path == a);
        final ib = order.indexWhere((file) => file.path == b);
        if (ia >= 0 && ib >= 0) return ia.compareTo(ib);
        return a.compareTo(b);
      });
    final entries = <Object>[];
    for (final key in keys) {
      final group = groups[key]!;
      entries.add(key);
      entries.addAll(group);
    }
    return ListView.builder(
      key: const ValueKey('review-threads'),
      padding: const EdgeInsets.fromLTRB(
        HarnessSpace.gutter,
        HarnessSpace.sm,
        HarnessSpace.gutter,
        HarnessSpace.xl,
      ),
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        if (entry is String) {
          final file = entry.isEmpty ? null : controller.changes?.file(entry);
          return _groupHeader(context, entry, file, groups[entry]!);
        }
        return Padding(
          padding: const EdgeInsets.only(bottom: HarnessSpace.sm),
          child: ReviewThreadTile(
            controller: controller,
            thread: entry as ReviewThread,
            onOpen: () => onOpen(entry),
          ),
        );
      },
    );
  }

  Widget _groupHeader(
    BuildContext context,
    String path,
    ChangedFile? file,
    List<ReviewThread> threads,
  ) {
    final open = threads.where((thread) => thread.isOpen).length;
    final toReview = threads.where((thread) => thread.toReview).length;
    return Padding(
      padding: const EdgeInsets.only(
        top: HarnessSpace.sm,
        bottom: HarnessSpace.xs,
      ),
      child: Row(
        children: [
          if (file != null)
            _StatusLetter(file: file)
          else
            const Icon(Icons.alt_route_rounded, size: 16),
          const SizedBox(width: HarnessSpace.sm),
          Expanded(
            child: Text(
              file == null ? 'The change' : (path.isEmpty ? file.path : path),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: HarnessText.subtitle(context).copyWith(
                color: Theme.of(context).colorScheme.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (open > 0) Text('$open open', style: HarnessText.meta(context)),
          if (open > 0 && toReview > 0)
            Text(' · ', style: HarnessText.meta(context)),
          if (toReview > 0)
            Text(
              '$toReview to review',
              style: HarnessText.meta(context).copyWith(
                color: HarnessColors.amber,
                fontWeight: FontWeight.w700,
              ),
            ),
        ],
      ),
    );
  }
}

class _FilterBar extends StatelessWidget {
  const _FilterBar({required this.controller, required this.threads});

  final ReviewController controller;
  final List<ReviewThread> threads;

  int _count(ReviewThreadFilter filter) => threads
      .where((thread) => filter.matches(thread, hasDraft: thread.drafted > 0))
      .length;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(
          horizontal: HarnessSpace.gutter,
          vertical: HarnessSpace.sm,
        ),
        children: [
          for (final filter in ReviewThreadFilter.values) ...[
            HarnessPill(
              label: filter.label,
              count: _count(filter),
              selected: controller.threadFilter == filter,
              onTap: () => controller.setThreadFilter(filter),
            ),
            const SizedBox(width: HarnessSpace.xs),
          ],
        ],
      ),
    );
  }
}

class _LastCloseBanner extends StatelessWidget {
  const _LastCloseBanner({required this.controller});

  final ReviewController controller;

  @override
  Widget build(BuildContext context) {
    final close = controller.lastClose;
    if (close == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Container(
      key: const ValueKey('review-last-close'),
      margin: const EdgeInsets.fromLTRB(
        HarnessSpace.gutter,
        HarnessSpace.sm,
        HarnessSpace.gutter,
        0,
      ),
      padding: const EdgeInsets.all(HarnessSpace.md),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.lock_outline_rounded,
                size: 16,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Text(
                'Last thread closed',
                style: HarnessText.meta(context).copyWith(
                  color: theme.colorScheme.onSurface,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            close.text,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: HarnessText.body(context).copyWith(fontSize: 13),
          ),
          const SizedBox(height: HarnessSpace.xs),
          Wrap(
            spacing: HarnessSpace.xs,
            children: [
              HarnessTextButton(
                label: 'Send',
                icon: Icons.send_rounded,
                dense: true,
                onPressed: controller.sending ? null : controller.sendLastClose,
              ),
              HarnessTextButton(
                label: 'Drop',
                icon: Icons.close_rounded,
                dense: true,
                onPressed: controller.sending
                    ? null
                    : controller.discardLastClose,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// One thread, as a list row: its state, where it is, what it says, and how
/// many replies it holds.
class ReviewThreadTile extends StatelessWidget {
  const ReviewThreadTile({
    super.key,
    required this.controller,
    required this.thread,
    required this.onOpen,
  });

  final ReviewController controller;
  final ReviewThread thread;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final color = ReviewStyle.threadColor(context, thread);
    final location = thread.location;
    final note = controller.revisionNote(thread.revision);
    final participants = thread.participants;
    return Semantics(
      button: true,
      label:
          'Thread on ${location?.label ?? 'the change'}, '
          '${ReviewStyle.threadLabel(thread)}, ${thread.comments.length} replies',
      child: Material(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(2),
          side: BorderSide(
            color: thread.toReview
                ? HarnessColors.amber.withValues(alpha: 0.55)
                : Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
        child: InkWell(
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsets.all(HarnessSpace.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _ThreadStatus(thread: thread),
                    const SizedBox(width: HarnessSpace.sm),
                    Expanded(
                      child: Text(
                        location?.label ?? 'The change',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: HarnessText.mono(context).copyWith(
                          fontSize: 11,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    if (thread.drafted > 0)
                      Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: _MiniBadge(
                          label: thread.drafted == 1
                              ? '1 draft'
                              : '${thread.drafted} drafts',
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  thread.excerpt.isEmpty ? 'No words' : thread.excerpt,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: HarnessText.body(context)
                      .copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    if (participants.isNotEmpty)
                      Flexible(
                        child: Text(
                          participants
                              .map((author) => author.label)
                              .join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: HarnessText.meta(context),
                        ),
                      ),
                    const Spacer(),
                    if (note != null) ...[
                      Flexible(
                        child: Text(
                          note,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: HarnessText.meta(context)
                              .copyWith(color: HarnessColors.amber),
                        ),
                      ),
                      const SizedBox(width: 6),
                    ],
                    Text(
                      '${thread.comments.length} '
                      '${thread.comments.length == 1 ? 'reply' : 'replies'}',
                      style: HarnessText.meta(context).copyWith(color: color),
                    ),
                    const Icon(Icons.chevron_right_rounded, size: 18),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The letter git gives a file, in a shape that says it even without colour.
class _StatusLetter extends StatelessWidget {
  const _StatusLetter({required this.file});

  final ChangedFile file;

  @override
  Widget build(BuildContext context) {
    final color = ReviewStyle.fileColor(context, file);
    return Container(
      width: 20,
      height: 20,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: ReviewStyle.fileTint(context, file),
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Text(
        file.statusLetter,
        style: HarnessText.meta(context)
            .copyWith(color: color, fontWeight: FontWeight.w800, fontSize: 10),
      ),
    );
  }
}

class _ThreadStatus extends StatelessWidget {
  const _ThreadStatus({required this.thread});

  final ReviewThread thread;

  @override
  Widget build(BuildContext context) {
    final color = ReviewStyle.threadColor(context, thread);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Text(
        ReviewStyle.threadLabel(thread),
        style: HarnessText.meta(context)
            .copyWith(color: color, fontWeight: FontWeight.w700),
      ),
    );
  }
}

class _MiniBadge extends StatelessWidget {
  const _MiniBadge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: HarnessText.meta(context)
            .copyWith(color: color, fontWeight: FontWeight.w700, fontSize: 10),
      ),
    );
  }
}

/// One thread opened: every comment, the long ones cut until asked for, the
/// earlier replies folded as the harness's views fold them, and what the
/// person can do with the thread.
class ReviewThreadConversation extends StatefulWidget {
  const ReviewThreadConversation({
    super.key,
    required this.controller,
    required this.thread,
    required this.onReply,
    required this.onQuote,
    required this.onShowPlace,
  });

  final ReviewController controller;
  final ReviewThread thread;
  final ValueChanged<ReviewComment> onReply;
  final ValueChanged<ReviewComment> onQuote;
  final VoidCallback onShowPlace;

  @override
  State<ReviewThreadConversation> createState() =>
      _ReviewThreadConversationState();
}

class _ReviewThreadConversationState extends State<ReviewThreadConversation> {
  bool _allReplies = false;
  final Set<String> _expandedComments = <String>{};

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final thread =
            widget.controller.thread(widget.thread.id) ?? widget.thread;
        final comments = thread.comments;
        final first = comments.isEmpty ? null : comments.first;
        final tail = comments.length <= 4
            ? comments.skip(1).toList()
            : comments.sublist(comments.length - 3);
        final middle = comments.length > 4 && !_allReplies
            ? comments.length - 4
            : 0;
        return ListView(
          key: const ValueKey('review-thread'),
          padding: const EdgeInsets.fromLTRB(
            HarnessSpace.gutter,
            HarnessSpace.sm,
            HarnessSpace.gutter,
            HarnessSpace.xl,
          ),
          children: [
            _ThreadHeader(
              controller: widget.controller,
              thread: thread,
              onShowPlace: widget.onShowPlace,
            ),
            const SizedBox(height: HarnessSpace.md),
            if (first != null)
              _CommentCard(
                controller: widget.controller,
                thread: thread,
                comment: first,
                expanded: _expandedComments.contains(first.id),
                onToggle: () => _toggleComment(first),
                onReply: () => widget.onReply(first),
                onQuote: () => widget.onQuote(first),
              ),
            if (middle > 0) ...[
              const SizedBox(height: HarnessSpace.xs),
              Center(
                child: HarnessTextButton(
                  key: const ValueKey('review-show-earlier'),
                  label: middle == 1
                      ? '1 earlier reply'
                      : '$middle earlier replies',
                  icon: Icons.unfold_more_rounded,
                  onPressed: () => setState(() => _allReplies = true),
                ),
              ),
            ],
            for (final comment in tail) ...[
              const SizedBox(height: HarnessSpace.xs),
              _CommentCard(
                controller: widget.controller,
                thread: thread,
                comment: comment,
                expanded: _expandedComments.contains(comment.id),
                onToggle: () => _toggleComment(comment),
                onReply: () => widget.onReply(comment),
                onQuote: () => widget.onQuote(comment),
              ),
            ],
            if (comments.isEmpty)
              Padding(
                padding: const EdgeInsets.all(HarnessSpace.lg),
                child: Text(
                  'No comments',
                  textAlign: TextAlign.center,
                  style: HarnessText.caption(context),
                ),
              ),
            const SizedBox(height: HarnessSpace.md),
            _ThreadActions(controller: widget.controller, thread: thread),
          ],
        );
      },
    );
  }

  void _toggleComment(ReviewComment comment) {
    setState(() {
      if (!_expandedComments.remove(comment.id)) {
        _expandedComments.add(comment.id);
      }
    });
  }
}

class _ThreadHeader extends StatelessWidget {
  const _ThreadHeader({
    required this.controller,
    required this.thread,
    required this.onShowPlace,
  });

  final ReviewController controller;
  final ReviewThread thread;
  final VoidCallback onShowPlace;

  @override
  Widget build(BuildContext context) {
    final location = thread.location;
    final theme = Theme.of(context);
    final note = controller.revisionNote(thread.revision);
    return Container(
      padding: const EdgeInsets.all(HarnessSpace.md),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _ThreadStatus(thread: thread),
              const SizedBox(width: HarnessSpace.sm),
              Expanded(
                child: Text(
                  location?.label ?? 'The change',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: HarnessText.mono(context).copyWith(fontSize: 12),
                ),
              ),
              HarnessIconButton(
                key: const ValueKey('thread-show-place'),
                icon: Icons.my_location_rounded,
                label: 'Show in the diff',
                onPressed: location == null ? null : onShowPlace,
              ),
            ],
          ),
          if (thread.revision != null) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: HarnessSpace.sm,
              runSpacing: HarnessSpace.xs,
              children: [
                _MetaChip(
                  label: controller.revisionLabel(thread.revision),
                  icon: Icons.commit_rounded,
                ),
                if (note != null)
                  _MetaChip(
                    label: note,
                    color: HarnessColors.amber,
                  ),
                if (thread.drafted > 0)
                  _MetaChip(
                    label: thread.drafted == 1
                        ? '1 draft'
                        : '${thread.drafted} drafts',
                    color: theme.colorScheme.primary,
                  ),
              ],
            ),
          ],
          if (location?.excerpt != null &&
              location!.excerpt!.trim().isNotEmpty) ...[
            const SizedBox(height: HarnessSpace.sm),
            _Excerpt(text: location.excerpt!),
          ],
        ],
      ),
    );
  }
}

class _Excerpt extends StatefulWidget {
  const _Excerpt({required this.text});

  final String text;

  @override
  State<_Excerpt> createState() => _ExcerptState();
}

class _ExcerptState extends State<_Excerpt> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final lines = widget.text.split('\n');
    final shown = _open ? lines : lines.take(6).toList();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(HarnessSpace.sm),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final line in shown)
            Text(
              line,
              style: HarnessText.mono(context).copyWith(
                fontSize: 11,
                color: line.startsWith('+')
                    ? ReviewStyle.additionInk(context)
                    : line.startsWith('-')
                    ? ReviewStyle.deletionInk(context)
                    : Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          if (lines.length > 6)
            HarnessTextButton(
              label: _open ? 'Show less' : 'Show more',
              dense: true,
              onPressed: () => setState(() => _open = !_open),
            ),
        ],
      ),
    );
  }
}

class _MetaChip extends StatelessWidget {
  const _MetaChip({required this.label, this.icon, this.color});

  final String label;
  final IconData? icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final tint = color ?? Theme.of(context).colorScheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 13, color: tint),
          const SizedBox(width: 3),
        ],
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: HarnessText.meta(context).copyWith(color: tint),
          ),
        ),
      ],
    );
  }
}

class _CommentCard extends StatelessWidget {
  const _CommentCard({
    required this.controller,
    required this.thread,
    required this.comment,
    required this.expanded,
    required this.onToggle,
    required this.onReply,
    required this.onQuote,
  });

  final ReviewController controller;
  final ReviewThread thread;
  final ReviewComment comment;
  final bool expanded;
  final VoidCallback onToggle;
  final VoidCallback onReply;
  final VoidCallback onQuote;

  static const _collapsedLines = 8;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final body = comment.body;
    final lines = body.split('\n');
    final long = lines.length > _collapsedLines;
    final draft = comment.isDraft;
    return Container(
      key: ValueKey('review-comment-${comment.id}'),
      padding: const EdgeInsets.all(HarnessSpace.md),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border.all(
          color: draft
              ? theme.colorScheme.primary.withValues(alpha: 0.5)
              : theme.colorScheme.outlineVariant,
        ),
        borderRadius: BorderRadius.circular(2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 10,
                backgroundColor: comment.author.isAgent
                    ? HarnessColors.oxide.withValues(alpha: 0.22)
                    : HarnessColors.moss.withValues(alpha: 0.2),
                child: Icon(
                  comment.author.isAgent
                      ? Icons.auto_awesome_rounded
                      : Icons.person_outline_rounded,
                  size: 12,
                  color: comment.author.isAgent
                      ? HarnessColors.oxideDark
                      : HarnessColors.moss,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  comment.author.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: HarnessText.meta(context).copyWith(
                    color: theme.colorScheme.onSurface,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (comment.time != null)
                Text(
                  relativeTime(comment.time),
                  style: HarnessText.meta(context),
                ),
              if (draft) ...[
                const SizedBox(width: 6),
                _MiniBadge(label: 'Draft', color: theme.colorScheme.primary),
              ],
            ],
          ),
          const SizedBox(height: 6),
          if (long && !expanded)
            Text(
              lines.take(_collapsedLines).join('\n'),
              maxLines: _collapsedLines,
              overflow: TextOverflow.ellipsis,
              style: HarnessText.body(context).copyWith(fontSize: 13.5),
            )
          else
            HarnessMarkdown(text: body, compact: true),
          if (long)
            HarnessTextButton(
              key: ValueKey('review-comment-more-${comment.id}'),
              label: expanded ? 'Show less' : 'Show more',
              dense: true,
              onPressed: onToggle,
            ),
          if (!draft)
            Wrap(
              spacing: 2,
              children: [
                HarnessTextButton(
                  key: ValueKey('review-comment-reply-${comment.id}'),
                  label: 'Reply',
                  dense: true,
                  onPressed: onReply,
                ),
                HarnessTextButton(
                  key: ValueKey('review-comment-quote-${comment.id}'),
                  label: 'Quote',
                  dense: true,
                  onPressed: onQuote,
                ),
              ],
            )
          else
            Wrap(
              spacing: 2,
              children: [
                HarnessTextButton(
                  label: 'Edit',
                  dense: true,
                  onPressed: () => _editDraft(context),
                ),
                HarnessTextButton(
                  label: 'Delete',
                  dense: true,
                  destructive: true,
                  onPressed: () => _deleteDraft(context),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Future<void> _editDraft(BuildContext context) async {
    final draft = controller.editCommentDraft(thread, comment);
    await showReviewComposer(
      context,
      controller: controller,
      draft: draft,
      title: 'Draft',
      hint: 'Comment',
      saveLabel: 'Save',
      onSaved: () {},
    );
  }

  Future<void> _deleteDraft(BuildContext context) async {
    final confirmed = await showHarnessDialog<bool>(
      context: context,
      title: 'Delete draft',
      confirmLabel: 'Delete',
      cancelLabel: 'Cancel',
      destructive: true,
    );
    if (confirmed == true) await controller.deleteComment(comment.id);
  }
}

class _ThreadActions extends StatelessWidget {
  const _ThreadActions({required this.controller, required this.thread});

  final ReviewController controller;
  final ReviewThread thread;

  @override
  Widget build(BuildContext context) {
    final closing = thread.closing;
    return Wrap(
      spacing: HarnessSpace.sm,
      runSpacing: HarnessSpace.sm,
      children: [
        if (thread.isOpen)
          HarnessSecondaryButton(
            key: const ValueKey('thread-resolve'),
            label: 'Resolve',
            icon: Icons.check_rounded,
            onPressed: () => controller.setThreadStatus(thread, false),
          )
        else
          HarnessSecondaryButton(
            key: const ValueKey('thread-reopen'),
            label: 'Reopen',
            icon: Icons.undo_rounded,
            onPressed: () => controller.setThreadStatus(thread, true),
          ),
        if (!thread.isOpen && closing != null && !closing.author!.isUser)
          HarnessTextButton(
            key: const ValueKey('thread-reviewed'),
            label: thread.toReview ? 'Mark reviewed' : 'To review',
            icon: thread.toReview
                ? Icons.done_all_rounded
                : Icons.pending_outlined,
            onPressed: () => controller.markReviewed(thread, thread.toReview),
          ),
      ],
    );
  }
}
