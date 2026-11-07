import 'package:flutter/material.dart';

import '../../models/review.dart';
import '../../state/review_controller.dart';
import '../adaptive/adaptive_widgets.dart';
import '../adaptive/layout_widgets.dart';
import '../navigation.dart';
import '../theme/harness_theme.dart';
import 'review_style.dart';

/// Write one comment or reply, with the place and revision it is bound to in
/// sight, and the keyboard where the words go.
///
/// The box is the bottom of the page and the page makes room for the
/// keyboard, so what is written is never under it.  A draft saved here is
/// kept by the harness (`patch-review/apply`, `add-comment`), not by the
/// phone alone; leaving the page keeps what was typed in [ReviewDraft] even
/// before it is saved.
Future<bool?> showReviewComposer(
  BuildContext context, {
  required ReviewController controller,
  required ReviewDraft draft,
  required String title,
  required String hint,
  required String saveLabel,
  VoidCallback? onSaved,
}) {
  return Navigator.of(context).push<bool>(
    harnessRoute<bool>(
      context,
      (_) => ReviewComposerScreen(
        controller: controller,
        draft: draft,
        title: title,
        hint: hint,
        saveLabel: saveLabel,
        onSaved: onSaved,
      ),
    ),
  );
}

class ReviewComposerScreen extends StatefulWidget {
  const ReviewComposerScreen({
    super.key,
    required this.controller,
    required this.draft,
    required this.title,
    required this.hint,
    required this.saveLabel,
    this.onSaved,
  });

  final ReviewController controller;
  final ReviewDraft draft;
  final String title;
  final String hint;
  final String saveLabel;
  final VoidCallback? onSaved;

  @override
  State<ReviewComposerScreen> createState() => _ReviewComposerScreenState();
}

