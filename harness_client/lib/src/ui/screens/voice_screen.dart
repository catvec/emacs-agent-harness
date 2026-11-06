import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../voice/voice_controller.dart';
import '../../voice/voice_models.dart';
import '../../voice/voice_settings.dart';
import '../theme/harness_theme.dart';
import '../widgets/voice_orb.dart';
import '../widgets/voice_settings_sheet.dart';

/// The full-screen voice conversation: what the person and the agent are
/// saying, what the provider is doing, and the three controls that matter
/// while they talk.
///
/// It is deliberately dark in both themes: a voice screen is a place apart
/// from the conversation behind it, and the orb is easier to read on it.
class VoiceScreen extends StatefulWidget {
  const VoiceScreen({super.key, required this.controller});

  final VoiceController controller;

  @override
  State<VoiceScreen> createState() => _VoiceScreenState();
}

class _VoiceScreenState extends State<VoiceScreen> {
  final _captions = ScrollController();
  bool _started = false;
  String _captionKey = '';

  VoiceController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_started) {
        _started = true;
        unawaited(_controller.start());
      }
    });
  }

  @override
  void dispose() {
    _controller.removeListener(_changed);
    unawaited(_controller.stop());
    _controller.dispose();
    _captions.dispose();
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    final last = _controller.captions.isEmpty
        ? null
        : _controller.captions.last;
    final key = last == null
        ? ''
        : '${_controller.captions.length}:${last.speaker.name}:${last.text}:${last.finalized}';
    if (key == _captionKey) return;
    _captionKey = key;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_captions.hasClients &&
          _captions.position.maxScrollExtent > _captions.offset) {
        _captions.animateTo(
          _captions.position.maxScrollExtent,
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _close() async {
    // The screen goes at once; the microphone and the provider are let go
    // behind it, so a platform channel that is slow to answer never makes
    // the person wait to leave.
    unawaited(_controller.stop());
    if (mounted) Navigator.of(context).maybePop();
  }

  Future<void> _openSettings() async {
    final next = await showVoiceSettingsSheet(
      context,
      settings: _controller.settings,
      harnessAddress: _controller.harnessAddress,
    );
    if (next == null || !mounted) return;
    await _controller.updateSettings(next);
  }

  @override
  Widget build(BuildContext context) {
    final phase = _controller.displayPhase;
    final color = voicePhaseColor(phase);
    return Theme(
      data: HarnessTheme.material(Brightness.dark),
      child: Builder(
        builder: (context) => Scaffold(
          backgroundColor: const Color(0xFF0D0D0F),
          body: Container(
            decoration: const BoxDecoration(
              gradient: RadialGradient(
                center: Alignment(0, -0.45),
                radius: 1.1,
                colors: [Color(0xFF1D1B1A), Color(0xFF0D0D0F)],
              ),
            ),
            child: SafeArea(
              child: Column(
                children: [
                  _Header(
                    provider: _controller.settings.provider,
                    onClose: _close,
                    onSettings: _openSettings,
                  ),
                  Expanded(
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 720),
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final orb = math
                                .min(
                                  constraints.maxWidth * 0.62,
                                  constraints.maxHeight * 0.34,
                                )
                                .clamp(112.0, 228.0);
                            return Column(
                              children: [
                                Expanded(
                                  flex: 5,
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      VoiceOrb(
                                        phase: phase,
                                        level: _controller.level,
                                        size: orb,
                                        animate: phase != VoicePhase.ended,
                                      ),
                                      const SizedBox(height: 10),
                                      Text(
                                        phase.label,
                                        key: const Key('voice-status'),
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                          color: const Color(0xFFF3F0EA)
                                              .withValues(alpha: 0.94),
                                          fontSize: 14,
                                          fontWeight: FontWeight.w500,
                                          letterSpacing: 0.2,
                                        ),
                                      ),
                                      if (phase == VoicePhase.approval)
                                        _ApprovalNotice(onOpen: _close),
                                      if (_controller.problem != null)
                                        _ProblemNotice(
                                          problem: _controller.problem!,
                                          onRetry: _controller.retry,
                                        ),
                                    ],
                                  ),
                                ),
                                Expanded(
                                  flex: 4,
                                  child: _Transcript(
                                    captions: _controller.captions,
                                    scroll: _captions,
                                    color: color,
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                  Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 520),
                      child: _Controls(
                        phase: phase,
                        muted: _controller.muted,
                        onMute: _controller.toggleMute,
                        onInterrupt: _controller.interrupt,
                        onEnd: _close,
                        onRetry: _controller.retry,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.provider,
    required this.onClose,
    required this.onSettings,
  });

  final VoiceProvider provider;
  final VoidCallback onClose;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 56,
      child: Row(
        children: [
          IconButton(
            key: const Key('voice-close'),
            onPressed: onClose,
            tooltip: 'End',
            icon: const Icon(
              Icons.keyboard_arrow_down_rounded,
              color: Color(0xFFE9E5DE),
              size: 28,
            ),
            iconSize: 28,
          ),
          Expanded(
            child: Center(
              child: Text(
                'Voice',
                style: TextStyle(
                  color: const Color(0xFFF3F0EA).withValues(alpha: 0.92),
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.1,
                ),
              ),
            ),
          ),
          Tooltip(
            message: 'Voice settings',
            child: InkWell(
              key: const Key('voice-settings'),
              onTap: onSettings,
              borderRadius: BorderRadius.circular(20),
              child: Container(
                margin: const EdgeInsets.only(right: 10),
                padding: const EdgeInsets.fromLTRB(11, 7, 8, 7),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.07),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.10),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      provider == VoiceProvider.clip
                          ? Icons.graphic_eq_rounded
                          : Icons.bolt_rounded,
                      size: 13,
                      color: const Color(0xFFCFCBC4),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      provider == VoiceProvider.clip ? 'Clip' : 'Live',
                      style: TextStyle(
                        color: const Color(0xFFE2DED7).withValues(alpha: 0.9),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.2,
                      ),
                    ),
                    const SizedBox(width: 2),
                    const Icon(
                      Icons.expand_more_rounded,
                      size: 15,
                      color: Color(0xFF9D9993),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Transcript extends StatelessWidget {
  const _Transcript({
    required this.captions,
    required this.scroll,
    required this.color,
  });

  final List<VoiceCaption> captions;
  final ScrollController scroll;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                'Transcript',
                style: TextStyle(
                  color: const Color(0xFF8E8A85).withValues(alpha: 0.8),
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.1,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Container(
                  height: 1,
                  color: Colors.white.withValues(alpha: 0.06),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: captions.isEmpty
                ? Center(
                    child: Text(
                      'No speech yet',
                      key: const Key('voice-empty'),
                      style: TextStyle(
                        color: const Color(0xFF8E8A85).withValues(alpha: 0.7),
                        fontSize: 13,
                      ),
                    ),
                  )
                : ListView.builder(
                    key: const Key('voice-captions'),
                    controller: scroll,
                    padding: const EdgeInsets.only(bottom: 6),
                    itemCount: captions.length,
                    itemBuilder: (context, index) {
                      final caption = captions[index];
                      return _CaptionLine(
                        caption: caption,
                        color: caption.speaker == VoiceSpeaker.agent
                            ? color
                            : const Color(0xFFCFCBC4),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _CaptionLine extends StatelessWidget {
  const _CaptionLine({required this.caption, required this.color});

  final VoiceCaption caption;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final partial = !caption.finalized;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 2,
            height: 18,
            margin: const EdgeInsets.only(top: 2, right: 10),
            decoration: BoxDecoration(
              color: color.withValues(alpha: partial ? 0.35 : 0.8),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  caption.speaker.label,
                  style: TextStyle(
                    color: color.withValues(alpha: 0.75),
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.9,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  caption.text,
                  style: TextStyle(
                    color: const Color(0xFFF1EDE6)
                        .withValues(alpha: partial ? 0.55 : 0.93),
                    fontSize: 14.5,
                    height: 1.38,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ApprovalNotice extends StatelessWidget {
  const _ApprovalNotice({required this.onOpen});

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 10, 24, 0),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 9, 8, 9),
        decoration: BoxDecoration(
          color: const Color(0xFFE2B85D).withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: const Color(0xFFE2B85D).withValues(alpha: 0.28),
          ),
        ),
        child: Row(
          children: [
            const Icon(Icons.gavel_rounded, size: 15, color: Color(0xFFE2B85D)),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                'Permission request',
                style: TextStyle(
                  color: Color(0xFFE9D6AC),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            TextButton(
              key: const Key('voice-open-conversation'),
              onPressed: onOpen,
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFFE2B85D),
                textStyle: TextStyle(
                  fontFamily: Theme.of(context)
                      .textTheme
                      .labelLarge
                      ?.fontFamily,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 28),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text(
                'Open',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProblemNotice extends StatelessWidget {
  const _ProblemNotice({required this.problem, required this.onRetry});

  final VoiceProblem problem;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 10, 24, 0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Flexible(
            child: Text(
              problem.detail == null
                  ? problem.label
                  : '${problem.label} · ${problem.detail}',
              key: const Key('voice-problem'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Color(0xFFE39A8E),
                fontSize: 11.5,
                height: 1.3,
              ),
            ),
          ),
          if (problem.recoverable)
            TextButton(
              key: const Key('voice-retry-problem'),
              onPressed: () => unawaited(onRetry()),
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFFE39A8E),
                textStyle: TextStyle(
                  fontFamily: Theme.of(context)
                      .textTheme
                      .labelLarge
                      ?.fontFamily,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                ),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 26),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text(
                'Retry',
                style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700),
              ),
            ),
        ],
      ),
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({
    required this.phase,
    required this.muted,
    required this.onMute,
    required this.onInterrupt,
    required this.onEnd,
    required this.onRetry,
  });

  final VoicePhase phase;
  final bool muted;
  final Future<void> Function() onMute;
  final Future<void> Function() onInterrupt;
  final Future<void> Function() onEnd;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final finished = phase.finished;
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 10, 28, 18),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Control(
            key: const Key('voice-mute'),
            icon: muted ? Icons.mic_off_rounded : Icons.mic_rounded,
            label: muted ? 'Unmute' : 'Mute',
            onTap: finished ? null : onMute,
          ),
          _Control(
            key: const Key('voice-interrupt'),
            icon: Icons.stop_rounded,
            label: 'Interrupt',
            onTap: finished ? null : onInterrupt,
          ),
          _Control(
            key: const Key('voice-end'),
            icon: Icons.call_end_rounded,
            label: 'End',
            color: const Color(0xFFD65A36),
            filled: true,
            onTap: onEnd,
          ),
          if (finished)
            _Control(
              key: const Key('voice-retry'),
              icon: Icons.refresh_rounded,
              label: 'Retry',
              onTap: onRetry,
            ),
        ],
      ),
    );
  }
}

class _Control extends StatelessWidget {
  const _Control({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
    this.filled = false,
  });

  final IconData icon;
  final String label;
  final Future<void> Function()? onTap;
  final Color? color;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final accent = color ?? const Color(0xFFE9E5DE);
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      child: Opacity(
        opacity: enabled ? 1 : 0.38,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: enabled ? () => unawaited(onTap!()) : null,
                customBorder: const CircleBorder(),
                child: Container(
                  width: filled ? 62 : 54,
                  height: filled ? 62 : 54,
                  decoration: BoxDecoration(
                    color: filled
                        ? accent
                        : Colors.white.withValues(alpha: 0.07),
                    shape: BoxShape.circle,
                    border: filled
                        ? null
                        : Border.all(
                            color: Colors.white.withValues(alpha: 0.09),
                          ),
                  ),
                  child: Icon(
                    icon,
                    size: filled ? 27 : 22,
                    color: filled ? Colors.white : accent,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 7),
            Text(
              label,
              style: TextStyle(
                color: const Color(0xFFB9B5AE)
                    .withValues(alpha: enabled ? 0.9 : 0.5),
                fontSize: 10.5,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
