import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../models/resources.dart';
import '../../models/workspace.dart';
import '../../state/app_controller.dart';
import '../../state/session_controller.dart';
import '../../state/workspace_buddy_controller.dart';
import '../../state/workspace_controller.dart';
import '../../services/voice_runtime.dart';
import '../../voice/voice_controller.dart';
import '../../vnc/rfb.dart';
import '../../vnc/vnc_view.dart';
import '../../vnc/websocket_transport.dart';
import '../navigation.dart';
import '../adaptive/adaptive_widgets.dart';
import '../adaptive/layout_widgets.dart';
import '../theme/harness_theme.dart';
import '../widgets/interaction_card.dart';
import '../widgets/markdown_view.dart';
import '../widgets/message_composer.dart';
import '../widgets/workspace_buddy.dart';
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
    this.vncTransportFactory,
  });

  final AppController app;
  final ValueChanged<String> onOpenSession;

  /// A controller for the widget tests and the screenshot cases; the shell
  /// passes null and the screen follows [AppController.workspace].
  final WorkspaceController? controller;

  /// Where the RFB bytes come from.  The app leaves it null and opens the
  /// endpoint's WebSocket; a test hands it a transport of its own, so the
  /// picture is still decoded by the real client.
  final RfbTransport Function(String url)? vncTransportFactory;

  @override
  State<WorkspaceScreen> createState() => _WorkspaceScreenState();
}

class _WorkspaceScreenState extends State<WorkspaceScreen> {
  String? _lastMessageKey;
  final _scroll = ScrollController();
  bool _unread = false;
  _FailedSend? _failed;
  bool _retrying = false;
  final _composerText = TextEditingController();

  /// Whether the desktop desk is folded to its rail.  The chat takes the
  /// room the screen had, and the rail keeps the way back.
  bool _deskHidden = false;

  /// The conversation of the active thread's live episode: its requests are
  /// the cards above the composer, answered the way a chat answers them.
  SessionController? _pending;
  String? _pendingLive;
  bool _wasConnected = false;

  WorkspaceController? get _controller =>
      widget.controller ?? widget.app.workspace;

  WorkspaceBuddyController? get _buddy => widget.app.workspaceBuddy;

  @override
  void initState() {
    super.initState();
    _controller?.addListener(_changed);
    widget.app.addListener(_onAppChanged);
    _wasConnected = widget.app.isConnected;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _controller?.load(showSpinner: false);
      _syncPending(_controller?.activeThread?.live);
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
    if (oldWidget.app != widget.app) {
      oldWidget.app.removeListener(_onAppChanged);
      widget.app.addListener(_onAppChanged);
      _detachPending();
      _wasConnected = widget.app.isConnected;
    }
  }

  @override
  void dispose() {
    widget.app.removeListener(_onAppChanged);
    _detachPending();
    _controller?.removeListener(_changed);
    _scroll.dispose();
    _composerText.dispose();
    super.dispose();
  }

  /// The conversation of the live episode [live], when this screen may read
  /// one: a preview or a disconnected app has no harness to ask.
  bool get _mayReadSessions =>
      widget.app.harness != null && widget.app.isConnected;

  void _syncPending(String? live) {
    if (live == _pendingLive) {
      if (live == null || _pending != null || !_mayReadSessions) return;
    }
    _detachPending();
    _pendingLive = live;
    if (live == null || !_mayReadSessions) return;
    final session = widget.app.sessionController(live);
    _pending = session;
    session.addListener(_onPendingChanged);
    unawaited(session.refreshPending());
  }

  void _detachPending() {
    _pending?.removeListener(_onPendingChanged);
    _pending = null;
    _pendingLive = null;
  }

  void _onPendingChanged() {
    if (mounted) setState(() {});
  }

  void _onAppChanged() {
    if (!mounted) return;
    final connected = widget.app.isConnected;
    if (connected && !_wasConnected && _pending != null) {
      // The requests the connection went away with are read again.
      unawaited(_pending!.refreshPending());
    }
    _wasConnected = connected;
    _syncPending(_controller?.activeThread?.live);
    setState(() {});
  }