class _ReviewComposerScreenState extends State<ReviewComposerScreen> {
  late final TextEditingController _text = TextEditingController(
    text: widget.draft.text,
  );
  final FocusNode _focus = FocusNode();

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    widget.draft.text = _text.text;
    final saved = await widget.controller.saveDraft(widget.draft.key);
    if (!mounted) return;
    if (saved) {
      widget.onSaved?.call();
      Navigator.of(context).pop(true);
    }
  }

  Future<void> _delete() async {
    final confirmed = await showHarnessDialog<bool>(
      context: context,
      title: 'Delete draft',
      confirmLabel: 'Delete',
      cancelLabel: 'Cancel',
      destructive: true,
    );
    if (confirmed != true || !mounted) return;
    final deleted = await widget.controller.discardDraft(widget.draft.key);
    if (deleted && mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final theme = Theme.of(context);
        final revision = widget.draft.revision;
        final note = widget.controller.revisionNote(revision);
        return HarnessPage(
          title: widget.title,
          subtitle: Text(
            _placeLabel() ?? '',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            if (widget.draft.isSaved)
              HarnessIconButton(
                icon: Icons.delete_outline_rounded,
                label: 'Delete draft',
                onPressed: _delete,
              ),
          ],
          body: ListView(
            padding: const EdgeInsets.fromLTRB(
              HarnessSpace.gutter,
              HarnessSpace.sm,
              HarnessSpace.gutter,
              HarnessSpace.xl,
            ),
            children: [
              if (widget.draft.location != null ||
                  widget.draft.threadId != null) ...[
                Container(
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
                            widget.draft.threadId == null
                                ? Icons.add_comment_outlined
                                : Icons.reply_rounded,
                            size: 16,
                            color: theme.colorScheme.primary,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              widget.draft.threadId == null
                                  ? 'New thread'
                                  : 'Reply',
                              style: HarnessText.meta(context).copyWith(
                                color: theme.colorScheme.onSurface,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          if (widget.draft.isSaved)
                            Text(
                              'Draft',
                              style: HarnessText.meta(context)
                                  .copyWith(color: theme.colorScheme.primary),
                            ),
                        ],
                      ),
                      if (widget.draft.location != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          widget.draft.location!.label,
                          style: HarnessText.mono(context)
                              .copyWith(fontSize: 12),
                        ),
                        if (widget.draft.location!.excerpt != null) ...[
                          const SizedBox(height: 6),
                          _Excerpt(text: widget.draft.location!.excerpt!),
                        ],
                      ],
                      if (revision != null && revision.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: HarnessSpace.sm,
                          runSpacing: HarnessSpace.xs,
                          children: [
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.commit_rounded,
                                  size: 13,
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                                const SizedBox(width: 3),
                                Text(
                                  widget.controller.revisionLabel(revision),
                                  style: HarnessText.meta(context),
                                ),
                              ],
                            ),
                            if (note != null)
                              Text(
                                note,
                                style: HarnessText.meta(context).copyWith(
                                  color: HarnessColors.amber,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: HarnessSpace.md),
              ],
              if (note != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: HarnessSpace.sm),
                  child: HarnessNotice(
                    icon: Icons.history_rounded,
                    color: HarnessColors.amber,
                    message:
                        'Pinned revision ${widget.controller.revisionLabel(revision)}',
                  ),
                ),
              const HarnessSectionHeader(label: 'Comment'),
              const SizedBox(height: HarnessSpace.xs),
              Text('Markdown', style: HarnessText.caption(context)),
            ],
          ),
          bottom: SafeArea(
            top: false,
            child: Container(
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                border: Border(
                  top: BorderSide(color: theme.colorScheme.outlineVariant),
                ),
              ),
              padding: const EdgeInsets.fromLTRB(
                HarnessSpace.gutter,
                HarnessSpace.sm,
                HarnessSpace.gutter,
                HarnessSpace.sm,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  HarnessTextField(
                    key: const ValueKey('review-composer-field'),
                    controller: _text,
                    focusNode: _focus,
                    hint: widget.hint,
                    minLines: 2,
                    maxLines: 6,
                    keyboardType: TextInputType.multiline,
                    autofocus: true,
                    onChanged: (value) => widget.draft.text = value,
                  ),
                  const SizedBox(height: HarnessSpace.sm),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          widget.draft.isSaved ? 'Saved draft' : 'Draft',
                          style: HarnessText.meta(context),
                        ),
                      ),
                      HarnessTextButton(
                        label: 'Cancel',
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                      const SizedBox(width: HarnessSpace.sm),
                      HarnessPrimaryButton(
                        key: const ValueKey('review-composer-save'),
                        label: widget.saveLabel,
                        icon: Icons.save_outlined,
                        busy: widget.draft.saving,
                        onPressed: widget.draft.saving ? null : _save,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  String? _placeLabel() {
    final location = widget.draft.location;
    if (location != null) return location.label;
    if (widget.draft.threadId != null) return 'Thread';
    return 'The change';
  }
}

class _Excerpt extends StatelessWidget {
  const _Excerpt({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final lines = text.split('\n');
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
          for (final line in lines.take(8))
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
          if (lines.length > 8)
            Text('…', style: HarnessText.mono(context).copyWith(fontSize: 11)),
        ],
      ),
    );
  }
}

/// The feedback box: what sends a task back, or the replies of a task at
/// work, with every draft it will carry in sight.
///
/// A task waiting for review goes back with `task/reject`, and the harness
/// adds the drafts to the feedback.  With drafts and no words the feedback
/// is replies only, which is allowed: there is something to answer.  A task
/// at work sends its replies with `patch-review/send-replies`; words typed
/// here become a thread on the change as a whole.
class ReviewFeedbackScreen extends StatefulWidget {
  const ReviewFeedbackScreen({
    super.key,
    required this.controller,
    this.onSent,
  });

  final ReviewController controller;
  final VoidCallback? onSent;

  @override
  State<ReviewFeedbackScreen> createState() => _ReviewFeedbackScreenState();
}

class _ReviewFeedbackScreenState extends State<ReviewFeedbackScreen> {
  late final TextEditingController _text = TextEditingController(
    text: widget.controller.feedbackText,
  );
  final FocusNode _focus = FocusNode();

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    widget.controller.feedbackText = _text.text;
    final sent = await widget.controller.send();
    if (!mounted) return;
    if (sent) {
      widget.onSent?.call();
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final controller = widget.controller;
        final theme = Theme.of(context);
        final drafts = _allDrafts();
        final headline = controller.isReview ? 'Feedback' : 'Replies';
        final sendLabel = controller.isReview
            ? 'Send feedback'
            : 'Send replies';
        final repliesOnly = _text.text.trim().isEmpty && drafts.isNotEmpty;
        final canSend = controller.hasSomethingToSend && !controller.sending;
        return HarnessPage(
          title: headline,
          subtitle: Text(
            controller.task?.title ?? '',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(
              HarnessSpace.gutter,
              HarnessSpace.sm,
              HarnessSpace.gutter,
              HarnessSpace.xl,
            ),
            children: [
              if (controller.error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: HarnessSpace.sm),
                  child: HarnessErrorBanner(message: controller.error!),
                ),
              if (controller.notice case final notice?)
                Padding(
                  padding: const EdgeInsets.only(bottom: HarnessSpace.sm),
                  child: HarnessNotice(
                    icon: notice.error
                        ? Icons.error_outline_rounded
                        : Icons.check_circle_outline_rounded,
                    message: notice.text,
                    color: notice.error
                        ? theme.colorScheme.error
                        : HarnessColors.moss,
                  ),
                ),
              Container(
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
                        HarnessStatusLabel(
                          label: controller.isReview ? 'Review' : 'Replies',
                          color: controller.isReview
                              ? HarnessColors.column('review', theme.brightness)
                              : HarnessColors.column(
                                  'active',
                                  theme.brightness,
                                ),
                        ),
                        const SizedBox(width: HarnessSpace.sm),
                        Expanded(
                          child: Text(
                            controller.changes == null
                                ? ''
                                : 'Revision ${controller.changes!.revisionLabel}',
                            style: HarnessText.meta(context),
                          ),
                        ),
                      ],
                    ),
                    if (repliesOnly) ...[
                      const SizedBox(height: HarnessSpace.xs),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary.withValues(
                            alpha: 0.14,
                          ),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          'Replies only',
                          style: HarnessText.meta(context).copyWith(
                            color: theme.colorScheme.primary,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: HarnessSpace.xs),
                    Text(
                      controller.isReview
                          ? 'Task back · drafts attached'
                          : 'Drafts · to the agent',
                      style: HarnessText.caption(context),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: HarnessSpace.md),
              HarnessSectionHeader(
                label: 'Drafts',
                trailing: Text(
                  '${drafts.length}',
                  style: HarnessText.meta(context),
                ),
              ),
              const SizedBox(height: HarnessSpace.xs),
              if (controller.lastClose case final close?)
                _DraftRow(
                  title: 'Last close',
                  place: close.text,
                  badge: 'Harness',
                  onDelete: controller.sending
                      ? null
                      : () => controller.discardLastClose(),
                ),
              for (final entry in drafts)
                _DraftRow(
                  key: ValueKey(
                    'feedback-draft-${entry.draft?.key ?? entry.commentId}',
                  ),
                  title: entry.title,
                  place: entry.place,
                  text: entry.text,
                  badge: entry.saved ? 'Saved' : 'New',
                  onDelete: controller.sending
                      ? null
                      : () => _deleteDraft(entry),
                ),
              if (drafts.isEmpty && controller.lastClose == null)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: HarnessSpace.md,
                  ),
                  child: Text('No drafts', style: HarnessText.caption(context)),
                ),
              const SizedBox(height: HarnessSpace.md),
              HarnessSectionHeader(label: 'Words'),
              const SizedBox(height: HarnessSpace.xs),
              Text(
                controller.isReview ? 'Markdown' : 'Markdown · a thread',
                style: HarnessText.caption(context),
              ),
            ],
          ),
          bottom: SafeArea(
            top: false,
            child: Container(
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                border: Border(
                  top: BorderSide(color: theme.colorScheme.outlineVariant),
                ),
              ),
              padding: const EdgeInsets.fromLTRB(
                HarnessSpace.gutter,
                HarnessSpace.sm,
                HarnessSpace.gutter,
                HarnessSpace.sm,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  HarnessTextField(
                    key: const ValueKey('review-feedback-field'),
                    controller: _text,
                    focusNode: _focus,
                    hint: controller.isReview ? 'Feedback' : 'Replies',
                    minLines: 2,
                    maxLines: 6,
                    keyboardType: TextInputType.multiline,
                    onChanged: (value) {
                      controller.feedbackText = value;
                      setState(() {});
                    },
                  ),
                  const SizedBox(height: HarnessSpace.sm),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          drafts.isEmpty
                              ? (controller.lastClose == null
                                    ? 'No drafts'
                                    : 'Last close')
                              : drafts.length == 1
                              ? '1 draft'
                              : '${drafts.length} drafts',
                          style: HarnessText.meta(context),
                        ),
                      ),
                      HarnessTextButton(
                        label: 'Cancel',
                        onPressed: controller.sending
                            ? null
                            : () => Navigator.of(context).pop(),
                      ),
                    ],
                  ),
                  const SizedBox(height: HarnessSpace.xs),
                  HarnessPrimaryButton(
                    key: const ValueKey('review-feedback-send'),
                    label: sendLabel,
                    icon: Icons.send_rounded,
                    expand: true,
                    busy: controller.sending,
                    onPressed: canSend ? _send : null,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  List<_DraftView> _allDrafts() {
    final out = <_DraftView>[];
    final localIds = <String>{};
    for (final draft in widget.controller.localDrafts) {
      if (draft.commentId != null) localIds.add(draft.commentId!);
      out.add(
        _DraftView(
          draft: draft,
          title: draft.threadId == null ? 'Thread' : 'Reply',
          place: draft.location?.label ?? 'The change',
          text: draft.text,
          saved: draft.isSaved,
        ),
      );
    }
    // Drafts saved by another client, or before this page opened.
    for (final thread
        in widget.controller.set?.threads ?? const <ReviewThread>[]) {
      for (final comment in thread.comments) {
        if (!comment.isDraft) continue;
        if (localIds.contains(comment.id)) continue;
        out.add(
          _DraftView(
            commentId: comment.id,
            title: 'Draft',
            place: comment.location?.label ?? 'The change',
            text: comment.body,
            saved: true,
          ),
        );
      }
    }
    // The drafts the harness holds but this page has no local entry for,
    // are read from the set too when they are a thread's only comment.
    for (final comment
        in widget.controller.set?.drafts ?? const <ReviewComment>[]) {
      if (localIds.contains(comment.id)) continue;
      if (out.any((entry) => entry.commentId == comment.id)) continue;
      out.add(
        _DraftView(
          commentId: comment.id,
          title: 'Draft',
          place: comment.location?.label ?? 'The change',
          text: comment.body,
          saved: true,
        ),
      );
    }
    return out;
  }

  Future<void> _deleteDraft(_DraftView entry) async {
    final draft = entry.draft;
    final ok = draft != null
        ? await widget.controller.discardDraft(draft.key)
        : await widget.controller.deleteComment(entry.commentId!);
    if (!ok && mounted) {
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(const SnackBar(content: Text('Delete failed')));
    }
  }
}

