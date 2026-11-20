# The voice ribbon: one bar, its stages, and its compact ring

Design note, November 2026.  **Implemented in Emacs and Flutter.**  It
refines [voice-pipeline-visualization.md](../voice-pipeline-visualization.md)
-- the five-column strip that page describes stays as the *details* view --
and shares the state model with
[the compact buddy](voice-buddy-compact.md), which hosts the same bars
rather than a second renderer.

Three questions this page answers:

1. Why the strip became a **continuous ribbon** whose position is the
   stage, and what a person can read off it at a glance.
2. What **the same blips around a circle** mean on a compact surface, and
   why it is a second drawing of one model, not a second model.
3. Exactly which real event puts a mark where, what the ribbon refuses to
   say, and what each platform does and does not allow.

The rule that governs all of it: **nothing moves on a clock**.  A blip
appears when the pipe kept a burst, moves when the stage it waits on
reports, and clears its old place.  A blip that waits warbles *in place*.
A loss stays where the pipe lost it and clears after a bounded linger.

## Why a ribbon

The strip before this change drew five labelled columns, each a small
stack of chips:

```text
Input              Filter                 Words                    Turn                 Speaker
level              x dropped · too short  ... transcribing · 2.0s  ok answered · 3.0s   speaking
Mic · live         o accepted · 1.4s      = transcribed · 1.0s
```

Every column is a box, and a burst that moved was **erased from one box
and drawn in another**, which reads as two different things happening.
Five boxes also cost five headings, five tooltips and a vertical rule
between each pair, in a surface that exists to answer one question — *is
my voice getting through, and where is it now?*

The ribbon answers it with one bar.  Its horizontal position (or, on a
compact surface, its angle) is the stage in the pipe, so a person reads
direction rather than labels:

```text
▃▄▄▅▅▆▅▅▄▄▃▄▅▅▆▇█▇▆▅▅▄▁▁▁▁▁▁▁▁▁▁▁ ≡≡≡≡≡≡≡≡≡≡≡ ▏▏▏▏▏▏▏▏▏▏▏
```

- one blip per real id, so a single utterance is never in two stages;
- independent segments are in different places **at the same time**,
  because they really are;
- **the bar is the whole control**: no heading over it, no labels row under
  it, no legend beside it and no summary line beneath it.  A stage with
  nothing in it draws **nothing**, and keeps only its place in the order,
  so a handoff moves a mark into it rather than sliding the ribbon along;
  the stages still read as one continuous waveform because they run on one
  pitch, never because something fills the gaps;
- the words are the tooltips, the screen-reader nodes and the voice
  settings, and the control has **no way into the settings**: a person
  who wants the ids and the measurements opens the voice settings, which
  is the only place they are drawn.

## The five stages, and why there are five

The approved prototype's legend has six words: Audio, Speech,
Transcoding, Processing, Audio out, Dropped.  The pipe has **five**
stages and no transcoding step: a burst is captured, the speech filter
keeps or drops it, a transcriber turns it into words, an agent turn runs,
and a player speaks the reply.  Adding a Transcoding band would draw a
step that never happens, so the ribbon has no such band and
`harness-ui-voice-ribbon-no-invented-stages` asserts the word is absent
from every string the surface says.  Dropped is not a stage either: it is
a *form* a blip takes in the stage that lost it.

| Band | Word | Tooltip | The real event that puts a blip there |
| --- | --- | --- | --- |
| `input` | `Audio` | `Microphone level before the speech filter` | the sidecar's `level` event (mean absolute sample, at most ten a second), or the client's `VoiceLevelEvent` from `VoiceActivityDetector.level` |
| `speech` | `Speech` | `Speech kept for transcription` | `segment state=accepted` — the sidecar's `Vad._finish`, or the clip backend's `_accept`; a `dropped` blip stays here when the filter rejected it |
| `words` | `Words` | `Speech to text` | `transcribing` / `transcribed` — the transcription worker, or a provider caption |
| `turn` | `Processing` | `Agent work` | `in-turn` / `answered` — the UI's own delegation and the turn's end |
| `speaker` | `Audio out` | `Playback` | a reply's `ready` / `held` / `handed` / `speaking` / `spoken` / `interrupted` |

A dropped or failed burst is drawn **in the band it had reached**, which
the model records as `:from` (Emacs) or `column` (Flutter) at the moment
the pipe ended it.  A burst the filter rejected is a broken mark in
`Speech`; one whose transcript came back empty is a broken mark in
`Words`.  The ribbon never draws a loss at a step the burst never took.

