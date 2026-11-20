import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../voice/voice_ribbon.dart';
import '../theme/harness_theme.dart';

/// Where a ribbon is drawn: the normal linear bar, or the compact ring.
enum VoiceRibbonPresentation { linear, polar }

/// The voice pipe as one continuous ribbon of bars.
///
/// One dark pill, and inside it the pipe's own bars from left to right: the
/// microphone's level, the speech the filter kept, the words, the agent's
/// work and the audio out.  A stage's place is the stage -- never how long
/// anything has been there -- so an utterance is one run of bars that moves
/// when the stage it waits on reports, and two real bursts in two stages are
/// two runs at once.
///
/// The same runs are drawn in two forms:
///
/// * [VoiceRibbonPresentation.linear], every full-size surface;
/// * [VoiceRibbonPresentation.polar], a collapsed or mini surface, where the
///   stages run clockwise from twelve o'clock.
///
/// Neither form carries a stage word, a key, a count or a summary: the shapes
/// say the stages, and a screen reader hears the words.  The detailed lines
/// live in the voice settings, never here.
class VoiceRibbonView extends StatefulWidget {
  const VoiceRibbonView({
    super.key,
    required this.ribbon,
    this.form = VoiceRibbonPresentation.linear,
    this.clock,
    this.height,
  });

  final VoiceRibbon ribbon;
  final VoiceRibbonPresentation form;

  /// What "now" is, for the warble and for a dropped run's linger.  A test
  /// or a preview passes its own; the app reads the clock.
  final DateTime Function()? clock;

  /// The pill's height, or the ring's side.  The host decides the room; a
  /// control with none of its own takes the defaults below.
  final double? height;

  /// The pill's height when the host gives no room of its own.
  static const pillHeight = 46.0;

  /// The pill's width in pill-heights.
  ///
  /// The approved ribbon is 690x111 px: 6.2 heights across.  The pill is a
  /// compact bar, not a band stretched across the window, so it keeps that
  /// proportion and stops growing; a wider window gets a wider pill only up
  /// to this ratio, and the stages never drift apart into five marks.
  static const pillWidthInHeights = 6.2;

  /// The widest the pill grows, however much room the host has.
  static const pillMaxWidth = pillHeight * pillWidthInHeights;

  /// The ring's side when the host gives no room of its own.
  ///
  /// The approved badge is a small glance -- its disc is 133 px across in a
  /// 1440 px sheet -- so the compact form is drawn at a similar size rather
  /// than filling whatever room it is offered.
  static const ringSide = 104.0;

  /// How far the disc's edge sits inside the ring's own side, as a fraction
  /// of that side.
  ///
  /// The marks sit on a track inside the disc, so the disc reaches a little
  /// past them and the badge reads as one filled shape.  The painter and the
  /// comparison sheet both read it here, so the disc a picture compares with
  /// is the disc the app draws.
  static const ringInset = 0.045;

  /// The disc's diameter when the ring is drawn at [ringSide].
  ///
  /// A sheet that compares the ring with the approved badge draws both discs
  /// at this size, so the two are compared at one scale rather than at two.
  static const ringDisc = ringSide * (1 - 2 * ringInset);

  @override
  State<VoiceRibbonView> createState() => _VoiceRibbonViewState();
}

