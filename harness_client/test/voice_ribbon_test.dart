import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/voice/voice_backend.dart';
import 'package:harness_client/src/voice/voice_pipeline.dart';
import 'package:harness_client/src/voice/voice_ribbon.dart';

final _now = DateTime(2026, 11, 9, 12);

VoicePipelineSnapshot _snapshot({
  VoiceInputState input = VoiceInputState.live,
  double level = 0.56,
  bool levelSeen = true,
  DateTime? levelAt,
  bool speechActive = false,
  List<VoiceSegment> segments = const [],
  List<VoiceTurn> turns = const [],
  List<VoiceReply> replies = const [],
  int accepted = 0,
  int dropped = 0,
  bool playing = false,
}) => VoicePipelineSnapshot(
  generation: 1,
  input: input,
  level: level,
  levelSeen: levelSeen,
  levelAt: levelAt ?? _now,
  speechActive: speechActive,
  segments: segments,
  turns: turns,
  replies: replies,
  accepted: accepted,
  dropped: dropped,
  spoken: 0,
  playing: playing,
);

VoiceSegment _segment(
  String id,
  VoicePipelineStage stage, {
  Duration? duration,
  VoiceSegmentDrop? drop,
  String? text,
  DateTime? endedAt,
}) => VoiceSegment(
  id: id,
  stage: stage,
  generation: 1,
  duration: duration,
  drop: drop,
  text: text,
  endedAt: endedAt,
);

VoiceRibbon _ribbon(VoicePipelineSnapshot snapshot, {DateTime? now}) =>
    VoiceRibbon.fromSnapshot(snapshot, now ?? _now);

VoiceRibbonBlip _blip(VoiceRibbon ribbon, String id) =>
    ribbon.blips.firstWhere((blip) => blip.id == id);