class _DraftView {
  const _DraftView({
    this.draft,
    this.commentId,
    required this.title,
    required this.place,
    required this.text,
    required this.saved,
  });

  final ReviewDraft? draft;
  final String? commentId;
  final String title;
  final String place;
  final String text;
  final bool saved;
}

class _DraftRow extends StatelessWidget {
  const _DraftRow({
    super.key,
    required this.title,
    required this.place,
    this.text,
    this.badge,
    this.onDelete,
  });

  final String title;
  final String place;
  final String? text;
  final String? badge;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: HarnessSpace.sm),
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
              Text(
                title,
                style: HarnessText.meta(context).copyWith(
                  color: theme.colorScheme.onSurface,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: HarnessSpace.sm),
              Expanded(
                child: Text(
                  place,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: HarnessText.mono(context).copyWith(fontSize: 11),
                ),
              ),
              if (badge != null)
                Text(
                  badge!,
                  style: HarnessText.meta(context)
                      .copyWith(color: theme.colorScheme.primary),
                ),
              if (onDelete != null)
                HarnessIconButton(
                  icon: Icons.close_rounded,
                  label: 'Delete draft',
                  size: 18,
                  onPressed: onDelete,
                ),
            ],
          ),
          if (text != null && text!.trim().isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              text!,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: HarnessText.body(context).copyWith(fontSize: 13),
            ),
          ],
        ],
      ),
    );
  }
}
