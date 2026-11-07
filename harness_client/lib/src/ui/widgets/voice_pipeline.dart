import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../voice/voice_pipeline.dart';
import '../theme/harness_theme.dart';

/// The voice pipe in one frame: the microphone's level before the speech
/// filter, the audio the filter kept, its transcript, the agent turn it was
/// sent in, and what the speaker is doing.
///
/// It draws a [VoicePipelineSnapshot] and decides nothing: a marker moves
/// only when the snapshot says the stage it waits on reported, so the flow is
/// a picture of real events, not an animation that runs by itself.
///
/// The same frame is what a desktop buddy shows, with `compact: true`: the
/// summary line carries every state in words, so a small presentation is not
/// less truthful than the wide one.
class VoicePipelineView extends StatefulWidget {
  const VoicePipelineView({
    super.key,
    required this.snapshot,
    this.compact = false,
    this.heading = true,
    this.clock,
  });

  final VoicePipelineSnapshot snapshot;

  /// One row and one summary line, for a narrow panel or the buddy.
  final bool compact;

  /// Whether the view names itself; a host that draws its own heading turns
  /// this off.
  final bool heading;

  /// What "now" is for the level's freshness.  A test or a preview passes its
  /// own; the app reads the clock.
  final DateTime Function()? clock;

  @override
  State<VoicePipelineView> createState() => _VoicePipelineViewState();
}

class _VoicePipelineViewState extends State<VoicePipelineView> {
  static const _lanes = 3;
  static const _laneHeight = 19.0;
  static const _laneGap = 2.0;
  static const _headerHeight = 14.0;
  static const _gap = 6.0;

  bool _details = false;
  Timer? _staleTimer;
  DateTime? _staleDeadline;

  @override
  void initState() {
    super.initState();
    _scheduleStaleCheck();
  }

