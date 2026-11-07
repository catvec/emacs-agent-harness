import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/workspace.dart';
import '../../state/app_controller.dart';
import '../../state/workspace_controller.dart';
import '../../services/voice_runtime.dart';
import '../../voice/voice_controller.dart';
import '../navigation.dart';
import '../adaptive/adaptive_widgets.dart';
import '../adaptive/layout_widgets.dart';
import '../theme/harness_theme.dart';
import '../widgets/message_composer.dart';
import '../widgets/vnc_takeover.dart';
import '../widgets/workspace_graph.dart';
import 'memory_screen.dart';
import 'resources_screen.dart';
import 'voice_screen.dart';

/// The persistent workspace: one chat over threads, its memory, and the
/// computer at its edge.
///
/// It is deliberately one page at every size.  A phone gets the chat and a
/// thread sheet; a tablet gets a rail; a desktop gets the rail, the chat and
/// the computer side by side, with the concept periphery between them.  The
/// chat never becomes a dashboard.
class WorkspaceScreen extends StatefulWidget {
  const WorkspaceScreen({
    super.key,
    required this.app,
    required this.onOpenSession,
    this.controller,
  });

  final AppController app;
  final ValueChanged<String> onOpenSession;

  /// A controller for the widget tests and the screenshot cases; the shell
  /// passes null and the screen follows [AppController.workspace].
  final WorkspaceController? controller;

  @override
  State<WorkspaceScreen> createState() => _WorkspaceScreenState();
}

class _WorkspaceScreenState extends State<WorkspaceScreen> {
  String? _lastMessageKey;
  final _scroll = ScrollController();

  WorkspaceController? get _controller => widget.controller ?? widget.app.workspace;