class _VoiceRibbonViewState extends State<VoiceRibbonView> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  @override
  void didUpdateWidget(VoiceRibbonView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _schedule();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  DateTime get _now => (widget.clock ?? DateTime.now)();

  /// How long a run takes to reach the stage it just moved to.  Reduced
  /// motion puts it there at once; every shape stays either way.
  ///
  /// Long enough to read as travel rather than a jump, short enough that a
  /// second handoff cannot arrive before the first has landed.
  Duration get _moveDuration =>
      widget.ribbon.motion &&
          MediaQuery.maybeOf(context)?.disableAnimations != true
      ? const Duration(milliseconds: 320)
      : Duration.zero;

  /// One wake-up for the ribbon's next change of its own: a waiting run's
  /// warble frame, or a dropped one clearing.  Nothing else moves without an
  /// event, so there is no ticker here.
  void _schedule() {
    _timer?.cancel();
    _timer = null;
    final wait = widget.ribbon.nextChange(_now);
    if (wait == null) return;
    _timer = Timer(wait, () {
      _timer = null;
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final now = _now;
    final ribbon = widget.ribbon;
    final motion =
        ribbon.motion &&
        MediaQuery.maybeOf(context)?.disableAnimations != true;
    final effective = motion
        ? ribbon
        : VoiceRibbon(blips: ribbon.blips, summary: ribbon.summary, motion: false);
    final wobble = effective.warblePhaseAt(now);
    // The words are the ribbon's own label, and each run is a node of its
    // own under it: a reader can hear the whole pipe and then each mark, and
    // none of it is drawn.
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: effective.summary,
      child: widget.form == VoiceRibbonPresentation.polar
          ? _polar(context, effective, now, wobble)
          : _linear(context, effective, now, wobble),
    );
  }

  // ------------------------------------------------------------------ linear

  /// The pill and its runs, drawn on the approved geometry: one bar of
  /// 0.122 pill-heights, one gap of 0.099, the same pitch in every stage.
  ///
  /// The stages are not separated by gutters.  The approved ribbon runs its
  /// bars straight on from one stage into the next, which is what makes it
  /// read as one waveform; only the shape and the colour say where a stage
  /// begins.  A stage with nothing in it draws nothing at all, so an empty
  /// pipe is an empty pill.
  /// The pill and its runs, drawn on the approved geometry.
  ///
  /// The approved ribbon is not five equal columns: its stages are laid end to
  /// end at one pitch, each with the fixed number of bars its own shape has,
  /// and the whole sequence is centred in the pill.  That is why a stage
  /// boundary reads as the next bar rather than as a gap, and why a populated
  /// ribbon comes out at the original's own 28 marks.  A stage with nothing in
  /// it draws nothing at all, so an empty pipe is an empty pill.
  Widget _linear(
    BuildContext context,
    VoiceRibbon ribbon,
    DateTime now,
    double wobble,
  ) {
    final height = widget.height ?? VoiceRibbonView.pillHeight;
    return SizedBox(
      height: height,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final room = constraints.maxWidth;
          final width = math.min(
            room,
            height * VoiceRibbonView.pillWidthInHeights,
          );
          final inset = (room - width) / 2;
          final metrics = _BarMetrics(height);
          // The room the runs may use: the pill less its rounded caps.
          final inner = math.max(1.0, width - metrics.inset * 2);
          return Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: inset,
                top: 0,
                width: width,
                height: height,
                child: CustomPaint(painter: const _PillPainter()),
              ),
              ..._linearRuns(
                ribbon,
                metrics,
                inner,
                inset,
                height,
                wobble,
                now,
              ),
            ],
          );
        },
      ),
    );
  }

  /// Every stage's runs, end to end, at one pitch.
  ///
  /// A run keeps the approved size of its bars; the sequence is centred in the
  /// pill, and only when the runs together are wider than the pill are they
  /// drawn smaller, so a busy pipe stays inside its own bar rather than
  /// spilling past the cap.  Two real bursts in one stage stay two runs side
  /// by side in that stage's own place in the order.
  List<Widget> _linearRuns(
    VoiceRibbon ribbon,
    _BarMetrics metrics,
    double inner,
    double inset,
    double height,
    double wobble,
    DateTime now,
  ) {
    final placements = <_Placement>[];
    for (final band in VoiceRibbonBand.values) {
      for (final blip in ribbon.bandAt(band, now)) {
        final count = _approvedBars(blip.form);
        final bars = _bars(
          blip.form,
          blip.level,
          wobble,
          0,
          height,
          count: count,
        );
        // A run owns exactly its own bars' worth of the grid: COUNT cells at
        // the pitch the whole ribbon is drawn on.  Nothing is left over for a
        // later bar to be pushed off, and nothing is left empty inside it.
        placements.add(_Placement(band, blip, bars, count.toDouble()));
      }
    }
    if (placements.isEmpty) return const [];
    // Every mark in the ribbon sits on ONE grid.  A stage owns as many cells
    // as its own approved shape draws -- four for the microphone, five for
    // kept speech, five for the words, three for the agent's work, seven for
    // the audio out -- and a stage with a second real burst in it takes
    // another run's worth of cells, so two bursts are two runs side by side
    // and neither is drawn over the other.
    //
    // The cell is the pitch: one bar and the gap beside it.  When the whole
    // sequence fits at the approved pitch it is drawn at that pitch and
    // centred; when it does not, every cell shrinks by the same factor, so the
    // ribbon keeps the approved bar-to-gap ratio at any density instead of
    // closing the gaps until the bars touch.
    //
    // A run of dotted bars is the one exception, and it is why the drop used
    // to read as a hole: a drop is drawn as a hairline across, and a hairline
    // in a whole bar's cell leaves most of that cell empty.  Its cell is the
    // hairline and its own gap -- the approved drop's own pitch -- so its dots
    // sit as close as the shape wants them while the slot it reserves still
    // holds a bar's worth of the ribbon.
    const weights = [4, 5, 5, 3, 7];
    final cells = List<int>.filled(weights.length, 0);
    for (final place in placements) {
      cells[place.band.index] += place.cells.toInt();
    }
    final slots = <int>[
      for (var band = 0; band < weights.length; band++)
        math.max(weights[band], cells[band]),
    ];
    final total = slots.fold<int>(0, (sum, slot) => sum + slot);
    final unit = math.min(metrics.pitch, inner / total);
    // The approved bar and gap, scaled together to the cell that was found:
    // the ratio between them is the original's whatever the density.
    final scale = unit / metrics.pitch;
    final barWidth = metrics.width * scale;
    final gap = metrics.gap * scale;
    // The sequence is centred on the marks it draws, not on the cells it
    // reserves: the last cell ends with the gap that follows its bar, so
    // centring the cells would leave one gap more room on the right than on
    // the left and the bar would sit visibly off-centre in its own pill.
    final marks = total * unit - gap;
    final origin =
        inset + metrics.inset + math.max(0.0, (inner - marks) / 2);
    final used = List<int>.filled(weights.length, 0);
    final widgets = <Widget>[];
    for (final place in placements) {
      final band = place.band.index;
      final before =
          slots.take(band).fold<int>(0, (sum, slot) => sum + slot);
      final at = origin + unit * (before + used[band]);
      used[band] += place.cells.toInt();
      widgets.add(
        AnimatedPositioned(
          key: ValueKey('voice-ribbon-${place.blip.id}'),
          duration: _moveDuration,
          // A handoff eases out of its old place and settles into the new one,
          // so a mark reads as travelling rather than as snapping across.  The
          // width is not animated: a run's own box is its cells, and a box that
          // grew mid-flight would redraw the bars at a second pitch.
          curve: Curves.easeInOutCubic,
          left: at,
          top: 0,
          // The run's box is exactly the cells it owns, so its last bar ends
          // where the next stage's first bar begins.
          width: unit * place.cells,
          height: height,
          child: _Run(
            blip: place.blip,
            bars: place.bars,
            color: _blipColor(place.band, place.blip.form),
            metrics: metrics,
            barWidth: barWidth,
            gap: gap,
            rotate: 0,
          ),
        ),
      );
    }
    return widgets;
  }

  // ------------------------------------------------------------------- polar

  /// The compact form: the same runs around a ring, the first stage at
  /// twelve o'clock and the rest clockwise, each run radial so the ring reads
  /// as a ring of bars rather than a dotted scaffold.
  Widget _polar(
    BuildContext context,
    VoiceRibbon ribbon,
    DateTime now,
    double wobble,
  ) {
    final side = widget.height ?? VoiceRibbonView.ringSide;
    final metrics = _BarMetrics(side);
    return SizedBox(
      width: side,
      height: side,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(child: CustomPaint(painter: const _RingPainter())),
          for (final band in VoiceRibbonBand.values)
            ..._polarBand(ribbon, band, side, metrics, wobble, now),
        ],
      ),
    );
  }

  /// One stage's marks along its own fifth of the rim.
  ///
  /// The angle is the stage: twelve o'clock is the microphone and the pipe
  /// runs clockwise, so a handoff moves a mark round the ring rather than
  /// redrawing it somewhere else.  A stage with nothing in it draws nothing:
  /// the approved compact badge is a bare disc until the pipe has something
  /// to say.
  ///
  /// A stage's marks follow the rim one by one, each in its own small box and
  /// turned to the tangent where it sits.  A run is a long arc -- a fifth of
  /// the rim -- and a single straight box cannot follow it without hanging
  /// outside the disc, which is why the approved badge's dashes are laid one
  /// after another along its edge.
  List<Widget> _polarBand(
    VoiceRibbon ribbon,
    VoiceRibbonBand band,
    double side,
    _BarMetrics metrics,
    double wobble,
    DateTime now,
  ) {
    final blips = ribbon.bandAt(band, now);
    if (blips.isEmpty) return const [];
    final centre = Offset(side / 2, side / 2);
    final discRadius = side / 2 - side * 0.045;
    // The approved badge's marks are square tiles, not dashes: measured from
    // the original, each is 12 px on a 134 px disc -- 0.089 of the disc --
    // and they sit evenly round the rim.  A thin dash reads as a tick on a
    // dial; a tile reads as the approved badge's own treatment.
    final tile = math.max(3.0, side * 0.089);
    // A mark is turned about its own centre, so its own reach is half its
    // diagonal; the track is that much inside the rim, which puts every mark
    // on the rim without any corner crossing it.
    final radius = discRadius - tile * 0.7071;
    // One stage owns a fifth of the rim, and its marks fill that arc at a
    // pitch of their own, so the ring reads as a broken rim rather than as
    // five sparse clusters.
    final arc = 2 * math.pi * radius / VoiceRibbonBand.values.length;
    // The approved badge spaces its tiles evenly round the rim: the gap
    // between two tiles is about their own size, which is what makes the rim
    // read as a ring of marks rather than a dotted line.
    final pitch = tile * 2.0;
    final perStage = math.max(2, (arc * 0.94 / pitch).floor());
    final angle = VoiceRibbonGeometry.geometry.polar(band);
    final step = pitch / radius;
    final span = perStage * step;
    return [
      for (final blip in blips)
        for (var mark = 0; mark < perStage; mark++)
          () {
            final index = blips.indexOf(blip);
            // A stage's marks are centred on its own angle and run clockwise,
            // so the stage the blip is in is the angle a reader sees, and a
            // second burst of one stage follows the first.
            final at = angle +
                (mark - (perStage - 1) / 2) * step +
                index * span;
            final point = Offset(
              centre.dx + radius * math.sin(at),
              centre.dy - radius * math.cos(at),
            );
            // A ring mark is the approved badge's tile: one square of the
            // stage's own colour, whatever shape the stage draws on the pill.
            // The badge is a glance at *where* the pipe is, and the approved
            // concept draws every state as the same square tile; a rounded
            // hump or a paired hairline there read as scratches rather than
            // as the badge's marks.
            final marks = [
              _Bar(tile, 1.0),
            ];
            // The blip's own node is the mark at the middle of its run, which
            // is the one on the stage's own angle: a reader and a test find
            // the blip where its stage is, not where its run begins.
            final first = mark == perStage ~/ 2;
            return Positioned(
              // The blip's own node is its first mark, so a reader and a test
              // find the blip where it really is on the ring.
              key: first
                  ? ValueKey('voice-ribbon-${blip.id}')
                  : ValueKey('voice-ribbon-${blip.id}-$mark'),
              left: point.dx - tile / 2,
              top: point.dy - tile / 2,
              width: tile,
              height: tile,
              child: Transform.rotate(
                angle: at,
                alignment: Alignment.center,
                child: first
                    ? Semantics(
                        container: true,
                        excludeSemantics: true,
                        label: 'Blip, ${blip.label}',
                        child: Tooltip(
                          message: blip.label,
                          child: CustomPaint(
                            painter: _RunPainter(
                              bars: marks,
                              color: _blipColor(band, blip.form),
                              metrics: metrics,
                            ),
                          ),
                        ),
                      )
                    : CustomPaint(
                        painter: _RunPainter(
                          bars: marks,
                          color: _blipColor(band, blip.form),
                          metrics: metrics,
                        ),
                      ),
              ),
            );
          }(),
    ];
  }

  // ------------------------------------------------------------------ colors

  /// The stage's own colour: the grey of a level meter, the mint of kept
  /// speech, the blue of a transcription, the white of the agent's work and
  /// of the audio out.  A confirmed loss is drawn in the drop tone as an
  /// outline of dots, so it never reads as a live bar, and the palette never
  /// carries a fact alone.
  static Color _blipColor(VoiceRibbonBand band, VoiceRibbonForm form) {
    if (form == VoiceRibbonForm.dropped ||
        form == VoiceRibbonForm.failed ||
        form == VoiceRibbonForm.interrupted) {
      return _dropTone;
    }
    return switch (band) {
      VoiceRibbonBand.audio => _audio,
      VoiceRibbonBand.speech => HarnessColors.moss,
      VoiceRibbonBand.words => _words,
      VoiceRibbonBand.processing => _work,
      VoiceRibbonBand.audioOut => _work,
    };
  }
}