  void _changed() {
    if (!mounted) return;
    _syncPending(_controller?.activeThread?.live);
    final nearBottom = _scroll.hasClients &&
        (_scroll.position.maxScrollExtent - _scroll.position.pixels) < 80;
    final entries = _controller?.visibleEntries ?? const <WorkspaceEntry>[];
    final pending = _pending?.currentInteraction ?? _controller?.previewRequest;
    final pendingKey = pending == null
        ? ''
        : '${pending.method}:${pending.harnessId}:${pending.title}';
    final key = entries.isEmpty
        ? ':$pendingKey'
        : '${entries.length}:${entries.last.text.length}:$pendingKey';
    final grew = key != _lastMessageKey;
    _lastMessageKey = key;
    setState(() {
      if (grew) _unread = !nearBottom;
    });
    _restoreFailedDraft();
    if (grew && nearBottom) _scrollToEnd();
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

  String _threadTitle(WorkspaceController controller, String? id) {
    for (final thread in controller.threads) {
      if (thread.id == id) return thread.title;
    }
    return id ?? 'Workspace';
  }

  /// Restore the failed text into the field, but never over something the
  /// person has typed since, and only while its own thread is open.
  void _restoreFailedDraft() {
    final failed = _failed;
    final controller = _controller;
    if (failed == null || controller == null) return;
    if (controller.selectedThread != failed.thread) return;
    if (_composerText.text.isNotEmpty) return;
    _composerText.value = TextEditingValue(
      text: failed.text,
      selection: TextSelection.collapsed(offset: failed.text.length),
    );
  }

  void _retryFailed(WorkspaceController controller) {
    final failed = _failed;
    if (failed == null || _retrying || controller.sending) return;
    setState(() => _retrying = true);
    unawaited(
      controller.send(failed.text, thread: failed.thread).then((sent) {
        if (!mounted) return;
        setState(() {
          _retrying = false;
          if (sent) {
            _failed = null;
            if (_composerText.text.trim() == failed.text.trim()) {
              _composerText.clear();
            }
          }
        });
      }),
    );
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
    // One workspace call, whatever the buddy's opt-in: the in-call bar
    // shows it and the full call view is the same call, not a second one.
    // A workspace call that has nothing to open with (no connection, no
    // voice setup) leaves Call to the screen that owns its own call and
    // shows its setup or failure, as it did before.
    final buddy = widget.app.workspaceBuddy;
    if (buddy != null && (buddy.inCall || buddy.canStart)) {
      if (!buddy.inCall) {
        await buddy.start();
        if (!mounted) return;
      }
      if (buddy.voice == null) return;
      await openWorkspaceCallView(
        context: context,
        navigator: Navigator.of(context),
        buddy: buddy,
      );
      return;
    }
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
    await Navigator.of(
      context,
    ).push(harnessRoute(context, (context) => VoiceScreen(controller: voice)));
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
        harnessAddress: widget.app.address ?? widget.app.settings.address,
        harnessToken: widget.app.sessionSecret,
        vncTransportFactory: widget.vncTransportFactory,
        onOpenDetails: () {
          Navigator.of(context).pop();
          unawaited(_showComputerDetails());
        },
        onOpenResources: () {
          Navigator.of(context).pop();
          unawaited(_openResources());
        },
      ),
    );
  }

  /// The computer's details: what the box is, not its screen again.
  Future<void> _showComputerDetails() async {
    final controller = _controller;
    if (controller == null) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => _ComputerDetailsSheet(
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
        final buddy = _buddy;
        final buddyHere =
            buddy != null &&
            workspace != null &&
            MediaQuery.sizeOf(context).width >= 920;
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
          if (buddyHere) _BuddyAction(buddy: buddy),
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
        thread?.statusLabel,
        notes == null ? null : '$notes notes',
        controller.selectedTag == null
            ? null
            : 'Tag · ${controller.selectedTag}',
      ],
      dropWhatDoesNotFit: true,
    );
  }

  Widget _compact(BuildContext context, WorkspaceController controller) {
    final thread = controller.activeThread;
    return Column(
      children: [
        if (controller.concepts.isNotEmpty)
          ConceptStrip(
            concepts: controller.concepts,
            selected: controller.selectedTag,
            onSelect: controller.selectTag,
          ),
        // A phone's header has no room for the subtitle: the episode says
        // what it is doing above its chat instead, where it cannot fall off.
        if (thread != null && thread.live != null)
          _compactStatus(context, thread),
        Expanded(
          child: _timeline(context, controller),
        ),
        _pendingCard(context, controller),
        _composer(context, controller),
      ],
    );
  }

  Widget _compactStatus(BuildContext context, WorkspaceThread thread) {
    final color = _threadStatusColor(thread, Theme.of(context));
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        HarnessSpace.gutter,
        2,
        HarnessSpace.gutter,
        0,
      ),
      child: Row(
        children: [
          HarnessDot(color: color, size: 7),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              thread.statusLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: HarnessText.meta(context).copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }

  /// A column of the desktop layout, wider when the text is larger: a font
  /// at 150% needs a third more room for a thread's name before it is cut,
  /// and the chat keeps a readable width in what is left.
  double _grown(BuildContext context, double base, double perStep, double max) {
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
              _pendingCard(context, controller, maxWidth: 900),
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
        VerticalDivider(width: 1, color: theme.colorScheme.outlineVariant),
        Expanded(
          child: Column(
            children: [
              Expanded(child: _timeline(context, controller, maxWidth: 920)),
              _pendingCard(context, controller, maxWidth: 920),
              _composer(context, controller, maxWidth: 920),
            ],
          ),
        ),
        if (controller.concepts.isNotEmpty) ...[
          VerticalDivider(width: 1, color: theme.colorScheme.outlineVariant),
          ConceptRail(
            concepts: controller.concepts,
            selected: controller.selectedTag,
            onSelect: controller.selectTag,
            width: conceptWidth,
          ),
        ],
        VerticalDivider(width: 1, color: theme.colorScheme.outlineVariant),
        if (_deskHidden)
          _DeskRail(
            controller: controller,
            width: _grown(context, 56, 16, 72),
            onShow: () => setState(() => _deskHidden = false),
            onOpenDetails: _showComputerDetails,
          )
        else
          SizedBox(
            width: deskWidth,
            child: _Desk(
              controller: controller,
              onOpenDetails: _showComputerDetails,
              onHide: () => setState(() => _deskHidden = true),
              onOpenResources: _openResources,
              harnessAddress: widget.app.address ?? widget.app.settings.address,
              harnessToken: widget.app.sessionSecret,
              vncTransportFactory: widget.vncTransportFactory,
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
      child = _EmptyWorkspace(onCreate: () => controller.create('Home'));
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
            // A streamed message keeps its element while its text grows:
            // the reveal plays once, not again on every chunk.  A streamed
            // reply is keyed by its node; anything else by its time.
            key: ValueKey(
              entry.node.isEmpty
                  ? '${entry.kind}:${entry.thread}:'
                      '${entry.at?.toIso8601String() ?? 'at-$index'}'
                  : '${entry.kind}:${entry.thread}:${entry.node}',
            ),
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

  /// The card of what the active thread's live episode waits on, above the
  /// composer: a permission prompt or a question, answered here with the
  /// same card a conversation uses.  A card is bound to the request it was
  /// built for and to the conversation that showed it; a tap after a thread
  /// switch, an episode change or an answer elsewhere does nothing.
  Widget _pendingCard(
    BuildContext context,
    WorkspaceController controller, {
    double? maxWidth,
  }) {
    final live = controller.activeThread?.live;
    final session = live != null && live == _pendingLive ? _pending : null;
    final request =
        session?.currentInteraction ??
        (session == null ? controller.previewRequestFor(live) : null);
    if (request == null) return const SizedBox.shrink();
    Future<void> none() => Future<void>.value();
    final card = PendingActionCard(
      key: ValueKey(
        '${controller.current?.id}:${controller.activeThread?.id}:'
        '${pendingRequestKey(request)}',
      ),
      request: request,
      onPermission: (optionId, {pattern}) {
        if (session == null) {
          controller.resolvePreview(request);
          return none();
        }
        if (!identical(session, _pending) ||
            !identical(session.currentInteraction, request)) {
          return none();
        }
        return session.answerPermission(optionId, pattern: pattern);
      },
      onQuestion: (answer) {
        if (session == null) {
          controller.resolvePreview(request);
          return none();
        }
        if (!identical(session, _pending) ||
            !identical(session.currentInteraction, request)) {
          return none();
        }
        return session.answerQuestion(answer);
      },
      onDismissPermission: () {
        if (session == null) {
          controller.resolvePreview(request);
          return none();
        }
        if (!identical(session, _pending) ||
            !identical(session.currentInteraction, request)) {
          return none();
        }
        return session.dismissPermission();
      },
      onCancelQuestion: () {
        if (session == null) {
          controller.resolvePreview(request);
          return none();
        }
        if (!identical(session, _pending) ||
            !identical(session.currentInteraction, request)) {
          return none();
        }
        return session.cancelQuestion();
      },
      questionImage: (index) {
        if (session == null || !identical(session, _pending)) {
          return Future<Uint8List?>.value();
        }
        return session.questionImage(index);
      },
    );
    // A request may be answered on any size; the card scrolls inside this
    // room rather than push the composer out of the window or under the
    // keyboard.
    final room = MediaQuery.sizeOf(context).height -
        MediaQuery.viewInsetsOf(context).bottom;
    final padded = Padding(
      padding: const EdgeInsets.fromLTRB(
        HarnessSpace.gutter,
        0,
        HarnessSpace.gutter,
        0,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: (room * 0.34).clamp(140.0, 340.0)),
        child: Align(
          alignment: AlignmentDirectional.topCenter,
          child: card,
        ),
      ),
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

  Widget _composer(
    BuildContext context,
    WorkspaceController controller, {
    double? maxWidth,
  }) {
    final box = MessageComposer(
      drafts: widget.app.drafts,
      draftKey:
          'workspace:${controller.current?.id}:${controller.selectedThread}',
      running: controller.sending,
      cancelling: false,
      canAttach: false,
      enabled: controller.current != null,
      hint: 'Workspace message',
      textController: _composerText,
      onSend: (text, attachments) {
        if (!controller.canSend) return false;
        final origin = controller.selectedThread ?? controller.activeThread?.id;
        unawaited(
          controller.send(text, thread: origin).then((sent) {
            if (!mounted) return;
            setState(() {
              if (sent) {
                if (_failed?.text == text && _failed?.thread == origin) {
                  _failed = null;
                }
                _unread = false;
              } else {
                _failed ??= _FailedSend(text, origin);
              }
            });
            if (sent) {
              _scrollToEnd(immediate: true);
            } else {
              _restoreFailedDraft();
            }
          }),
        );
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
    final column = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (controller.error != null && _failed != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: HarnessSpace.gutter),
            child: Row(
              children: [
                Expanded(
                  child: Tooltip(
                    message: controller.error!,
                    child: Text(
                      'Send failed · ${_threadTitle(controller, _failed!.thread)}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: HarnessText.caption(context).copyWith(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                ),
                HarnessTextButton(
                  label: _retrying ? 'Sending…' : 'Retry',
                  dense: true,
                  onPressed: _retrying ? null : () => _retryFailed(controller),
                ),
              ],
            ),
          ),
        if (_unread)
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: Padding(
              padding: const EdgeInsets.only(right: HarnessSpace.gutter),
              child: HarnessTextButton(
                label: 'Latest',
                icon: Icons.arrow_downward_rounded,
                dense: true,
                onPressed: () {
                  setState(() => _unread = false);
                  _scrollToEnd(immediate: true);
                },
              ),
            ),
          ),
        padded,
      ],
    );
    if (maxWidth == null) return column;
    return Align(
      alignment: AlignmentDirectional.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: column,
      ),
    );
  }
}

/// The workspace-scoped opt-in.  On a desktop the buddy is this workspace's
/// call surface; turning it on shows the compact card and starts no call.
class _BuddyAction extends StatefulWidget {
  const _BuddyAction({required this.buddy});

  final WorkspaceBuddyController buddy;

  @override
  State<_BuddyAction> createState() => _BuddyActionState();
}

class _BuddyActionState extends State<_BuddyAction> {
  final FocusNode _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedBuilder(
      animation: widget.buddy,
      builder: (context, _) {
        final on = widget.buddy.enabled;
        final tooltip = on ? 'Workspace buddy · on' : 'Workspace buddy · off';
        return Tooltip(
          message: tooltip,
          child: Semantics(
            container: true,
            button: true,
            toggled: on,
            label: 'Buddy',
            tooltip: tooltip,
            onTap: () => unawaited(widget.buddy.toggle()),
            onFocus: () => _focus.requestFocus(),
            focusable: true,
            excludeSemantics: true,
            child: IconButton(
              key: const Key('workspace-buddy-action'),
              focusNode: _focus,
              onPressed: () => unawaited(widget.buddy.toggle()),
              tooltip: null,
              icon: Icon(
                on
                    ? Icons.record_voice_over_rounded
                    : Icons.record_voice_over_outlined,
                size: 22,
                color: on ? theme.colorScheme.primary : null,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _FailedSend {
  const _FailedSend(this.text, this.thread);
  final String text;
  final String? thread;
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

/// The colour a thread's state shows in, in its row and on a phone's status
/// line.
Color _threadStatusColor(WorkspaceThread thread, ThemeData theme) =>
    switch (thread.statusKey) {
      'running' => HarnessColors.moss,
      'live' => HarnessColors.moss,
      'blocked' => HarnessColors.amber,
      'stopped' => HarnessColors.amber,
      'idle' => HarnessColors.moss.withValues(alpha: 0.55),
      'failed' => theme.colorScheme.error,
      'inactive' || 'done' => theme.colorScheme.outline,
      _ => theme.colorScheme.outlineVariant,
    };

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
    final color = _threadStatusColor(thread, theme);
    final showsStatus =
        thread.statusKey != 'parked' && thread.statusKey != 'done';
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Semantics(
        button: true,
        selected: selected,
        label: 'Thread ${thread.title}, ${thread.statusLabel}',
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
                if (showsStatus)
                  Padding(
                    padding: const EdgeInsets.only(left: 5),
                    child: Text(
                      thread.statusWord,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: HarnessText.meta(context).copyWith(
                        fontSize: 10.5,
                        color: color,
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

String _computerStateLabel(WorkspaceComputerStatus computer) {
  if (computer.live) return 'Live';
  if (computer.starting) return 'Starting';
  return 'Off';
}

Color _computerStateColor(
  BuildContext context,
  WorkspaceComputerStatus computer,
) {
  if (computer.live) return HarnessColors.moss;
  if (computer.starting) return HarnessColors.amber;
  return Theme.of(context).colorScheme.outline;
}

String _computerFooter(WorkspaceComputerStatus computer) {
  if (computer.live) {
    return computer.backend.isEmpty
        ? 'Box running'
        : 'Box · ${computer.backend}';
  }
  return computer.reason ?? 'Computer off';
}

class _Desk extends StatelessWidget {
  const _Desk({
    required this.controller,
    required this.onOpenDetails,
    required this.onHide,
    required this.onOpenResources,
    required this.harnessAddress,
    required this.harnessToken,
    this.vncTransportFactory,
  });

  final WorkspaceController controller;
  final VoidCallback onOpenDetails;
  final VoidCallback onHide;
  final VoidCallback onOpenResources;
  final String? harnessAddress;
  final String harnessToken;
  final RfbTransport Function(String url)? vncTransportFactory;

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
            HarnessSpace.sm,
            HarnessSpace.sm,
            0,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text('Computer', style: HarnessText.label(context)),
              ),
              Text(
                _computerStateLabel(computer),
                style: HarnessText.meta(context)
                    .copyWith(color: _computerStateColor(context, computer)),
              ),
              HarnessIconButton(
                icon: Icons.keyboard_double_arrow_right_rounded,
                label: 'Hide computer',
                size: 18,
                onPressed: onHide,
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
            child: _ComputerWindow(
              controller: controller,
              harnessAddress: harnessAddress,
              harnessToken: harnessToken,
              vncTransportFactory: vncTransportFactory,
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
                _computerFooter(computer),
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
                      onPressed: onOpenDetails,
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

/// The folded desk: the way back, and the details, on a narrow rail where
/// the screen was.  The chat keeps the rest.
class _DeskRail extends StatelessWidget {
  const _DeskRail({
    required this.controller,
    required this.width,
    required this.onShow,
    required this.onOpenDetails,
  });

  final WorkspaceController controller;
  final double width;
  final VoidCallback onShow;
  final VoidCallback onOpenDetails;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final computer = controller.computer;
    return Container(
      width: width,
      color: theme.colorScheme.surfaceContainerLow,
      child: Column(
        children: [
          const SizedBox(height: HarnessSpace.sm),
          HarnessIconButton(
            icon: Icons.desktop_windows_outlined,
            label: 'Show computer',
            size: 20,
            onPressed: onShow,
          ),
          const SizedBox(height: HarnessSpace.xs),
          HarnessDot(color: _computerStateColor(context, computer), size: 7),
          Expanded(
            child: Center(
              child: RotatedBox(
                quarterTurns: 3,
                child: Text(
                  'Computer · ${_computerStateLabel(computer)}',
                  maxLines: 1,
                  overflow: TextOverflow.fade,
                  style: HarnessText.label(context),
                ),
              ),
            ),
          ),
          HarnessIconButton(
            icon: Icons.info_outline_rounded,
            label: 'Details',
            size: 18,
            onPressed: onOpenDetails,
          ),
          const SizedBox(height: HarnessSpace.md),
        ],
      ),
    );
  }
}

/// The computer's screen: the box's RFB stream, or an honest empty state
/// when there is no box.  A test can hand it a transport, but the widget
/// still decodes whatever that transport carries with the real client.
class _ComputerWindow extends StatefulWidget {
  const _ComputerWindow({
    required this.controller,
    this.harnessAddress,
    this.harnessToken = '',
    this.vncTransportFactory,
  });

  final WorkspaceController controller;
  final String? harnessAddress;
  final String harnessToken;
  final RfbTransport Function(String url)? vncTransportFactory;

  @override
  State<_ComputerWindow> createState() => _ComputerWindowState();
}

class _ComputerWindowState extends State<_ComputerWindow> {
  int _generation = 0;
  String? _socket;
  RfbTransport? _transport;
  int _transportGeneration = -1;
  bool _lost = false;

  @override
  void didUpdateWidget(_ComputerWindow oldWidget) {
    super.didUpdateWidget(oldWidget);
    final socket = oldWidget.controller.computer.socket;
    final next = widget.controller.computer.socket;
    if (socket != next) {
      _generation++;
      _lost = false;
    }
  }

  RfbTransport? _transportFor(String socket) {
    if (_socket != socket) {
      _socket = socket;
      _generation++;
      _transport = null;
      _transportGeneration = -1;
      _lost = false;
    }
    if (_transport == null || _transportGeneration != _generation) {
      final resolved = VncEndpoint.resolve(socket, widget.harnessAddress);
      if (resolved == null) return null;
      final factory = widget.vncTransportFactory;
      _transport = factory != null
          ? factory(resolved)
          : WebSocketTransport.connect(resolved, token: widget.harnessToken);
      _transportGeneration = _generation;
    }
    return _transport;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final computer = widget.controller.computer;
    if (computer.live && computer.socket != null) {
      final transport = _transportFor(computer.socket!);
      if (transport != null) {
        return VncTakeover(
          active: computer.userControl,
          available: true,
          preview: false,
          onTakeOver: () => unawaited(widget.controller.takeOver()),
          onReturnControl: () => unawaited(widget.controller.returnControl()),
          child: Stack(
            fit: StackFit.expand,
            children: [
              VncView(
                key: ValueKey('workspace-vnc-$_generation'),
                transport: transport,
                enabled: computer.userControl && !_lost,
                onLost: (_) {
                  if (mounted && !_lost) setState(() => _lost = true);
                },
              ),
              if (_lost)
                Positioned(
                  left: 12,
                  right: 12,
                  bottom: 60,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.62),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 7,
                      ),
                      child: Text(
                        'Screen lost',
                        textAlign: TextAlign.center,
                        style: HarnessText.caption(context)
                            .copyWith(color: Colors.white),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      }
    }
    final starting = computer.starting;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(HarnessSpace.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (starting) ...[
                const HarnessActivity(radius: 10),
                const SizedBox(height: 12),
                Text('Starting', style: HarnessText.rowTitle(context)),
              ] else ...[
                Icon(
                  Icons.desktop_windows_outlined,
                  size: 30,
                  color: theme.colorScheme.outline,
                ),
                const SizedBox(height: 8),
                Text('Computer off', style: HarnessText.rowTitle(context)),
                if (computer.reason != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    computer.reason!,
                    textAlign: TextAlign.center,
                    style: HarnessText.caption(context),
                  ),
                ],
                const SizedBox(height: 12),
                HarnessPill(
                  label: 'Start',
                  icon: Icons.play_arrow_rounded,
                  onTap: () => unawaited(widget.controller.startComputer()),
                ),
              ],
            ],
          ),
        ),
      ),
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
    final body = HarnessMarkdown(
      text: entry.text,
      compact: true,
      tight: true,
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
                    child: Text(
                      'Threads',
                      style: HarnessText.sheetTitle(context),
                    ),
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
    required this.onOpenDetails,
    required this.onOpenResources,
    this.harnessAddress,
    this.harnessToken = '',
    this.vncTransportFactory,
  });

  final WorkspaceController controller;
  final VoidCallback onOpenDetails;
  final VoidCallback onOpenResources;
  final String? harnessAddress;
  final String harnessToken;
  final RfbTransport Function(String url)? vncTransportFactory;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final computer = controller.computer;
        return SafeArea(
          key: const ValueKey('computer-screen-sheet'),
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
                      child: Text(
                        'Computer',
                        style: HarnessText.sheetTitle(context),
                      ),
                    ),
                    Text(
                      _computerStateLabel(computer),
                      style: HarnessText.meta(context).copyWith(
                        color: _computerStateColor(context, computer),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: HarnessSpace.md),
                SizedBox(
                  height: 300,
                  child: _ComputerWindow(
                    controller: controller,
                    harnessAddress: harnessAddress,
                    harnessToken: harnessToken,
                    vncTransportFactory: vncTransportFactory,
                  ),
                ),
                const SizedBox(height: HarnessSpace.md),
                Text(
                  _computerFooter(computer),
                  style: HarnessText.caption(context),
                ),
                const SizedBox(height: HarnessSpace.sm),
                Wrap(
                  spacing: HarnessSpace.sm,
                  runSpacing: HarnessSpace.sm,
                  children: [
                    HarnessTextButton(
                      label: 'Details',
                      icon: Icons.info_outline_rounded,
                      onPressed: onOpenDetails,
                    ),
                    HarnessTextButton(
                      label: 'Resources',
                      icon: Icons.inventory_2_outlined,
                      onPressed: onOpenResources,
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// What the computer is: its state, boundary, control, directories and the
/// endpoints its screen speaks to.  It draws no screen of its own; the desk
/// and the phone's sheet are where the screen lives.
class _ComputerDetailsSheet extends StatelessWidget {
  const _ComputerDetailsSheet({
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
        final screen = computer.width > 0 && computer.height > 0
            ? '${computer.width} × ${computer.height}'
            : '—';
        return SafeArea(
          key: const ValueKey('computer-details-sheet'),
          child: SingleChildScrollView(
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
                      child: Text(
                        'Computer',
                        style: HarnessText.sheetTitle(context),
                      ),
                    ),
                    Text(
                      _computerStateLabel(computer),
                      style: HarnessText.meta(context).copyWith(
                        color: _computerStateColor(context, computer),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: HarnessSpace.sm),
                _DetailRow(
                  label: 'Control',
                  value: computer.userControl ? 'You' : 'Agent',
                  action: computer.live
                      ? HarnessTextButton(
                          label: computer.userControl
                              ? 'Return control'
                              : 'Take over',
                          dense: true,
                          onPressed: () => unawaited(
                            computer.userControl
                                ? controller.returnControl()
                                : controller.takeOver(),
                          ),
                        )
                      : null,
                ),
                _DetailRow(
                  label: 'Backend',
                  value: computer.backend.isEmpty ? '—' : computer.backend,
                ),
                _DetailRow(
                  label: 'Isolation',
                  value: computer.isolation.isEmpty ? '—' : computer.isolation,
                ),
                _DetailRow(
                  label: 'Display',
                  value: computer.display.isEmpty ? '—' : computer.display,
                  mono: true,
                ),
                _DetailRow(label: 'Screen', value: screen),
                _DetailRow(
                  label: 'Home',
                  value: computer.home.isEmpty ? '—' : computer.home,
                  mono: true,
                ),
                _DetailRow(
                  label: 'Profile',
                  value: computer.profile.isEmpty ? '—' : computer.profile,
                  mono: true,
                ),
                _DetailRow(
                  label: 'Disk',
                  value: computer.disk > 0 ? formatBytes(computer.disk) : '—',
                ),
                _DetailRow(
                  label: 'Desktop',
                  value: computer.url ?? '—',
                  mono: true,
                ),
                _DetailRow(
                  label: 'Socket',
                  value: computer.socket ?? '—',
                  mono: true,
                ),
                if (computer.reason != null)
                  _DetailRow(
                    label: 'Reason',
                    value: computer.reason!,
                    accent: HarnessColors.amber,
                  ),
                if (computer.missing.isNotEmpty)
                  _DetailRow(
                    label: 'Missing',
                    value: computer.missing.join(' · '),
                    accent: HarnessColors.amber,
                  ),
                const SizedBox(height: HarnessSpace.md),
                Wrap(
                  spacing: HarnessSpace.sm,
                  runSpacing: HarnessSpace.sm,
                  children: [
                    HarnessTextButton(
                      label: 'Resources',
                      icon: Icons.inventory_2_outlined,
                      onPressed: onOpenResources,
                    ),
                    if (!computer.live && !computer.starting)
                      HarnessTextButton(
                        label: 'Start',
                        icon: Icons.play_arrow_rounded,
                        onPressed: () => unawaited(controller.startComputer()),
                      ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// One label and its value in the details sheet; a long path stays on one
/// line and its tooltip carries the whole of it.
class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.label,
    required this.value,
    this.mono = false,
    this.accent,
    this.action,
  });

  final String label;
  final String value;
  final bool mono;
  final Color? accent;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final style = mono
        ? HarnessText.mono(context).copyWith(fontSize: 11.5)
        : HarnessText.body(context).copyWith(fontSize: 13);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: action == null
            ? CrossAxisAlignment.start
            : CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 88,
            child: Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Text(label, style: HarnessText.meta(context)),
            ),
          ),
          Expanded(
            child: Tooltip(
              message: value,
              waitDuration: const Duration(milliseconds: 500),
              child: Text(
                value,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: accent == null ? style : style.copyWith(color: accent),
              ),
            ),
          ),
          if (action != null) ...[
            const SizedBox(width: HarnessSpace.sm),
            action!,
          ],
        ],
      ),
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
