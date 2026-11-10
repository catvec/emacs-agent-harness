import 'dart:async';

import 'package:flutter/material.dart';

import '../../state/app_controller.dart';
import '../../state/workspace_buddy_controller.dart';
import '../../voice/voice_buddy.dart';
import '../theme/harness_theme.dart';
import 'voice_buddy_dot.dart';
import 'workspace_buddy.dart'
    show workspaceBuddyPhaseColor, workspaceBuddyPhaseIcon;

/// Whether the in-call bar has a place on the screen: a call is open and
/// the full call view is not the surface showing it.
///
/// The bar is at every width, on a phone and on a desktop, and whether or
/// not the compact away card is also on screen.  It is the call's
/// persistent surface.
bool workspaceCallBarVisible({
  required WorkspaceBuddyController? controller,
  required bool hasSession,
}) {
  if (!hasSession || controller == null) return false;
  if (!controller.inCall || controller.callViewOpen) return false;
  return true;
}

/// Puts the in-call bar above everything the app shows, on every route, and
/// keeps the pages clear of the status bar only while the bar takes it.
///
/// It listens to the app for the buddy that comes and goes with the
/// workspace, and to that buddy for the call.  The bar always has its place
/// in the column, empty when hidden, so a call starting or ending does not
/// rebuild the navigator under it.
class WorkspaceCallBarHost extends StatefulWidget {
  const WorkspaceCallBarHost({
    super.key,
    required this.app,
    required this.child,
    required this.onOpenCallView,
  });

  final AppController app;
  final Widget child;
  final ValueChanged<WorkspaceBuddyController> onOpenCallView;

  @override
  State<WorkspaceCallBarHost> createState() => _WorkspaceCallBarHostState();
}

class _WorkspaceCallBarHostState extends State<WorkspaceCallBarHost> {
  WorkspaceBuddyController? _buddy;
  bool _bar = false;

  @override
  void initState() {
    super.initState();
    widget.app.addListener(_appChanged);
    widget.app.windowActive.addListener(_changed);
    _bind();
  }

  @override
  void didUpdateWidget(WorkspaceCallBarHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.app != widget.app) {
      oldWidget.app.removeListener(_appChanged);
      oldWidget.app.windowActive.removeListener(_changed);
      widget.app.addListener(_appChanged);
      widget.app.windowActive.addListener(_changed);
      _bind();
    }
  }

  @override
  void dispose() {
    widget.app.removeListener(_appChanged);
    widget.app.windowActive.removeListener(_changed);
    _buddy?.removeListener(_changed);
    super.dispose();
  }

  void _bind() {
    final next = widget.app.workspaceBuddy;
    if (identical(next, _buddy)) return;
    _buddy?.removeListener(_changed);
    _buddy = next;
    _buddy?.addListener(_changed);
  }

  void _appChanged() {
    final before = _buddy;
    _bind();
    if (!identical(before, _buddy) && mounted) setState(() {});
    _changed();
  }

  /// Only a change in whether the bar takes the top of the screen rebuilds
  /// the pages: the bar itself follows its call and the app's other news
  /// (a task, a session) does not re-lay the navigator under it.
  void _changed() {
    if (!mounted) return;
    final next = workspaceCallBarVisible(
      controller: widget.app.workspaceBuddy,
      hasSession: widget.app.hasSession,
    );
    if (next != _bar) setState(() => _bar = next);
  }

  @override
  Widget build(BuildContext context) {
    final buddy = widget.app.workspaceBuddy;
    final withSession = widget.app.hasSession;
    final bar = workspaceCallBarVisible(
      controller: buddy,
      hasSession: withSession,
    );
    _bar = bar;
    return Column(
      children: [
        if (buddy != null)
          WorkspaceCallBar(
            controller: buddy,
            visible: bar,
            onOpenCallView: () => widget.onOpenCallView(buddy),
          )
        else
          const SizedBox.shrink(),
        Expanded(
          child: MediaQuery.removePadding(
            context: context,
            removeTop: bar,
            child: widget.child,
          ),
        ),
      ],
    );
  }
}

/// The call as the app shows it above every page: one bar, the workspace's
/// call, the state the call reports and the controls that matter while it
/// runs.  The full call view and the away card are the same call.
class WorkspaceCallBar extends StatelessWidget {
  const WorkspaceCallBar({
    super.key,
    required this.controller,
    required this.visible,
    required this.onOpenCallView,
  });

