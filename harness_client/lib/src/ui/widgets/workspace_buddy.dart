import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../state/workspace_buddy_controller.dart';
import '../../voice/voice_buddy.dart';
import '../adaptive/adaptive_widgets.dart';
import '../adaptive/layout_widgets.dart';
import '../navigation.dart';
import '../screens/voice_screen.dart';
import '../theme/harness_theme.dart';

/// Open the full call view of [buddy]'s call: the same call the in-call bar
/// shows, in the screen that owns the large controls.  Leaving the view does
/// not end the call; [VoiceScreen]'s End goes back through the controller.
Future<void> openWorkspaceCallView({
  required BuildContext context,
  required NavigatorState navigator,
  required WorkspaceBuddyController buddy,
}) async {
  final voice = buddy.voice;
  if (voice == null) return;
  buddy.callViewOpen = true;
  try {
    await navigator.push(
      harnessRoute(
        context,
        (context) =>
            VoiceScreen(controller: voice, attached: true, onEnd: buddy.end),
      ),
    );
  } finally {
    buddy.callViewOpen = false;
  }
}

/// The optional compact presence of a workspace's voice call, as the shell
/// draws it when the window is not the one in use: one card, its real state,
/// and the controls that end or mute it.  While the window is active the
/// in-call bar and the full call view are the call's surfaces, and this card
/// stays out of the way.
class WorkspaceBuddyLayer extends StatefulWidget {
  const WorkspaceBuddyLayer({
    super.key,
    required this.controller,
    required this.onOpenWorkspace,
    required this.onOpenSettings,
    this.away = true,
  });

  final WorkspaceBuddyController controller;
  final VoidCallback onOpenWorkspace;
  final VoidCallback onOpenSettings;

  /// Whether the window is not the one in use.  The card is the away
  /// surface; a test draws it without a window lifecycle.
  final bool away;

  @override
  State<WorkspaceBuddyLayer> createState() => _WorkspaceBuddyLayerState();
}

class _WorkspaceBuddyLayerState extends State<WorkspaceBuddyLayer> {
  /// The app's desktop breakpoint.  The card is a desktop surface: below it
  /// the in-call bar is the call's surface at every width, and the card is
  /// not built.
  static const double minWidth = 920;

  final GlobalKey _cardKey = GlobalKey();
  Offset? _position;
  Size _cardSize = const Size(312, 240);

  Size _measureCard() {
    final card = _cardKey.currentContext?.findRenderObject() as RenderBox?;
    if (card != null && card.hasSize) _cardSize = card.size;
    return _cardSize;
  }

  Offset _defaultPosition(Size layerSize, Size cardSize) => Offset(
    math.max(8.0, layerSize.width - cardSize.width - 16),
    math.max(8.0, layerSize.height - cardSize.height - 16),
  );

  Offset _clamp(Offset position, Size layerSize, Size cardSize) => Offset(
    position.dx.clamp(8.0, math.max(8.0, layerSize.width - cardSize.width - 8)),
    position.dy.clamp(
      8.0,
      math.max(8.0, layerSize.height - cardSize.height - 8),
    ),
  );

  void _drag(Offset delta, Size layerSize) {
    // A gesture callback may read the laid-out size; build may not.
    final cardSize = _measureCard();
    final current = _position ?? _defaultPosition(layerSize, cardSize);
    setState(() {
      _position = _clamp(current + delta, layerSize, cardSize);
    });
  }

  void _reclampAfterLayout(Size layerSize) {
    if (_position == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final clamped = _clamp(_position!, layerSize, _measureCard());
      if (clamped != _position) setState(() => _position = clamped);
    });
  }

  /// Below the desktop breakpoint, or while the window is the one in use,
  /// the card is not built.  The call stays in the in-call bar, which is at
  /// every width: no microphone is left behind a surface that is not there.
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        if (!widget.controller.enabled) return const SizedBox.shrink();
        if (!widget.away) return const SizedBox.shrink();
        if (widget.controller.callViewOpen) return const SizedBox.shrink();
        final width = MediaQuery.maybeOf(context)?.size.width ?? 0;
        if (width < minWidth) return const SizedBox.shrink();
        return SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final layerSize = constraints.biggest;
              _reclampAfterLayout(layerSize);
              final card = KeyedSubtree(
                key: _cardKey,
                child: WorkspaceBuddy(
                  controller: widget.controller,
                  onOpenWorkspace: widget.onOpenWorkspace,
                  onOpenSettings: widget.onOpenSettings,
                  onDragUpdate: (delta) => _drag(delta, layerSize),
                  maxHeight: math.max(160.0, layerSize.height - 24),
                ),
              );
              return Stack(
                children: [
                  if (_position == null)
                    Positioned(right: 16, bottom: 16, child: card)
                  else
                    Positioned(
                      left: _position!.dx,
                      top: _position!.dy,
                      child: card,
                    ),
                ],
              );
            },
          ),
        );
      },
    );
  }
}