### The two input bands say what the input measures

The words above are a **microphone** session's.  A provider that reads a
face measures mouth motion instead of a sample level, and the pipe's own
vocabulary already says so: its capture is `Camera · live`, its level is
`Motion · 56%` and its gate is `Mouth · moving`.  The ribbon draws no
words, but its stage words are what the settings and a screen reader say,
so for a camera session they are the pipe's, not the microphone's:

| Band | Word | Tooltip |
| --- | --- | --- |
| `input` | `Motion` | `Mouth motion before the speech gate` |
| `speech` | `Mouth` | `Mouth motion kept for transcription` |

The other three bands are the same for both inputs: a camera's words are
still transcribed, a turn still runs and a reply is still spoken.
`harness-voice-ribbon-stage-labels` takes the pipeline and returns the
pipe's own columns, so the two surfaces cannot drift apart, and
`harness-ui-voice-ribbon-a-camera-keeps-its-own-words` asserts both that a
camera never reads `Mic`, `Microphone` or `Audio ·`, and that the
microphone's five words are unchanged.

## One blip per real id

| Blip | Its id | Why it is one mark |
| --- | --- | --- |
| the microphone | `input` | the level is one measurement of one open capture |
| a kept or lost burst | `u-N` / `r-N` | the backend's own id, from the moment it decided |
| a reply | `n-N` | the node the speaker was given |

**A turn is deliberately not a blip.**  The segments that fed it are
already marks in the `Processing` band, and drawing the turn as well
would show one utterance twice and suggest that one reply answers one
utterance — a one-to-one causality the events do not support.  A turn
with two utterances is two marks; a turn with two replies is two marks in
`Audio out`.  The fan-in is in the events, and the ribbon shows what the
events show.

**Two bursts in one stage are two marks**, on two lanes (three by
default, `harness-voice-ribbon-lanes`): the oldest takes the first lane
and a newer one sits beside it instead of covering it.

### Correlation boundaries

The ribbon draws what the events say, and no more:

- **Ids are the backend's.**  A segment keeps `u-N` / `r-N` from acceptance
  to the turn, and a reply keeps `n-N`; a partial transcript rewrites the
  same blip, never adding one.  Two clients reading the same ids draw the
  same picture.
- **A stage only moves forward.**  A late `accepted` after a `transcribing`
  moves nothing; a terminal stage (`dropped`, `failed`, `answered`,
  `spoken`, `interrupted`) is never left.  A duplicate is counted in the
  model's ignored total and draws nothing new.
- **Generations separate conversations.**  Every blip belongs to a
  generation; a new call, a restart or a route change bumps it and clears
  the bars, so an event that names the last conversation draws nothing.
  Flutter additionally stamps each backend's epoch, so a replaced
  backend's playback cannot end a newer reply's mark.
- **A fan-in is shown, not merged.**  Two utterances in one turn are two
  blips in `Processing`, and two replies are two blips in `Audio out`.
  The ribbon never draws one arrow from an utterance to a reply.
- **A stop is drawn as the stop it was.**  Mute, pause, cancel, interrupt
  and a failure end a blip with their own reason (`muted`, `paused`,
  `cancelled`, `interrupted`, `failed`), drawn where it stopped and
  cleared after the linger; nothing is left waiting for an event that
  will not come.

## What moves, and what only looks alive

| The blip | Its shape | Moves when | Reduced motion |
| --- | --- | --- | --- |
| microphone | a hump of rounded blocks, tallest in the middle | the level arrives | the bars stand still at the last measured height |
| accepted | a hump of rounded mint blocks | the stage reports | unchanged |
| transcribing | alternating square-cut blue blocks | warbles in place | the first frame, still |
| transcribed | flat square-cut blue blocks | the stage reports | unchanged |
| in turn | segmented white bars | warbles in place | the first frame |
| answered | segmented white bars | clears after `harness-voice-ribbon-linger` | the same |
| ready / held / handed | segmented or paired white bars | warble in place while waiting | the first frame |
| speaking | fine paired white bars | the player's own report | unchanged |
| spoken | fine paired white bars | clears after the linger | the same |
| interrupted | an outline of dots | clears after the linger | the same |
| dropped | an outline of dots | clears after the linger, **never advances** | the same |
| failed | a cross | clears after the linger | the same |