  @override
  void initState() {
    super.initState();
    _controller?.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _controller?.load(showSpinner: false);
      _scrollToEnd(immediate: true);
    });
  }

  @override
  void didUpdateWidget(WorkspaceScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final before = oldWidget.controller ?? oldWidget.app.workspace;
    final after = _controller;
    if (before != after) {
      before?.removeListener(_changed);
      after?.addListener(_changed);
    }
  }

  @override
  void dispose() {
    _controller?.removeListener(_changed);
    _scroll.dispose();
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    final entries = _controller?.visibleEntries ?? const <WorkspaceEntry>[];
    final key = entries.isEmpty
        ? ''
        : '${entries.length}:${entries.last.text.hashCode}';
    if (key != _lastMessageKey) {
      _lastMessageKey = key;
      _scrollToEnd();
    }
  }

  void _scrollToEnd({bool immediate = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final end = _scroll.position.maxScrollExtent;
      if (immediate || MediaQuery.maybeOf(context)?.disableAnimations == true) {
        _scroll.jumpTo(end);
      } else {
        _scroll.animateTo(
          end,
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutCubic,
        );
      }
    });
  }

  Future<void> _newThread() async {
    final title = await showDialog<String>(
      context: context,
      builder: (context) => _NewThreadDialog(),
    );
    if (title == null || title.trim().isEmpty) return;
    await _controller?.newThread(title.trim());
  }

  Future<void> _showThreads() async {
    final controller = _controller;
    if (controller == null) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => _ThreadsSheet(
        controller: controller,
        onPick: (thread) {
          controller.selectThread(thread.id);
          Navigator.of(context).pop();
        },
        onNew: () {
          Navigator.of(context).pop();
          unawaited(_newThread());
        },
      ),
    );
  }

  Future<void> _openCall() async {
    final live = _controller?.activeThread?.live;
    if (live == null) return;
    final session = await widget.app.openSessionById(live);
    if (!mounted || session == null) return;
    final bridge = SessionVoiceBridge(session);
    final voice = VoiceController(
      settings: widget.app.settings.voiceSettings,
      bridge: bridge,
      harnessAddress: widget.app.address ?? widget.app.settings.address,
      backendFactory: (settings, address) =>
          createVoiceBackend(settings, address, bridge),
      onSettingsChanged: widget.app.settings.setVoiceSettings,
    );
    if (!mounted) return;
    await Navigator.of(context).push(
      harnessRoute(context, (context) => VoiceScreen(controller: voice)),
    );
  }

  Future<void> _showComputer() async {
    final controller = _controller;
    if (controller == null) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => _ComputerSheet(
        controller: controller,
        onOpenResources: () {
          Navigator.of(context).pop();
          unawaited(_openResources());
        },
      ),
    );
  }

  Future<void> _openMemory() async {
    final workspace = _controller?.current;
    if (workspace == null) return;
    await Navigator.of(context).push(
      harnessRoute(
        context,
        (context) => MemoryScreen(app: widget.app, workspace: workspace),
      ),
    );
  }

  Future<void> _openResources() async {
    final workspace = _controller?.current;
    if (workspace == null) return;
    await Navigator.of(context).push(
      harnessRoute(
        context,
        (context) => ResourcesScreen(app: widget.app, workspace: workspace),
      ),
    );
  }

  void _openEpisode() {
    final session = _controller?.activeThread?.live;
    if (session != null) widget.onOpenSession(session);
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) {
      return const Center(child: HarnessActivity(radius: 10));
    }
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final workspace = controller.current;
        final thread = controller.activeThread;
        final compact = MediaQuery.sizeOf(context).width < 720;
        final actions = <Widget>[
          HarnessIconButton(
            icon: Icons.add_comment_outlined,
            label: 'New thread',
            onPressed: _newThread,
          ),
          HarnessIconButton(
            icon: Icons.list_alt_outlined,
            label: 'Threads',
            onPressed: _showThreads,
          ),
          if (thread?.live != null)
            HarnessIconButton(
              icon: Icons.call_outlined,
              label: 'Call',
              onPressed: _openCall,
            ),
          HarnessIconButton(
            icon: Icons.auto_awesome_outlined,
            label: 'Memory',
            onPressed: _openMemory,
          ),
          HarnessIconButton(
            icon: Icons.desktop_windows_outlined,
            label: 'Computer',
            onPressed: _showComputer,
          ),
          if (!compact) ...[
            if (thread?.live != null)
              HarnessIconButton(
                icon: Icons.open_in_new_rounded,
                label: 'Open episode',
                onPressed: _openEpisode,
              ),
            HarnessIconButton(
              icon: Icons.refresh_rounded,
              label: 'Refresh',
              onPressed: () => controller.reload(showSpinner: false),
            ),
          ],
        ];
        return HarnessPage(
          title: workspace?.name ?? 'Workspace',
          subtitle: _subtitle(context, controller, thread),
          actions: actions,
          body: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              if (width < 720) {
                return _compact(context, controller);
              }
              if (width < 1100) {
                return _medium(context, controller);
              }
              return _expanded(context, controller);
            },
          ),
        );
      },
    );
  }

  Widget _subtitle(
    BuildContext context,
    WorkspaceController controller,
    WorkspaceThread? thread,
  ) {
    final notes = controller.memory?.notes;
    return HarnessMetaLine(
      parts: [
        thread?.title,
        thread == null ? null : _stateWord(thread.state),
        notes == null ? null : '$notes notes',
        controller.selectedTag == null
            ? null
            : 'Tag · ${controller.selectedTag}',
      ],
      dropWhatDoesNotFit: true,
    );
  }

  String _stateWord(String state) => switch (state) {
    'live' => 'Live',
    'waiting' => 'Waiting',
    'done' => 'Done',
    _ => 'Parked',
  };

  Widget _compact(BuildContext context, WorkspaceController controller) {
    return Column(
      children: [
        if (controller.concepts.isNotEmpty)
          ConceptStrip(
            concepts: controller.concepts,
            selected: controller.selectedTag,
            onSelect: controller.selectTag,
          ),
        Expanded(
          child: _timeline(context, controller),
        ),
        _composer(context, controller),
      ],
    );
  }

  /// A column of the desktop layout, wider when the text is larger: a font
  /// at 150% needs a third more room for a thread's name before it is cut,
  /// and the chat keeps a readable width in what is left.
  double _grown(
    BuildContext context,
    double base,
    double perStep,
    double max,
  ) {
    final scale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 2.0);
    return (base + (scale - 1) * perStep).clamp(base, max);
  }

  Widget _medium(BuildContext context, WorkspaceController controller) {
    return Row(
      children: [
        _ThreadRail(
          controller: controller,
          width: _grown(context, 226, 60, 300),
          onNew: _newThread,
        ),
        VerticalDivider(
          width: 1,
          color: Theme.of(context).colorScheme.outlineVariant,
        ),
        Expanded(
          child: Column(
            children: [
              if (controller.concepts.isNotEmpty)
                ConceptStrip(
                  concepts: controller.concepts,
                  selected: controller.selectedTag,
                  onSelect: controller.selectTag,
                ),
              Expanded(child: _timeline(context, controller, maxWidth: 900)),
              _composer(context, controller, maxWidth: 900),
            ],
          ),
        ),
      ],
    );
  }

  Widget _expanded(BuildContext context, WorkspaceController controller) {
    final theme = Theme.of(context);
    final railWidth = _grown(context, 210, 70, 290);
    final conceptWidth = _grown(context, 120, 40, 170);
    final deskWidth = _grown(context, 330, 110, 460);
    return Row(
      children: [
        _ThreadRail(
          controller: controller,
          width: railWidth,
          onNew: _newThread,
        ),
        VerticalDivider(
          width: 1,
          color: theme.colorScheme.outlineVariant,
        ),
        Expanded(
          child: Column(
            children: [
              Expanded(child: _timeline(context, controller, maxWidth: 920)),
              _composer(context, controller, maxWidth: 920),
            ],
          ),
        ),
        if (controller.concepts.isNotEmpty) ...[
          VerticalDivider(
            width: 1,
            color: theme.colorScheme.outlineVariant,
          ),
          ConceptRail(
            concepts: controller.concepts,
            selected: controller.selectedTag,
            onSelect: controller.selectTag,
            width: conceptWidth,
          ),
        ],
        VerticalDivider(
          width: 1,
          color: theme.colorScheme.outlineVariant,
        ),
        SizedBox(
          width: deskWidth,
          child: _Desk(
            controller: controller,
            onOpenComputer: _showComputer,
            onOpenResources: _openResources,
          ),
        ),
      ],
    );
  }

  Widget _timeline(
    BuildContext context,
    WorkspaceController controller, {
    double? maxWidth,
  }) {
    final entries = controller.visibleEntries;
    Widget child;
    if (controller.loading && entries.isEmpty) {
      child = const Center(child: HarnessActivity(radius: 10));
    } else if (controller.error != null && entries.isEmpty) {
      child = _ErrorState(
        message: controller.error!,
        onRetry: () => controller.reload(),
      );
    } else if (controller.current == null) {
      child = _EmptyWorkspace(
        onCreate: () => controller.create('Home'),
      );
    } else if (entries.isEmpty) {
      child = const _EmptyTimeline();
    } else {
      child = ListView.builder(
        key: const PageStorageKey('workspace-timeline'),
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(
          HarnessSpace.gutter,
          HarnessSpace.lg,
          HarnessSpace.gutter,
          HarnessSpace.lg,
        ),
        itemCount: entries.length,
        itemBuilder: (context, index) {
          final entry = entries[index];
          return _EntryReveal(
            key: ValueKey('${entry.kind}:${entry.thread}:${entry.at}:${entry.text.hashCode}:$index'),
            child: _TimelineEntry(
              entry: entry,
              thread: _threadFor(controller, entry.thread),
            ),
          );
        },
      );
    }
    if (maxWidth == null) return child;
    return Align(
      alignment: AlignmentDirectional.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }

  WorkspaceThread? _threadFor(WorkspaceController controller, String id) {
    for (final thread in controller.threads) {
      if (thread.id == id) return thread;
    }
    return null;
  }

  Widget _composer(
    BuildContext context,
    WorkspaceController controller, {
    double? maxWidth,
  }) {
    final box = MessageComposer(
      drafts: widget.app.drafts,
      draftKey: 'workspace:${controller.current?.id}:${controller.selectedThread}',
      running: controller.sending,
      cancelling: false,
      canAttach: false,
      enabled: controller.current != null,
      hint: 'Workspace message',
      onSend: (text, attachments) {
        if (!controller.canSend) return false;
        unawaited(controller.send(text));
        return true;
      },
      onStop: () => unawaited(controller.cancel()),
    );
    final padded = Padding(
      padding: const EdgeInsets.fromLTRB(
        HarnessSpace.gutter,
        0,
        HarnessSpace.gutter,
        HarnessSpace.md,
      ),
      child: box,
    );
    if (maxWidth == null) return padded;
    return Align(
      alignment: AlignmentDirectional.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: padded,
      ),
    );
  }
}