/// The card itself, with the shell's live controller.
class WorkspaceBuddy extends StatelessWidget {
  const WorkspaceBuddy({
    super.key,
    required this.controller,
    required this.onOpenWorkspace,
    required this.onOpenSettings,
    this.onDragUpdate,
    this.maxHeight,
  });

  final WorkspaceBuddyController controller;
  final VoidCallback onOpenWorkspace;
  final VoidCallback onOpenSettings;
  final ValueChanged<Offset>? onDragUpdate;
  final double? maxHeight;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => WorkspaceBuddyView(
        model: controller.model,
        onStart: () => unawaited(controller.start()),
        onEnd: () => unawaited(controller.end()),
        onMute: () => unawaited(controller.toggleMute()),
        onPause: () => unawaited(controller.togglePause()),
        onInterrupt: () => unawaited(controller.interrupt()),
        onRetry: () => unawaited(controller.retry()),
        onOff: () => unawaited(controller.disable()),
        onOpenWorkspace: onOpenWorkspace,
        onOpenSettings: onOpenSettings,
        onDragUpdate: onDragUpdate,
        maxHeight: maxHeight,
      ),
    );
  }
}

/// The presentational card.  It takes an immutable [BuddyViewModel] so the
/// exact copy and the layout of every state are testable without a harness.
class WorkspaceBuddyView extends StatelessWidget {
  const WorkspaceBuddyView({
    super.key,
    required this.model,
    required this.onStart,
    required this.onEnd,
    required this.onMute,
    required this.onPause,
    required this.onInterrupt,
    required this.onRetry,
    required this.onOff,
    required this.onOpenWorkspace,
    required this.onOpenSettings,
    this.onDragUpdate,
    this.maxHeight,
  });

  final BuddyViewModel model;
  final VoidCallback onStart;
  final VoidCallback onEnd;
  final VoidCallback onMute;
  final VoidCallback onPause;
  final VoidCallback onInterrupt;
  final VoidCallback onRetry;
  final VoidCallback onOff;
  final VoidCallback onOpenWorkspace;
  final VoidCallback onOpenSettings;
  final ValueChanged<Offset>? onDragUpdate;
  final double? maxHeight;