The warble is a *decoration of the stage*, never a step towards the
next: its frames are the same stage drawn twice, and a waiting blip
never changes band.  `harness-voice-ribbon-motion` nil (Emacs) and
`MediaQuery.disableAnimations` (Flutter) stop it with every word, shape
and position unchanged — the tests compare the two renditions line for
line.

The breath has a **period of its own**, and it is not the redraw
interval.  A host redraws a waiting run once per
`harness-voice-ribbon-warble-rate` (5 a second); the breath takes
`harness-voice-ribbon-warble-breath` (1.6 s), so each redraw samples a
different point of it.  Sampling a sine once per period gives the same
phase every time — the heights never move and the run stands still,
which is a blink dressed up as a breath.  That is what the first
version of this animation did, and the tests that were supposed to
catch it passed because they sampled *between* redraws rather than at
them; `-the-breath-is-not-the-redraw` and `-the-breath-reaches-the-bar`
now sample at the redraws themselves and fail on the frozen version.
The one-row forms (the badge's glyphs, the segmented work) show the
breath as two glyphs, and their frame follows the breath rather than
the redraw, for the same reason.

A **segmented waiting run** needed both halves of that.  The agent's
work and a handed reply are drawn as a fixed-height run of dashes, so a
breath that only changed the dashes left the run looking still:
measured across a whole breath it drew exactly *one* distinct frame in
Emacs, and its height never moved in either client.  Its glyph now
follows the breath and its height swells with it, so a waiting turn
really breathes.  `-a-segmented-wait-breathes` and `a waiting turn
breathes, not just its dashes` read the run's own drawn height at the
trough and the crest and fail on the old code.

The captures say which waiting form each one shows, because they move
differently: `voice-ribbon-breath.gif` is the words waiting,
`voice-ribbon-segmented.gif` is the turn waiting, and
`breath-versus-approved.gif` puts the approved motion reference above
both.

The shapes are distinguishable **without colour**: a hump of rounded
blocks, a square-cut block, a segmented bar, fine paired bars, an outline
of dots.  Colour says the same thing again -- grey for the microphone,
mint for speech, blue for the words, white for the agent's work and the
audio out, the drop tone for a loss -- and is never the only cue.

## The compact ring

A narrow window, a collapsed buddy, a mini view or a picture-in-picture
surface cannot hold five positions across.  It gets the **same blips
around a circle**:

```text
   ▄▅▅▆▇▇▇▆▅▅▄
 ▄▄           ▄▄
▄▄             ▄▄
 ▄▄           ▄▄
   ▄▄▄▄▄▄▄▄▄▄▄
```

- **twelve o'clock is the first stage** (`Audio`), and the pipe runs
  clockwise: `Speech` at 72 degrees, `Words` at 144, `Processing` at 216,
  `Audio out` at 288;
- **angle is stage, never time** — nothing sweeps round the ring;
- **a segment moves around the ring, it is not duplicated**: one id, one
  mark, and the old angle is empty after it moves;
- **independent segments coexist** at different angles, as on the bar;
- a second blip of one stage is drawn on a **nearer ring**
  (`radius(0) = 1.0`, then 0.74, 0.48), so two real bursts in one stage
  are two marks;
- **waiting stays in place**: the same warble, at the same angle;
- a stage's bars are spaced **along the rim's own length**, not along the
  angle, so a wide ellipse does not bunch them at the top and leave the
  sides bare;
- the badge is **compact**: a filled disc with a hairline rim, drawn in a
  fixed block of cells and centred in the room it has.  It carries no key,
  no summary and no dotted scaffold -- the bars on the rim are the whole
  picture.

The ring is not a replacement for the ribbon.  A full-size surface always
gets the linear form, at every text size; `harness-voice-ribbon-linear-minimum`
(46 columns) is the width below which Emacs switches, and the Flutter view
switches only when its host says the surface is compact (`compact: true`) or
when the window is smaller than 300 by 420 points.  Larger text alone never
turns the ribbon into a ring.

## The approved geometry, measured

The bar is not drawn by eye.  Every proportion in both clients is measured
from Noah's approved Option A ribbon, `voice-pipeline-all-bars.png`, and
recorded here so a later change can be checked rather than argued about.
The pill is 690x111 px and carries thirty-seven marks:

| What | Approved | Ratio to the pill's height | Where it lives |
| --- | --- | --- | --- |
| one bar | 13.5 px | **0.122** | `_BarMetrics.width`, `harness-voice-ribbon--bar-width` |
| one gap | 11 px | **0.099** | `_BarMetrics.gap` |
| one bar and its gap | 24.6 px | **0.222** | `_BarMetrics.pitch` |
| the rounded cap | 12.8 px | 0.115 | `_BarMetrics.inset` |
| the tallest run | 69 px | 0.62 | `_BarMetrics.tallest` |
| the pill's width | 690 px | 6.2 | `VoiceRibbonView.pillWidthInHeights` |
| the pill's fill | `#15221D` | -- | `_pill`, `harness-voice-ribbon-face` |

The stage shapes are the approved ones, in the approved heights as fractions
of the pill:

| Stage | Approved heights | Form |
| --- | --- | --- |
| microphone | 0.10, 0.17, 0.31, 0.18 | a rounded hump, scaled by the level |
| kept speech | 0.31, 0.48, 0.62, 0.39, 0.23 | a taller rounded hump |
| the words | 0.35 across | square-cut, flat |
| the agent's work | 0.30 across | segmented white bars |
| the audio out | 0.12, 0.26, 0.47, 0.58, 0.34, 0.18 | paired hairlines, the densest run |
| a confirmed drop | 0.50 across | an outline of dots, in the drop tone |

### Each stage draws its own number of bars

The original's stages are **not five equal columns**.  Measured across the
690 px pill, its 28 marks fall into the shapes above, and the counts are the
stage's own:

| Stage | Bars | Why |
| --- | --- | --- |
| microphone | 4 | its hump is four bars |
| kept speech | 5 | its hump is five |
| the words | 5 | a flat row of five |
| the agent's work | 3 | three segmented bars |
| the audio out | 7 | seven pairs of hairlines |
| a confirmed drop | 4 | four columns of dots |

Those counts are what make a populated ribbon come out at the original's
density: 4+5+5+3+7 = 24 bars at the approved pitch, plus the gaps, is the
whole pill.  Both clients carry the same table (`_approvedBars` in the
widget, `harness-voice-ribbon--approved-bars` in Emacs).

Three consequences a reader can check on the sheets:

- **the pitch is the same in every stage.**  The approved ribbon runs its
  bars straight on from one stage into the next, so the stages are told apart
  by shape and colour, never by a gutter.  An earlier revision drew each
  stage as a cluster with a margin, which made the bar markedly denser and
  narrower than the original; another filled each stage's equal fifth, which
  made a lone mark sit in the middle of a wide empty slot.
- **a stage keeps its slot even when it is idle.**  An idle stage draws
  nothing, but its place in the order stays reserved, so a handoff moves a
  mark right into the next stage rather than sliding the whole ribbon up.
  The slot grows when a real event puts two bursts in one stage, so a second
  burst never overlaps the first.
- **an idle stage draws nothing.**  The approved ribbon leaves a stage with
  nothing in it empty; an earlier revision filled it with a dim bed of
  uniform bars, which was a measurement the pipe never made and made every
  run look the same height.
- **a run fills exactly the cells it owns.**  A stage's slot is the number of
  bars its own run draws -- never the approved weight on its own, which left
  dead columns between two stages and made the bar read as broken.  The bar
  width and the gap are scaled together by the one cell the ribbon found, so
  the approved bar-to-gap ratio survives any density and two neighbouring
  bars can never close on each other.  The sequence is centred on the marks
  it draws, not on the cells it reserves, so it sits level in its own pill.
- **the Emacs grid fills the pill.**  At the approved two-column pitch a full
  pipe's 24 slots take 48 of a 60-column ribbon, which left the bar stopping
  short of its own ends.  The pitch therefore grows evenly to the width when
  there is room for more than the approved pitch, and every bar is placed on
  that one float pitch and rounded to its column, so the gaps stay even from
  the first stage to the last.

### The compact ring's marks

The approved badge is a small filled disc with square tiles lying **on** its
rim.  The ring therefore places each mark individually, on a track one
half-diagonal inside the disc's edge, turned to the tangent where it sits: a
run spans a fifth of the rim -- about 72 degrees -- and a single straight box
cannot follow that arc without a corner hanging outside the disc.  The ring
is drawn at the approved badge's own size rather than filling whatever room
it is given, so the compact form stays a glance.

The comparison sheet follows the same rule.  Its approved badge is drawn so
its own disc is the size of the disc the app's ring draws (`ringDisc`, 95 px
at the default side), and the ring is drawn at its own size on the sheet
rather than filling the room the sheet offers.  The sheet shows one badge
rather than the concept's row of four: four badges at that scale need
789 px, and a sheet that squeezed them into its own width drew the approved
disc at a third of the ring's size while its caption called it one scale.
The badge it shows is the words treatment, and the app's side draws a
populated pipe, because the approved badge shows the rim's whole treatment
rather than a single stage's arc.