class _ThreadRail extends StatelessWidget {
  const _ThreadRail({
    required this.controller,
    required this.width,
    required this.onNew,
    this.onPick,
  });

  final WorkspaceController controller;
  final double width;
  final VoidCallback onNew;
  final ValueChanged<WorkspaceThread>? onPick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final content = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              HarnessSpace.gutter,
              HarnessSpace.lg,
              HarnessSpace.sm,
              HarnessSpace.sm,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text('Threads', style: HarnessText.label(context)),
                ),
                HarnessIconButton(
                  icon: Icons.add_rounded,
                  label: 'New thread',
                  size: 18,
                  onPressed: onNew,
                ),
              ],
            ),
          ),
          if (controller.selectedTag != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                HarnessSpace.gutter,
                0,
                HarnessSpace.sm,
                HarnessSpace.sm,
              ),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: InputChip(
                  label: Text('Tag · ${controller.selectedTag}'),
                  onDeleted: () => controller.selectTag(null),
                  deleteIcon: const Icon(Icons.close_rounded, size: 15),
                  visualDensity: VisualDensity.compact,
                  side: BorderSide(color: theme.colorScheme.outlineVariant),
                  labelStyle: HarnessText.meta(context),
                ),
              ),
            ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: HarnessSpace.sm),
              children: [
                if (controller.shownThreads.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(HarnessSpace.gutter),
                    child: Text(
                      'No threads',
                      style: HarnessText.caption(context),
                    ),
                  ),
                for (final thread in controller.shownThreads)
                  _ThreadTile(
                    thread: thread,
                    selected: thread.id == controller.selectedThread,
                    onTap: () {
                      controller.selectThread(thread.id);
                      onPick?.call(thread);
                    },
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(HarnessSpace.gutter),
            child: Text(
              controller.memory == null
                  ? 'Memory · unavailable'
                  : 'Memory · ${controller.memory!.notes} notes',
              style: HarnessText.caption(context),
            ),
          ),
        ],
      );
    return width.isFinite ? SizedBox(width: width, child: content) : content;
  }
}