  /// The width of the card at the current text scale, bounded so that it
  /// stays a corner surface at the app's 920 px desktop breakpoint and at
  /// 150% text.
  static double widthFor(BuildContext context) {
    final scale = MediaQuery.maybeOf(context)?.textScaler.scale(1) ?? 1.0;
    return (312 + (scale.clamp(1.0, 2.0) - 1) * 56).clamp(312.0, 376.0);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final motion = reduceMotion
        ? Duration.zero
        : const Duration(milliseconds: 160);
    final width = widthFor(context);
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(context, motion),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _identity(context),
              const SizedBox(height: 8),
              _status(context, motion),
              const SizedBox(height: 5),
              _microphone(context),
              const SizedBox(height: 10),
              _callControls(context),
              const SizedBox(height: 4),
              _secondaryControls(context),
              if (model.problem != null) ...[
                const SizedBox(height: 8),
                _problem(context),
              ],
              if (model.note != null) ...[
                const SizedBox(height: 6),
                Text(
                  model.note!,
                  key: const Key('buddy-note'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: HarnessText.caption(context)
                      .copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ],
          ),
        ),
      ],
    );
    return FocusTraversalGroup(
      policy: ReadingOrderTraversalPolicy(),
      child: Semantics(
        container: true,
        label: 'Workspace buddy',
        explicitChildNodes: true,
        child: Material(
          type: MaterialType.transparency,
          child: HarnessCard(
            key: const Key('workspace-buddy'),
            radius: 18,
            padding: EdgeInsets.zero,
            color: theme.colorScheme.surfaceContainerHigh,
            child: SizedBox(
              key: const Key('workspace-buddy-size'),
              width: width,
              child: maxHeight == null
                  ? content
                  : ConstrainedBox(
                      constraints: BoxConstraints(maxHeight: maxHeight!),
                      child: SingleChildScrollView(child: content),
                    ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(BuildContext context, Duration motion) {
    final theme = Theme.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.move,
      child: GestureDetector(
        key: const Key('buddy-drag-handle'),
        behavior: HitTestBehavior.opaque,
        onPanUpdate: onDragUpdate == null
            ? null
            : (details) => onDragUpdate!(details.delta),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 6, 6),
          child: Row(
            children: [
              Icon(
                Icons.record_voice_over_rounded,
                size: 16,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        'Buddy',
                        key: const Key('buddy-title'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: HarnessText.label(context)
                            .copyWith(color: theme.colorScheme.onSurface),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      flex: 2,
                      child: _ConnectionPill(
                        connection: model.connection,
                        detail: model.connectionDetail,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              _IconControl(
                key: const Key('buddy-off'),
                icon: Icons.close_rounded,
                label: 'Workspace buddy off',
                tooltip: 'Buddy · off',
                onPressed: onOff,
                size: 18,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _identity(BuildContext context) {
    return _WorkspaceIdentity(
      workspaceName: model.workspaceName,
      threadTitle: model.threadTitle,
      onOpen: onOpenWorkspace,
    );
  }

  Widget _status(BuildContext context, Duration motion) {
    final theme = Theme.of(context);
    final phase = model.status.phase;
    final color = _phaseColor(context, phase);
    return Row(
      children: [
        Icon(_phaseIcon(phase), size: 15, color: color),
        const SizedBox(width: 6),
        Expanded(
          child: Semantics(
            key: const Key('buddy-status-node'),
            container: true,
            liveRegion: true,
            label: 'Status · ${phase.label}',
            excludeSemantics: true,
            child: AnimatedSwitcher(
              duration: motion,
              child: Text(
                phase.label,
                key: ValueKey<String>('buddy-status-${phase.name}'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: HarnessText.rowTitle(context)
                    .copyWith(fontSize: 14, color: color),
              ),
            ),
          ),
        ),
        const SizedBox(width: 6),
        Tooltip(
          message: 'Voice provider · ${model.providerLabel}',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                model.providerLabel == 'Live'
                    ? Icons.bolt_rounded
                    : Icons.graphic_eq_rounded,
                size: 12,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 3),
              Text(
                model.providerLabel,
                key: const Key('buddy-provider'),
                style: HarnessText.caption(context),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _microphone(BuildContext context) {
    final theme = Theme.of(context);
    final mic = model.status.mic;
    final live = mic == BuddyMic.live;
    return Row(
      children: [
        Icon(
          switch (mic) {
            BuddyMic.live => Icons.mic_rounded,
            BuddyMic.muted => Icons.mic_off_rounded,
            BuddyMic.paused => Icons.pause_circle_outline_rounded,
            BuddyMic.starting => Icons.mic_none_rounded,
            BuddyMic.closing => Icons.mic_none_rounded,
            BuddyMic.off => Icons.mic_none_rounded,
          },
          size: 14,
          color: live ? HarnessColors.moss : theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 5),
        Flexible(
          child: Semantics(
            key: const Key('buddy-mic-node'),
            container: true,
            liveRegion: true,
            label: mic.label,
            excludeSemantics: true,
            child: Text(
              mic.label,
              key: const Key('buddy-mic'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: HarnessText.caption(context),
            ),
          ),
        ),
        if (model.showsLevel) ...[
          const SizedBox(width: 8),
          Tooltip(
            message: 'Microphone · level',
            child: ExcludeSemantics(
              child: _LevelMeter(
                key: const Key('buddy-level'),
                level: model.level,
              ),
            ),
          ),
        ],
        const SizedBox(width: 8),
        if (model.extraOutput != BuddyOutput.idle)
          Flexible(child: _ActivityChip(output: model.extraOutput)),
      ],
    );
  }

  Widget _callControls(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _LabelControl(
            key: const Key('buddy-start'),
            label: 'Start',
            tooltip: 'Call · start',
            icon: Icons.play_arrow_rounded,
            onPressed: model.canStart ? onStart : null,
            filled: true,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _LabelControl(
            key: const Key('buddy-end'),
            label: 'End',
            tooltip: 'Call · end',
            icon: Icons.call_end_rounded,
            onPressed: model.canEnd ? onEnd : null,
            destructive: true,
          ),
        ),
      ],
    );
  }

  Widget _secondaryControls(BuildContext context) {
    final mic = model.status.mic;
    return Wrap(
      spacing: 1,
      runSpacing: 1,
      children: [
        _SmallControl(
          key: const Key('buddy-mute'),
          label: model.muted ? 'Unmute' : 'Mute',
          // The microphone's own state, not the phase: a failed or starting
          // call has no live microphone to toggle.
          tooltip: 'Microphone · ${mic.name}',
          icon: mic == BuddyMic.live
              ? Icons.mic_rounded
              : Icons.mic_off_rounded,
          toggled: model.muted,
          onPressed: model.canMute ? onMute : null,
        ),
        _SmallControl(
          key: const Key('buddy-pause'),
          label: model.paused ? 'Resume' : 'Pause',
          tooltip: model.paused
              ? 'Conversation · paused'
              : 'Conversation · live',
          icon: model.paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
          toggled: model.paused,
          onPressed: model.canPause ? onPause : null,
        ),
        _SmallControl(
          key: const Key('buddy-interrupt'),
          label: 'Interrupt',
          tooltip: 'Playback · interruption',
          icon: Icons.stop_rounded,
          onPressed: model.canInterrupt ? onInterrupt : null,
        ),
        _SmallControl(
          key: const Key('buddy-settings'),
          label: 'Voice settings',
          tooltip: 'Voice settings',
          icon: Icons.settings_outlined,
          onPressed: onOpenSettings,
        ),
      ],
    );
  }

  Widget _problem(BuildContext context) {
    final theme = Theme.of(context);
    final problem = model.problem!;
    return Container(
      key: const Key('buddy-problem'),
      padding: const EdgeInsets.fromLTRB(8, 6, 4, 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: theme.colorScheme.error.withValues(alpha: 0.35),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.error_outline_rounded,
            size: 14,
            color: theme.colorScheme.error,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  problem.label,
                  key: const Key('buddy-problem-label'),
                  style: HarnessText.caption(context).copyWith(
                    color: theme.colorScheme.onErrorContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (problem.detail case final detail?
                    when detail.trim().isNotEmpty)
                  Text(
                    detail,
                    key: const Key('buddy-problem-detail'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: HarnessText.caption(context).copyWith(
                      color: theme.colorScheme.onErrorContainer.withValues(
                        alpha: 0.8,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (model.canRetry)
            Tooltip(
              message: 'Call · retry',
              child: TextButton(
                key: const Key('buddy-retry'),
                onPressed: onRetry,
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 28),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  foregroundColor: theme.colorScheme.error,
                ),
                child: const Text(
                  'Retry',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                ),
              ),
            ),
        ],
      ),
    );
  }

  IconData _phaseIcon(BuddyPhase phase) => workspaceBuddyPhaseIcon(phase);

  Color _phaseColor(BuildContext context, BuddyPhase phase) =>
      workspaceBuddyPhaseColor(context, phase);
}

/// The icon of a call phase, the same in the card and in the in-call bar.
IconData workspaceBuddyPhaseIcon(BuddyPhase phase) => switch (phase) {
  BuddyPhase.off => Icons.power_settings_new_rounded,
  BuddyPhase.starting => Icons.more_horiz_rounded,
  BuddyPhase.listening => Icons.hearing_rounded,
  BuddyPhase.hearing => Icons.graphic_eq_rounded,
  BuddyPhase.transcribing => Icons.text_fields_rounded,
  BuddyPhase.working => Icons.build_circle_outlined,
  BuddyPhase.holdingReply => Icons.pause_circle_outline_rounded,
  BuddyPhase.speaking => Icons.volume_up_rounded,
  BuddyPhase.interrupted => Icons.stop_circle_outlined,
  BuddyPhase.muted => Icons.mic_off_rounded,
  BuddyPhase.paused => Icons.pause_circle_outline_rounded,
  BuddyPhase.approval => Icons.front_hand_rounded,
  BuddyPhase.ending => Icons.call_end_rounded,
  BuddyPhase.ended => Icons.call_end_rounded,
  BuddyPhase.failed => Icons.error_outline_rounded,
  BuddyPhase.unknown => Icons.help_outline_rounded,
};

/// The colour of a call phase, the same in the card and in the in-call bar.
Color workspaceBuddyPhaseColor(BuildContext context, BuddyPhase phase) {
  final theme = Theme.of(context);
  return switch (phase) {
    BuddyPhase.failed => theme.colorScheme.error,
    BuddyPhase.listening || BuddyPhase.speaking => HarnessColors.moss,
    BuddyPhase.hearing => HarnessColors.oxide,
    BuddyPhase.starting ||
    BuddyPhase.transcribing ||
    BuddyPhase.working ||
    BuddyPhase.holdingReply ||
    BuddyPhase.interrupted ||
    BuddyPhase.paused ||
    BuddyPhase.approval => HarnessColors.amber,
    BuddyPhase.off ||
    BuddyPhase.muted ||
    BuddyPhase.ending ||
    BuddyPhase.ended ||
    BuddyPhase.unknown => theme.colorScheme.onSurfaceVariant,
  };
}

class _WorkspaceIdentity extends StatefulWidget {
  const _WorkspaceIdentity({
    required this.workspaceName,
    required this.threadTitle,
    required this.onOpen,
  });

  final String workspaceName;
  final String? threadTitle;
  final VoidCallback onOpen;

  @override
  State<_WorkspaceIdentity> createState() => _WorkspaceIdentityState();
}

class _WorkspaceIdentityState extends State<_WorkspaceIdentity> {
  final FocusNode _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final thread = widget.threadTitle?.trim() ?? '';
    return Tooltip(
      message: 'Workspace · open',
      child: Semantics(
        button: true,
        label: 'Workspace · open',
        tooltip: 'Workspace · open',
        onTap: widget.onOpen,
        onFocus: () => _focus.requestFocus(),
        focusable: true,
        excludeSemantics: true,
        child: InkWell(
          key: const Key('buddy-workspace'),
          focusNode: _focus,
          onTap: widget.onOpen,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                Expanded(
                  flex: 5,
                  child: Text(
                    widget.workspaceName,
                    key: const Key('buddy-workspace-name'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: HarnessText.rowTitle(context).copyWith(fontSize: 14),
                  ),
                ),
                if (thread.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 5),
                    child: Text('·', style: HarnessText.caption(context)),
                  ),
                  Expanded(
                    flex: 6,
                    child: Text(
                      thread,
                      key: const Key('buddy-thread'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: HarnessText.caption(context),
                    ),
                  ),
                ],
                Icon(
                  Icons.open_in_new_rounded,
                  size: 12,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ConnectionPill extends StatelessWidget {
  const _ConnectionPill({required this.connection, required this.detail});

  final BuddyConnection connection;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = switch (connection) {
      BuddyConnection.connected => HarnessColors.moss,
      BuddyConnection.reconnecting => HarnessColors.amber,
      BuddyConnection.offline => theme.colorScheme.onSurfaceVariant,
    };
    final pill = HarnessStatusPill(
      label: connection.label,
      color: color,
      flexible: true,
    );
    final trimmed = detail.trim();
    return trimmed.isEmpty
        ? pill
        : Tooltip(message: 'Connection · $trimmed', child: pill);
  }
}

class _ActivityChip extends StatelessWidget {
  const _ActivityChip({required this.output});

  final BuddyOutput output;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = output == BuddyOutput.held
        ? HarnessColors.amber
        : theme.colorScheme.primary;
    return Container(
      key: const Key('buddy-activity'),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Text(
        output.label,
        style: HarnessText.caption(context)
            .copyWith(color: color, fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// A tiny level meter drawn from the only levels a backend reports.  It is
/// not an animation and it is absent unless the microphone is live and the
/// backend has actually reported a level.
class _LevelMeter extends StatelessWidget {
  const _LevelMeter({super.key, required this.level});

  final double level;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final filled = (level.clamp(0.0, 1.0) * 6).ceil();
    return SizedBox(
      width: 54,
      height: 12,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var index = 0; index < 6; index++) ...[
            if (index > 0) const SizedBox(width: 2),
            Container(
              width: 7,
              height: 4 + index * 1.4,
              decoration: BoxDecoration(
                color: index < filled
                    ? HarnessColors.moss
                    : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _LabelControl extends StatefulWidget {
  const _LabelControl({
    super.key,
    required this.label,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.filled = false,
    this.destructive = false,
  });

  final String label;
  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool filled;
  final bool destructive;

  @override
  State<_LabelControl> createState() => _LabelControlState();
}

class _LabelControlState extends State<_LabelControl> {
  final FocusNode _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = widget.onPressed != null;
    final child = Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(widget.icon, size: 17),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            widget.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
    final button = widget.filled
        ? FilledButton(
            focusNode: _focus,
            onPressed: widget.onPressed,
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 38),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              textStyle: TextStyle(
                fontFamily: theme.textTheme.labelLarge?.fontFamily,
              ),
            ),
            child: child,
          )
        : OutlinedButton(
            focusNode: _focus,
            onPressed: widget.onPressed,
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(0, 38),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              foregroundColor: widget.destructive
                  ? theme.colorScheme.error
                  : null,
              side: BorderSide(
                color: widget.destructive
                    ? theme.colorScheme.error.withValues(alpha: 0.5)
                    : theme.colorScheme.outlineVariant,
              ),
              textStyle: TextStyle(
                fontFamily: theme.textTheme.labelLarge?.fontFamily,
              ),
            ),
            child: child,
          );
    return Tooltip(
      message: widget.tooltip,
      child: Semantics(
        container: true,
        button: true,
        enabled: enabled,
        label: widget.label,
        tooltip: widget.tooltip,
        onTap: enabled ? widget.onPressed : null,
        onFocus: enabled ? () => _focus.requestFocus() : null,
        focusable: enabled,
        excludeSemantics: true,
        child: button,
      ),
    );
  }
}

class _SmallControl extends StatefulWidget {
  const _SmallControl({
    super.key,
    required this.label,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.toggled = false,
  });

  final String label;
  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool toggled;

  @override
  State<_SmallControl> createState() => _SmallControlState();
}

class _SmallControlState extends State<_SmallControl> {
  final FocusNode _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = widget.onPressed != null;
    return Tooltip(
      message: widget.tooltip,
      child: Semantics(
        container: true,
        button: true,
        enabled: enabled,
        toggled: widget.toggled,
        label: widget.label,
        tooltip: widget.tooltip,
        onTap: enabled ? widget.onPressed : null,
        onFocus: enabled ? () => _focus.requestFocus() : null,
        focusable: enabled,
        excludeSemantics: true,
        child: TextButton.icon(
          focusNode: _focus,
          onPressed: widget.onPressed,
          icon: Icon(widget.icon, size: 15),
          label: Text(widget.label),
          style: TextButton.styleFrom(
            minimumSize: const Size(0, 30),
            padding: const EdgeInsets.symmetric(horizontal: 7),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: VisualDensity.compact,
            foregroundColor: enabled
                ? theme.colorScheme.onSurface
                : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
            textStyle: TextStyle(
              fontFamily: theme.textTheme.labelLarge?.fontFamily,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

class _IconControl extends StatefulWidget {
  const _IconControl({
    super.key,
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.onPressed,
    this.size = 20,
  });

  final IconData icon;
  final String label;
  final String tooltip;
  final VoidCallback onPressed;
  final double size;

  @override
  State<_IconControl> createState() => _IconControlState();
}

class _IconControlState extends State<_IconControl> {
  final FocusNode _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: Semantics(
        container: true,
        button: true,
        label: widget.label,
        tooltip: widget.tooltip,
        onTap: widget.onPressed,
        onFocus: () => _focus.requestFocus(),
        focusable: true,
        excludeSemantics: true,
        child: IconButton(
          focusNode: _focus,
          onPressed: widget.onPressed,
          icon: Icon(widget.icon, size: widget.size),
          padding: const EdgeInsets.all(4),
          constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          visualDensity: VisualDensity.compact,
          tooltip: null,
        ),
      ),
    );
  }
}