/// The approved bar metrics, in pill-heights.
///
/// Measured from the approved Option A ribbon (690x111 px, thirty-seven marks
/// in voice-pipeline-all-bars.png): a bar is 13.5 px across in a 111 px pill,
/// and one bar plus one gap is 24.6 px.  Every number below is that ratio, so
/// the bar keeps its proportions at any pill height instead of getting denser
/// or thinner as the surface changes.
class _BarMetrics {
  const _BarMetrics(this.height);

  /// The pill's height, in the same units as the bars.
  final double height;

  /// One bar's width: 0.122 of the pill's height.
  double get width => height * 0.122;

  /// The space between two bars: 0.099 of the pill's height.  The gap is the
  /// same everywhere, so the runs of neighbouring stages read as one ribbon
  /// rather than as five clusters with gutters between them.
  double get gap => height * 0.099;

  /// The finest bar the audio out is drawn in: the approved output stage is a
  /// pair of hairlines per bar, 0.035 of the pill's height across.
  double get hairline => math.max(1.0, height * 0.035);

  /// How far the runs sit from the pill's ends: 0.115 of its height, the
  /// rounded cap's own radius, so no bar spills past the cap.
  double get inset => height * 0.115;

  /// The tallest a run may be: the approved bars reach 0.62 of the pill's
  /// height, so a full-height bar never touches the pill's edge.  The run's
  /// box is this tall, and the fractions `_bars' is given are of it.
  double get tallest => height * 0.62;