Every mark on the ring is the approved badge's own **square tile**, 0.089 of
the disc, spaced by about its own size: measured from the original, each is
12 px on a 134 px disc.  A mark is not the stage's pill shape carried round
the rim -- a rounded hump or a paired hairline there read as scratches on a
dial rather than as the badge's marks -- so the ring draws the tile in the
stage's own colour and lets the angle and the colour say which stage it is.

`scripts/voice-ribbon-fidelity.py` measures a rendered pill and prints the
same ratios beside the approved ones, so a claim about fidelity is a pair of
numbers.  On the ordinary sheet, measuring the app's pill with
`--box 270,216,850,312`, it reports bar width **1.16x**, pitch **1.01x** and
gap **0.82x** of the approved proportions, with **thirty-five** marks
against thirty-seven.  The pitch is the number that matters -- the bars sit
on the original's rhythm -- and the gap is the one that is visibly off: the
app leaves slightly less room between bars than the approved drawing, which
is why its bars read a shade wider.  The sheets are reproduced from the
committed code: regenerating them gives the committed files byte for byte,
so the picture the numbers come from is the picture this branch draws.

### Where the approved pixels come from

The sheets compare against the originals themselves, not against a drawing of
them.  `scripts/voice-ribbon-reference-crops.py` verifies the four delivered
files' SHA-256 sums, cuts named crops, and records each crop's source file,
rectangle and hash in `docs/media/voice-ribbon-review/reference-crops/CROPS.json`.
The originals live in `scripts/.dev/approved-voice-references/`, which is
gitignored -- they are Noah's pictures, not this repository's -- so only the
crops are committed, and every sheet names the file and rectangle it shows.