class _ThreadTile extends StatelessWidget {
  const _ThreadTile({
    required this.thread,
    required this.selected,
    required this.onTap,
  });

  final WorkspaceThread thread;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = switch (thread.state) {
      'waiting' => HarnessColors.amber,
      'live' => HarnessColors.moss,
      'done' => theme.colorScheme.outline,
      _ => theme.colorScheme.outlineVariant,
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Semantics(
        button: true,
        selected: selected,
        label: 'Thread ${thread.title}, ${thread.state}',
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            decoration: BoxDecoration(
              color: selected
                  ? theme.colorScheme.surfaceContainerHighest
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    thread.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: HarnessText.rowTitle(context).copyWith(
                      fontSize: 13.5,
                      color: selected
                          ? theme.colorScheme.onSurface
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                if (thread.pinned)
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: Icon(
                      Icons.push_pin_outlined,
                      size: 13,
                      color: theme.colorScheme.outline,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Desk extends StatelessWidget {
  const _Desk({
    required this.controller,
    required this.onOpenComputer,
    required this.onOpenResources,
  });

  final WorkspaceController controller;
  final VoidCallback onOpenComputer;
  final VoidCallback onOpenResources;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final computer = controller.computer;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            HarnessSpace.gutter,
            HarnessSpace.lg,
            HarnessSpace.gutter,
            HarnessSpace.sm,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text('Computer', style: HarnessText.label(context)),
              ),
              Text(
                computer.preview ? 'Preview' : 'Live',
                style: HarnessText.meta(context).copyWith(
                  color: computer.preview
                      ? HarnessColors.amber
                      : HarnessColors.moss,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              HarnessSpace.gutter,
              0,
              HarnessSpace.gutter,
              HarnessSpace.sm,
            ),
            child: VncTakeover(
              active: computer.userControl,
              available: computer.available,
              preview: computer.preview,
              onTakeOver: () => unawaited(controller.takeOver()),
              onReturnControl: () => unawaited(controller.returnControl()),
              child: const _ComputerPreview(),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            HarnessSpace.gutter,
            0,
            HarnessSpace.gutter,
            HarnessSpace.md,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                computer.preview
                    ? 'Sandbox staged · preview'
                    : computer.backend.isEmpty
                    ? 'Box running'
                    : 'Box · ${computer.backend}',
                style: HarnessText.caption(context),
              ),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 4,
                  children: [
                    HarnessTextButton(
                      label: 'Details',
                      onPressed: onOpenComputer,
                      dense: true,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Divider(height: 1, color: theme.colorScheme.outlineVariant),
      ],
    );
  }
}

class _ComputerPreview extends StatelessWidget {
  const _ComputerPreview();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
      ),
      child: Column(
        children: [
          Container(
            height: 34,
            padding: const EdgeInsets.symmetric(horizontal: 11),
            color: theme.colorScheme.surfaceContainerHigh,
            child: Row(
              children: [
                _Dot(color: theme.colorScheme.error),
                const SizedBox(width: 5),
                _Dot(color: HarnessColors.amber),
                const SizedBox(width: 5),
                _Dot(color: HarnessColors.moss),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'stoneco.example/quote',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: HarnessText.mono(context).copyWith(
                      fontSize: 11,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Stone Co — Countertop quote',
                    style: HarnessText.rowTitle(context).copyWith(fontSize: 14),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    'Quartz · 2cm edge · template Tuesday',
                    style: HarnessText.caption(context),
                  ),
                  const SizedBox(height: 14),
                  Container(
                    height: 8,
                    width: 150,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.outlineVariant,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    height: 8,
                    width: 106,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.outlineVariant.withValues(alpha: 0.7),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    'Quote · 5,800 · template Tuesday',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 7,
      height: 7,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

class _TimelineEntry extends StatelessWidget {
  const _TimelineEntry({required this.entry, this.thread});

  final WorkspaceEntry entry;
  final WorkspaceThread? thread;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (entry.isDivider) {
      final word = switch (entry.reason) {
        'revived' => 'Resumed',
        'long-context' => 'Continued',
        _ => 'New thread',
      };
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: HarnessSpace.lg),
        child: Row(
          children: [
            const Expanded(child: Divider()),
            Flexible(
              flex: 5,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Text(
                  '$word · ${thread?.title ?? entry.title}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: HarnessText.caption(context),
                ),
              ),
            ),
            const Expanded(child: Divider()),
          ],
        ),
      );
    }
    if (entry.isBrief) {
      return Padding(
        padding: const EdgeInsets.only(bottom: HarnessSpace.lg),
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: theme.colorScheme.outlineVariant),
            ),
            child: Text(
              'Brief · ${entry.tokens} tokens',
              style: HarnessText.caption(context),
            ),
          ),
        ),
      );
    }
    final agent = entry.isAgent;
    final label = agent ? 'Agent' : 'You';
    final body = Text(
      entry.text,
      style: HarnessText.body(context).copyWith(height: 1.5),
    );
    final bubble = Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 11, 14, 12),
      decoration: BoxDecoration(
        color: agent
            ? Colors.transparent
            : theme.colorScheme.surfaceContainerHigh,
        border: Border(
          left: BorderSide(
            color: agent ? HarnessColors.moss : theme.colorScheme.primary,
            width: 2,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: HarnessText.label(context).copyWith(
              color: agent ? HarnessColors.moss : theme.colorScheme.primary,
            ),
          ),
          const SizedBox(height: 4),
          body,
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: HarnessSpace.lg),
      child: bubble,
    );
  }
}

class _EntryReveal extends StatefulWidget {
  const _EntryReveal({super.key, required this.child});

  final Widget child;

  @override
  State<_EntryReveal> createState() => _EntryRevealState();
}

class _EntryRevealState extends State<_EntryReveal>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 280),
  )..forward();
  late final Animation<double> _fade = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.maybeOf(context)?.disableAnimations ?? false) {
      return widget.child;
    }
    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.025),
          end: Offset.zero,
        ).animate(_fade),
        child: widget.child,
      ),
    );
  }
}

