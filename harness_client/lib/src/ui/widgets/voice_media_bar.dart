import 'dart:async';

import 'package:flutter/material.dart';

import '../../media/media_capture.dart';
import '../../voice/voice_controller.dart';
import '../theme/harness_theme.dart';

/// The camera and phone-screen controls beside a workspace call: one source
/// at a time, a visible state, one-step stop, and one frame at a time to the
/// session for a provider that takes images rather than a video track.
///
/// It is the same [VoiceController] the orb and the in-call bar use; it
/// starts nothing on its own.
class VoiceMediaBar extends StatelessWidget {
  const VoiceMediaBar({super.key, required this.controller});

  final VoiceController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final source = controller.mediaStatus.source;
    final active = controller.mediaStatus.state.active;
    final camera = controller.capabilityFor(CaptureSource.camera);
    final screen = controller.capabilityFor(CaptureSource.screen);
    final busy = controller.mediaSending || controller.mediaFrameSending;
    return Column(
      key: const Key('voice-media-bar'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 6,
          children: [
            _MediaToggle(
              key: const Key('media-camera'),
              label: source == CaptureSource.camera && active
                  ? 'Stop camera'
                  : 'Camera',
              icon: source == CaptureSource.camera && active
                  ? Icons.videocam_off_rounded
                  : Icons.videocam_rounded,
              selected: source == CaptureSource.camera && active,
              // Stop stays available while a frame is being sent: a person
              // must never be held in a capture by a slow encode.
              enabled:
                  (source == CaptureSource.camera && active) ||
                  (!busy && camera?.usable == true),
              tooltip: _tooltip('Camera', CaptureSource.camera, camera),
              onPressed: () =>
                  unawaited(controller.toggleMedia(CaptureSource.camera)),
            ),
            _MediaToggle(
              key: const Key('media-screen'),
              label: source == CaptureSource.screen && active
                  ? 'Stop screen share'
                  : 'Screen',
              icon: source == CaptureSource.screen && active
                  ? Icons.stop_screen_share_rounded
                  : Icons.screen_share_rounded,
              selected: source == CaptureSource.screen && active,
              enabled:
                  (source == CaptureSource.screen && active) ||
                  (!busy && screen?.usable == true),
              tooltip: _tooltip('Screen', CaptureSource.screen, screen),
              onPressed: () =>
                  unawaited(controller.toggleMedia(CaptureSource.screen)),
            ),
            _MediaToggle(
              key: const Key('media-frame-to-chat'),
              label: 'Frame to chat',
              icon: Icons.add_photo_alternate_outlined,
              selected: false,
              enabled: !busy && controller.canFrameToChat,
              tooltip: _frameTooltip(controller),
              onPressed: () => unawaited(controller.sendFrameToChat()),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Semantics(
          key: const Key('media-status-node'),
          container: true,
          liveRegion: true,
          label: controller.mediaStateLabel,
          excludeSemantics: true,
          child: Text(
            controller.mediaStateLabel,
            key: const Key('media-status'),
            textAlign: TextAlign.center,
            style: theme.textTheme.labelMedium?.copyWith(
              color: captureStateColor(controller.mediaStatus.state),
            ),
          ),
        ),
        if (controller.mediaPreview case final preview?) ...[
          const SizedBox(height: 6),
          Center(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.memory(
                preview.png,
                key: const Key('media-preview'),
                width: 128,
                height: 72,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                filterQuality: FilterQuality.low,
              ),
            ),
          ),
        ],
        if (controller.frameProblem case final problem?) ...[
          const SizedBox(height: 4),
          Text(
            problem,
            key: const Key('media-frame-problem'),
            textAlign: TextAlign.center,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ],
        if (controller.mediaProblem case final problem?) ...[
          const SizedBox(height: 4),
          Text(
            problem,
            key: const Key('media-problem'),
            textAlign: TextAlign.center,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ],
        if (controller.sessionMedia?.visionUnconfirmed == true &&
            controller.mediaStatus.state.active) ...[
          const SizedBox(height: 2),
          Text(
            'Vision unconfirmed',
            key: const Key('media-vision-unconfirmed'),
            textAlign: TextAlign.center,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }

  String _tooltip(
    String label,
    CaptureSource source,
    CaptureCapability? capability,
  ) {
    if (capability == null) return '$label · checking';
    if (!capability.available) {
      return switch (capability.reason) {
        'ios-screen-share-needs-broadcast-extension' =>
          '$label · needs a broadcast extension',
        'microphone-in-use' => '$label · microphone in use',
        _ => '$label · unavailable',
      };
    }
    if (capability.foregroundOnly) return '$label · foreground only';
    return label;
  }

  String _frameTooltip(VoiceController controller) {
    final media = controller.sessionMedia;
    if (controller.mediaStatus.state.active != true) {
      return 'Frame to chat · no live camera or screen';
    }
    if (media == null) return 'Frame to chat · harness not ready';
    if (media.vision == false) {
      return 'Frame to chat · model without vision';
    }
    if (media.visionUnconfirmed) return 'Frame to chat · vision unconfirmed';
    return 'Frame to chat';
  }
}

class _MediaToggle extends StatelessWidget {
  const _MediaToggle({
    super.key,
    required this.label,
    required this.icon,
    required this.selected,
    required this.enabled,
    required this.tooltip,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final bool enabled;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        toggled: selected,
        enabled: enabled,
        label: tooltip,
        excludeSemantics: true,
        child: OutlinedButton.icon(
          onPressed: enabled ? onPressed : null,
          icon: Icon(icon, size: 16),
          label: Text(label),
          style: OutlinedButton.styleFrom(
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            foregroundColor: selected
                ? HarnessColors.moss
                : theme.colorScheme.onSurface,
            side: BorderSide(
              color: selected
                  ? HarnessColors.moss
                  : theme.colorScheme.outlineVariant,
            ),
          ),
        ),
      ),
    );
  }
}
