import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/review.dart';
import '../../models/task.dart';
import '../../state/app_controller.dart';
import '../../state/review_controller.dart';
import '../adaptive/adaptive_widgets.dart';
import '../adaptive/layout_widgets.dart';
import '../navigation.dart';
import '../theme/harness_theme.dart';
import '../widgets/review_composer.dart';
import '../widgets/review_style.dart';
import '../widgets/review_threads.dart';
import 'review_file_screen.dart';
import 'review_thread_screen.dart';

/// Where a task's work is reviewed on a phone: its files, the threads of its
/// review, and the way into each file's diff and into the feedback.
///
/// The changes are the harness's (`patch-review/get`, `-changes`, `-diff`);
/// nothing is read from the repository here and no comment is kept on the
/// phone.  A comment written here is an operation of the harness's review,
/// read by Emacs and by the agent as any other.
class ReviewScreen extends StatefulWidget {
  const ReviewScreen({
    super.key,
    required this.app,
    required this.task,
    this.initialTab = ReviewTab.files,
  });

  final AppController app;
  final HarnessTask task;
  final ReviewTab initialTab;

  static Future<void> show(
    BuildContext context, {
    required AppController app,
    required HarnessTask task,
    ReviewTab initialTab = ReviewTab.files,
  }) {
    return Navigator.of(context).push<void>(
      harnessRoute<void>(
        context,
        (_) => ReviewScreen(app: app, task: task, initialTab: initialTab),
      ),
    );
  }

  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

enum ReviewTab { files, threads }

class _ReviewScreenState extends State<ReviewScreen> {
  ReviewController? _controller;
  late ReviewTab _tab = widget.initialTab;
  bool _filtering = false;
  String _query = '';
  final TextEditingController _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    _controller = widget.app.reviewFor(widget.task);
    final controller = _controller;
    if (controller != null) unawaited(controller.load());
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _openFile(String path) {
    final controller = _controller;
    if (controller == null) return;
    controller.selectFile(path);
    Navigator.of(context).push<void>(
      harnessRoute<void>(
        context,
        (_) => ReviewFileScreen(controller: controller, path: path),
      ),
    );
  }

  void _openThread(ReviewThread thread) {
    final controller = _controller;
    if (controller == null) return;
    Navigator.of(context).push<void>(
      harnessRoute<void>(
        context,
        (_) => ReviewThreadScreen(controller: controller, threadId: thread.id),
      ),
    );
  }

  void _openFeedback() {
    final controller = _controller;
    if (controller == null) return;
    Navigator.of(context).push<void>(
      harnessRoute<void>(
        context,
        (_) => ReviewFeedbackScreen(controller: controller),
      ),
    );
  }

  Future<void> _more(ReviewController controller) async {
    final choice = await showHarnessMenu<String>(
      context: context,
      title: 'Review',
      items: [
        HarnessMenuItem(
          value: 'skip',
          label: controller.skipApproved
              ? 'Skip approved: on'
              : 'Skip approved: off',
          icon: Icons.skip_next_rounded,
        ),
        HarnessMenuItem(
          value: 'reload',
          label: 'Reload',
          icon: Icons.refresh_rounded,
        ),
        HarnessMenuItem(
          value: 'report',
          label: 'Report',
          icon: Icons.assignment_turned_in_outlined,
        ),
      ],
    );
    if (choice == null || !mounted) return;
    switch (choice) {
      case 'skip':
        controller.setSkipApproved(!controller.skipApproved);
      case 'reload':
        unawaited(controller.load(force: true));
      case 'report':
        // The session's page is the report's page; the task bar leads there.
        Navigator.of(context).pop();
    }
  }