  @override
  void didUpdateWidget(VoicePipelineView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.snapshot.levelAt != widget.snapshot.levelAt) {
      _scheduleStaleCheck();
    }
  }

  @override
  void dispose() {
    _staleTimer?.cancel();
    super.dispose();
  }

  /// One wake-up for the moment the last level becomes too old to stand for
  /// the present, so a frozen meter turns into "no data" rather than
  /// pretending to be a quiet room.
  void _scheduleStaleCheck() {
    final snapshot = widget.snapshot;
    final at = snapshot.levelAt;
    if (!snapshot.levelSeen || at == null) {
      _staleTimer?.cancel();
      _staleTimer = null;
      _staleDeadline = null;
      return;
    }
    final deadline = at.add(VoicePipelineSnapshot.staleAfter);
    if (deadline == _staleDeadline) return;
    _staleTimer?.cancel();
    _staleDeadline = deadline;
    final now = _now;
    final wait = deadline.difference(now);
    _staleTimer = Timer(wait.isNegative ? Duration.zero : wait, () {
      _staleTimer = null;
      _staleDeadline = null;
      if (mounted) setState(() {});
    });
  }

  void _toggleDetails() => setState(() => _details = !_details);

  DateTime get _now => (widget.clock ?? DateTime.now)();

  bool get _motion => MediaQuery.maybeOf(context)?.disableAnimations != true;

  @override
  Widget build(BuildContext context) {
    final now = _now;
    final snapshot = widget.snapshot;
    return LayoutBuilder(
      builder: (context, constraints) {
        // A narrow panel, and one whose text is too large for four columns,
        // fold to the compact presentation; it says the same things in words.
        final scale = MediaQuery.textScalerOf(context).scale(1);
        final compact =
            widget.compact ||
            constraints.maxWidth < 330 ||
            (constraints.maxWidth < 560 && scale >= 1.5);
        final summary = compact
            ? snapshot.shortSummary(now)
            : snapshot.summary(now);
        return Semantics(
          container: true,
          explicitChildNodes: true,
          label: summary,
          hint: 'Pipeline details',
          child: FocusableActionDetector(
            // The stages' own words are the nodes a reader walks; the focus
            // node keeps the keys, not a second merged copy of every label.
            includeFocusSemantics: false,
            shortcuts: const <ShortcutActivator, Intent>{
              SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
              SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
            },
            actions: <Type, Action<Intent>>{
              ActivateIntent: CallbackAction<ActivateIntent>(
                onInvoke: (intent) => _toggleDetails(),
              ),
            },
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!compact && widget.heading)
                  _Heading(open: _details, onToggle: _toggleDetails),
                if (compact)
                  _compactRow(context, snapshot, now)
                else
                  _wideRow(context, snapshot, now),
                const SizedBox(height: 4),
                Text(
                  summary,
                  key: const Key('voice-pipeline-summary'),
                  // Free to wrap: a large text size must not hide a stage.
                  style: HarnessText.meta(context).copyWith(fontSize: 11),
                ),
                if (_details) _detailLines(context, snapshot),
              ],
            ),
          ),
        );
      },
    );
  }

  // -------------------------------------------------------------------- wide

  Widget _wideRow(
    BuildContext context,
    VoicePipelineSnapshot snapshot,
    DateTime now,
  ) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final meterWidth = (constraints.maxWidth * 0.2).clamp(58.0, 96.0);
        final speakerWidth = (constraints.maxWidth * 0.16).clamp(44.0, 74.0);
        final corridor =
            (constraints.maxWidth - meterWidth - speakerWidth - _gap * 2).clamp(
              96.0,
              640.0,
            );
        final column = corridor / 3;
        final lanes = <String, int>{};
        for (final segment in snapshot.segments) {
          final key = segment.column.name;
          lanes[key] = (lanes[key] ?? 0) + 1;
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: meterWidth,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _header(
                    context,
                    'Input',
                    'Microphone level before the speech filter',
                  ),
                  const SizedBox(height: 3),
                  _Meter(
                    level: snapshot.level,
                    hasData: !snapshot.levelStale(now),
                    live: snapshot.input.captureOpen,
                    width: meterWidth - 6,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    snapshot.inputLabel,
                    key: const Key('voice-pipeline-input'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _microStyle(context),
                  ),
                  Text(
                    snapshot.meterLabel(now),
                    key: const Key('voice-pipeline-level'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _microStyle(context),
                  ),
                ],
              ),
            ),
            const SizedBox(width: _gap),
            Expanded(
              child: SizedBox(
                width: corridor,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: _header(
                            context,
                            'Filter',
                            'Speech kept for transcription',
                          ),
                        ),
                        Expanded(
                          child: _header(context, 'Words', 'Speech to text'),
                        ),
                        Expanded(child: _header(context, 'Turn', 'Agent work')),
                      ],
                    ),
                    SizedBox(
                      height: _lanes * (_laneHeight + _laneGap),
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          for (
                            var columnIndex = 0;
                            columnIndex < 3;
                            columnIndex++
                          )
                            Positioned(
                              left: columnIndex * column,
                              top: 0,
                              bottom: 0,
                              width: 1,
                              child: ColoredBox(
                                color: Theme.of(context)
                                    .colorScheme
                                    .outlineVariant
                                    .withValues(alpha: 0.35),
                              ),
                            ),
                          for (final segment in snapshot.segments)
                            _markerPosition(
                              context,
                              segment,
                              columnWidth: column,
                              lane: _laneOf(snapshot, segment),
                            ),
                          if (snapshot.speechActive)
                            Positioned(
                              left: 2,
                              top: _lanePosition(_lanes - 1),
                              width: column - 4,
                              height: _laneHeight,
                              child: const _GateChip(),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: _gap),
            SizedBox(
              width: speakerWidth,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  _header(context, 'Speaker', 'Playback'),
                  const SizedBox(height: 2),
                  _Speaker(snapshot: snapshot),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  int _laneOf(VoicePipelineSnapshot snapshot, VoiceSegment segment) {
    var lane = 0;
    for (final other in snapshot.segments) {
      if (identical(other, segment)) break;
      if (other.column == segment.column) lane++;
    }
    return lane % _lanes;
  }

  double _lanePosition(int lane) => lane * (_laneHeight + _laneGap);

  Widget _markerPosition(
    BuildContext context,
    VoiceSegment segment, {
    required double columnWidth,
    required int lane,
  }) {
    return AnimatedPositioned(
      key: ValueKey('lane-${segment.id}'),
      duration: _motion ? const Duration(milliseconds: 240) : Duration.zero,
      curve: Curves.easeOutCubic,
      left: segment.column.index * columnWidth + 2,
      top: _lanePosition(lane),
      width: columnWidth - 6,
      height: _laneHeight,
      child: _Marker(segment: segment, withStage: columnWidth >= 110),
    );
  }

  // ----------------------------------------------------------------- compact

  Widget _compactRow(
    BuildContext context,
    VoicePipelineSnapshot snapshot,
    DateTime now,
  ) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final meterWidth = (constraints.maxWidth * 0.18).clamp(40.0, 64.0);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(
              width: meterWidth,
              child: _Meter(
                level: snapshot.level,
                hasData: !snapshot.levelStale(now),
                live: snapshot.input.captureOpen,
                width: meterWidth - 4,
                height: 20,
              ),
            ),
            const SizedBox(width: _gap),
            Expanded(
              child: SizedBox(
                height: _headerHeight + 4,
                child: Row(
                  children: [
                    for (final column in VoicePipelineColumn.values)
                      Expanded(
                        child: _compactColumn(context, snapshot, column),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: _gap),
            _Speaker(snapshot: snapshot, compact: true),
          ],
        );
      },
    );
  }

  Widget _compactColumn(
    BuildContext context,
    VoicePipelineSnapshot snapshot,
    VoicePipelineColumn column,
  ) {
    final markers = snapshot.segments
        .where((segment) => segment.column == column)
        .toList()
        .reversed
        .take(2)
        .toList();
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (column == VoicePipelineColumn.filter && snapshot.speechActive)
          const Padding(
            padding: EdgeInsets.only(right: 2),
            child: _GateChip(compact: true),
          ),
        for (final segment in markers)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 1),
            child: _Marker(segment: segment, compact: true),
          ),
        if (markers.isEmpty && column == VoicePipelineColumn.turn)
          Icon(
            Icons.more_horiz_rounded,
            size: 12,
            color: Theme.of(context).colorScheme.outline,
          ),
      ],
    );
  }

  // ------------------------------------------------------------------ pieces

  Widget _header(BuildContext context, String label, String help) {
    return Tooltip(
      message: help,
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: HarnessText.label(context)
            .copyWith(fontSize: 9.5, letterSpacing: 0.9),
      ),
    );
  }

  TextStyle _microStyle(BuildContext context) =>
      HarnessText.meta(context).copyWith(fontSize: 9.5, height: 1.25);

  Widget _detailLines(BuildContext context, VoicePipelineSnapshot snapshot) {
    final details = snapshot.details;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 76),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (details.isEmpty)
                Text('No segments yet', style: _microStyle(context)),
              for (final line in details)
                Text(
                  line,
                  style: _microStyle(context).copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading({required this.open, required this.onToggle});

  final bool open;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 18,
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Pipeline',
              style: HarnessText.label(context).copyWith(fontSize: 10),
            ),
          ),
          Tooltip(
            message: 'Pipeline details',
            child: Semantics(
              button: true,
              toggled: open,
              label: 'Pipeline details',
              child: Material(
                // The view brings its own Material: a buddy hosts it in a
                // plain panel, not necessarily in a Scaffold.
                type: MaterialType.transparency,
                child: InkWell(
                  key: const Key('voice-pipeline-details'),
                  onTap: onToggle,
                  borderRadius: BorderRadius.circular(6),
                  child: Padding(
                    padding: const EdgeInsets.all(2),
                    child: Icon(
                      open
                          ? Icons.keyboard_arrow_up_rounded
                          : Icons.keyboard_arrow_down_rounded,
                      size: 15,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Bars that answer the microphone: the level before the speech filter.
/// Without telemetry they stay unlit and the label beside them says so.
class _Meter extends StatelessWidget {
  const _Meter({
    required this.level,
    required this.hasData,
    required this.live,
    required this.width,
    this.height = 24,
  });

  final double level;
  final bool hasData;
  final bool live;
  final double width;
  final double height;

  /// Bars across the meter.  A small, fixed count keeps the paint cheap and
  /// the same on every width.
  static const bars = 9;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lit = hasData && live ? (level.clamp(0.0, 1.0) * bars).ceil() : 0;
    final color = hasData
        ? (theme.brightness == Brightness.dark
              ? HarnessColors.moss
              : theme.colorScheme.tertiary)
        : theme.colorScheme.outline;
    return SizedBox(
      width: width,
      height: height,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var i = 0; i < bars; i++)
            Expanded(
              child: Padding(
                padding: EdgeInsets.only(right: i == bars - 1 ? 0 : 1.6),
                child: FractionallySizedBox(
                  alignment: Alignment.bottomCenter,
                  heightFactor: hasData
                      ? (0.28 + 0.72 * (i + 1) / bars) * (i < lit ? 1.0 : 0.34)
                      : 0.16,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: i < lit
                          ? color
                          : color.withValues(alpha: hasData ? 0.28 : 0.35),
                      borderRadius: BorderRadius.circular(1.5),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _GateChip extends StatelessWidget {
  const _GateChip({this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.tertiary;
    return Tooltip(
      message: 'Speech gate · speech heard',
      excludeFromSemantics: true,
      child: Semantics(
        container: true,
        excludeSemantics: true,
        label: 'Speech gate, speech heard',
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.hearing_rounded, size: compact ? 10 : 11, color: color),
            if (!compact) ...[
              const SizedBox(width: 2),
              Text(
                'heard',
                style: HarnessText.meta(context)
                    .copyWith(fontSize: 9.5, color: color),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Marker extends StatelessWidget {
  const _Marker({
    required this.segment,
    this.compact = false,
    this.withStage = false,
  });

  final VoiceSegment segment;
  final bool compact;

  /// Whether the chip has room to name its stage beside the measurement.
  final bool withStage;

  @override
  Widget build(BuildContext context) {
    final color = _stageColor(context, segment);
    final icon = _stageIcon(segment);
    final text = _markerText(segment);
    final label = _semantics(segment);
    return Tooltip(
      message: _tooltip(segment),
      excludeFromSemantics: true,
      child: Semantics(
        container: true,
        excludeSemantics: true,
        label: label,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: color.withValues(alpha: 0.55)),
          ),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: compact ? 1 : 3),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: compact ? 9 : 10, color: color),
                if (!compact && (text != null || withStage)) ...[
                  const SizedBox(width: 3),
                  Flexible(
                    child: Text(
                      withStage
                          ? (text == null
                                ? segment.stage.label
                                : '${segment.stage.label} · $text')
                          : text!,
                      maxLines: 1,
                      overflow: TextOverflow.clip,
                      style: HarnessText.meta(context).copyWith(
                        fontSize: 9.5,
                        height: 1.1,
                        color: color,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  static IconData _stageIcon(VoiceSegment segment) => switch (segment.stage) {
    VoicePipelineStage.accepted => Icons.circle,
    VoicePipelineStage.transcribing => Icons.more_horiz_rounded,
    VoicePipelineStage.transcribed => Icons.short_text_rounded,
    VoicePipelineStage.inTurn => Icons.autorenew_rounded,
    VoicePipelineStage.answered => Icons.check_rounded,
    VoicePipelineStage.dropped => Icons.close_rounded,
    VoicePipelineStage.failed => Icons.error_outline_rounded,
  };

  /// What the chip says beside its icon: why it stopped, or how much audio it
  /// holds.  A live burst has no measured duration; there the stage word
  /// (when the column has room) is all it shows.
  static String? _markerText(VoiceSegment segment) {
    if (segment.stage == VoicePipelineStage.dropped &&
        segment.dropLabel != null) {
      return segment.dropLabel;
    }
    final duration = segment.duration;
    return duration == null ? null : voicePipelineDuration(duration);
  }

  static Color _stageColor(BuildContext context, VoiceSegment segment) {
    final scheme = Theme.of(context).colorScheme;
    return switch (segment.stage) {
      VoicePipelineStage.accepted => scheme.onSurfaceVariant,
      VoicePipelineStage.transcribing => HarnessColors.amber,
      VoicePipelineStage.transcribed => scheme.tertiary,
      VoicePipelineStage.inTurn => scheme.primary,
      VoicePipelineStage.answered => HarnessColors.moss,
      VoicePipelineStage.dropped => scheme.outline,
      VoicePipelineStage.failed => scheme.error,
    };
  }

  static String _tooltip(VoiceSegment segment) {
    final parts = <String>[
      segment.id,
      segment.stage.label,
      if (segment.duration case final duration?)
        voicePipelineDuration(duration),
      if (segment.dropLabel case final reason?) reason,
      if (segment.text case final text? when text.trim().isNotEmpty)
        '"${voicePipelineExcerpt(text, max: 40)}"',
      if (segment.detail case final detail? when detail.trim().isNotEmpty)
        detail,
    ];
    return parts.join(' · ');
  }

  static String _semantics(VoiceSegment segment) {
    final parts = <String>[
      'Segment ${segment.id}',
      segment.stage.label,
      if (segment.duration case final duration?)
        '${voicePipelineDuration(duration)} of audio',
      if (segment.dropLabel case final reason?) reason,
    ];
    return parts.join(', ');
  }
}

class _Speaker extends StatelessWidget {
  const _Speaker({required this.snapshot, this.compact = false});

  final VoicePipelineSnapshot snapshot;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final state = snapshot.output;
    final color = _color(context, state);
    final icon = _icon(state);
    final label = 'Speaker · ${state.label}';
    return Tooltip(
      message: 'Speaker · ${state.label}',
      excludeFromSemantics: true,
      child: Semantics(
        container: true,
        excludeSemantics: true,
        label: label,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: compact ? 16 : 20, color: color),
            if (!compact)
              Text(
                state.label,
                key: const Key('voice-pipeline-speaker'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: HarnessText.meta(context)
                    .copyWith(fontSize: 9.5, color: color),
              ),
          ],
        ),
      ),
    );
  }

  static IconData _icon(VoiceOutputState state) => switch (state) {
    VoiceOutputState.silent => Icons.volume_off_rounded,
    VoiceOutputState.ready => Icons.volume_down_rounded,
    VoiceOutputState.held => Icons.pause_circle_outline_rounded,
    VoiceOutputState.handed => Icons.outbox_rounded,
    VoiceOutputState.speaking => Icons.volume_up_rounded,
    VoiceOutputState.interrupted => Icons.stop_circle_outlined,
    VoiceOutputState.failed => Icons.error_outline_rounded,
  };

  static Color _color(BuildContext context, VoiceOutputState state) {
    final scheme = Theme.of(context).colorScheme;
    return switch (state) {
      VoiceOutputState.silent => scheme.outline,
      VoiceOutputState.ready => scheme.onSurfaceVariant,
      VoiceOutputState.held => HarnessColors.amber,
      VoiceOutputState.handed => scheme.tertiary,
      VoiceOutputState.speaking => HarnessColors.moss,
      VoiceOutputState.interrupted => HarnessColors.amber,
      VoiceOutputState.failed => scheme.error,
    };
  }
}