  final WorkspaceBuddyController controller;
  final bool visible;
  final VoidCallback onOpenCallView;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        if (!visible) return const SizedBox.shrink();
        return WorkspaceCallBarView(
          model: controller.model,
          onMute: () => unawaited(controller.toggleMute()),
          onEnd: () => unawaited(controller.end()),
          onRetry: () => unawaited(controller.retry()),
          onOpenCallView: controller.voice == null ? null : onOpenCallView,
        );
      },
    );
  }
}

/// The presentational in-call bar.  It takes the buddy's immutable model so
/// the exact words, the controls and the layout are testable without a call.
class WorkspaceCallBarView extends StatelessWidget {
  const WorkspaceCallBarView({
    super.key,
    required this.model,
    required this.onMute,
    required this.onEnd,
    required this.onRetry,
    this.onOpenCallView,
  });

  final BuddyViewModel model;
  final VoidCallback onMute;
  final VoidCallback onEnd;
  final VoidCallback onRetry;

  /// Open the full call view.  Null while the call has no controller to
  /// show, such as the first moment of Starting or a start that failed.
  final VoidCallback? onOpenCallView;

  static const double wide = 860;
  static const Color _endColor = Color(0xFFD65A36);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final motion = reduceMotion
        ? Duration.zero
        : const Duration(milliseconds: 160);
    return Material(
      key: const Key('workspace-call-bar'),
      color: theme.colorScheme.surfaceContainerHigh,
      child: Container(
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: theme.colorScheme.outlineVariant),
          ),
        ),
        child: SafeArea(
          bottom: false,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final isWide = constraints.maxWidth >= wide;
              // A bar, not a page: it grows by a bounded amount when the
              // text does, so the two lines and their words stay whole.
              final scale = MediaQuery.textScalerOf(context)
                  .scale(1)
                  .clamp(1.0, 2.0);
              return SizedBox(
                height: (isWide ? 60 : 56) + (scale - 1) * (isWide ? 12 : 20),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      // The buddy's circle: identity inside a ring that says
                      // the last reported state.  The status and microphone
                      // words beside it stay, so the state is never colour
                      // alone and never only in a 28 px circle.
                      VoiceBuddyDot(
                        key: const Key('call-bar-dot'),
                        status: model.status,
                        workspaceName: model.workspaceName,
                        level: model.level,
                        size: 28,
                        pulseAllowed: !reduceMotion,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: isWide
                            ? _identity(context, isWide)
                            : Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  _identity(context, isWide),
                                  const SizedBox(height: 1),
                                  _statusAndMic(context, isWide, motion),
                                ],
                              ),
                      ),
                      if (isWide) ...[
                        const SizedBox(width: 10),
                        _statusAndMic(context, isWide, motion),
                        const SizedBox(width: 10),
                        Container(
                          width: 1,
                          height: 18,
                          color: theme.colorScheme.outlineVariant,
                        ),
                      ],
                      const SizedBox(width: 8),
                      if (model.canRetry) ...[
                        const SizedBox(width: 4),
                        _BarIcon(
                          key: const Key('call-bar-retry'),
                          icon: Icons.refresh_rounded,
                          label: 'Retry',
                          tooltip: 'Call · retry',
                          onPressed: onRetry,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ],
                      const SizedBox(width: 4),
                      _BarIcon(
                        key: const Key('call-bar-mute'),
                        icon: model.status.mic == BuddyMic.live
                            ? Icons.mic_rounded
                            : Icons.mic_off_rounded,
                        label: model.muted ? 'Unmute' : 'Mute',
                        // What the microphone reports, not the phase: a failed
                        // or starting call has no live microphone.
                        tooltip: 'Microphone · ${model.status.mic.name}',
                        toggled: model.muted,
                        onPressed: model.canMute ? onMute : null,
                        color: model.status.mic == BuddyMic.live
                            ? HarnessColors.moss
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 6),
                      _EndControl(
                        key: const Key('call-bar-end'),
                        enabled: model.canEnd,
                        onPressed: onEnd,
                      ),
                      if (onOpenCallView != null) ...[
                        const SizedBox(width: 4),
                        _BarIcon(
                          key: const Key('call-bar-view'),
                          icon: Icons.open_in_full_rounded,
                          label: 'Call view',
                          tooltip: 'Call · view',
                          onPressed: onOpenCallView!,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ],
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _identity(BuildContext context, bool isWide) {
    final theme = Theme.of(context);
    final thread = model.threadTitle?.trim() ?? '';
    final title = Text(
      'In a call',
      key: const Key('call-bar-title'),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: HarnessText.label(context).copyWith(
        fontSize: 11,
        letterSpacing: 0.7,
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
    final name = Text(
      model.workspaceName,
      key: const Key('call-bar-workspace'),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: HarnessText.label(context)
          .copyWith(fontSize: 13, color: theme.colorScheme.onSurface),
    );
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Flexible(flex: 3, child: title),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 5),
              child: Text('·', style: HarnessText.caption(context)),
            ),
            Flexible(flex: 4, child: name),
            if (isWide && thread.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 5),
                child: Text('·', style: HarnessText.caption(context)),
              ),
              Flexible(
                child: Text(
                  thread,
                  key: const Key('call-bar-thread'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: HarnessText.caption(context),
                ),
              ),
            ],
          ],
        ),
      ],
    );
    if (onOpenCallView == null) return content;
    return Semantics(
      button: true,
      label: 'Call · view',
      tooltip: 'Call · view',
      child: InkWell(
        key: const Key('call-bar-identity'),
        onTap: onOpenCallView,
        borderRadius: BorderRadius.circular(6),
        canRequestFocus: true,
        child: content,
      ),
    );
  }

  /// The status and the microphone line: what the call actually reports,
  /// grouped under the identity, in one live region each.  A phone width
  /// keeps the words; they are what tells recording from muted.
  Widget _statusAndMic(BuildContext context, bool isWide, Duration motion) {
    final theme = Theme.of(context);
    final phase = model.status.phase;
    final mic = model.status.mic;
    final live = mic == BuddyMic.live;
    final status = Semantics(
      key: const Key('call-bar-status-node'),
      container: true,
      liveRegion: true,
      label: 'Status · ${phase.label}',
      excludeSemantics: true,
      child: AnimatedSwitcher(
        duration: motion,
        child: Row(
          key: ValueKey<String>('call-bar-${phase.name}'),
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              workspaceBuddyPhaseIcon(phase),
              size: 14,
              color: workspaceBuddyPhaseColor(context, phase),
            ),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                phase.label,
                key: const Key('call-bar-status'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: HarnessText.rowTitle(context).copyWith(
                  fontSize: 13,
                  color: workspaceBuddyPhaseColor(context, phase),
                ),
              ),
            ),
          ],
        ),
      ),
    );
    final microphone = Semantics(
      key: const Key('call-bar-mic-node'),
      container: true,
      liveRegion: true,
      label: mic.label,
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
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
            size: 13,
            color: live
                ? HarnessColors.moss
                : theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 3),
          Flexible(
            child: Text(
              mic.label,
              key: const Key('call-bar-mic'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: HarnessText.caption(context).copyWith(fontSize: 12),
            ),
          ),
        ],
      ),
    );
    if (!isWide) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(child: status),
          const SizedBox(width: 8),
          Flexible(child: microphone),
        ],
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        status,
        const SizedBox(width: 10),
        Container(
          width: 1,
          height: 16,
          color: theme.colorScheme.outlineVariant,
        ),
        const SizedBox(width: 10),
        microphone,
      ],
    );
  }
}