  Future<void> _chooseVersion(ReviewController controller) async {
    if (!controller.hasVersions) return;
    final chosen = await showHarnessMenu<String>(
      context: context,
      title: 'Versions',
      items: [
        for (final version in controller.versions.reversed)
          HarnessMenuItem(
            value: version.id,
            label:
                '${version.name} · ${shortRevisionOf(version.tip ?? version.id)}',
            icon: version.id == controller.changes?.versionId
                ? Icons.check_rounded
                : Icons.commit_rounded,
          ),
      ],
    );
    if (chosen == null || !mounted) return;
    await controller.selectVersion(chosen);
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) {
      return HarnessPage(
        title: 'Review',
        body: const Center(child: Text('Review unavailable')),
      );
    }
    return AnimatedBuilder(
      animation: Listenable.merge([controller, widget.app]),
      builder: (context, _) {
        return HarnessPage(
          title: 'Review',
          subtitle: Text(
            controller.task?.title ?? widget.task.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            if (_tab == ReviewTab.files)
              HarnessIconButton(
                icon: _filtering
                    ? Icons.search_off_rounded
                    : Icons.search_rounded,
                label: _filtering ? 'Hide file search' : 'Search files',
                onPressed: () => setState(() {
                  _filtering = !_filtering;
                  if (!_filtering) {
                    _query = '';
                    _search.clear();
                  }
                }),
              ),
            HarnessIconButton(
              icon: Icons.refresh_rounded,
              label: 'Refresh review',
              onPressed: controller.loading
                  ? null
                  : () => controller.load(force: true),
            ),
            HarnessIconButton(
              icon: Icons.more_horiz_rounded,
              label: 'Review actions',
              onPressed: () => _more(controller),
            ),
          ],
          body: Column(
            children: [
              _Summary(
                controller: controller,
                onVersions: () => _chooseVersion(controller),
              ),
              if (_filtering && _tab == ReviewTab.files)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    HarnessSpace.gutter,
                    HarnessSpace.sm,
                    HarnessSpace.gutter,
                    0,
                  ),
                  child: HarnessTextField(
                    key: const ValueKey('review-file-search'),
                    controller: _search,
                    hint: 'Files',
                    autofocus: true,
                    onChanged: (value) => setState(() => _query = value),
                  ),
                ),
              if (controller.error != null)
                HarnessErrorBanner(
                  message: controller.error!,
                  onDismiss: () => controller.clearNotice(),
                ),
              if (controller.stale) _StaleBanner(controller: controller),
              if (widget.app.isReconnecting)
                HarnessNotice(
                  leading: const HarnessActivity(radius: 8),
                  message: 'Reconnecting',
                  color: HarnessColors.amber,
                ),
              if (controller.notice case final notice?)
                HarnessNotice(
                  icon: notice.error
                      ? Icons.error_outline_rounded
                      : Icons.check_circle_outline_rounded,
                  message: notice.text,
                  color: notice.error
                      ? Theme.of(context).colorScheme.error
                      : HarnessColors.moss,
                  actionLabel: 'Dismiss',
                  onAction: controller.clearNotice,
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  HarnessSpace.gutter,
                  HarnessSpace.sm,
                  HarnessSpace.gutter,
                  HarnessSpace.sm,
                ),
                child: HarnessTabStrip<ReviewTab>(
                  tabs: [
                    HarnessTab(
                      value: ReviewTab.files,
                      label: 'Files',
                      count: controller.fileCount,
                    ),
                    HarnessTab(
                      value: ReviewTab.threads,
                      label: 'Threads',
                      count: controller.threadCount,
                    ),
                  ],
                  value: _tab,
                  onChanged: (tab) => setState(() => _tab = tab),
                ),
              ),
              Expanded(
                child: controller.loading && controller.set == null
                    ? const Center(child: HarnessActivity(radius: 10))
                    : _tab == ReviewTab.files
                    ? _FilesPane(
                        controller: controller,
                        query: _query,
                        onOpenFile: _openFile,
                        onOpenThreads: () =>
                            setState(() => _tab = ReviewTab.threads),
                        onOpenThread: _openThread,
                      )
                    : ReviewThreadsList(
                        controller: controller,
                        onOpen: _openThread,
                      ),
              ),
              _ActionBar(
                controller: controller,
                onFeedback: _openFeedback,
                closed: controller.task?.isClosed ?? false,
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.controller, this.onVersions});

  final ReviewController controller;
  final VoidCallback? onVersions;

  @override
  Widget build(BuildContext context) {
    final changes = controller.changes;
    final theme = Theme.of(context);
    if (changes == null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(
          HarnessSpace.gutter,
          HarnessSpace.sm,
          HarnessSpace.gutter,
          0,
        ),
        child: Text(
          controller.error ??
              (controller.loading ? 'Loading review' : 'No changes'),
          style: HarnessText.caption(context),
        ),
      );
    }
    return Container(
      key: const ValueKey('review-summary'),
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
              HarnessStatusLabel(
                label: controller.isReview ? 'Review' : 'Replies',
                color: controller.isReview
                    ? HarnessColors.column('review', theme.brightness)
                    : HarnessColors.column('active', theme.brightness),
              ),
              const SizedBox(width: HarnessSpace.sm),
              Expanded(
                child: InkWell(
                  key: const ValueKey('review-versions'),
                  onTap: controller.hasVersions ? onVersions : null,
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          changes.label == null
                              ? 'Revision ${changes.revisionLabel}'
                              : '${changes.label} · ${changes.revisionLabel}',
                          key: const ValueKey('review-revision'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: HarnessText.meta(context).copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      if (controller.hasVersions)
                        Icon(
                          Icons.expand_more_rounded,
                          size: 18,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                    ],
                  ),
                ),
              ),
              if (controller.refreshing) const HarnessActivity(radius: 7),
            ],
          ),
          const SizedBox(height: HarnessSpace.sm),
          Wrap(
            spacing: HarnessSpace.md,
            runSpacing: HarnessSpace.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(changes.summaryLabel, style: HarnessText.meta(context)),
              if (controller.readOnlyVersion)
                const _Fact(
                  label: 'Earlier version',
                  color: HarnessColors.amber,
                )
              else ...[
                _Fact(
                  label:
                      '${controller.reviewedFileCount}/${controller.fileCount} viewed',
                  color: HarnessColors.moss,
                ),
                _Fact(
                  label:
                      '${controller.approvedFileCount}/${controller.fileCount} approved',
                  color: HarnessColors.oxide,
                ),
              ],
              _Fact(
                label:
                    '${controller.openThreadCount} open · ${controller.toReviewCount} to review',
                color: controller.toReviewCount > 0
                    ? HarnessColors.amber
                    : null,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact({required this.label, this.color});

  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: HarnessText.meta(context).copyWith(
        color: color ?? Theme.of(context).colorScheme.onSurfaceVariant,
        fontWeight: color == null ? FontWeight.w400 : FontWeight.w700,
      ),
    );
  }
}

class _StaleBanner extends StatelessWidget {
  const _StaleBanner({required this.controller});