  /// The quietest a bar may be: 0.10 of the pill's height, the approved
  /// short audio bars.
  double get shortest => math.max(2.0, height * 0.10);

  /// The pitch: one bar and one gap.
  double get pitch => width + gap;

  /// How many bars fit in ROOM at this pitch.
  int fit(double room) => math.max(1, (room / pitch).floor());
}

/// One bar of a run: how wide, how tall as a fraction of the run's own
/// tallest, and how it is filled.
@immutable
class _Bar {
  const _Bar(
    this.width,
    this.height, {
    this.rounded = false,
    this.segments = 0,
    this.dotted = false,
    this.paired = false,
  });

  final double width;

  /// The bar's height as a fraction of the room it has, 0..1.
  final double height;

  /// A level or speech bar has round ends; a transcription is square cut.
  final bool rounded;

  /// How many dashes a segmented bar is drawn in; 0 is a solid bar.
  final int segments;

  /// A confirmed drop: an outline of dots, never a fill.
  final bool dotted;

  /// The audio out is two hairlines a bar, the approved output stage's own
  /// paired form, rather than one solid bar.
  final bool paired;
}

/// The bars a form draws across SHARE of the pill, at most HEIGHT tall.
///
/// A run is several bars, so an event reads as a piece of a waveform rather
/// than a lone mark.  The count follows the room the run has and the approved
/// pitch; the silhouette follows the stage, so the shape says which stage it
/// is as plainly as the colour does.
List<_Bar> _bars(
  VoiceRibbonForm form,
  double? level,
  double wobble,
  double share,
  double height, {
  bool ring = false,
  double? pill,
  int? count,
}) {
  // WOBBLE is the warble's own phase in 0..1: a shape that waits swells by it
  // instead of stepping between two fixed frames, so the wait reads as a
  // breath rather than a blink.  It is 0 when motion is off, which puts every
  // shape at rest.
  final swell = wobble.clamp(0.0, 1.0);
  // HEIGHT is the run's own box, and PILL the height of the whole pill: an
  // approved fraction is of the pill, so it becomes a fraction of the run's
  // box by dividing by the box's share of the pill.  On the ring the run's box
  // is the badge, and a fraction is taken as it is.
  final boxShare = pill == null ? 1.0 : (height / pill);
  double ofPill(double fraction) =>
      (boxShare > 0 ? fraction / boxShare : fraction).clamp(0.06, 1.0);
  // A bar's width, gap and pitch are proportions of the PILL, not of the
  // run's box: HEIGHT is how tall this run may be, and deriving a bar's width
  // from it made every bar narrower than the approved ribbon's.
  final metrics = _BarMetrics(pill ?? height);
  // The ring's ticks are finer than the pill's bars, because a run there is
  // a short arc and not a stretch of a pill: the approved compact badge draws
  // a fine broken rim.  A tick's width and its gap are fractions of the run's
  // own box, so the ring looks the same at any badge size.
  final ringWidth = math.max(1.2, height * 0.20);
  final ringGap = math.max(1.0, height * 0.16);
  final ringPitch = ringWidth + ringGap;
  // A dotted run is built at the bar's own width: its cells are the bars it
  // would have drawn, and the painter breaks each one into dots.  Building it
  // at a hairline width reserved a whole bar's cell for a hairline's worth of
  // mark, which is what left the drop reading as a hole.
  // A ring mark is a tile, not a bar of a pill: its box IS the mark, so it is
  // built at the box's own width and fills it.  Built at the pill's fine ring
  // width instead, it was drawn as a sliver inside a square tile, which is
  // why the compact badge read as scratches rather than as the approved
  // badge's square marks.
  final width = ring ? share : metrics.width;
  // How many bars fit in SHARE: one bar plus one gap each, so a run never
  // overruns the stage's own stretch of the pill or the pill's cap.
  int fitCount(double barWidth, double gap) =>
      math.max(1, ((share + gap * 0.5) / (barWidth + gap)).floor());
  // The approved ribbon gives each stage the number of bars its own shape
  // has -- four for the microphone, five for kept speech, five for the words,
  // three for the agent's work, four for a drop and seven paired for the audio
  // out -- and lays those runs end to end at one pitch.  A run is therefore its
  // own fixed length, not a share of the pill filled to the brim, which is what
  // gives the original its 28 marks in a 690 px bar.  The ring has no such
  // sequence to keep: its run is an arc, so its count follows the arc.
  final bars = count ??
      (ring
          ? math.max(3, ((share + ringGap) / ringPitch).floor())
          : math.max(1, fitCount(width, metrics.gap)));

  /// SHAPE's own height at INDEX of COUNT, interpolated along the shape.
  ///
  /// The approved stages have a handful of bars each, and a run with more
  /// bars than the shape has interpolates it rather than repeating or
  /// flattening it, so the silhouette keeps its own profile at any density.
  double along(List<double> shape, int index) {
    if (shape.isEmpty) return 0.0;
    if (bars <= 1 || shape.length == 1) return shape.first;
    final at = index / (bars - 1) * (shape.length - 1);
    final low = at.floor().clamp(0, shape.length - 1);
    final high = (low + 1).clamp(0, shape.length - 1);
    final part = at - low;
    return shape[low] * (1.0 - part) + shape[high] * part;
  }

  List<_Bar> run(double Function(int) silhouette,
          {bool rounded = false, int segments = 0, bool dotted = false, bool paired = false}) =>
      [
        for (var index = 0; index < bars; index++)
          _Bar(
            width,
            silhouette(index).clamp(0.06, 1.0),
            rounded: rounded,
            segments: segments,
            dotted: dotted,
            paired: paired,
          ),
      ];

  switch (form) {
    case VoiceRibbonForm.level:
      // The microphone's own measurement: the approved audio hump, 0.10, 0.17,
      // 0.31, 0.18 of the pill's height, scaled by the level.  With no level
      // it is drawn at its quietest, never as silence.
      const shape = [0.10, 0.17, 0.31, 0.18];
      final measured = level == null ? 1.0 : (0.55 + 0.65 * level).clamp(0.0, 1.0);
      return run(
        (index) => ofPill(along(shape, index) * measured),
        rounded: true,
      );
    case VoiceRibbonForm.accepted:
      // Speech the filter kept: the approved speech hump.  Its own five bars
      // are 0.31, 0.48, 0.62, 0.39 and 0.23 of the pill's height, and a run
      // with more bars interpolates that shape rather than flattening it.
      const shape = [0.31, 0.48, 0.62, 0.39, 0.23];
      return run(
        (index) => ofPill(along(shape, index)),
        rounded: true,
      );
    case VoiceRibbonForm.transcribing:
      // Square-cut blue bars that warble in place while the words come.
      return run(
        (index) =>
          ofPill(0.35 + (index.isEven ? 1 : -1) * (0.02 + 0.03 * swell)),
      );
    case VoiceRibbonForm.transcribed:
      // The words have arrived: the approved flat row, every bar 0.35.
      return run((index) => ofPill(0.35));
    case VoiceRibbonForm.inTurn:
      // The agent has the words: the approved segmented work, 0.30 high.  Its
      // segment count changes as it waits, and its height swells with it: a
      // run whose only motion is the dashes inside it reads as a still mark,
      // so a waiting stage would show no breath at all.
      return run(
        (index) => ofPill(0.30 + 0.03 * swell),
        segments: 2 + (swell * 1.99).floor(),
      );
    case VoiceRibbonForm.answered:
      return run((index) => ofPill(0.30), segments: 3);
    case VoiceRibbonForm.ready:
      return run(
        (index) => ofPill(0.30 + 0.03 * swell),
        segments: 2 + (swell * 1.99).floor(),
      );
    case VoiceRibbonForm.held:
      return run(
        (index) => ofPill(0.18 + 0.12 * (index.isEven ? swell : 1 - swell)),
      );
    case VoiceRibbonForm.handed:
      return run((index) => ofPill(0.30 + 0.03 * swell), segments: 3);
    case VoiceRibbonForm.speaking:
      // The approved audio out: fine paired bars stepping 0.12 to 0.58, which
      // is the tallest run in the ribbon.
      const steps = [0.153, 0.261, 0.468, 0.577, 0.342, 0.180, 0.117];
      return run(
        (index) {
          final base = steps[index.clamp(0, steps.length - 1)];
          return ofPill(base * (0.88 + 0.12 * swell));
        },
        paired: true,
      );
    case VoiceRibbonForm.spoken:
      return run((index) => ofPill(0.18), paired: true);
    case VoiceRibbonForm.interrupted:
      return run((index) => ofPill(0.20), dotted: true);
    case VoiceRibbonForm.dropped:
      // A confirmed drop: the stage's bars as an outline of dots, at the
      // approved drop height of 0.50.  It stays where it was and goes nowhere.
      return run((index) => ofPill(0.50), dotted: true);
    case VoiceRibbonForm.failed:
      return run((index) => ofPill(0.50), dotted: true);
  }
}
/// The number of bars each approved stage draws, measured from
/// voice-pipeline-all-bars.png: the microphone four, kept speech five, the
/// words five, the agent's work three, a confirmed drop four and the audio out
/// seven paired hairlines.  These are the original's own counts, and they are
/// what make a populated ribbon come out at its 28 marks.
int _approvedBars(VoiceRibbonForm form) => switch (form) {
  VoiceRibbonForm.level => 4,
  VoiceRibbonForm.accepted => 5,
  VoiceRibbonForm.transcribing => 5,
  VoiceRibbonForm.transcribed => 5,
  VoiceRibbonForm.inTurn => 3,
  VoiceRibbonForm.answered => 3,
  VoiceRibbonForm.ready => 3,
  VoiceRibbonForm.held => 3,
  VoiceRibbonForm.handed => 3,
  VoiceRibbonForm.speaking => 7,
  VoiceRibbonForm.spoken => 7,
  VoiceRibbonForm.interrupted => 4,
  VoiceRibbonForm.dropped => 4,
  VoiceRibbonForm.failed => 4,
};

