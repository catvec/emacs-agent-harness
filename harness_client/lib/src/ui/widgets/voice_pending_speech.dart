import 'dart:async';

import 'package:flutter/material.dart';

import '../../voice/voice_controller.dart';
import '../../voice/voice_turn_completion.dart';
import '../theme/harness_theme.dart';

/// The words still on the person's side of a voice call, separate from the
/// agent's work and the immediate audio captions. Compact surfaces keep the
/// same status, draft and submission control as the full call view.
class VoicePendingSpeech extends StatelessWidget {
  const VoicePendingSpeech({
    super.key,
    required this.controller,
    this.compact = false,
  });

  final VoiceController controller;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final draft = controller.pendingSpeech;
        if (draft.isEmpty) return const SizedBox.shrink();
        final theme = Theme.of(context);
        final reason = controller.pendingReason ?? VoiceTurnReason.grace;
        final color = HarnessColors.status('blocked', theme.brightness);
        final enabled = controller.canSendPending;
        final action = TextButton.icon(
          key: const Key('voice-pending-send'),
          onPressed: enabled
              ? () => unawaited(controller.sendPendingNow())
              : null,
          icon: const Icon(Icons.send_rounded, size: 15),
          label: const Text('Submission'),
          style: TextButton.styleFrom(
            foregroundColor: color,
            textStyle: theme.textTheme.labelSmall
                ?.merge(HarnessText.caption(context))
                .copyWith(fontWeight: FontWeight.w700),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            minimumSize: const Size(0, 40),
            tapTargetSize: MaterialTapTargetSize.padded,
          ),
        );
        // The persistent call bar is above the navigator. Like its other
        // controls, it exposes a semantic tooltip without requiring an
        // overlay; a call view or buddy window also gets a hover tooltip.
        final submission = Overlay.maybeOf(context) == null
            ? Semantics(
                key: const Key('voice-pending-tooltip'),
                container: true,
                tooltip: 'Pending speech submission',
                child: action,
              )
            : Tooltip(
                key: const Key('voice-pending-tooltip'),
                message: 'Pending speech submission',
                child: action,
              );
        return Container(
          key: const Key('voice-pending-speech'),
          padding: EdgeInsets.fromLTRB(
            compact ? 10 : 12,
            compact ? 4 : 6,
            compact ? 10 : 12,
            compact ? 10 : 12,
          ),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.07),
            border: Border.all(color: color.withValues(alpha: 0.3)),
            borderRadius: BorderRadius.circular(2),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              OverflowBar(
                alignment: MainAxisAlignment.spaceBetween,
                overflowAlignment: OverflowBarAlignment.end,
                spacing: 8,
                children: [
                  Text(
                    'Unsent speech',
                    key: const Key('voice-pending-heading'),
                    style: HarnessText.rowTitle(context).copyWith(
                      fontSize: compact ? 13 : 14,
                    ),
                  ),
                  submission,
                ],
              ),
              Semantics(
                liveRegion: true,
                child: Text(
                  reason.label,
                  key: const Key('voice-pending-status'),
                  style: HarnessText.caption(context).copyWith(
                    color: color,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: compact ? 72 : 104),
                child: SingleChildScrollView(
                  key: const Key('voice-pending-scroll'),
                  primary: false,
                  child: Text(
                    draft,
                    key: const Key('voice-pending-draft'),
                    style: compact
                        ? HarnessText.subtitle(context).copyWith(
                            color: theme.colorScheme.onSurface,
                          )
                        : HarnessText.body(context),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