## The contract a host uses

Both clients keep one model and two geometries:

| | Emacs | Flutter |
| --- | --- | --- |
| the blips | `harness-voice-ribbon-blips P NOW` | `VoiceRibbon.fromSnapshot(snapshot, now)` |
| the linear form | `harness-voice-ribbon-linear-lines P WIDTH NOW` | `VoiceRibbonView(form: linear)` |
| the compact form | `harness-voice-ribbon-ring-lines P NOW ROOM` | `VoiceRibbonView(form: polar)` |
| the one that fits | `harness-voice-ribbon-line P WIDTH NOW` | `VoicePipelineView` chooses |
| the words | `harness-voice-ribbon-labels`, `-stage-labels` | `blip.label`, `band.label` / `band.help` |
| when to redraw | `harness-voice-ribbon-next-change P NOW` | `VoiceRibbon.nextChange(now)` |

A host that draws either form gets the same blips in the same order with
the same words; `harness-ui-voice-ribbon-linear-and-polar-agree` and
`the linear ribbon and the compact ring are one picture` assert exactly
that, glyph by glyph and word by word.

`next-change` is the whole animation contract: it returns the moment the
ribbon changes *by itself* (a warble frame, or a linger running out), and
nil when only an event can change it.  Emacs arms one timer for it
(`harness-voice-live--ribbon-schedule`); Flutter arms one `Timer`.  There
is no ticker, so a ribbon with nothing waiting costs nothing, and a hung
backend leaves a still ribbon rather than a plausible animation.

## What the ribbon will not say

- **A stage the pipe does not have.**  No `Transcoding`, no `Upload`, no
  `Transfer`.  The bars take only the shapes the events produce.
- **A level that is not there.**  A closed, muted, paused or disconnected
  microphone has no `Audio` blip at all; an open one with no telemetry is
  drawn hollow with `Level · no data`, never as silence at 0%.
- **A drop the client did not see.**  A burst whose transcript never
  arrives stays `transcribing` where it is.  The ribbon does not invent a
  filter decision.
- **Speech that is not playing.**  A reply the provider was handed but
  never reported playing stays `handed`.  Text generation finishing is
  not speaking.
- **One reply per utterance.**  A turn is not a mark; two utterances and
  two replies stay four facts.