void main() {
  group('one blip per real segment', () {
    test('a single utterance is one blip, never two stages at once', () {
      var snapshot = _snapshot(
        segments: [
          _segment(
            'u-1',
            VoicePipelineStage.accepted,
            duration: const Duration(milliseconds: 1400),
          ),
        ],
        accepted: 1,
      );
      var ribbon = _ribbon(snapshot);
      expect(ribbon.blips.map((blip) => blip.id), ['input', 'u-1']);
      expect(_blip(ribbon, 'u-1').band, VoiceRibbonBand.speech);

      snapshot = _snapshot(
        segments: [
          _segment(
            'u-1',
            VoicePipelineStage.transcribing,
            duration: const Duration(milliseconds: 1400),
          ),
        ],
        accepted: 1,
      );
      ribbon = _ribbon(snapshot);
      expect(
        ribbon.blips.map((blip) => blip.id),
        ['input', 'u-1'],
        reason: 'the blip moved; it was not copied',
      );
      expect(_blip(ribbon, 'u-1').band, VoiceRibbonBand.words);
    });

    test('a real handoff moves one blip and clears its old place', () {
      final accepted = _ribbon(
        _snapshot(
          segments: [
            _segment('u-1', VoicePipelineStage.accepted),
          ],
        ),
      );
      final transcribed = _ribbon(
        _snapshot(
          segments: [
            _segment('u-1', VoicePipelineStage.transcribed),
          ],
        ),
      );
      final from = VoiceRibbonGeometry.geometry
          .linear(_blip(accepted, 'u-1').band, 0)
          .fraction;
      final to = VoiceRibbonGeometry.geometry
          .linear(_blip(transcribed, 'u-1').band, 0)
          .fraction;
      expect(to, greaterThan(from));
      expect(transcribed.blips.where((blip) => blip.id == 'u-1').length, 1);
      expect(
        transcribed.blips.any((blip) => blip.band == VoiceRibbonBand.speech),
        isFalse,
      );
    });

    test('independent segments are two blips in their own stages', () {
      final ribbon = _ribbon(
        _snapshot(
          segments: [
            _segment('u-1', VoicePipelineStage.transcribed),
            _segment('u-2', VoicePipelineStage.accepted),
          ],
        ),
      );
      expect(_blip(ribbon, 'u-1').band, VoiceRibbonBand.words);
      expect(_blip(ribbon, 'u-2').band, VoiceRibbonBand.speech);
      expect(ribbon.blips.length, 3);
    });

    test('two bursts in one stage take two lanes, not one mark', () {
      final ribbon = _ribbon(
        _snapshot(
          segments: [
            _segment('u-1', VoicePipelineStage.accepted),
            _segment('u-2', VoicePipelineStage.accepted),
          ],
        ),
      );
      final speech = ribbon.bandAt(VoiceRibbonBand.speech, _now);
      expect(speech.map((blip) => blip.lane), [0, 1]);
    });

    test('a partial and its final are one blip', () {
      final ribbon = _ribbon(
        _snapshot(
          segments: [
            _segment('u-1', VoicePipelineStage.transcribed, text: 'hello'),
          ],
        ),
      );
      expect(
        ribbon.blips.where((blip) => blip.id == 'u-1').length,
        1,
      );
      expect(_blip(ribbon, 'u-1').label, 'u-1 · transcribed');
    });
  });

  group('what stopped stays where it stopped', () {
    test('a dropped burst is a broken form in its own band', () {
      final dropped = _ribbon(
        _snapshot(
          segments: [
            _segment(
              'u-1',
              VoicePipelineStage.dropped,
              duration: const Duration(milliseconds: 640),
              drop: VoiceSegmentDrop.tooShort,
              endedAt: _now,
            ),
          ],
          dropped: 1,
        ),
      );
      final blip = _blip(dropped, 'u-1');
      expect(blip.band, VoiceRibbonBand.speech);
      expect(blip.form, VoiceRibbonForm.dropped);
      expect(blip.terminal, isTrue);
      expect(blip.label, 'u-1 · dropped · 640ms · too short');
      // After its linger it clears without moving anywhere.
      expect(blip.visibleAt(_now.add(const Duration(seconds: 4))), isFalse);
    });

    test('a burst whose words had no request stays in the words band', () {
      final ribbon = _ribbon(
        _snapshot(
          segments: [
            _segment(
              'u-1',
              VoicePipelineStage.dropped,
              drop: VoiceSegmentDrop.noWords,
              endedAt: _now,
            ),
          ],
        ),
      );
      expect(_blip(ribbon, 'u-1').band, VoiceRibbonBand.words);
      expect(_blip(ribbon, 'u-1').label, 'u-1 · dropped · no words');
    });

    test('a failed transcription is not a drop, and stays in words', () {
      final ribbon = _ribbon(
        _snapshot(
          segments: [
            _segment(
              'u-1',
              VoicePipelineStage.failed,
              endedAt: _now,
            ),
          ],
        ),
      );
      final blip = _blip(ribbon, 'u-1');
      expect(blip.form, VoiceRibbonForm.failed);
      // Speech to text failed: the blip is drawn where the words would have
      // been, with its own cross, not moved on and not called a drop.
      expect(blip.band, VoiceRibbonBand.words);
      expect(blip.form, isNot(VoiceRibbonForm.dropped));
    });

    test('mute, cancelled and interrupted are all distinguishable', () {
      final ribbon = _ribbon(
        _snapshot(
          segments: [
            _segment(
              'r-1',
              VoicePipelineStage.dropped,
              drop: VoiceSegmentDrop.tooShort,
              endedAt: _now,
            ),
            _segment(
              'r-2',
              VoicePipelineStage.dropped,
              drop: VoiceSegmentDrop.cancelled,
              endedAt: _now,
            ),
            _segment(
              'r-3',
              VoicePipelineStage.dropped,
              drop: VoiceSegmentDrop.failed,
              endedAt: _now,
            ),
          ],
          replies: [
            const VoiceReply(
              id: 'n-1',
              stage: VoiceReplyStage.interrupted,
              generation: 1,
              endedAt: null,
            ),
          ],
        ),
      );
      expect(_blip(ribbon, 'r-1').form, VoiceRibbonForm.dropped);
      expect(_blip(ribbon, 'r-2').form, VoiceRibbonForm.dropped);
      expect(_blip(ribbon, 'r-3').form, VoiceRibbonForm.failed);
      expect(_blip(ribbon, 'n-1').form, VoiceRibbonForm.interrupted);
      expect(_blip(ribbon, 'n-1').band, VoiceRibbonBand.audioOut);
    });
  });

  group('waiting is drawn in place', () {
    test('a waiting blip warbles and never advances', () {
      final ribbon = _ribbon(
        _snapshot(
          segments: [
            _segment('u-1', VoicePipelineStage.transcribing),
          ],
        ),
      );
      final blip = _blip(ribbon, 'u-1');
      expect(blip.waits, isTrue);
      expect(blip.band, VoiceRibbonBand.words);
      expect(ribbon.frameAt(_now), isNot(ribbon.frameAt(
        _now.add(const Duration(milliseconds: 250)),
      )));
    });

    test('reduced motion stops the warble and keeps every word', () {
      final snapshot = _snapshot(
        segments: [
          _segment('u-1', VoicePipelineStage.transcribing),
        ],
      );
      final moving = VoiceRibbon.fromSnapshot(snapshot, _now);
      final still = VoiceRibbon.fromSnapshot(snapshot, _now, motion: false);
      expect(moving.summary, still.summary);
      expect(
        still.frameAt(_now),
        still.frameAt(_now.add(const Duration(milliseconds: 400))),
      );
      expect(moving.nextChange(_now), isNotNull);
      expect(still.nextChange(_now), isNull);
    });

    test('every redraw shows a different point of the breath', () {
      // The host redraws once per warbleFramesPerSecond.  If the breath's
      // period were that interval, every redraw would sample the sine at the
      // same phase: the heights would never move and the run would stand
      // still, which is a blink dressed up as a breath.
      final ribbon = _ribbon(
        _snapshot(
          segments: [
            _segment('u-1', VoicePipelineStage.transcribing),
          ],
        ),
      );
      const step = Duration(
        microseconds:
            Duration.microsecondsPerSecond ~/
            VoiceRibbon.warbleFramesPerSecond,
      );
      final phases = [
        for (var tick = 0; tick < 16; tick++)
          ribbon.warblePhaseAt(_now.add(step * tick)),
      ];
      for (var index = 1; index < phases.length; index++) {
        expect(
          (phases[index] - phases[index - 1]).abs(),
          greaterThan(0.001),
          reason: 'redraw $index must move the breath',
        );
      }
      // A swell, not a ramp: it rises and falls through most of its range.
      expect(
        phases.reduce(math.max) - phases.reduce(math.min),
        greaterThan(0.9),
      );
      for (final phase in phases) {
        expect(phase, inInclusiveRange(0.0, 1.0));
      }
    });

    test('the one-row frame follows the breath, not the redraw', () {
      final ribbon = _ribbon(
        _snapshot(
          segments: [
            _segment('u-1', VoicePipelineStage.transcribing),
          ],
        ),
      );
      const step = Duration(
        microseconds:
            Duration.microsecondsPerSecond ~/
            VoiceRibbon.warbleFramesPerSecond,
      );
      // The glyph frame changes at the breath's own pace: over sixteen
      // redraws it is not simply alternating, which is what a flip at the
      // redraw rate gives.
      final frames = [
        for (var tick = 0; tick < 16; tick++)
          ribbon.frameAt(_now.add(step * tick)),
      ];
      expect(frames.toSet().length, 2, reason: 'both glyphs are used');
      var flips = 0;
      for (var index = 1; index < frames.length; index++) {
        if (frames[index] != frames[index - 1]) flips++;
      }
      // A flip every redraw would be 15; a breath crossing a couple of times
      // is far fewer.
      expect(flips, lessThan(6));
    });

    test('the next change names only what moves without an event', () {
      final quiet = _ribbon(
        _snapshot(
          segments: [
            _segment('u-1', VoicePipelineStage.transcribed),
          ],
        ),
      );
      expect(quiet.nextChange(_now), isNull);
    });
  });

  group('input and output', () {
    test('the microphone and the speaker are two marks at once', () {
      final ribbon = _ribbon(
        _snapshot(
          segments: [
            _segment('u-1', VoicePipelineStage.accepted),
          ],
          replies: const [
            VoiceReply(
              id: 'n-1',
              stage: VoiceReplyStage.speaking,
              generation: 1,
            ),
          ],
          playing: true,
        ),
      );
      expect(_blip(ribbon, 'input').band, VoiceRibbonBand.audio);
      expect(_blip(ribbon, 'u-1').band, VoiceRibbonBand.speech);
      expect(_blip(ribbon, 'n-1').band, VoiceRibbonBand.audioOut);
    });

    test('a reply that was only handed is not drawn as speaking', () {
      final ribbon = _ribbon(
        _snapshot(
          replies: const [
            VoiceReply(
              id: 'n-1',
              stage: VoiceReplyStage.handed,
              generation: 1,
            ),
          ],
        ),
      );
      final blip = _blip(ribbon, 'n-1');
      expect(blip.form, VoiceRibbonForm.handed);
      expect(blip.form, isNot(VoiceRibbonForm.speaking));
      expect(blip.label, 'n-1 · handed');
    });

    test('a level that is not there is hollow, never silence', () {
      final stale = _ribbon(
        _snapshot(levelAt: _now.subtract(const Duration(seconds: 5))),
      );
      expect(_blip(stale, 'input').level, isNull);
      expect(_blip(stale, 'input').label, 'Level · no data');
      // A closed microphone has no audio blip at all.
      final closed = _ribbon(_snapshot(input: VoiceInputState.muted));
      expect(closed.blips.any((blip) => blip.id == 'input'), isFalse);
    });
  });

  group('the linear ribbon and the compact ring are one picture', () {
    test('they draw the same blips with the same words', () {
      final ribbon = _ribbon(
        _snapshot(
          segments: [
            _segment(
              'u-1',
              VoicePipelineStage.transcribed,
              text: 'hello',
            ),
            _segment(
              'u-2',
              VoicePipelineStage.dropped,
              drop: VoiceSegmentDrop.tooShort,
              endedAt: _now,
            ),
          ],
          replies: const [
            VoiceReply(
              id: 'n-1',
              stage: VoiceReplyStage.handed,
              generation: 1,
            ),
          ],
        ),
      );
      for (final band in VoiceRibbonBand.values) {
        expect(
          ribbon.blips.where((blip) => blip.band == band).map((b) => b.id),
          ribbon.bandAt(band, _now).map((b) => b.id),
        );
      }
    });

    test('the stage order around the ring is the order along the ribbon', () {
      final angles = VoiceRibbonBand.values
          .map((band) => VoiceRibbonGeometry.geometry.polar(band))
          .toList();
      for (var index = 1; index < angles.length; index++) {
        expect(angles[index], greaterThan(angles[index - 1]));
      }
      expect(angles.first, 0);
      // Twelve o'clock is the first stage, and a quarter turn clockwise is
      // to its right: the angle, not the clock, is the stage.
      expect(angles[1], closeTo(math.pi * 2 / 5, 1e-9));
    });

    test('the ring does not duplicate a blip that moved', () {
      final ribbon = _ribbon(
        _snapshot(
          segments: [
            _segment('u-1', VoicePipelineStage.transcribing),
          ],
        ),
      );
      final words = ribbon.bandAt(VoiceRibbonBand.words, _now);
      expect(words.length, 1);
      expect(
        ribbon.blips.where((blip) => blip.id == 'u-1').length,
        1,
      );
    });

    test('a lane sits nearer the centre, never at another stage', () {
      expect(VoiceRibbonGeometry.geometry.radius(0), 1.0);
      expect(VoiceRibbonGeometry.geometry.radius(1), lessThan(1.0));
      expect(VoiceRibbonGeometry.geometry.radius(2), lessThan(
        VoiceRibbonGeometry.geometry.radius(1),
      ));
    });
  });

  group('stale generations, stop and restart', () {
    test('a new conversation draws nothing from the last one', () {
      final tracker = VoicePipelineTracker(clock: () => _now);
      tracker.begin();
      tracker.accept('u-1', duration: const Duration(seconds: 1));
      expect(
        VoiceRibbon.fromSnapshot(tracker.snapshot, _now)
            .blips
            .map((blip) => blip.id),
        contains('u-1'),
      );
      tracker.begin();
      final ribbon = VoiceRibbon.fromSnapshot(tracker.snapshot, _now);
      expect(ribbon.blips.any((blip) => blip.id == 'u-1'), isFalse);
      expect(ribbon.blips.any((blip) => blip.id == 'input'), isTrue);
    });

    test('a tracker stamps when a blip stopped', () {
      final tracker = VoicePipelineTracker(clock: () => _now);
      tracker.begin();
      tracker.accept('u-1', duration: const Duration(seconds: 1));
      tracker.drop('u-1');
      final segment = tracker.snapshot.segments.first;
      expect(segment.endedAt, _now);
      final ribbon = VoiceRibbon.fromSnapshot(tracker.snapshot, _now);
      expect(_blip(ribbon, 'u-1').visibleAt(
        _now.add(const Duration(seconds: 4)),
      ), isFalse);
    });

    test('a mute drops the reply, and the ribbon says so', () {
      final tracker = VoicePipelineTracker(clock: () => _now);
      tracker.begin();
      final id = tracker.replyReady('The queue has two tasks.');
      tracker.replyHanded(id);
      tracker.replyDropped(id);
      final ribbon = VoiceRibbon.fromSnapshot(tracker.snapshot, _now);
      final blip = _blip(ribbon, id);
      expect(blip.form, VoiceRibbonForm.dropped);
      expect(blip.band, VoiceRibbonBand.audioOut);
    });
  });

  group('the words', () {
    test('the bands name the pipe, in order', () {
      expect(
        VoiceRibbonBand.values.map((band) => band.label),
        ['Audio', 'Speech', 'Words', 'Processing', 'Audio out'],
      );
      expect(
        VoiceRibbonBand.values.map((band) => band.help),
        [
          'Microphone level before the speech filter',
          'Speech kept for transcription',
          'Speech to text',
          'Agent work',
          'Playback',
        ],
      );
      expect(
        VoiceRibbon.legend,
        'Audio · Speech · Words · Processing · Audio out',
      );
    });

    test('there is no stage the pipe does not have', () {
      final words = [
        ...VoiceRibbonBand.values.map((band) => band.label),
        ...VoiceRibbonBand.values.map((band) => band.help),
        VoiceRibbon.legend,
      ].join(' ').toLowerCase();
      expect(words, isNot(contains('transcod')));
      expect(words, isNot(contains('upload')));
      expect(words, isNot(contains('transfer')));
    });

    test('a blip is named by its id, stage and measurement', () {
      final ribbon = _ribbon(
        _snapshot(
          segments: [
            _segment(
              'u-1',
              VoicePipelineStage.transcribed,
              duration: const Duration(milliseconds: 900),
            ),
            _segment(
              'r-1',
              VoicePipelineStage.dropped,
              drop: VoiceSegmentDrop.noWords,
              endedAt: _now,
            ),
          ],
        ),
      );
      expect(_blip(ribbon, 'u-1').label, 'u-1 · transcribed · 900ms');
      expect(_blip(ribbon, 'r-1').label, 'r-1 · dropped · no words');
      expect(_blip(ribbon, 'input').label, 'Level · 56%');
    });
  });
}