class _EmptyTimeline extends StatelessWidget {
  const _EmptyTimeline();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(HarnessSpace.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.forum_outlined,
              size: 32,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: HarnessSpace.md),
            Text('No messages', style: HarnessText.subtitle(context)),
          ],
        ),
      ),
    );
  }
}

class _EmptyWorkspace extends StatelessWidget {
  const _EmptyWorkspace({required this.onCreate});

  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(HarnessSpace.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.workspaces_outline,
              size: 36,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: HarnessSpace.md),
            Text('No workspace', style: HarnessText.subtitle(context)),
            const SizedBox(height: HarnessSpace.xs),
            Text(
              'One chat, its threads and its memory',
              style: HarnessText.caption(context),
            ),
            const SizedBox(height: HarnessSpace.lg),
            FilledButton.tonal(
              onPressed: onCreate,
              child: const Text('New workspace'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(HarnessSpace.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_off_outlined,
              size: 32,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: HarnessSpace.md),
            Text('Workspace unavailable', style: HarnessText.subtitle(context)),
            const SizedBox(height: HarnessSpace.xs),
            Text(
              message,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: HarnessText.caption(context),
            ),
            const SizedBox(height: HarnessSpace.lg),
            HarnessTextButton(label: 'Retry', onPressed: onRetry),
          ],
        ),
      ),
    );
  }
}