/// One run waiting to be placed: which stage it is in, the mark itself, its
/// bars, and how many cells of the ribbon's grid it owns.
class _Placement {
  const _Placement(this.band, this.blip, this.bars, this.cells);

  final VoiceRibbonBand band;
  final VoiceRibbonBlip blip;
  final List<_Bar> bars;

  /// The cells this run occupies on the grid: one per bar it draws.
  final double cells;
}

/// One run on the ribbon: the stage's own bars, never its colour alone.
class _Run extends StatelessWidget {
  const _Run({
    required this.blip,
    required this.bars,
    required this.color,
    required this.metrics,
    required this.barWidth,
    required this.gap,
    required this.rotate,
  });

  final VoiceRibbonBlip blip;
  final List<_Bar> bars;
  final Color color;
  final _BarMetrics metrics;

  /// One bar's width on the grid the whole ribbon is drawn on.
  final double barWidth;

  /// The gap between two bars on that same grid.
  final double gap;
  final double rotate;

  @override
  Widget build(BuildContext context) {
    final label = blip.label;
    return Tooltip(
      message: label,
      excludeFromSemantics: true,
      child: Semantics(
        container: true,
        excludeSemantics: true,
        // A reader is told what the node is, then its own words.
        label: 'Blip, $label',
        child: CustomPaint(
          painter: _RunPainter(
            bars: bars,
            color: color,
            metrics: metrics,
            barWidth: barWidth,
            gap: gap,
          ),
        ),
      ),
    );
  }
}