  final ReviewController controller;

  @override
  Widget build(BuildContext context) {
    return HarnessNotice(
      key: const ValueKey('review-stale'),
      icon: Icons.new_releases_outlined,
      message: 'New revision',
      detail:
          'Shown ${controller.revisionLabel(controller.changes?.revision)} · new ${controller.revisionLabel(controller.staleRevision)}',
      color: HarnessColors.amber,
      actionLabel: 'Reload',
      actionKey: const ValueKey('review-stale-reload'),
      onAction: controller.takeNewRevision,
      detailLines: 2,
    );
  }
}

class _ActionBar extends StatelessWidget {
  const _ActionBar({
    required this.controller,
    required this.onFeedback,
    required this.closed,
  });

  final ReviewController controller;
  final VoidCallback onFeedback;
  final bool closed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final drafts = controller.draftCount;
    final lastClose = controller.lastClose != null ? 1 : 0;
    final count = drafts + lastClose;
    return Container(
      key: const ValueKey('review-actions'),
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
      child: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    closed
                        ? 'Review closed'
                        : controller.isReview
                        ? 'Review'
                        : 'Replies',
                    style: HarnessText.meta(context).copyWith(
                      color: theme.colorScheme.onSurface,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Text(
                  count == 0
                      ? 'No drafts'
                      : count == 1
                      ? '1 draft'
                      : '$count drafts',
                  style: HarnessText.meta(context),
                ),
              ],
            ),
            const SizedBox(height: HarnessSpace.xs),
            HarnessPrimaryButton(
              key: const ValueKey('review-feedback-button'),
              label: controller.isReview
                  ? (count > 0 ? 'Feedback · $count' : 'Feedback')
                  : (count > 0 ? 'Replies · $count' : 'Replies'),
              icon: Icons.rate_review_outlined,
              expand: true,
              onPressed: closed ? null : onFeedback,
            ),
          ],
        ),
      ),
    );
  }
}

class _FilesPane extends StatelessWidget {
  const _FilesPane({
    required this.controller,
    required this.query,
    required this.onOpenFile,
    required this.onOpenThreads,
    required this.onOpenThread,
  });

  final ReviewController controller;
  final String query;
  final ValueChanged<String> onOpenFile;
  final VoidCallback onOpenThreads;
  final ValueChanged<ReviewThread> onOpenThread;

