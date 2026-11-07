import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/memory.dart';
import '../../models/workspace.dart';
import '../../state/app_controller.dart';
import '../../state/memory_controller.dart';
import '../adaptive/adaptive_widgets.dart';
import '../format.dart';
import '../theme/harness_theme.dart';
import '../widgets/dither.dart';

/// The workspace's intelligent memory: what it kept and a recall search that
/// goes back to the thread a note came from.
///
/// The page is the long-lasting knowledge side of the workspace: notes are
/// cards with their thread, who said them and when, and a search shows the
/// matched words in place.  The model keeps the note; the page only reads it.
class MemoryScreen extends StatefulWidget {
  const MemoryScreen({
    super.key,
    required this.app,
    required this.workspace,
    this.controller,
  });

  final AppController app;
  final WorkspaceSummary workspace;
  final MemoryController? controller;

  @override
  State<MemoryScreen> createState() => _MemoryScreenState();
}

class _MemoryScreenState extends State<MemoryScreen> {
  late MemoryController _controller;
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    _controller = widget.controller ??
        MemoryController(widget.app.harness, workspaceId: widget.workspace.id);
    _controller.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _controller.load(showSpinner: false);
    });
  }

  @override
  void dispose() {
    _controller.removeListener(_changed);
    if (widget.controller == null) _controller.dispose();
    _search.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _submit(String value) {
    unawaited(_controller.search(value));
  }

  @override
  Widget build(BuildContext context) {
    final status = _controller.status;
    return HarnessPage(
      title: 'Memory',
      subtitle: Text(
        [
          widget.workspace.name,
          status == null ? 'Loading' : '${status.notes} notes',
          if (status?.fullText ?? false) 'Full text',
        ].join(' · '),
      ),
      actions: [
        HarnessIconButton(
          icon: Icons.refresh_rounded,
          label: 'Refresh',
          onPressed: () => unawaited(_controller.load(showSpinner: false)),
        ),
      ],
      body: Align(
        alignment: AlignmentDirectional.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 860),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              HarnessSpace.gutter,
              HarnessSpace.lg,
              HarnessSpace.gutter,
              HarnessSpace.xl,
            ),
            children: [
              _memoryCard(status),
              const SizedBox(height: HarnessSpace.md),
              _searchField(),
              if (_controller.error != null) ...[
                const SizedBox(height: HarnessSpace.md),
                Text(
                  _controller.error!,
                  style: HarnessText.caption(context).copyWith(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ],
              const SizedBox(height: HarnessSpace.lg),
              _section(
                _controller.hasQuery
                    ? 'Recall · ${_controller.notes.length}'
                    : 'Recent notes',
              ),
              if (_controller.notes.isEmpty)
                _empty()
              else
                for (final note in _controller.notes) _noteCard(note),
            ],
          ),
        ),
      ),
    );
  }

  Widget _memoryCard(WorkspaceMemoryStatus? status) {
    final notes = status?.notes ?? 0;
    return DitherPanel(
      padding: const EdgeInsets.all(HarnessSpace.lg),
      radius: 14,
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: HarnessColors.moss.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(2),
            ),
            child: const Icon(
              Icons.auto_awesome_rounded,
              size: 23,
              color: HarnessColors.moss,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Memory', style: HarnessText.rowTitle(context)),
                const SizedBox(height: 3),
                Text(
                  [
                    '$notes notes',
                    if (status?.fullText ?? false) 'full-text recall',
                    if (status?.last != null) 'last used ${_ago(status!.last)}',
                  ].join(' · '),
                  style: HarnessText.caption(context),
                ),
              ],
            ),
          ),
          _chip(status == null ? 'Loading' : 'Ready'),
        ],
      ),
    );
  }

  Widget _searchField() {
    return TextField(
      key: const ValueKey('memory-search'),
      controller: _search,
      textInputAction: TextInputAction.search,
      onSubmitted: _submit,
      decoration: InputDecoration(
        hintText: 'Search memory',
        prefixIcon: const Icon(Icons.search_rounded, size: 20),
        suffixIcon: _controller.hasQuery
            ? IconButton(
                tooltip: 'Clear',
                icon: const Icon(Icons.close_rounded, size: 18),
                onPressed: () {
                  _search.clear();
                  unawaited(_controller.clearSearch());
                },
              )
            : null,
      ),
    );
  }

  Widget _noteCard(MemoryNote note) {
    final accent = note.isAgent ? HarnessColors.moss : HarnessColors.oxide;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(2),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: IntrinsicHeight(
        child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            width: 4,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.7),
              borderRadius: const BorderRadius.horizontal(
                left: Radius.circular(2),
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _highlighted(note.display),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      _chip('# ${note.thread.isEmpty ? 'Workspace' : note.thread}'),
                      Text(
                        '${note.roleLabel} · ${_ago(note.at)}',
                        style: HarnessText.meta(context),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      ),
    );
  }

  Widget _highlighted(String text) {
    final spans = <TextSpan>[];
    final pattern = RegExp(r'<<(.+?)>>');
    var at = 0;
    for (final match in pattern.allMatches(text)) {
      if (match.start > at) {
        spans.add(TextSpan(text: text.substring(at, match.start)));
      }
      spans.add(
        TextSpan(
          text: match.group(1),
          style: TextStyle(
            color: Theme.of(context).colorScheme.primary,
            fontWeight: FontWeight.w700,
            backgroundColor: Theme.of(context)
                .colorScheme
                .primaryContainer
                .withValues(alpha: 0.35),
          ),
        ),
      );
      at = match.end;
    }
    if (at < text.length) spans.add(TextSpan(text: text.substring(at)));
    return Text.rich(
      TextSpan(children: spans),
      style: HarnessText.body(context).copyWith(height: 1.5),
      maxLines: 4,
      overflow: TextOverflow.ellipsis,
    );
  }

  Widget _section(String label) => Padding(
    padding: const EdgeInsets.only(bottom: HarnessSpace.sm),
    child: Text(label, style: HarnessText.label(context)),
  );

  Widget _chip(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(2),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Text(label, style: HarnessText.meta(context)),
    );
  }

  Widget _empty() {
    final searching = _controller.hasQuery;
    return Container(
      padding: const EdgeInsets.all(HarnessSpace.xl),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(2),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            searching ? Icons.search_off_rounded : Icons.auto_awesome_outlined,
            size: 26,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: HarnessSpace.sm),
          Text(
            searching ? 'No matches' : 'No notes',
            style: HarnessText.rowTitle(context),
          ),
          const SizedBox(height: 2),
          Text(
            searching ? 'Different words' : 'Start a conversation',
            style: HarnessText.caption(context),
          ),
        ],
      ),
    );
  }
}

String _ago(DateTime? time) {
  if (time == null) return '';
  final text = relativeTime(time);
  if (RegExp(r'^\d+[mhd]$').hasMatch(text)) return '$text ago';
  return text;
}