class _RunPainter extends CustomPainter {
  const _RunPainter({
    required this.bars,
    required this.color,
    required this.metrics,
    this.barWidth,
    this.gap,
  });

  final List<_Bar> bars;
  final Color color;
  final _BarMetrics metrics;

  /// One bar's width on the ribbon's own grid, or null to take the bar's own
  /// approved width -- a ring tick, whose box is the tick itself.
  final double? barWidth;

  /// The gap beside a bar on that grid, so the pitch is barWidth + gap.
  final double? gap;

  @override
  void paint(Canvas canvas, Size size) {
    final fill = Paint()..color = color;
    final centreY = size.height / 2;
    // Every bar is drawn at the width the caller's grid gave it, and the next
    // one starts a whole pitch later.  The width and the gap are scaled
    // together by that same grid, so the approved bar-to-gap ratio survives
    // any density and two neighbouring bars can never close on each other.
    //
    // A ring tick carries no grid: its box IS one tick, so it is drawn at its
    // own width and its own height and there is nothing to lay out beside it.
    final own = barWidth ?? (bars.isEmpty ? size.width : bars.first.width);
    final beside = gap ?? 0.0;
    final wanted = math.max(0.0, own + beside);
    final room = bars.isEmpty ? 0.0 : math.max(0.0, size.width) / bars.length;
    final step = wanted > 0 ? math.min(wanted, room) : room;
    final scale = wanted > 0 ? step / wanted : 1.0;
    // A dotted run fills the cell it was given: the dots are the broken form,
    // and a hairline-width column of dots in a whole cell left most of the
    // cell empty, which read as a hole in the ribbon rather than a drop.
    final width = own * scale;
    var x = 0.0;
    for (final bar in bars) {
      final height = math.max(2.0, size.height * bar.height.clamp(0.0, 1.0));
      final rect = Rect.fromLTWH(x, centreY - height / 2, width, height);
      if (bar.dotted) {
        _dots(canvas, rect, fill);
      } else if (bar.segments > 0) {
        _segmented(canvas, rect, bar.segments, fill);
      } else if (bar.paired) {
        // The audio out is a pair of hairlines inside one bar's own width:
        // the approved output stage draws two thin lines with a gap between
        // them, which is why it reads finer than the work beside it.
        final each = math.max(0.8, width * 0.34);
        final space = math.max(0.8, width - each * 2);
        canvas.drawRect(
          Rect.fromLTWH(rect.left, rect.top, each, height),
          fill,
        );
        canvas.drawRect(
          Rect.fromLTWH(rect.left + each + space, rect.top, each, height),
          fill,
        );
      } else if (bar.rounded) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect, Radius.circular(width / 2)),
          fill,
        );
      } else {
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect, const Radius.circular(0.8)),
          fill,
        );
      }
      // The next bar starts one whole pitch later, so the gap beside this
      // bar is exactly the gap the grid gave it.
      x += step;
    }
  }

  void _segmented(Canvas canvas, Rect rect, int segments, Paint paint) {
    final gap = math.max(1.0, metrics.gap * 0.55);
    final dash = math.max(1.2, (rect.height - gap * (segments - 1)) / segments);
    var y = rect.top;
    for (var index = 0; index < segments; index++) {
      canvas.drawRect(Rect.fromLTWH(rect.left, y, rect.width, dash), paint);
      y += dash + gap;
    }
  }

  void _dots(Canvas canvas, Rect rect, Paint paint) {
    // The approved drop is a broken bar: a column of small round dots down the
    // bar's own width.  Measured from the original, a dot is 2 px at a 5 px
    // pitch on an 89 px pill -- 0.022 and 0.056 of its height -- so the column
    // reads as dotted rather than as beads (too fat) or a solid line (too
    // tight).
    final dot = math.max(0.7, math.min(rect.width * 0.34, metrics.height * 0.022));
    final step = math.max(dot * 1.8, metrics.height * 0.056);
    final centre = rect.left + rect.width / 2;
    final down = math.max(1, ((rect.height - dot) / step).floor() + 1);
    final start = rect.top + (rect.height - (down - 1) * step) / 2;
    for (var row = 0; row < down; row++) {
      canvas.drawCircle(Offset(centre, start + row * step), dot, paint);
    }
  }

  @override
  bool shouldRepaint(_RunPainter old) =>
      old.color != color || old.bars != bars || old.metrics != metrics;
}