- **That the pictures are live.**  Every picture in the docs and in the
  app's screenshot tests is a **fixture**: the protocol's own events, fed
  through the real handlers, with no microphone opened and no speech
  service called.

## Platform surfaces

The compact ring is drawn **only where the app already draws its own
surface**:

| Surface | Today | The ring |
| --- | --- | --- |
| Emacs, narrow window or collapsed transcript | works | drawn, in character cells |
| Flutter desktop, compact buddy card | works | drawn (`VoiceRibbonView(form: VoiceRibbonPresentation.polar)`) |
| Flutter in-app call view, narrow | works | drawn |
| Android Picture-in-Picture | **not implemented** — needs `supportsPictureInPicture`, `configChanges`, and a foreground service to keep capture alive | would draw the app's own compact layout; nothing was added |
| iOS Picture-in-Picture / Live Activity | **not implemented** — needs a widget extension target (Live Activity) and `UIBackgroundModes` (background audio) | not drawn |
| a free-floating overlay on either phone | **not supported by the platform** | never |

No background recording, overlay permission, startup persistence or new
service was added.  The platform table in
[voice-buddy-compact.md](voice-buddy-compact.md) is the authority for
what each OS allows, and this task did not change it.

## The words

Nouns, noun phrases and adjectives only; every string is asserted exactly
in `harness-ui-voice-ribbon-test.el` and `voice_ribbon_test.dart`, and the
settings' own words in `harness-ui-voice-providers-test.el` and
`voice_ui_test.dart`.

| Place | Copy |
| --- | --- |
| the control | **nothing.**  No heading, no band words, no legend, no count, no summary and no `Pipeline details` |
| band tooltips | `Microphone level before the speech filter`, `Speech kept for transcription`, `Speech to text`, `Agent work`, `Playback` -- on a mark, and never drawn as a row; a camera session's are `Motion`, `Mouth` and the same last three |
| blip labels | the id, the stage word, the duration and the reason: `u-1 · in turn · 1.4s`, `u-2 · dropped · 80ms · too short` |
| the screen reader | the pipeline's own summary, `Mic · live · Level · 56% · 1 accepted · Turn · working · Speaker · speaking`, then `Blip, <label>` for each mark |
| the settings | `Pipe`, the stage table and every marker; `No markers yet` when there is none |
| settings | `harness-voice-ribbon-motion` (*Whether a waiting blip warbles in place*), `harness-voice-ribbon-linger` (*Seconds a dropped, failed or answered blip stays before it clears*), `harness-voice-ribbon-warble-rate`, `harness-voice-ribbon-warble-breath`, `harness-voice-ribbon-lanes`, `harness-voice-ribbon-linear-minimum`, `harness-voice-ribbon-max-width` |

Nothing new is prose, and nothing is drawn: the tooltips that describe a
stage are noun phrases, the summary is a screen reader's and the settings'
line, and the ribbon adds no sentence of its own.

## What was considered and not done

- **One box per stage, drawn as a rounded panel.**  That is the strip
  this replaces: five headings in a surface that has room for one.
- **A labels row or a legend under the bar.**  Both were drawn, and both
  turned a picture back into a text dashboard.  The stages are read from
  the shapes and colours of the bars; a person who wants words opens the
  voice settings.
- **A `Pipeline details` control on the pipe.**  It made the control a
  dashboard with a disclosure, and Noah's correction is explicit: the
  details are navigated to through the voice settings, never from the
  pipe.
- **A ring for large text.**  Larger text alone used to turn the ribbon
  into a giant sparse circle.  The pill now keeps its form at every text
  size, and only a surface the host declares compact gets the ring.
- **A band of quiet bars that says an event happened.**  An earlier
  revision gave every idle stage a dim, flat bed of uniform bars to make
  the five stretches look continuous.  It was a measurement the pipe never
  made, it made every run look the same height, and it is gone: an idle
  stage is empty, and the pitch alone carries the continuity.
- **A band called `Transcoding`.**  The approved prototype's legend has
  the word; the pipe has no such step, so the ribbon has no such band.
  Where a real transcription stage exists it is `Words`, fed by the
  transcription worker's own events.
- **Drawing the turn as its own blip.**  It would put one utterance in
  two places and claim the one-to-one causality the events deny.
- **A progress sweep round the ring.**  It would be an animation that
  runs on a clock and claims steps that did not occur.
- **A shared binary renderer for both clients.**  Emacs draws character
  cells and Flutter draws smooth bars; they share the model, the stage
  words and the geometry's meaning, not a rasterizer.
