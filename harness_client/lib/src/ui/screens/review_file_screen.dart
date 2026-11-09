import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/review.dart';
import '../../state/review_controller.dart';
import '../adaptive/adaptive_widgets.dart';
import '../adaptive/layout_widgets.dart';
import '../navigation.dart';
import '../theme/harness_theme.dart';
import '../widgets/review_composer.dart';
import '../widgets/review_diff_view.dart';
import '../widgets/review_style.dart';
import '../widgets/review_threads.dart';
import 'review_thread_screen.dart';

/// One file of a review: its diff, the threads on it, and what the person
/// can say about it.
///
/// The file stays at the top and the hunk the reader is at stays named while
/// the diff scrolls; the next and previous file are a tap away, stepping
/// over the files already approved when that is on.  A comment is made on a
/// line or a range of the diff and keeps the revision it was read at.
class ReviewFileScreen extends StatefulWidget {
  const ReviewFileScreen({
    super.key,
    required this.controller,
    required this.path,
    this.focusThreadId,
  });

  final ReviewController controller;
  final String path;
  final String? focusThreadId;

  @override
  State<ReviewFileScreen> createState() => _ReviewFileScreenState();
}

class _ReviewFileScreenState extends State<ReviewFileScreen> {
  late String _path = widget.path;
  String? _focusThreadId;

