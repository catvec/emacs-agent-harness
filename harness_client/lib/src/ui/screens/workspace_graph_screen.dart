import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/workspace.dart';
import '../../models/workspace_graph.dart';
import '../../state/app_controller.dart';
import '../../state/workspace_graph_controller.dart';
import '../adaptive/adaptive_widgets.dart';
import '../format.dart';
import '../theme/harness_theme.dart';
import '../widgets/dither.dart';

/// The thread's page in the workspace's Logseq graph: its identity and state,
/// the notes and turns on it, and the pages that link it back.
///
/// The page only reads the graph; the harness and the user's editor write it.
/// A node opens with its children, a linked page opens by name, and Back
/// returns to the view before this one.
class WorkspaceGraphScreen extends StatefulWidget {
  const WorkspaceGraphScreen({
    super.key,
    required this.app,
    required this.workspace,
    this.threadId,
    this.controller,
  });

  final AppController app;
  final WorkspaceSummary workspace;
  final String? threadId;
  final WorkspaceGraphController? controller;

  @override
  State<WorkspaceGraphScreen> createState() => _WorkspaceGraphScreenState();
}

class _WorkspaceGraphScreenState extends State<WorkspaceGraphScreen> {
  late WorkspaceGraphController _controller;

  @override
  void initState() {
    super.initState();
    _controller =
        widget.controller ??
        WorkspaceGraphController(
          widget.app.harness,
          workspaceId: widget.workspace.id,
          threadId: widget.threadId,
        );
    _controller.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _controller.load(showSpinner: false);
    });
  }

  @override
  void dispose() {
    _controller.removeListener(_changed);
    if (widget.controller == null) _controller.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  WorkspaceGraph? get _graph => _controller.graph;

  String _place() {
    final graph = _graph;
    if (graph == null) return 'Thread';
    return switch (_controller.view.kind) {
      'node' => 'Node · ${_controller.view.id}',
      'page' => 'Page · ${graph.pageName}',
      _ => 'Thread · ${graph.thread.isEmpty ? graph.pageName : graph.thread}',
    };
  }

  String _state() {
    if (_controller.error != null) return 'Error';
    final graph = _graph;
    if (graph == null) return 'Loading';
    return switch (graph.status) {
      'ready' => 'Ready',
      'missing' => _controller.view.kind == 'node' ? 'No node' : 'No page',
      'unavailable' => 'No graph',
      _ => graph.status,
    };
  }

  @override
  Widget build(BuildContext context) {
    final graph = _graph;
    return HarnessPage(
      title: 'Graph',
      subtitle: Text(
        [
          widget.workspace.name,
          _place(),
          _state(),
          if (graph != null && graph.ready) _nodesLabel(graph),
        ].join(' · '),
      ),
      actions: [
        if (_controller.canGoBack)
          HarnessIconButton(
            icon: Icons.arrow_back_rounded,
            label: 'Back',
            onPressed: () => unawaited(_controller.back()),
          ),
        HarnessIconButton(
          icon: Icons.refresh_rounded,
          label: 'Refresh',
          onPressed: () => unawaited(_controller.refresh()),
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
              _stateCard(graph),
              if (_controller.error != null) ...[
                const SizedBox(height: HarnessSpace.md),
                Text(
                  _controller.error!,
                  style: HarnessText.caption(context)
                      .copyWith(color: Theme.of(context).colorScheme.error),
                ),
              ],
              if (graph != null && graph.ready) ..._views(graph),
            ],
          ),
        ),
      ),
    );
  }

  String _nodesLabel(WorkspaceGraph graph) {
    final count = _controller.view.kind == 'thread'
        ? graph.count
        : graph.blocks.length;
    return count == 1 ? '1 node' : '$count nodes';
  }

  Widget _stateCard(WorkspaceGraph? graph) {
    final ready = graph?.ready ?? false;
    final status = _state();
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
              Icons.hub_rounded,
              size: 23,
              color: HarnessColors.moss,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  ready ? graph!.pageName : status,
                  style: HarnessText.rowTitle(context),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 3),
                Text(
                  ready ? _place() : _why(graph),
                  style: HarnessText.caption(context),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          _chip(status),
        ],
      ),
    );
  }

  String _why(WorkspaceGraph? graph) {
    final why = graph?.why;
    if (why == null || why.isEmpty) return 'Logseq';
    return why;
  }

  List<Widget> _views(WorkspaceGraph graph) {
    return switch (_controller.view.kind) {
      'node' => _nodeView(graph),
      'page' => _pageView(graph),
      _ => _threadView(graph),
    };
  }

  List<Widget> _threadView(WorkspaceGraph graph) {
    final page = graph.page;
    return [
      const SizedBox(height: HarnessSpace.lg),
      if (page != null) ..._pageCard(page, showName: false),
      const SizedBox(height: HarnessSpace.lg),
      _section('Nodes'),
      if (graph.blocks.isEmpty)
        _empty('No nodes', 'An empty page')
      else
        for (final block in graph.blocks) _nodeCard(block),
      const SizedBox(height: HarnessSpace.lg),
      _section('Backlinks'),
      if (graph.backlinks.isEmpty)
        _empty('No backlinks', 'Not linked yet')
      else
        for (final block in graph.backlinks) _backlink(block),
    ];
  }

  List<Widget> _nodeView(WorkspaceGraph graph) {
    final block = graph.block;
    return [
      const SizedBox(height: HarnessSpace.lg),
      if (block == null)
        _empty('No node', 'Gone from the page')
      else ...[
        _nodeCard(block, openable: false),
        const SizedBox(height: HarnessSpace.lg),
        _section('Children'),
        if (graph.children.isEmpty)
          _empty('No children', 'A leaf node')
        else
          for (final child in graph.children) _nodeCard(child),
      ],
    ];
  }

  List<Widget> _pageView(WorkspaceGraph graph) {
    final page = graph.page;
    return [
      const SizedBox(height: HarnessSpace.lg),
      if (page == null)
        _empty('No page', 'Gone from the graph')
      else
        ..._pageCard(page),
      const SizedBox(height: HarnessSpace.lg),
      _section('Nodes'),
      if (graph.blocks.isEmpty)
        _empty('No nodes', 'An empty page')
      else
        for (final block in graph.blocks) _nodeCard(block),
      const SizedBox(height: HarnessSpace.lg),
      _section('Backlinks'),
      if (graph.backlinks.isEmpty)
        _empty('No backlinks', 'Not linked yet')
      else
        for (final block in graph.backlinks) _backlink(block),
    ];
  }

  List<Widget> _pageCard(WorkspaceGraphPage page, {bool showName = true}) {
    final pairs = page.properties.entries.toList();
    return [
      Container(
        padding: const EdgeInsets.all(HarnessSpace.lg),
        decoration: _cardDecoration(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (showName) ...[
              Text(page.name, style: HarnessText.rowTitle(context)),
              const SizedBox(height: 8),
            ],
            if (page.tags.isNotEmpty)
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [for (final tag in page.tags) _chip(tag)],
              ),
            if (pairs.isNotEmpty) ...[
              const SizedBox(height: 10),
              for (final pair in pairs) _property(pair.key, pair.value),
            ],
            if (page.links.isNotEmpty) ...[
              const SizedBox(height: 10),
              _linkRow('Links', page.links),
            ],
          ],
        ),
      ),
    ];
  }

  Widget _nodeCard(WorkspaceGraphBlock block, {bool openable = true}) {
    final card = Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: _cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _chip(block.roleLabel),
              if (block.at != null)
                Text(relativeTime(block.at!), style: HarnessText.meta(context)),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            block.display,
            style: HarnessText.body(context).copyWith(height: 1.45),
            maxLines: 8,
            overflow: TextOverflow.ellipsis,
          ),
          if (block.tags.isNotEmpty || block.links.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final tag in block.tags) _chip(tag),
                for (final link in block.links)
                  _pageLink(link, tooltip: 'The page in the graph'),
              ],
            ),
          ],
          for (final pair in block.properties.entries)
            if (pair.key != 'role' &&
                pair.key != 'workspace' &&
                pair.key != 'workspace-id')
              _property(pair.key, pair.value),
        ],
      ),
    );
    if (!openable || block.id.isEmpty) return card;
    return InkWell(
      key: ValueKey('graph-node-${block.id}'),
      onTap: () => unawaited(_controller.openNode(block.id)),
      child: card,
    );
  }

  Widget _backlink(WorkspaceGraphBlock block) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: _cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _chip(block.journal ? block.roleLabel : 'Page'),
              if (block.page.isNotEmpty)
                _pageLink(block.page, tooltip: 'The page in the graph'),
              if (block.at != null)
                Text(relativeTime(block.at!), style: HarnessText.meta(context)),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            block.display,
            style: HarnessText.caption(context),
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Widget _property(String name, String value) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 116,
            child: Text(
              name,
              style: HarnessText.meta(context),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: HarnessText.caption(context),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _linkRow(String label, List<String> links) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 116,
          child: Text(label, style: HarnessText.meta(context)),
        ),
        Expanded(
          child: Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              for (final link in links)
                _pageLink(link, tooltip: 'The page in the graph'),
            ],
          ),
        ),
      ],
    );
  }

  Widget _pageLink(String name, {String? tooltip}) {
    return Tooltip(
      message: tooltip ?? 'The page in the graph',
      child: InkWell(
        key: ValueKey('graph-page-$name'),
        onTap: () => unawaited(_controller.openPage(name)),
        child: Text(
          name,
          style: HarnessText.caption(context).copyWith(
            color: Theme.of(context).colorScheme.primary,
            decoration: TextDecoration.underline,
          ),
        ),
      ),
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

  Widget _empty(String title, String note) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(HarnessSpace.lg),
      decoration: _cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.hub_outlined,
            size: 24,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: HarnessSpace.sm),
          Text(title, style: HarnessText.rowTitle(context)),
          const SizedBox(height: 2),
          Text(note, style: HarnessText.caption(context)),
        ],
      ),
    );
  }

  BoxDecoration _cardDecoration() => BoxDecoration(
    color: Theme.of(context).colorScheme.surfaceContainerLow,
    borderRadius: BorderRadius.circular(2),
    border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
  );
}