class _EndControl extends StatelessWidget {
  const _EndControl({
    super.key,
    required this.enabled,
    required this.onPressed,
  });

  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: enabled,
      label: 'End',
      tooltip: 'Call · end',
      excludeSemantics: true,
      child: Opacity(
        opacity: enabled ? 1 : 0.4,
        child: Material(
          color: WorkspaceCallBarView._endColor,
          shape: const CircleBorder(),
          child: InkWell(
            onTap: enabled ? onPressed : null,
            customBorder: const CircleBorder(),
            canRequestFocus: enabled,
            child: const SizedBox(
              width: 36,
              height: 36,
              child: Icon(
                Icons.call_end_rounded,
                size: 18,
                color: Colors.white,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BarIcon extends StatelessWidget {
  const _BarIcon({
    super.key,
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.onPressed,
    required this.color,
    this.toggled = false,
  });

  final IconData icon;
  final String label;
  final String tooltip;
  final VoidCallback? onPressed;
  final Color color;
  final bool toggled;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Semantics(
      button: true,
      enabled: enabled,
      toggled: toggled,
      label: label,
      tooltip: tooltip,
      excludeSemantics: true,
      child: InkWell(
        onTap: enabled ? onPressed : null,
        customBorder: const CircleBorder(),
        canRequestFocus: enabled,
        child: SizedBox(
          width: 34,
          height: 34,
          child: Icon(
            icon,
            size: 18,
            color: enabled ? color : color.withValues(alpha: 0.4),
          ),
        ),
      ),
    );
  }
}