class _ThreadsSheet extends StatelessWidget {
  const _ThreadsSheet({
    required this.controller,
    required this.onPick,
    required this.onNew,
  });

  final WorkspaceController controller;
  final ValueChanged<WorkspaceThread> onPick;
  final VoidCallback onNew;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.58,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                HarnessSpace.sheetGutter,
                0,
                HarnessSpace.sm,
                HarnessSpace.sm,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text('Threads', style: HarnessText.sheetTitle(context)),
                  ),
                  HarnessTextButton(
                    label: 'New thread',
                    icon: Icons.add_rounded,
                    onPressed: onNew,
                  ),
                ],
              ),
            ),
            Expanded(
              child: _ThreadRail(
                controller: controller,
                width: double.infinity,
                onNew: onNew,
                onPick: onPick,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ComputerSheet extends StatelessWidget {
  const _ComputerSheet({
    required this.controller,
    required this.onOpenResources,
  });

  final WorkspaceController controller;
  final VoidCallback onOpenResources;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final computer = controller.computer;
        return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          HarnessSpace.sheetGutter,
          0,
          HarnessSpace.sheetGutter,
          HarnessSpace.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('Computer', style: HarnessText.sheetTitle(context)),
                ),
                Text(
                  computer.preview ? 'Preview' : 'Live',
                  style: HarnessText.meta(context),
                ),
              ],
            ),
            const SizedBox(height: HarnessSpace.md),
            SizedBox(
              height: 300,
              child: VncTakeover(
                active: computer.userControl,
                available: computer.available,
                preview: computer.preview,
                onTakeOver: () => unawaited(controller.takeOver()),
                onReturnControl: () => unawaited(controller.returnControl()),
                child: const _ComputerPreview(),
              ),
            ),
            const SizedBox(height: HarnessSpace.md),
            Text(
              computer.preview
                  ? 'Sandbox staged · preview'
                  : computer.backend.isEmpty
                  ? 'Box running'
                  : 'Box · ${computer.backend}',
              style: HarnessText.caption(context),
            ),
            const SizedBox(height: HarnessSpace.sm),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: HarnessTextButton(
                label: 'Resources',
                icon: Icons.inventory_2_outlined,
                onPressed: onOpenResources,
              ),
            ),
          ],
        ),
      ),
    );
      },
    );
  }
}

class _NewThreadDialog extends StatefulWidget {
  @override
  State<_NewThreadDialog> createState() => _NewThreadDialogState();
}

class _NewThreadDialogState extends State<_NewThreadDialog> {
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New thread'),
      content: TextField(
        controller: _text,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Thread title'),
        onSubmitted: (value) => Navigator.of(context).pop(value),
      ),
      actions: [
        HarnessTextButton(
          label: 'Cancel',
          onPressed: () => Navigator.of(context).pop(),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_text.text),
          child: const Text('Create'),
        ),
      ],
    );
  }
}