- **A mobile circular overlay.**  Neither phone platform offers one, so
  the ring is drawn only in the app's own compact surfaces.

## What changed

| File | What it does |
| --- | --- |
| `lisp/ui/harness-ui-voice-ribbon.el` | the blips, the linear character-cell ribbon, the ring, the warble and linger timing, the words |
| `lisp/ui/harness-ui-voice-ribbon-test.el` | the model and both drawings, asserted |
| `lisp/ui/harness-ui-voice-pipeline.el` | records `:from` (the band a loss stopped in) and `:ended` (when), and the five band words |
| `lisp/ui/harness-ui-voice-live.el` | draws the ribbon in the transcript, with one timer for its next change, and opens the settings from `d` |
| `harness_client/lib/src/voice/voice_ribbon.dart` | the stage, form, blip and geometry model, shared by both forms |
| `harness_client/lib/src/ui/widgets/voice_ribbon.dart` | the linear bar and the polar ring, warble, linger, semantics |
| `harness_client/lib/src/ui/widgets/voice_pipeline.dart` | hosts the ribbon: linear for a full-size surface at every text size, polar only for a compact one |
| `lisp/ui/harness-ui-voice-providers.el` | the voice settings' `Pipe` section: the stage table and every marker |
| `harness_client/lib/src/ui/widgets/voice_settings_sheet.dart` | the settings' `Pipeline` section, the only way into the markers |
| `harness_client/test/voice_ribbon_test.dart` | the model and the two geometries, asserted |
| `docs/voice-pipeline-visualization.md` | the ribbon as the strip's leading form, with its event table |
| `docs/media/voice-ribbon.png`, `voice-ribbon-compact.png` | the two Emacs forms, from fixtures |
| `docs/media/voice-ribbon-review/` | the reference-versus-implementation sheets at ordinary, narrow, large-text and compact sizes, and the motion capture |
| `harness_client/test/voice_pipeline_reference_shots_test.dart` | puts a crop of an approved original beside a real screenshot of the app's own widget, at those four sizes |
| `scripts/voice-ribbon-reference-crops.py` | verifies the delivered originals' hashes and cuts the committed crops the sheets show |
| `scripts/voice-ribbon-fidelity.py` | measures a rendered pill against the approved proportions |
| `harness_client/test/voice_pipeline_motion_shots_test.dart` | one frame per real stage change, for the capture |
| `scripts/voice-ribbon-motion.sh` | writes the sheets and the capture |

## Verification

Focused, while working:

```sh
scripts/test.sh lisp/ui/harness-ui-voice-ribbon-test.el \
                lisp/ui/harness-ui-voice-pipeline-test.el \
                lisp/ui/harness-ui-voice-live-test.el
cd harness_client && flutter test test/voice_ribbon_test.dart \
                                  test/voice_pipeline_widget_test.dart
scripts/media.sh voice-ribbon voice-ribbon-compact voice-pipeline-details
scripts/voice-ribbon-motion.sh
```

The review's own check, at the four sizes:

| Size | The sheet | What it shows |
| --- | --- | --- |
| ordinary | `voice-ribbon-versus-ordinary.png` | one compact pill, the same bar language as the reference |
| narrow | `voice-ribbon-versus-narrow.png` | the pill stays the pill; it never becomes a ring for its width alone |
| large text | `voice-ribbon-versus-large-text.png` | the pill at 200% text, still one bar |
| compact | `voice-ribbon-versus-compact.png` | the same bars round the disc, twelve o'clock first, beside one approved badge at the ring's own size |
| bar language | `voice-ribbon-versus-bar-language.png` | the six approved stage shapes, and the app drawing all five stages and a drop at once |
| Emacs cells | `voice-ribbon-versus-emacs-cells.png` | the approved Emacs mockup, and the app's own pill |
| motion | `voice-ribbon-motion.gif` | one frame per real stage change: the burst moves right, the drop clears, the reply is played |

The Emacs client's own two forms are `docs/media/voice-ribbon.png` and
`voice-ribbon-compact.png`, drawn from the same fixtures by
`scripts/media.sh voice-ribbon voice-ribbon-compact`; no sheet above draws
them, and none of the sheets' captions says it does.