  @override
  Widget build(BuildContext context) {
    final changes = controller.changes;
    if (changes == null) {
      return const SizedBox.shrink();
    }
    final needle = query.trim().toLowerCase();
    final files = needle.isEmpty
        ? changes.files
        : [
            for (final file in changes.files)
              if (file.path.toLowerCase().contains(needle)) file,
          ];
    if (files.isEmpty) {
      return HarnessEmptyState(
        icon: Icons.description_outlined,
        title: needle.isEmpty ? 'No changes' : 'No files',
        message: needle.isEmpty ? 'No changed files' : 'No matching file',
      );
    }
    final wholeChange = controller.set?.wholeChange ?? const <ReviewThread>[];
    final rows = controller.treeView
        ? flattenReviewTree(
            buildReviewTree(files),
            collapsed: controller.collapsedDirectories,
          )
        : [
            for (final file
                in (files.toList()..sort((a, b) => a.path.compareTo(b.path))))
              ReviewTreeRow(
                name: file.name,
                path: file.path,
                depth: 0,
                file: file,
                added: file.added ?? 0,
                deleted: file.deleted ?? 0,
                files: 1,
              ),
          ];
    return Column(
      children: [
        _FilesToolbar(controller: controller),
        Expanded(
          child: ListView.builder(
            key: const ValueKey('review-files'),
            padding: const EdgeInsets.only(bottom: HarnessSpace.xl),
            itemCount: rows.length + 1,
            itemBuilder: (context, index) {
              if (index == rows.length) {
                return _WholeChangeRow(
                  controller: controller,
                  threads: wholeChange,
                  onOpen: onOpenThreads,
                  onOpenThread: onOpenThread,
                );
              }
              final row = rows[index];
              if (row.directory) {
                return _DirectoryRow(
                  row: row,
                  expanded: controller.directoryExpanded(row.path),
                  onTap: () => controller.toggleDirectory(row.path),
                );
              }
              final file = row.file!;
              return _FileRow(
                controller: controller,
                file: file,
                onTap: () => onOpenFile(file.path),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _FilesToolbar extends StatelessWidget {
  const _FilesToolbar({required this.controller});

  final ReviewController controller;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        HarnessSpace.gutter,
        HarnessSpace.xs,
        HarnessSpace.gutter,
        0,
      ),
      child: Row(
        children: [
          Text(
            '${controller.navigationFiles.length} files',
            style: HarnessText.meta(context),
          ),
          const Spacer(),
          HarnessIconButton(
            key: const ValueKey('review-flat-toggle'),
            icon: controller.treeView
                ? Icons.account_tree_outlined
                : Icons.view_list_outlined,
            label: controller.treeView ? 'Flat list' : 'File tree',
            onPressed: () => controller.setTreeView(!controller.treeView),
          ),
          HarnessIconButton(
            key: const ValueKey('review-skip-approved'),
            icon: Icons.skip_next_rounded,
            label: controller.skipApproved
                ? 'Skip approved: on'
                : 'Skip approved: off',
            selected: controller.skipApproved,
            onPressed: () =>
                controller.setSkipApproved(!controller.skipApproved),
          ),
        ],
      ),
    );
  }
}

class _DirectoryRow extends StatelessWidget {
  const _DirectoryRow({
    required this.row,
    required this.expanded,
    required this.onTap,
  });

  final ReviewTreeRow row;
  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      expanded: expanded,
      label: '${row.name}, ${row.files} files',
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            HarnessSpace.gutter + row.depth * 12,
            HarnessSpace.sm,
            HarnessSpace.gutter,
            HarnessSpace.sm,
          ),
          child: Row(
            children: [
              Icon(
                expanded
                    ? Icons.keyboard_arrow_down_rounded
                    : Icons.keyboard_arrow_right_rounded,
                size: 18,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 4),
              Icon(
                expanded ? Icons.folder_open_rounded : Icons.folder_outlined,
                size: 17,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  row.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: HarnessText.body(context)
                      .copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              // A directory's own counts are secondary: on a narrow screen
              // read at a large size they would push the name out, so the
              // name keeps the room and the counts go.
              if (MediaQuery.sizeOf(context).width >= 360 &&
                  MediaQuery.textScalerOf(context).scale(12) <= 15) ...[
                Text(
                  '${row.files} ${row.files == 1 ? 'file' : 'files'}',
                  style: HarnessText.meta(context),
                ),
                const SizedBox(width: HarnessSpace.sm),
                Text(
                  '+${row.added} −${row.deleted}',
                  style: HarnessText.meta(context),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _FileRow extends StatelessWidget {
  const _FileRow({
    required this.controller,
    required this.file,
    required this.onTap,
  });

  final ReviewController controller;
  final ChangedFile file;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final seen = controller.viewed.isSeen(file);
    final approved = controller.viewed.isApproved(file);
    final threads =
        controller.set?.threadsForFile(file.path, oldPath: file.oldPath) ??
        const <ReviewThread>[];
    final toReview = threads.where((thread) => thread.toReview).length;
    final theme = Theme.of(context);
    final color = ReviewStyle.fileColor(context, file);
    return Semantics(
      button: true,
      label:
          '${file.path}, ${file.statusLabel}, '
          '${file.added ?? 0} lines added, ${file.deleted ?? 0} lines deleted, '
          '${threads.length} threads${seen ? ', viewed' : ''}${approved ? ', approved' : ''}',
      child: InkWell(
        key: ValueKey('review-file-${file.path}'),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 56),
          padding: EdgeInsets.fromLTRB(
            HarnessSpace.gutter,
            HarnessSpace.xs,
            HarnessSpace.gutter,
            HarnessSpace.xs,
          ),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
              ),
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
                  border: Border.all(color: color.withValues(alpha: 0.45)),
                ),
                child: Text(
                  file.statusLetter,
                  style: HarnessText.meta(context).copyWith(
                    color: color,
                    fontWeight: FontWeight.w800,
                    fontSize: 10,
                  ),
                ),
              ),
              const SizedBox(width: HarnessSpace.sm),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      file.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: HarnessText.body(context)
                          .copyWith(fontWeight: FontWeight.w600),
                    ),
                    if (file.directory.isNotEmpty)
                      Text(
                        file.directory,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: HarnessText.mono(context).copyWith(
                          fontSize: 10,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: HarnessSpace.xs),
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(file.countsLabel, style: HarnessText.meta(context)),
                  if (threads.isNotEmpty)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.mode_comment_outlined,
                          size: 11,
                          color: toReview > 0
                              ? HarnessColors.amber
                              : theme.colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 2),
                        Text(
                          '${threads.length}',
                          style: HarnessText.meta(context).copyWith(
                            color: toReview > 0
                                ? HarnessColors.amber
                                : theme.colorScheme.onSurfaceVariant,
                            fontWeight: toReview > 0
                                ? FontWeight.w700
                                : FontWeight.w400,
                          ),
                        ),
                      ],
                    ),
                ],
              ),
              if (seen || approved) ...[
                const SizedBox(width: HarnessSpace.xs),
                Icon(
                  approved
                      ? Icons.verified_rounded
                      : Icons.check_circle_outline_rounded,
                  size: 15,
                  color: approved ? HarnessColors.oxide : HarnessColors.moss,
                ),
              ],
              const Icon(Icons.chevron_right_rounded, size: 18),
            ],
          ),
        ),
      ),
    );
  }
}