/// The continuous bar behind the runs: one pill, no dividers, no marks of its
/// own.
class _PillPainter extends CustomPainter {
  const _PillPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(0, 0, size.width, size.height);
    final radius = Radius.circular(size.height / 2);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, radius),
      Paint()..color = _pill,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect.deflate(0.6), radius),
      Paint()
        ..color = _pillEdge
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );
  }

  @override
  bool shouldRepaint(_PillPainter old) => false;
}

/// The compact badge the runs sit on: one filled disc with a hairline
/// rim, the way the approved compact glance is drawn.  No stage dots and no
/// words: the bars on the rim are the whole picture.
class _RingPainter extends CustomPainter {
  const _RingPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final centre = Offset(size.width / 2, size.height / 2);
    // The runs sit on a track of this radius, so the disc reaches a little
    // past them and the avatar reads as one filled badge.
    final radius =
        size.shortestSide / 2 -
        size.shortestSide * VoiceRibbonView.ringInset;
    canvas.drawCircle(centre, radius, Paint()..color = _pill);
    canvas.drawCircle(
      centre,
      radius - 0.6,
      Paint()
        ..color = _pillEdge
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.1,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) => false;
}

/// The pill, and the hairline that keeps it whole on a dark surface.
///
/// #15221D is the approved pill's own fill, sampled from the Option A
/// original; #2A3A33 is its hairline.  The ribbon is darker and greener than
/// the surrounding surface, which is what makes it read as one solid bar.
const _pill = Color(0xFF15221D);
const _pillEdge = Color(0xFF2A3A33);

/// The stage palette: grey, mint, blue, white -- the same four in both
/// clients, and never a fifth for a state that has a shape of its own.
const _audio = Color(0xFF9AA0A6);
const _words = Color(0xFF8B9CF7);
const _work = Color(0xFFE8E9EC);
const _dropTone = Color(0xFF8A9099);