  @override
  void initState() {
    super.initState();
    _focusThreadId = widget.focusThreadId;
    // The page is not the one that says where the review is: the controller
    // is listened to by the page under this one too, and a notify here would
    // rebuild it in the middle of this page's build.
    if (widget.controller.selectedPath != _path) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.controller.selectFile(_path);
      });
    }
    if (widget.controller.set == null) {
      unawaited(widget.controller.load(force: true, quiet: true));
    }
  }

  ReviewController get controller => widget.controller;

  ChangedFile? get _file => controller.changes?.file(_path);

  void _step(int direction) {
    final next = direction > 0
        ? controller.nextFile()
        : controller.previousFile();
    if (next == null || !mounted) return;
    controller.selectFile(next);
    setState(() {
      _path = next;
      _focusThreadId = null;
    });
  }

  Future<void> _comment(
    String side,
    int start,
    int end,
    ReviewFileDiff diff,
  ) async {
    final file = _file;
    if (file == null || diff.path != _path) return;
    // The lines the reviewer selected are this diff's, at this diff's
    // revision: a version chosen while it was on screen does not move them.
    final draft = controller.lineDraft(
      file: file,
      side: side,
      start: start,
      end: end,
      revision: diff.revision,
      diff: diff,
    );
    await _compose(draft, title: 'Comment', hint: 'Comment', saveLabel: 'Save');
  }

  /// A thread of the file's own, with no line picked: what is wrong with the
  /// file as a whole says so without making the reader select a line.
  Future<void> _newThread() async {
    final file = _file;
    if (file == null) return;
    await _compose(
      controller.newThreadDraft(file: file),
      title: 'New thread',
      hint: 'Comment',
      saveLabel: 'Save',
    );
  }

  Future<void> _compose(
    ReviewDraft draft, {
    required String title,
    required String hint,
    required String saveLabel,
  }) async {
    await showReviewComposer(
      context,
      controller: controller,
      draft: draft,
      title: title,
      hint: hint,
      saveLabel: saveLabel,
      onSaved: () {},
    );
    if (!mounted) return;
    final notice = controller.notice;
    if (notice != null && !notice.error) {
      controller.clearNotice();
    }
  }

  void _openThread(ReviewThread thread) {
    Navigator.of(context).push<void>(
      harnessRoute<void>(
        context,
        (_) => ReviewThreadScreen(controller: controller, threadId: thread.id),
      ),
    );
  }

  Future<void> _threadsOfFile() async {
    final file = _file;
    if (file == null) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: SizedBox(
          height: MediaQuery.sizeOf(sheetContext).height * 0.7,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        file.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: HarnessText.rowTitle(sheetContext),
                      ),
                    ),
                    Text('Threads', style: HarnessText.meta(sheetContext)),
                  ],
                ),
              ),
              Expanded(
                child: ReviewThreadsList(
                  controller: controller,
                  filePath: file.path,
                  showFilters: true,
                  onOpen: (thread) {
                    Navigator.of(sheetContext).pop();
                    _openThread(thread);
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final file = _file;
        if (file == null) {
          return HarnessPage(
            title: 'Review',
            body: const HarnessEmptyState(
              icon: Icons.description_outlined,
              title: 'No file',
              message: 'Not in this revision',
            ),
          );
        }
        final seen = controller.viewed.isSeen(file);
        final approved = controller.viewed.isApproved(file);
        final threads =
            controller.set?.threadsForFile(file.path, oldPath: file.oldPath) ??
            const <ReviewThread>[];
        final theme = Theme.of(context);
        return HarnessPage(
          title: file.name,
          subtitle: Text(
            file.path,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            HarnessIconButton(
              key: const ValueKey('review-previous-file'),
              icon: Icons.arrow_upward_rounded,
              label: 'Previous file',
              onPressed: controller.navigationFiles.length <= 1
                  ? null
                  : () => _step(-1),
            ),
            HarnessIconButton(
              key: const ValueKey('review-next-file'),
              icon: Icons.arrow_downward_rounded,
              label: 'Next file',
              onPressed: controller.navigationFiles.length <= 1
                  ? null
                  : () => _step(1),
            ),
          ],
          body: Column(
            children: [
              if (controller.notice case final notice?)
                HarnessNotice(
                  icon: notice.error
                      ? Icons.error_outline_rounded
                      : Icons.check_circle_outline_rounded,
                  message: notice.text,
                  color: notice.error
                      ? theme.colorScheme.error
                      : HarnessColors.moss,
                  actionLabel: 'Dismiss',
                  onAction: controller.clearNotice,
                ),
              if (controller.stale)
                HarnessNotice(
                  icon: Icons.new_releases_outlined,
                  message: 'New revision',
                  detail:
                      'Review revision ${controller.revisionLabel(controller.staleRevision)} · current ${controller.revisionLabel(controller.changes?.revision)}',
                  color: HarnessColors.amber,
                  actionLabel: 'Reload',
                  onAction: controller.takeNewRevision,
                ),
              _FileFacts(
                controller: controller,
                file: file,
                seen: seen,
                approved: approved,
                threads: threads.length,
              ),
              _FileActions(
                controller: controller,
                file: file,
                seen: seen,
                approved: approved,
                threads: threads.length,
                onThreads: _threadsOfFile,
                onNewThread: _newThread,
              ),
              Expanded(
                child: ReviewDiffView(
                  key: ValueKey('review-diff-${file.path}'),
                  controller: controller,
                  file: file,
                  revision: controller.changes?.revision,
                  focusThreadId: _focusThreadId,
                  onOpenThread: _openThread,
                  onComment: _comment,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _FileFacts extends StatelessWidget {
  const _FileFacts({
    required this.controller,
    required this.file,
    required this.seen,
    required this.approved,
    required this.threads,
  });

  final ReviewController controller;
  final ChangedFile file;
  final bool seen;
  final bool approved;
  final int threads;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      key: const ValueKey('review-file-facts'),
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(
        HarnessSpace.gutter,
        HarnessSpace.xs,
        HarnessSpace.gutter,
        HarnessSpace.xs,
      ),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: ReviewStyle.fileTint(context, file),
              borderRadius: BorderRadius.circular(3),
              border: Border.all(
                color: ReviewStyle.fileColor(
                  context,
                  file,
                ).withValues(alpha: 0.45),
              ),
            ),
            child: Text(
              file.statusLetter,
              style: HarnessText.meta(context).copyWith(
                color: ReviewStyle.fileColor(context, file),
                fontWeight: FontWeight.w800,
                fontSize: 10,
              ),
            ),
          ),
          const SizedBox(width: HarnessSpace.sm),
          Expanded(
            child: Text(
              file.isRename
                  ? '${file.statusLabel} · ${file.oldPath} → ${file.path}'
                  : file.statusLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: HarnessText.meta(context)
                  .copyWith(color: theme.colorScheme.onSurface),
            ),
          ),
          Text(
            file.countsLabel,
            style: HarnessText.meta(context)
                .copyWith(color: ReviewStyle.additionInk(context)),
          ),
          if (!controller.readOnlyVersion) ...[
            const SizedBox(width: HarnessSpace.sm),
            Icon(
              seen
                  ? Icons.check_circle_rounded
                  : Icons.check_circle_outline_rounded,
              size: 15,
              color: seen
                  ? HarnessColors.moss
                  : theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 4),
            Icon(
              approved ? Icons.verified_rounded : Icons.verified_outlined,
              size: 15,
              color: approved
                  ? HarnessColors.oxide
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ],
          if (threads > 0) ...[
            const SizedBox(width: HarnessSpace.sm),
            Icon(
              Icons.mode_comment_outlined,
              size: 13,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 2),
            Text('$threads', style: HarnessText.meta(context)),
          ],
        ],
      ),
    );
  }
}

/// The marks and the threads of a file, as controls with words: the page's
/// header keeps the room for the file's name and the way to the next one.
class _FileActions extends StatelessWidget {
  const _FileActions({
    required this.controller,
    required this.file,
    required this.seen,
    required this.approved,
    required this.threads,
    required this.onThreads,
    required this.onNewThread,
  });

  final ReviewController controller;
  final ChangedFile file;
  final bool seen;
  final bool approved;
  final int threads;
  final VoidCallback onThreads;
  final VoidCallback onNewThread;

  @override
  Widget build(BuildContext context) {
    final busy = controller.isViewBusy(file);
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(
        HarnessSpace.gutter,
        HarnessSpace.xs,
        HarnessSpace.gutter,
        HarnessSpace.xs,
      ),
      child: Wrap(
        spacing: HarnessSpace.xs,
        runSpacing: HarnessSpace.xs,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (controller.readOnlyVersion)
            const HarnessPill(
              key: ValueKey('review-earlier-version'),
              label: 'Earlier version',
              icon: Icons.history_rounded,
              color: HarnessColors.amber,
            )
          else ...[
            HarnessPill(
              key: const ValueKey('review-viewed'),
              label: seen ? 'Viewed' : 'Not viewed',
              icon: seen
                  ? Icons.check_circle_rounded
                  : Icons.check_circle_outline_rounded,
              selected: seen,
              onTap: busy ? null : () => controller.setViewed(file, !seen),
            ),
            HarnessPill(
              key: const ValueKey('review-approved'),
              label: approved ? 'Approved' : 'Not approved',
              icon: approved ? Icons.verified_rounded : Icons.verified_outlined,
              selected: approved,
              onTap: busy
                  ? null
                  : () => controller.setApproved(file, !approved),
            ),
          ],
          HarnessPill(
            key: const ValueKey('review-file-threads'),
            label: 'Threads',
            count: threads,
            icon: Icons.forum_outlined,
            onTap: onThreads,
          ),
          HarnessPill(
            key: const ValueKey('review-file-new-thread'),
            label: 'New thread',
            icon: Icons.add_comment_outlined,
            onTap: onNewThread,
          ),
        ],
      ),
    );
  }
}