class _WholeChangeRow extends StatelessWidget {
  const _WholeChangeRow({
    required this.controller,
    required this.threads,
    required this.onOpen,
    required this.onOpenThread,
  });

  final ReviewController controller;
  final List<ReviewThread> threads;
  final VoidCallback onOpen;
  final ValueChanged<ReviewThread> onOpenThread;

  @override
  Widget build(BuildContext context) {
    final open = threads.where((thread) => thread.isOpen).length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        HarnessSpace.gutter,
        HarnessSpace.md,
        HarnessSpace.gutter,
        HarnessSpace.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          HarnessSectionHeader(
            label: 'The change',
            padding: EdgeInsets.zero,
            trailing: Text(
              threads.isEmpty
                  ? 'No threads'
                  : '${threads.length} threads · $open open',
              style: HarnessText.meta(context),
            ),
          ),
          if (threads.isEmpty)
            Text(
              'No threads on the change',
              style: HarnessText.caption(context),
            )
          else ...[
            for (final thread in threads.take(3))
              Padding(
                padding: const EdgeInsets.only(top: HarnessSpace.xs),
                child: ReviewThreadTile(
                  controller: controller,
                  thread: thread,
                  onOpen: () => onOpenThread(thread),
                ),
              ),
            HarnessTextButton(
              label: 'All threads',
              icon: Icons.forum_outlined,
              onPressed: onOpen,
            ),
          ],
        ],
      ),
    );
  }
}
