/**
 * The arrangement: turns the film's clock (timeline.ts) into events on a mixing session.
 *
 * `compose(timeline)` is a function of the timeline's exports and of nothing else, so a later film with more
 * modules and different footage timings is scored by the same code: what happens where is read from SECTIONS,
 * ENERGY and CUES, never from a frame number written here.
 *
 *   - Musical events sit on the grid, in samples: `(bar * 16 + step) * 6000` (a sixteenth is 3.75 frames).
 *   - The sounds of cues sit on their own frame, `frame * 1600`, wherever the grid is.  The one exception is a key
 *     press (C-c C-c), which may be nudged onto the sixteenth next to it when that is less than a frame away.
 *
 * The form, per section kind:
 *   plain   the harness as it is: a pad that swells in from nothing, a few music-box notes, the person typing in
 *           the foreground, a heartbeat that starts when the person sends; the last bar builds to the fall.
 *   module  starts with the landing (the cue pair `fall` / `impact`): a downward whoosh, a gap of near-silence, then
 *           kick + boom + crash + stab.  Then the groove under the footage, a hook, and the cues' own sounds.
 *   outro   the groove stops on the bar line; one last bright hit and its tail.
 */
import type { Act, Cue, Section } from "../timeline.js";
import { ANSWER, ARP_P1, ARP_P2, ARP_VEL, BASS_A, BASS_B, CHORDS, CLIMB, CYCLE, HOOK, PICKUP, PLAIN_PLUCKS, ladder, type BassNote, type Chord, type ChordName, type TuneNote } from "./harmony.js";
import { Rng, SR, dbToGain, fadeEdges, midiToHz, reversed, seedOf } from "./dsp.js";
import * as inst from "./instruments.js";
import * as sfx from "./sfx.js";
import { Session, type BusName } from "./session.js";

/** What the arrangement reads from the timeline: its exports. */
export interface Timeline {
  FPS: number;
  BPM: number;
  BEAT: number;
  BAR: number;
  FALL: number;
  TENSION: number;
  DURATION: number;
  BARS: number;
  OUTRO: number;
  ACTS: readonly Act[];
  SECTIONS: readonly Section[];
  ENERGY: readonly number[];
  CUES: readonly Cue[];
}

export interface Logged {
  sample: number;
  kind: string;
  label: string;
}

/** A sound the arrangement promises: the QA looks for an onset of `bus` on the frame of `cue`. */
export interface Expectation {
  bus: BusName;
  cue: Cue;
  /** Where the sound was placed (samples): the cue's frame, or the sixteenth a key press was nudged to. */
  sample: number;
  what: string;
}

/** A pitched note whose pitch the QA measures. */
export interface Note {
  bus: BusName;
  sample: number;
  /** Samples the note sounds for. */
  len: number;
  midi: number;
}

export interface BarPlan {
  bar: number;
  section: Section;
  /** Bar within its section, and bars left after this one in it. */
  local: number;
  left: number;
  chord: ChordName;
  energy: number;
}

/** One fall and landing: where the tension starts, the fall, the gap, the hit. */
export interface Landing {
  impact: Cue;
  fall?: Cue;
  impactS: number;
  fallS: number;
  /** Samples: the master is silent in [gap[0], gap[1]) and the reverb is emptied at gap[1]. */
  gap: [number, number];
  buildS: number;
}

export interface Composition {
  session: Session;
  timeline: Timeline;
  /** Samples in the film. */
  n: number;
  plans: BarPlan[];
  landings: Landing[];
  gaps: Array<[number, number]>;
  flush: number[];
  expect: Expectation[];
  /** Typing cues thinned away, and key presses moved onto the grid (frames moved). */
  dropped: Cue[];
  nudged: Array<{ cue: Cue; frames: number }>;
  /** The sample the groove stops on, when the film ends in an outro. */
  outroS: number | null;
  /** The lead's notes, for the QA's pitch check. */
  notes: Note[];
  log: Logged[];
}

// ---------------------------------------------------------------------------
// Tuning constants of the arrangement (everything else comes from the timeline)
// ---------------------------------------------------------------------------

/** Frames of near-silence in front of a landing: the hit lands from nothing. */
export const GAP_FRAMES = 3;
/** The typing is thinned to at most this many ticks in any second, and no two ticks sit closer than MIN_TICK_GAP frames. */
export const MAX_TICKS_PER_SECOND = 12;
export const MIN_TICK_GAP = 2;
/** A key press moves onto the sixteenth beside it only if that is closer than this (frames): the QA allows one. */
export const MAX_NUDGE_FRAMES = 0.9;
/** How much louder (dB) the typing is at full energy than in the quietest bars: the music gets in its way. */
export const TICK_BOOST_DB = 14;

const MARK_SEND = /^(sent|submit-\d+)$/;
const MARK_REVIEW = /^review-(\d+)$/;
const MARK_VERIFY = /^verify-(\d+)$/;

const hz = midiToHz;

/** Reverse-order helper for sorted insertion; the timeline's cues arrive sorted by frame. */
const byFrame = (a: Cue, b: Cue) => a.frame - b.frame;