The words are asserted exactly, on both clients, and the assertion is the
inventory: `harness-ui-voice-ribbon-says-nothing-on-the-pipe`,
`harness-ui-voice-ribbon-details-are-not-here`,
`harness-ui-voice-live-pipeline-details-live-in-the-settings`,
`the pipe is one continuous ribbon and says no words` and
`no way into the details, and no empty-state prose` each name the prohibited
words one by one, so a heading, a key, a legend, a count or a details link
that came back would fail by name.

Before hand-in: the full `scripts/test.sh`, `scripts/test.sh --status`,
`scripts/lint.sh` and `harness_client/tool/check_build.sh`, on the
committed tree.

The tests that matter, by name.  An Emacs name is the suffix of its
`ert-deftest` in `harness-ui-voice-ribbon-test.el`; a Flutter name is the
whole `test(...)` name in `voice_ribbon_test.dart` unless it names another
file.

| Claim | Emacs | Flutter |
| --- | --- | --- |
| one blip per segment, never two stages at once | `-one-blip-per-segment` | `a single utterance is one blip, never two stages at once` |
| a real handoff moves it and clears the old place | `-stage-handoff-moves-the-mark` | `a real handoff moves one blip and clears its old place` |
| independent segments coexist | `-independent-segments-coexist` | `independent segments are two blips in their own stages` |
| two bursts in one stage | `-same-stage-blips-take-two-rows` | `two bursts in one stage take two lanes, not one mark` |
| a waiting blip warbles in place | `-waiting-warbles-in-place` | `a waiting blip warbles and never advances` |
| the breath moves at every redraw | `-the-breath-is-not-the-redraw`, `-the-breath-reaches-the-bar` | `every redraw shows a different point of the breath`, `the one-row frame follows the breath, not the redraw` |
| a segmented wait breathes | `-a-segmented-wait-breathes` | `a waiting turn breathes, not just its dashes` |
| reduced motion loses no fact | `-reduced-motion-keeps-every-fact` | `reduced motion stops the warble and keeps every word` |
| a drop keeps its place and clears | `-drop-keeps-its-place-and-clears` | `a dropped burst is a broken form in its own band` |
| failure is not a drop | **none** -- the model keeps them apart (`harness-voice-pipeline-stage-band`), and only Flutter draws the two forms apart | `a failed transcription is not a drop, and stays in words` |
| partial, duplicate and out-of-order events | **none** in Emacs; the model's one-id rule is `-one-blip-per-segment` | `a partial and its final are one blip` |
| fan-in is shown, not invented | **none**; a turn is not a blip, which `-no-invented-stages` covers | **none** |
| input and output at once | `-input-and-output-coexist` | `the microphone and the speaker are two marks at once` |
| a stale generation draws nothing | **none** | `a new conversation draws nothing from the last one` |
| stop, mute, cancel and restart | **none** here; the live side's own suites assert what a mute does to the pipe | `a mute drops the reply, and the ribbon says so`, `mute, cancelled and interrupted are all distinguishable` |
| linear and polar are one picture | `-linear-and-polar-agree` | `they draw the same blips with the same words` |
| the ring is the same pipe clockwise | `-ring-does-not-duplicate-a-segment` | `the stage order around the ring is the order along the ribbon`, `the ring does not duplicate a blip that moved` |
| the words | `-labels-are-the-facts`, `-stage-labels-are-the-settings-words`, `-a-camera-keeps-its-own-words` | `the bands name the pipe, in order`, `a blip is named by its id, stage and measurement` |
| no invented stage, no words on the pipe | `-no-invented-stages`, `-says-nothing-on-the-pipe`, `-details-are-not-here` | `there is no stage the pipe does not have` |
| a missing level is hollow, never silence | `-missing-level-is-short-never-silent` | `a level that is not there is hollow, never silence` |
| a narrow window keeps the pill, and a compact surface the ring | `-narrow-window-uses-the-badge` | `a narrow full-size panel keeps the pill, not a ring`, `a compact surface draws the same clusters around a ring` (in `voice_pipeline_widget_test.dart`) |

Where the Emacs column says **none**, the claim is carried by the Flutter
tests and by the model's own suites, not by a drawing test in Emacs: this
table said otherwise, naming tests that do not exist, and it is corrected
here rather than by adding tests to fit the claim.

**Not verified here:** a real microphone, a real transcription service
and a real player on a device.  The fixtures exercise the model and both
drawings through the protocol's own events; what a physical microphone's
levels and a model's playback timings look like is the platform's to
show, and the ribbon reports them rather than simulating them.
