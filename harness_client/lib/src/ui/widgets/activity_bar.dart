import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/activity.dart';
import '../adaptive/adaptive_widgets.dart';
import '../adaptive/layout_widgets.dart';
import '../theme/harness_theme.dart';

/// The line above a composer that says what a running turn does now.
///
/// A conversation draws it above its own composer, and so does the
/// workspace, which runs the same turns in its threads: a chat and a
/// workspace say "Waiting for the model" and "Thinking" in one place and
/// one way.  It redraws itself once a second while it shows, so the
/// elapsed time moves without the screen rebuilding.
class ActivityBar extends StatefulWidget {
  const ActivityBar({
    super.key,
    required this.activity,
    required this.waiting,
    required this.running,
    this.animated = true,
  });

  /// What the turn does, as `agent/activity` says it; null before the
  /// first update, or from a harness that does not report activity.
  final TurnActivity? activity;

  /// The session waits on the user: it says so instead of what the model
  /// does, and offers no elapsed time.
  final bool waiting;

  /// A turn is in flight, even when no activity has arrived yet.
  final bool running;

  /// Show a moving spinner.  A bar with no elapsed time has nothing to
  /// count and can stand still, so a test that waits for the screen to
  /// settle has one animation less to wait for.
  final bool animated;

  @override
  State<ActivityBar> createState() => _ActivityBarState();
}

class _ActivityBarState extends State<ActivityBar> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _syncTimer();
  }

  @override
  void didUpdateWidget(ActivityBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncTimer();
  }

  /// Tick only while there is an elapsed time to move: a bar with no
  /// `since` draws no clock, and a clock no one reads must not keep the
  /// screen drawing.
  void _syncTimer() {
    if (widget.activity?.since == null) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    _timer ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final activity = widget.activity;
    final label =
        widget.waiting && (activity == null || activity.phase == 'checking')
        ? 'Waiting for your answer'
        : activity?.label ?? (widget.running ? 'Working' : '');
    if (label.isEmpty) return const SizedBox.shrink();
    final since = activity?.since;
    final elapsed = since == null ? null : DateTime.now().difference(since);
    final color = widget.waiting
        ? HarnessColors.amber
        : theme.colorScheme.primary;
    return Container(
      padding: const EdgeInsets.fromLTRB(
        HarnessSpace.gutter,
        8,
        HarnessSpace.gutter,
        8,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.04),
        border: Border(
          top: BorderSide(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 16,
            child: Center(
              child: widget.waiting
                  ? Icon(Icons.front_hand_rounded, size: 15, color: color)
                  : widget.animated
                  ? HarnessActivity(radius: 7, color: color)
                  : HarnessDot(color: color, size: 7),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: HarnessText.meta(context)
                  .copyWith(color: color, fontWeight: FontWeight.w600),
            ),
          ),
          if (elapsed != null)
            Text(_formatElapsed(elapsed), style: HarnessText.meta(context)),
        ],
      ),
    );
  }

  String _formatElapsed(Duration duration) {
    if (duration.inSeconds < 60) return '${duration.inSeconds}s';
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds % 60;
    return '${minutes}m ${seconds.toString().padLeft(2, '0')}s';
  }
}