export function compose(T: Timeline): Composition {
  const SPF = SR / T.FPS;
  if (!Number.isInteger(SPF)) throw new Error(`${SR} Hz is not a whole number of samples per frame at ${T.FPS} fps`);
  const N = T.DURATION * SPF;
  const STEP = (SR * 60) / T.BPM / 4; // a sixteenth: 6000 samples
  const BEAT_S = STEP * 4;
  const BAR_S = BEAT_S * 4;
  const frameS = (f: number) => Math.round(f * SPF);
  const stepS = (bar: number, step: number) => Math.round((bar * 16 + step) * STEP);
  const stepSec = (steps: number) => (steps * STEP) / SR;

  const s = new Session(N);
  const log: Logged[] = [];
  const expect: Expectation[] = [];
  const dropped: Cue[] = [];
  const nudged: Array<{ cue: Cue; frames: number }> = [];
  const notes: Note[] = [];
  const cues = [...T.CUES].sort(byFrame);

  // -------------------------------------------------------------------------
  // The plan: what each bar is
  // -------------------------------------------------------------------------

  const sectionOf = (bar: number): Section => {
    const sec = T.SECTIONS.find((x) => bar >= x.from && bar < x.to);
    if (!sec) throw new Error(`bar ${bar} is in no section of the timeline`);
    return sec;
  };

  /** The loop is Am F C G from the first bar of a section; the last bar of a section is G (it leans into the next downbeat); the bar before an outro is F, so that F - G - A closes the film. */
  const chordNameOf = (bar: number, sec: Section): ChordName => {
    if (sec.id === "outro") return "A";
    const local = bar - sec.from;
    const left = sec.to - 1 - bar;
    if (left === 0) return "G";
    if (left === 1 && sec.id === "module" && sec.to === T.OUTRO / T.BAR && local >= 2) return "F";
    return CYCLE[local % CYCLE.length];
  };

  const plans: BarPlan[] = Array.from({ length: T.BARS }, (_, bar) => {
    const section = sectionOf(bar);
    return { bar, section, local: bar - section.from, left: section.to - 1 - bar, chord: chordNameOf(bar, section), energy: T.ENERGY[bar] ?? 0.5 };
  });
  const chordOfSample = (smp: number): Chord => CHORDS[plans[Math.max(0, Math.min(T.BARS - 1, Math.floor(smp / BAR_S)))].chord];
  const barOfSample = (smp: number) => Math.max(0, Math.min(T.BARS - 1, Math.floor(smp / BAR_S)));
  const energyAt = (smp: number) => plans[barOfSample(smp)].energy;

  // -------------------------------------------------------------------------
  // The landings: each impact, the fall before it, the gap, where the tension starts
  // -------------------------------------------------------------------------

  const impacts = cues.filter((c) => c.kind === "impact");
  const falls = cues.filter((c) => c.kind === "fall");
  const landings: Landing[] = impacts.map((impact) => {
    const fall = [...falls].reverse().find((f) => f.frame <= impact.frame);
    const impactS = frameS(impact.frame);
    const fallFrame = fall ? fall.frame : impact.frame - T.FALL;
    const buildFrame = Math.min(fallFrame - T.TENSION, Math.floor((impact.frame - 1) / T.BAR) * T.BAR);
    return { impact, fall, impactS, fallS: frameS(fallFrame), gap: [impactS - GAP_FRAMES * SPF, impactS], buildS: frameS(Math.max(0, buildFrame)) };
  });
  const gaps = landings.map((l) => l.gap);
  const flush = landings.map((l) => l.gap[1]);

  const outroSection = T.SECTIONS.find((x) => x.id === "outro");
  const outroS = outroSection ? stepS(outroSection.from, 0) : null;

  /** The sample before which a sustained note of this bar must have ended: the gap of the landing after it, or the bar line the groove stops on. */
  const boundOf = (bar: number): number => {
    const a = bar * BAR_S;
    const b = a + BAR_S;
    for (const l of landings) if (l.gap[0] >= a && l.gap[0] < b) return l.gap[0];
    if (outroS !== null && b === outroS) return outroS;
    return Infinity;
  };
  /** The sample from which the groove of a module bar gives way to the build of the landing after it (or Infinity). */
  const grooveStopOf = (bar: number): number => {
    const a = bar * BAR_S;
    const b = a + BAR_S;
    for (const l of landings) if (l.buildS < b && l.gap[0] >= a) return Math.max(a, l.buildS);
    return Infinity;
  };

  // Cues whose own sound should not be doubled by a groove note a hair away (a flam): everything but the typing.
  const featureS = cues.filter((c) => c.kind !== "type").map((c) => frameS(c.frame));
  /** True if a percussive groove note at `smp` would flam with the sound of a cue (0.4 to 1.7 frames away). */
  const flams = (smp: number): boolean => featureS.some((c) => Math.abs(smp - c) > 0.4 * SPF && Math.abs(smp - c) < 1.7 * SPF);

  // -------------------------------------------------------------------------
  // Shared sound sources (rendered once, reused with different gains)
  // -------------------------------------------------------------------------

  const drum = new Rng(21);
  const kickBuf = inst.kick(1, new Rng(11));
  const kickBig = inst.kick(1.15, new Rng(12), { len: 0.7, f0: 210, sweep: 0.042, sat: 2.2 });
  const claps = [inst.clap(1, drum), inst.clap(1, drum), inst.clap(1, drum)];
  const snares = [inst.snare(1, drum), inst.snare(1, drum), inst.snare(1, drum)];
  const choke = (buf: Float32Array, sec: number) => {
    const out = buf.slice(0, Math.min(buf.length, Math.round(sec * SR)));
    fadeEdges(out, 0, Math.round(0.012 * SR));
    return out;
  };
  const hatC = [0, 1, 2, 3].map(() => choke(inst.hat(1, false, drum), 0.09));
  const hatO = [0, 1].map(() => choke(inst.hat(1, true, drum), 0.19));
  const subBeat = inst.subPulse(1);

  /** Pad low-pass in Hz and level from the bar's energy hint (the timeline's ENERGY). */
  const padCutoff = (e: number) => 350 * 7.5 ** Math.min(1, e);
  const padLevel = (e: number) => 0.12 + 0.88 * Math.min(1, e);

  // -------------------------------------------------------------------------
  // Plain: a pad from nothing, a few notes, a heartbeat once the person has sent
  // -------------------------------------------------------------------------

  const sent = cues.find((c) => c.kind === "mark" && c.label === "sent");

  function layerPlain(): void {
    const rng = new Rng(31);
    for (const p of plans) {
      if (p.section.id !== "plain") continue;
      const chord = CHORDS[p.chord];
      const t0 = p.bar * BAR_S;
      const cut = (t: number) => padCutoff(p.energy) * (1 + 0.1 * Math.sin(2 * Math.PI * 0.18 * (p.bar * 2 + t)));
      const attack = p.local === 0 ? 1.5 : 0.9;
      s.stereo("pad", t0, inst.pad(chord.padLow.map(hz), 2.0, cut, { attack, release: 0.6, detune: 8 }), { gain: padLevel(p.energy), rv: 0.3, until: boundOf(p.bar) });
    }
    // Music-box notes, never next to the person's keys.
    const quiet = (smp: number) => !cues.some((c) => (c.kind === "key" || c.kind === "mark") && Math.abs(frameS(c.frame) - smp) < 6 * SPF);
    for (const sec of T.SECTIONS) {
      if (sec.id !== "plain") continue;
      for (const [lb, step, midi, vel] of PLAIN_PLUCKS) {
        const bar = sec.from + lb;
        if (bar >= sec.to) continue;
        const t = stepS(bar, step);
        if (!quiet(t)) continue;
        s.mono("pluck", t, inst.ping(hz(midi), vel * 0.75, rng, 0.22), { pan: step % 3 === 0 ? -0.3 : 0.3, rv: 0.55, dl: 0.25, until: boundOf(bar) });
        log.push({ sample: t, kind: "pluck", label: `bar ${bar} step ${step} midi ${midi}` });
      }
      // The music answers the send: the next beat after it, a rising figure, then a heartbeat that quickens.
      const sec0 = stepS(sec.from, 0);
      const answerS = sent ? Math.ceil((frameS(sent.frame) + 4 * SPF) / BEAT_S) * BEAT_S : sec0 + 2 * BAR_S;
      const lastBar = sec.to - 1;
      const stop = Math.min(N, boundOf(lastBar), landings.find((l) => l.buildS >= sec0)?.buildS ?? Infinity);
      for (const [dstep, midi, vel] of ANSWER) {
        const t = answerS + dstep * STEP;
        if (t >= stop || !quiet(t)) continue;
        s.mono("pluck", t, inst.ping(hz(midi), vel * 0.7, rng, 0.26), { pan: dstep % 4 === 0 ? 0.25 : -0.25, rv: 0.5, dl: 0.3, until: stop });
        log.push({ sample: t, kind: "answer", label: `midi ${midi}` });
      }
      for (let t = answerS; t < stop; t += BEAT_S) {
        const u = (t - answerS) / Math.max(1, stop - answerS);
        s.mono("sub", t, subBeat, { gain: 0.22 + 0.33 * u, until: stop });
      }
    }
  }

  // -------------------------------------------------------------------------
  // The tension, the fall and the landing
  // -------------------------------------------------------------------------

  function layerLandings(): void {
    const rng = new Rng(51);
    for (const l of landings) {
      const gapStart = l.gap[0];
      const chordBefore = chordOfSample(l.buildS);
      const chordAfter = chordOfSample(l.impactS);
      // The riser and the tonal riser climb until the fall lets go.
      const riseEnd = l.fallS - Math.round(1.5 * SPF);
      const riseLen = (riseEnd - l.buildS) / SR;
      if (riseLen > 0.1) {
        s.stereo("riser", l.buildS, sfx.riserNoise(riseLen, 1, rng), { rv: 0.1, until: riseEnd });
        s.stereo("riser", l.buildS, sfx.riserTone(riseLen, hz(chordBefore.root + 24), hz(chordAfter.root + 36), 1), { rv: 0.15, until: riseEnd });
      }
      log.push({ sample: l.buildS, kind: "build", label: `tension from frame ${l.buildS / SPF}` });
      // The snare roll: eighths, then sixteenths for the last two beats but one, then thirty-seconds, crescendo, up to the gap.
      const t1 = l.impactS - 2 * BEAT_S;
      const t2 = l.impactS - BEAT_S;
      let i = 0;
      for (let t = l.buildS; t < gapStart - 600; ) {
        const space = t < t1 ? STEP * 2 : t < t2 ? STEP : STEP / 2;
        const u = (t - l.buildS) / Math.max(1, gapStart - l.buildS);
        const t0 = Math.round(t);
        if (!flams(t0)) {
          s.mono("snare", t0, inst.snare(0.15 + 0.5 * u ** 1.2, rng, { tone: 185 + 70 * u }), { pan: i % 2 ? 0.12 : -0.12, rv: 0.12, until: gapStart });
        }
        t += space;
        i++;
      }
      // Sixteenth hats crescendo from the second half of the bar.
      let h = 0;
      for (let t = t1; t < gapStart - 600; t += STEP) {
        const u = (t - t1) / Math.max(1, gapStart - t1);
        if (!flams(t)) s.mono("hats", t, hatC[h % 4], { gain: 0.1 + 0.25 * u, pan: h % 2 ? 0.2 : -0.2, until: gapStart });
        h++;
      }
      // A heartbeat on every beat of the build, louder and louder.
      for (let t = l.buildS; t < gapStart; t += BEAT_S) {
        const u = (t - l.buildS) / Math.max(1, gapStart - l.buildS);
        s.mono("sub", t, subBeat, { gain: 0.55 + 0.4 * u, until: gapStart });
      }
    }
  }

  /** Dip a bus around a sample: smooth in, hold, smooth out.  Room for a sound that must speak. */
  function carve(bus: BusName, smp: number, depthDb: number, holdSec: number, releaseSec: number): void {
    const b = s.bus[bus];
    const g = dbToGain(-depthDb);
    const edge = Math.round(0.006 * SR);
    const hold = Math.round(holdSec * SR);
    const rel = Math.round(releaseSec * SR);
    const a = smp - edge;
    for (let i = Math.max(0, a); i < Math.min(N, smp + hold + rel); i++) {
      const w = i < smp ? (smp - i) / edge : i < smp + hold ? 0 : (i - smp - hold) / rel; // 0 = fully dipped, 1 = untouched
      const m = g + (1 - g) * Math.min(1, Math.max(0, w));
      b.l[i] *= m;
      b.r[i] *= m;
    }
  }

  // -------------------------------------------------------------------------
  // The groove of a module
  // -------------------------------------------------------------------------

  function layerGroove(): void {
    const bassCache = new Map<string, Float32Array>();
    const bassNote = (midi: number, lenSteps: number, vel: number, bright: number) => {
      const key = `${midi}:${lenSteps}:${vel.toFixed(2)}:${bright.toFixed(1)}`;
      let b = bassCache.get(key);
      if (!b) {
        b = inst.bass(hz(midi), stepSec(lenSteps), vel, bright);
        bassCache.set(key, b);
      }
      return b;
    };
    const pluckCache = new Map<string, Float32Array>();
    const pl = (midi: number, vel: number, bright: number) => {
      const key = `${midi}:${vel.toFixed(2)}:${bright.toFixed(1)}`;
      let b = pluckCache.get(key);
      if (!b) {
        b = inst.pluck(hz(midi), vel, bright);
        pluckCache.set(key, b);
      }
      return b;
    };
    const VEL16 = [0.55, 0.26, 0.7, 0.3];
    let hv = 0;
    let cl = 0;

    for (const p of plans) {
      if (p.section.id !== "module") continue;
      const chord = CHORDS[p.chord];
      const next = CHORDS[plans[Math.min(T.BARS - 1, p.bar + 1)].chord];
      const barS = p.bar * BAR_S;
      const stop = grooveStopOf(p.bar);
      const bound = Math.min(boundOf(p.bar), stop);
      const e = p.energy;
      const beforeOutro = outroS !== null && barS + BAR_S === outroS;
      const dropBar = landings.some((l) => l.impactS >= barS && l.impactS < barS + BAR_S);

      // Kicks: four on the floor (the landing places its own on the downbeat of its bar).
      for (let b = 0; b < 4; b++) {
        const t = stepS(p.bar, b * 4);
        if (t >= stop || landings.some((l) => Math.abs(l.impactS - t) < SPF)) continue;
        s.mono("kick", t, kickBuf, { gain: 1 });
        s.kicks.push({ at: t, vel: 1 });
      }
      // Claps on 2 and 4.
      for (const b of [1, 3]) {
        const t = stepS(p.bar, b * 4);
        if (t >= stop) continue;
        s.mono("clap", t, claps[cl++ % 3], { gain: 1, pan: 0.05, rv: 0.18, until: bound });
      }
      // Hats: eighths in the landing bar, open offbeats after it, sixteenths from the third bar; a crescendo into the stop.
      const mode: "8" | "16" = p.local < 2 ? "8" : "16";
      const opens = p.local >= 1;
      for (let step = 0; step < 16; step++) {
        const t = stepS(p.bar, step);
        if (t >= stop || (mode === "8" && step % 2 === 1)) continue;
        const sub = step % 4;
        const open = opens && sub === 2;
        let base = mode === "8" ? (sub === 2 ? 0.7 : 0.5) : VEL16[sub];
        if (beforeOutro) base *= 0.5 + 0.7 * (step / 15);
        if (flams(t)) continue;
        const vel = base * (0.92 + 0.08 * (((hv++ * 7) % 5) / 4));
        s.mono("hats", t, open ? hatO[hv % 2] : hatC[hv % 4], { gain: open ? vel * 0.85 : vel, pan: step % 2 ? 0.2 : -0.2, until: bound });
      }
      // Bass: offbeats; the gallop from the third bar.
      const pattern: BassNote[] = p.local < 2 ? BASS_A : BASS_B;
      for (const bn of pattern) {
        const t = stepS(p.bar, bn.step);
        if (t >= stop) continue;
        const midi = bn.which === "root" ? chord.root : bn.which === "fifth" ? chord.fifth : bn.which === "octave" ? chord.root + 12 : bn.which === "next" ? next.root : next.root + 12;
        s.mono("bass", t, bassNote(midi, bn.len, bn.vel, 0.6 + 0.5 * Math.min(1, e)), { gain: 1, until: bound });
      }
      // Pad: the chord of the bar, brighter with the energy; it ends at the bar line the groove stops on.
      if (stop === Infinity || stop > barS) {
        const cut = (t: number) => padCutoff(e) * (1 + 0.08 * Math.sin(2 * Math.PI * 0.18 * (p.bar * 2 + t)));
        s.stereo("pad", barS, inst.pad(chord.pad.map(hz), 2.0, cut, { attack: 0.3, release: 0.5, detune: 9 }), { gain: padLevel(e), rv: 0.14, until: bound });
      }
      // Arp: sixteenths from the second bar; it steps back while the hook plays.
      const hookBar = phraseBars.has(p.bar);
      if (!dropBar && p.left >= 0) {
        const pat = p.local % 2 === 1 ? ARP_P1 : ARP_P2;
        for (let step = 0; step < 16; step++) {
          const t = stepS(p.bar, step);
          if (t >= stop || flams(t)) continue;
          const v = ARP_VEL[step] * (hookBar ? 0.55 : 1) * Math.min(1, 0.3 + e);
          s.mono("arp", t, pl(chord.arp[pat[step]], Math.min(1, v), 0.55 + 0.35 * Math.min(1, e)), { pan: step % 2 ? 0.3 : -0.3, rv: 0.12, dl: 0.4, until: bound });
        }
      }
      // Fill: the last bar before the outro ends in a snare run and a reverse cymbal into the line.
      if (beforeOutro && outroS !== null) {
        for (let step = 12; step < 16; step++) {
          const t = stepS(p.bar, step);
          if (flams(t)) continue;
          s.mono("snare", t, snares[step % 3], { gain: 0.3 + 0.55 * ((step - 12) / 3), pan: step % 2 ? 0.12 : -0.12, rv: 0.12, until: bound });
        }
        const swell = reversed(inst.crash(0.5, new Rng(61), 1.0));
        s.mono("riser", outroS - swell.length, swell, { gain: 1, rv: 0.1, until: outroS });
      }
    }
    log.push({ sample: 0, kind: "groove", label: `${s.kicks.length} kicks` });
  }

  /**
   * The lead's phrases: the hook on the third and fourth bar of every four of a module, and, when the module leads
   * into the outro, a climb over its last two bars, or, if the climb has no room, a pickup in the last half bar.  A
   * phrase is played only if no chime of the cues rings inside it: those are the melody there.
   */
  interface Phrase {
    name: "hook" | "climb" | "pickup";
    tune: TuneNote[];
    bar: number;
  }
  const chimeS = cues
    .filter((c) => c.kind === "highlight" || (c.kind === "mark" && (MARK_REVIEW.test(c.label ?? "") || MARK_VERIFY.test(c.label ?? ""))))
    .map((c) => frameS(c.frame));
  const chimeFree = (from: number, to: number) => !chimeS.some((c) => c >= from - 0.4 * SR && c < to);
  const phrases: Phrase[] = [];
  for (const sec of T.SECTIONS) {
    if (sec.id !== "module") continue;
    const first = sec.from;
    const last = sec.to - 1;
    const toOutro = outroS !== null && sec.to * BAR_S === outroS;
    const hookEnd = toOutro ? last - 2 : last;
    for (let bar = first + 2; bar + 1 <= hookEnd; bar += 4) {
      if (chimeFree(bar * BAR_S, (bar + 2) * BAR_S)) phrases.push({ name: "hook", tune: HOOK, bar });
    }
    if (!toOutro) continue;
    if (last - 1 >= first + 2 && chimeFree((last - 1) * BAR_S, (last + 1) * BAR_S)) phrases.push({ name: "climb", tune: CLIMB, bar: last - 1 });
    else if (last >= first + 1 && chimeFree(stepS(last, 8), (last + 1) * BAR_S)) phrases.push({ name: "pickup", tune: PICKUP, bar: last });
  }
  const phraseBars = new Set(phrases.flatMap((ph) => Array.from({ length: Math.max(...ph.tune.map((t) => t.bar)) + 1 }, (_, k) => ph.bar + k)));

  function layerLead(): void {
    for (const ph of phrases) {
      for (const nn of ph.tune) {
        const bar = ph.bar + nn.bar;
        const t = stepS(bar, nn.step);
        const stop = Math.min(grooveStopOf(bar), boundOf(bar));
        if (t >= stop) continue;
        const e = Math.min(1, plans[bar].energy);
        const len = Math.min(stepSec(nn.len) * 0.96, (stop - t) / SR);
        s.stereo("lead", t, inst.lead(hz(nn.midi), len, nn.vel ?? 1, { bright: 0.2 + 0.2 * e }), { gain: 1, rv: 0.2, dl: 0.3, until: stop });
        // Doubled an octave up, quietly, for sparkle.
        s.stereo("lead", t, inst.lead(hz(nn.midi + 12), len, (nn.vel ?? 1) * 0.5, { bright: 0.5 }), { gain: 0.22, rv: 0.3, dl: 0.3, until: stop });
        notes.push({ bus: "lead", sample: t, len: Math.round(len * SR), midi: nn.midi });
        log.push({ sample: t, kind: "lead", label: `${ph.name} bar ${bar} step ${nn.step} midi ${nn.midi}` });
      }
    }
  }

  // -------------------------------------------------------------------------
  // The outro: the groove has stopped on the bar line; one last bright hit and its tail
  // -------------------------------------------------------------------------

  function layerOutro(): void {
    if (outroS === null) return;
    const rng = new Rng(101);
    const chord = CHORDS.A;
    s.mono("kick", outroS, kickBuf, { gain: 0.5 });
    s.kicks.push({ at: outroS, vel: 1 });
    s.stereo("outro", outroS, inst.bigStab(chord.big.map(hz), 0.9, 1.3, { bright: 1.15 }), { gain: 0.8, rv: 0.35, dl: 0.15 });
    s.mono("outro", outroS, inst.crash(0.7, rng, 1.5), { gain: 1, pan: 0.05, rv: 0.25 });
    s.mono("outro", outroS, sfx.subDrop(0.5, 1.1), { gain: 1 });
    // The bell and its shimmer: A major with the ninth, ringing out.
    s.mono("bell", outroS, inst.bell(hz(81), 0.9, 3.4), { gain: 1, rv: 0.5, dl: 0.2 });
    [85, 88, 93, 95, 97].forEach((m, k) => s.mono("bell", outroS + Math.round(0.055 * SR * (k + 1)), inst.bell(hz(m), 0.6 - 0.07 * k, 2.4), { gain: 1, pan: k % 2 ? 0.35 : -0.35, rv: 0.6, dl: 0.3 }));
    [57, 64, 69].forEach((m) => s.mono("bell", outroS, inst.bell(hz(m), 0.35, 3.0, 0.4), { gain: 1, rv: 0.35 }));
    // A pad that blooms under it.
    const lastS = N - outroS;
    s.stereo("pad", outroS, inst.pad(chord.padLow.map(hz), Math.max(0.5, lastS / SR - 1.6), (t) => 1200 + 2600 * Math.min(1, t / 0.6), { attack: 0.08, release: 1.4, detune: 7 }), { gain: 0.45, rv: 0.3 });
    log.push({ sample: outroS, kind: "outro", label: "last hit: A major add9" });
  }

  // -------------------------------------------------------------------------
  // The sounds of the cues
  // -------------------------------------------------------------------------

  /** The quiet before and after a landing, for the typing (a multiplier 0..1): it must not talk over the fall. */
  function typingDuck(frame: number): number {
    let m = 1;
    for (const l of landings) {
      const a = l.fallS / SPF - 2;
      const b = l.impactS / SPF + 4;
      const ramp = 6;
      const w = frame >= a && frame <= b ? 1 : frame < a ? Math.max(0, 1 - (a - frame) / ramp) : Math.max(0, 1 - (frame - b) / ramp);
      m = Math.min(m, 1 - 0.85 * w);
    }
    return m;
  }

  /** The typing: every tick that is kept, and the ones thinned away. */
  function layerTyping(): void {
    const kept: Cue[] = [];
    const typed = cues.filter((c) => c.kind === "type");
    let last = -Infinity;
    let merged = 0;
    const mergedOf = new Map<Cue, number>();
    for (const c of typed) {
      const windowCount = kept.filter((k) => k.frame > c.frame - T.FPS).length;
      if (c.frame - last >= MIN_TICK_GAP && windowCount < MAX_TICKS_PER_SECOND) {
        kept.push(c);
        mergedOf.set(c, merged);
        merged = 0;
        last = c.frame;
      } else {
        dropped.push(c);
        merged++;
      }
    }
    kept.forEach((c, k) => {
      const rng = new Rng(seedOf(c.frame, k, 7));
      const t = frameS(c.frame);
      const chord = chordOfSample(t);
      const midi = rng.pick(ladder(chord, 52, 6));
      const size = rng.next() < 0.14 ? 1.6 : 1;
      const vel = (0.55 + 0.45 * rng.next() ** 0.8) * (1 + 0.1 * (mergedOf.get(c) ?? 0));
      const boost = dbToGain(TICK_BOOST_DB * Math.min(1, energyAt(t))) * typingDuck(c.frame);
      if (boost < 0.03) {
        dropped.push(c);
        return;
      }
      s.mono("type", t, sfx.typeTick(rng, vel, hz(midi), size), { gain: boost, pan: (rng.next() - 0.5) * 0.5, rv: 0.05 });
      expect.push({ bus: "type", cue: c, sample: t, what: "keyboard tick" });
    });
  }

  /** Key presses move onto the sixteenth next to them when it is closer than MAX_NUDGE_FRAMES. */
  const nudgeOf = (frame: number): { sample: number; frames: number } => {
    const exact = frameS(frame);
    const grid = Math.round(exact / STEP) * STEP;
    const d = (grid - exact) / SPF;
    return Math.abs(d) <= MAX_NUDGE_FRAMES ? { sample: grid, frames: d } : { sample: exact, frames: 0 };
  };
  const keySample = new Map<number, number>();
  for (const c of cues) {
    if (c.kind !== "key") continue;
    const { sample, frames } = nudgeOf(c.frame);
    keySample.set(c.frame, sample);
    if (frames !== 0) nudged.push({ cue: c, frames });
  }

  /** How many chime-like sounds the cue shares its frame with (they are made quieter together, so a pile-up is only a little louder than a single). */
  const crowd = (c: Cue): number =>
    cues.filter((x) => Math.abs(x.frame - c.frame) <= 1 && (x.kind === "callout" || x.kind === "highlight" || (x.kind === "mark" && (MARK_REVIEW.test(x.label ?? "") || MARK_VERIFY.test(x.label ?? ""))))).length;

  function layerCues(): void {
    let calloutN = 0;
    let clickN = 0;
    for (const [k, c] of cues.entries()) {
      const rng = new Rng(seedOf(c.frame, k, 13));
      const sample = frameS(c.frame);
      const chord = chordOfSample(sample);
      const e = energyAt(sample);
      const w = Math.max(1, crowd(c)) ** -0.35;
      switch (c.kind) {
        case "type":
          break; // layerTyping
        case "key": {
          const t = keySample.get(c.frame) ?? sample;
          const buf = sfx.keyThock(rng, 1, hz(chord.root + 24));
          s.mono("key", t, buf, { gain: dbToGain(TICK_BOOST_DB * Math.min(1, e)), pan: 0.04, rv: 0.06 });
          expect.push({ bus: "key", cue: c, sample: t, what: "C-c C-c thock" });
          break;
        }
        case "click": {
          const midi = rng.pick(ladder(chord, 84, 4));
          s.mono("click", sample, sfx.clickBlip(rng, 0.9, hz(midi)), { gain: 1, pan: (clickN++ % 2 ? 1 : -1) * 0.18, rv: 0.1 });
          expect.push({ bus: "click", cue: c, sample, what: "pointer click" });
          break;
        }
        case "callout": {
          const lad = ladder(chord, 79, 5);
          const midi = lad[1 + (calloutN++ % 3)];
          s.stereo("callout", sample, sfx.calloutPing(rng, 0.85 * w, hz(midi)), { gain: 1, rv: 0.3, dl: 0.2 });
          expect.push({ bus: "callout", cue: c, sample, what: "airy rising ping" });
          carve("arp", sample, 3, 0.12, 0.3);
          carve("lead", sample, 3, 0.12, 0.3);
          break;
        }
        case "highlight": {
          const midi = ladder(chord, 84, 3)[2];
          s.mono("chime", sample, sfx.chime(hz(midi), 0.9 * w, 0.8), { gain: 1, pan: 0.15, rv: 0.4, dl: 0.2 });
          expect.push({ bus: "chime", cue: c, sample, what: "bright chime" });
          carveForChime(sample);
          break;
        }
        case "mark": {
          const label = c.label ?? "";
          if (MARK_SEND.test(label)) {
            const t = keySample.get(c.frame) ?? sample;
            s.mono("send", t, sfx.sendPop(rng, 0.9), { gain: 1, rv: 0.08 });
            s.stereo("send", t, sfx.sendWhoosh(rng, 0.6), { gain: 1, rv: 0.1 });
            expect.push({ bus: "send", cue: c, sample: t, what: "send pop and whoosh" });
          } else if (MARK_REVIEW.test(label)) {
            const n = Number(label.match(MARK_REVIEW)?.[1] ?? 1);
            const [n1, n2] = [chord.stab[2] + 12, chord.stab[0] + 24];
            const v = (0.85 + 0.05 * Math.min(3, n - 1)) * w;
            s.mono("chime", sample, sfx.chime(hz(n1), v, 0.6), { gain: 1, pan: -0.15, rv: 0.4, dl: 0.2 });
            s.mono("chime", sample + Math.round(0.085 * SR), sfx.chime(hz(n2), v, 0.9), { gain: 1, pan: 0.15, rv: 0.45, dl: 0.25 });
            expect.push({ bus: "chime", cue: c, sample, what: "review chime: a fifth up to the root" });
            carveForChime(sample);
          } else if (MARK_VERIFY.test(label)) {
            // The resolve: the chord rises through its triad to the root an octave up and rings, over a low root that anchors it.
            const arpeggio = [chord.stab[0] + 12, chord.stab[1] + 12, chord.stab[2] + 12, chord.stab[0] + 24];
            arpeggio.forEach((m, j) => {
              const last = j === arpeggio.length - 1;
              s.mono("chime", sample + Math.round(0.055 * SR * j), sfx.chime(hz(m), (last ? 1.0 : 0.8) * w, last ? 1.2 : 0.45), { gain: 1, pan: (j % 2 ? 1 : -1) * 0.2, rv: 0.45, dl: 0.25 });
            });
            s.mono("chime", sample + Math.round(0.165 * SR), sfx.chime(hz(chord.root + 24), 0.6 * w, 1.0), { gain: 1, rv: 0.3 });
            s.mono("chime", sample + Math.round(0.165 * SR), sfx.chime(hz(chord.stab[0] + 36), 0.3 * w, 1.2), { gain: 1, pan: 0.3, rv: 0.6, dl: 0.3 });
            expect.push({ bus: "chime", cue: c, sample, what: "verify: rising arpeggio resolving on the root" });
            carveForChime(sample);
          } else {
            s.mono("click", sample, sfx.clickBlip(rng, 0.6, hz(ladder(chord, 84, 3)[1])), { gain: 1, rv: 0.1 });
            expect.push({ bus: "click", cue: c, sample, what: "unnamed mark: a small blip" });
          }
          break;
        }
        case "fall": {
          const l = landings.find((x) => x.fall === c);
          const gapStart = l ? l.gap[0] : sample + T.FALL * SPF;
          const len = (gapStart - sample) / SR;
          s.mono("fall", sample, sfx.fallLaunch(rng, 0.9), { gain: 2.4, rv: 0.1, until: gapStart });
          s.stereo("fall", sample, sfx.fallWhoosh(len, 1, rng), { gain: 0.8, rv: 0.1, until: gapStart });
          // A reversed cymbal swells under it and a reversed boom inhales: both end at the gap.
          const swell = reversed(inst.crash(0.7, rng, len));
          s.mono("fall", sample, swell, { gain: 0.6, rv: 0.1, until: gapStart });
          const inhale = reversed(sfx.subDrop(0.8, len));
          s.mono("fall", sample, inhale, { gain: 0.8, until: gapStart });
          expect.push({ bus: "fall", cue: c, sample, what: "launch tick, downward whoosh, reverse swell" });
          break;
        }
        case "impact": {
          const chordHit = chordOfSample(sample);
          s.mono("impact", sample, kickBig, { gain: 1.1 });
          s.kicks.push({ at: sample, vel: 1 });
          s.mono("impact", sample, sfx.subDrop(0.95, 0.9), { gain: 1 });
          s.mono("impact", sample, inst.crash(1.8, rng, 1.0), { gain: 0.8, pan: 0.05, rv: 0.3 });
          s.mono("impact", sample, sfx.noiseThump(rng, 0.7), { gain: 1 });
          s.stereo("impact", sample, inst.bigStab(chordHit.big.map(hz), 1, 0.8), { gain: 0.85, rv: 0.3, dl: 0.12 });
          expect.push({ bus: "impact", cue: c, sample, what: "kick + A boom + crash + thump + Am stab" });
          log.push({ sample, kind: "impact", label: c.label ?? "" });
          break;
        }
        default:
          break;
      }
    }
  }

  /** A chime is the one voice in its register: the arp and the lead step back while it rings. */
  function carveForChime(smp: number): void {
    carve("arp", smp, 6, 0.15, 0.4);
    carve("lead", smp, 6, 0.15, 0.4);
    carve("pad", smp, 2.5, 0.2, 0.5);
  }

  // The order matters only for the random streams, which are all seeded per layer.
  layerPlain();
  layerLandings();
  layerGroove();
  layerLead();
  layerOutro();
  layerTyping();
  layerCues();

  return { session: s, timeline: T, n: N, plans, landings, gaps, flush, expect, dropped, nudged, outroS, notes, log };
}
