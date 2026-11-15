/**
 * The sounds of the cues: what the person types, presses and clicks, what the footage lights up, and the fall
 * and the landing of a piece of UI.  Like the instruments they are rendered offline, note by note, into
 * Float32Arrays that start and end at zero; noise is seeded, so a cue always sounds the same.
 *
 * Every function normalizes its result to a known peak (`vel` times a fixed number), so a velocity means the
 * same thing for every random variation and the arrangement only has to set bus gains.  Pitched sounds are
 * given their pitch by the caller, which takes it from the chord of the bar: the cues stay in the key.
 */
import { Biquad, Rng, SR, SVF, TAU, centsToRatio, fadeEdges, newStereo, normalize, normalizeStereo, panGains, saw, type Stereo } from "./dsp.js";

const n = (sec: number) => Math.max(1, Math.round(sec * SR));

/** Add a short band-passed noise burst (a tap, a rattle) into `out` at `atSec`. */
function noiseTap(out: Float32Array, atSec: number, amp: number, fc: number, q: number, tau: number, rng: Rng): void {
  const start = n(atSec);
  const len = Math.min(out.length - start, n(tau * 7));
  if (len <= 0) return;
  const bp = new SVF(fc, q);
  for (let i = 0; i < len; i++) {
    const t = i / SR;
    bp.run(rng.signed());
    out[start + i] += bp.bp * Math.exp(-t / tau) * (1 - Math.exp(-t / 0.00015)) * amp;
  }
}

// ---------------------------------------------------------------------------
// The person
// ---------------------------------------------------------------------------

/**
 * One key of the person's typing: a soft, slightly muted "tok".  A band-passed noise click (the plastic), a
 * duller body resonance, and a short tuned thock (a sine that falls a few semitones in the first 10 ms) whose
 * pitch the caller picks from the chord, so a run of keys is a little marimba-like and never out of key.
 * `size` > 1 is a bigger key (longer, deeper).  About 70 ms long; peak = 0.9 * vel.
 */
export function typeTick(rng: Rng, vel: number, hz: number, size = 1): Float32Array {
  const out = new Float32Array(n(0.075 * size));
  const click = new SVF(2800 * (0.92 + 0.2 * rng.next()), 1.4);
  const body = new SVF(1100 * (0.9 + 0.25 * rng.next()), 2.4);
  const soften = new Biquad("lowpass", 7000, 0.7);
  let phase = 0;
  for (let i = 0; i < out.length; i++) {
    const t = i / SR;
    const w = rng.signed();
    click.run(w);
    body.run(w);
    phase += (TAU * hz * (1 + 0.3 * Math.exp(-t / 0.006))) / SR;
    const attack = 1 - Math.exp(-t / 0.0002);
    const c = click.bp * Math.exp(-t / 0.0012) * 1.1;
    const b = body.bp * Math.exp(-t / 0.0045) * 0.55;
    const th = Math.sin(phase) * Math.exp(-t / (0.01 * size)) * 0.55;
    out[i] = soften.run((c + b + th) * attack);
  }
  fadeEdges(out, 0, n(0.015));
  return normalize(out, 0.9 * vel);
}

/**
 * C-c C-c: a bigger key than the typing's.  A solid thock (pitched by the caller, an octave or two above the chord's
 * root so it speaks over the bass), the click of the plastic, a second tap as the long key bottoms out on its
 * stabilizer 34 ms later, and a faint key-up.  About 170 ms; peak = 0.9 * vel.
 */
export function keyThock(rng: Rng, vel: number, hz: number): Float32Array {
  const out = new Float32Array(n(0.17));
  const click = new SVF(2300 * (0.95 + 0.1 * rng.next()), 1.3);
  const body = new SVF(900, 2.0);
  let phase = 0;
  for (let i = 0; i < out.length; i++) {
    const t = i / SR;
    const w = rng.signed();
    click.run(w);
    body.run(w);
    phase += (TAU * hz * (1 + 0.35 * Math.exp(-t / 0.008))) / SR;
    const attack = 1 - Math.exp(-t / 0.00025);
    const c = click.bp * Math.exp(-t / 0.0016) * 0.95;
    const b = body.bp * Math.exp(-t / 0.007) * 0.7;
    const th = Math.sin(phase) * Math.exp(-t / 0.02) * 0.8;
    out[i] = (c + b + th) * attack;
  }
  noiseTap(out, 0.034, 0.6, 1900, 1.6, 0.0022, rng);
  noiseTap(out, 0.034, 0.25, 700, 2.0, 0.006, rng);
  noiseTap(out, 0.092, 0.18, 3100, 1.4, 0.0012, rng);
  new Biquad("lowpass", 6500, 0.7).apply(out);
  fadeEdges(out, 0, n(0.03));
  return normalize(out, 0.9 * vel);
}

/**
 * A pointer click: a crisp noise tick, a short bright blip at `hz` (a note of the chord, around 1.3-2.1 kHz) and a
 * faint low press under it.  About 110 ms; peak = 0.85 * vel.
 */
export function clickBlip(rng: Rng, vel: number, hz: number): Float32Array {
  const out = new Float32Array(n(0.11));
  const hp = new Biquad("highpass", 2200, 0.7);
  for (let i = 0; i < out.length; i++) {
    const t = i / SR;
    const attack = 1 - Math.exp(-t / 0.0003);
    const tick = hp.run(rng.signed()) * Math.exp(-t / 0.0006) * 0.8;
    const blip = (Math.sin(TAU * hz * t) + 0.3 * Math.sin(TAU * hz * 2 * t)) * Math.exp(-t / 0.013) * 0.7;
    const press = Math.sin(TAU * 330 * t) * Math.exp(-t / 0.007) * 0.4;
    out[i] = (tick + blip + press) * attack;
  }
  fadeEdges(out, 0, n(0.03));
  return normalize(out, 0.85 * vel);
}

/**
 * The send: a round "pop" (a sine that falls from 570 to 190 Hz in a few milliseconds, plus a click) at the frame
 * of the key.  Mono, about 130 ms; peak = 0.9 * vel.
 */
export function sendPop(rng: Rng, vel: number): Float32Array {
  const out = new Float32Array(n(0.13));
  const hp = new Biquad("highpass", 1800, 0.7);
  let phase = 0;
  for (let i = 0; i < out.length; i++) {
    const t = i / SR;
    phase += (TAU * (190 + 380 * Math.exp(-t / 0.012))) / SR;
    const attack = 1 - Math.exp(-t / 0.0003);
    out[i] = (Math.sin(phase) * Math.exp(-t / 0.022) * 0.9 + hp.run(rng.signed()) * Math.exp(-t / 0.0012) * 0.5) * attack;
  }
  fadeEdges(out, 0, n(0.03));
  return normalize(out, 0.9 * vel);
}

/**
 * The message flies away: air that rises from 700 Hz to 6.5 kHz over a third of a second, swelling in quickly and
 * dying away, panned from the left to the right.  Stereo; peak = 0.7 * vel.
 */
export function sendWhoosh(rng: Rng, vel: number): Stereo {
  const len = 0.34;
  const total = n(len);
  const out = newStereo(total);
  const bp = new SVF(700, 1.0);
  const bpR = new SVF(700, 1.0);
  const hp = new Biquad("highpass", 400, 0.7);
  for (let i = 0; i < total; i++) {
    const t = i / SR;
    const x = i / total;
    const f = 700 * (6500 / 700) ** (x * x * (3 - 2 * x));
    if ((i & 7) === 0) {
      bp.set(f, 1.0);
      bpR.set(f * 1.05, 1.0);
    }
    const w = hp.run(rng.signed());
    bp.run(w);
    bpR.run(w * 0.85 + rng.signed() * 0.15);
    const env = (1 - Math.exp(-t / 0.02)) * Math.exp(-t / 0.085);
    const [gl, gr] = panGains(-0.55 + 1.1 * x);
    out.l[i] = bp.bp * env * gl;
    out.r[i] = bpR.bp * env * gr;
  }
  fadeEdges(out.l, 0, n(0.06));
  fadeEdges(out.r, 0, n(0.06));
  return normalizeStereo(out, 0.7 * vel);
}

// ---------------------------------------------------------------------------
// The footage
// ---------------------------------------------------------------------------

/**
 * A caption is drawn: a small airy ping.  A sine that glides up a fifth into `hz` (a note of the chord) with a
 * little octave on top, and a breath of band-passed noise around it; the two channels are detuned a few cents and
 * carry different breath, so it opens a little in the stereo field.  About 0.5 s; peak = 0.8 * vel.
 */
export function calloutPing(rng: Rng, vel: number, hz: number): Stereo {
  const total = n(0.5);
  const out = newStereo(total);
  const airL = new SVF(6200, 1.1);
  const airR = new SVF(6400, 1.1);
  const airHpL = new Biquad("highpass", 3500, 0.7);
  const airHpR = new Biquad("highpass", 3500, 0.7);
  let phL = 0;
  let phR = 0;
  const detune = centsToRatio(5);
  for (let i = 0; i < total; i++) {
    const t = i / SR;
    const f = (hz / 1.5) * (1 + 0.5 * (1 - Math.exp(-t / 0.028)));
    phL += (TAU * f) / SR;
    phR += (TAU * f * detune) / SR;
    const env = (1 - Math.exp(-t / 0.006)) * Math.exp(-t / 0.11);
    const breath = (1 - Math.exp(-t / 0.012)) * Math.exp(-t / 0.06) * 0.28;
    airL.run(rng.signed());
    airR.run(rng.signed());
    out.l[i] = (Math.sin(phL) + 0.22 * Math.sin(2 * phL + 0.5)) * env + airHpL.run(airL.bp) * breath;
    out.r[i] = (Math.sin(phR) + 0.22 * Math.sin(2 * phR + 0.5)) * env + airHpR.run(airR.bp) * breath;
  }
  fadeEdges(out.l, 0, n(0.08));
  fadeEdges(out.r, 0, n(0.08));
  return normalizeStereo(out, 0.8 * vel);
}

/**
 * A chime / bright pluck at `hz`: two-operator FM with a harmonic modulator, so the spectrum is the note's own
 * harmonics (in key by construction): a bright attack that mellows to a near-pure tone in about 80 ms, a bell
 * overtone, and a faint click.  `len` is the ring time; peak = 0.8 * vel.
 */
export function chime(hz: number, vel = 1, len = 1.0, opts: { bright?: number } = {}): Float32Array {
  const bright = opts.bright ?? 1;
  const out = new Float32Array(n(len));
  const tau = len * 0.32;
  const hp = new Biquad("highpass", 5200, 0.7);
  const rng = new Rng(Math.round(hz * 7));
  for (let i = 0; i < out.length; i++) {
    const t = i / SR;
    const idx = bright * (3.4 * Math.exp(-t / 0.03) + 0.35 * Math.exp(-t / 0.4));
    const car = Math.sin(TAU * hz * t + idx * Math.sin(TAU * hz * 2 * t));
    const bellTone = 0.18 * Math.sin(TAU * hz * 4 * t) * Math.exp(-t / (tau * 0.25));
    const click = hp.run(rng.signed()) * Math.exp(-t / 0.0007) * 0.14;
    out[i] = (car * Math.exp(-t / tau) + bellTone + click) * (1 - Math.exp(-t / 0.0004));
  }
  fadeEdges(out, 0, n(Math.min(0.25, len * 0.3)));
  return normalize(out, 0.8 * vel);
}

// ---------------------------------------------------------------------------
// The fall and the landing
// ---------------------------------------------------------------------------

/**
 * The instant the UI is let go: a short airy "tsk" and a blip that falls from about 2.7 kHz, so the start of the
 * fall has an onset the ear (and the QA) can find.  About 160 ms; peak = 0.9 * vel.
 */
export function fallLaunch(rng: Rng, vel: number): Float32Array {
  const out = new Float32Array(n(0.16));
  const hp = new Biquad("highpass", 4200, 0.7);
  let phase = 0;
  for (let i = 0; i < out.length; i++) {
    const t = i / SR;
    phase += (TAU * (500 + 2200 * Math.exp(-t / 0.05))) / SR;
    const attack = 1 - Math.exp(-t / 0.0003);
    out[i] = (hp.run(rng.signed()) * Math.exp(-t / 0.006) * 0.8 + Math.sin(phase) * Math.exp(-t / 0.05) * 0.5) * attack;
  }
  fadeEdges(out, 0, n(0.04));
  return normalize(out, 0.9 * vel);
}

/**
 * The fall: air that sweeps DOWN from 7 kHz to 280 Hz while it swells (gravity: the louder, the faster), and a
 * faint tone that falls from A5 to A2 under it (kept low: any louder it is a cartoon bomb), so the whoosh ends on
 * the key's root as the boom begins.
 * `len` seconds; it ends loud (the caller cuts it at the gap); peak = 0.9 * vel.
 */
export function fallWhoosh(len: number, vel: number, rng: Rng): Stereo {
  const total = n(len);
  const out = newStereo(total);
  const hp = new Biquad("highpass", 120, 0.7);
  const a1 = new SVF(7000, 1.0);
  const a2 = new SVF(7000, 1.4);
  const b1 = new SVF(7000, 1.0);
  const b2 = new SVF(7000, 1.4);
  let tone = 0;
  for (let i = 0; i < total; i++) {
    const x = i / total;
    const f = 7000 * (280 / 7000) ** x ** 0.9;
    if ((i & 7) === 0) {
      a1.set(f, 1.0);
      a2.set(f, 1.4);
      b1.set(f * 1.06, 1.0);
      b2.set(f * 1.06, 1.4);
    }
    const w = hp.run(rng.signed());
    a1.run(w);
    a2.run(a1.bp);
    b1.run(w * 0.8 + rng.signed() * 0.2);
    b2.run(b1.bp);
    tone += (TAU * 880 * (110 / 880) ** x ** 0.9) / SR;
    const env = x ** 1.5 * (1 - Math.exp(-i / (SR * 0.01)));
    const tn = Math.sin(tone) * 0.16 * x ** 1.2;
    out.l[i] = a2.bp * env + tn;
    out.r[i] = b2.bp * env + tn;
  }
  fadeEdges(out.l, 0, n(0.006));
  fadeEdges(out.r, 0, n(0.006));
  return normalizeStereo(out, 0.9 * vel);
}

/**
 * The riser of the tension: air that climbs from 450 Hz to 10 kHz and swells (slowly at first, then fast), with a
 * flutter that speeds up from 5 to 25 Hz for urgency.  Stereo; peak = 0.8 * vel.
 */
export function riserNoise(len: number, vel: number, rng: Rng): Stereo {
  const total = n(len);
  const out = newStereo(total);
  const hp = new Biquad("highpass", 250, 0.7);
  const bpL = new SVF(450, 0.7);
  const bpR = new SVF(450, 0.7);
  let flutter = 0;
  for (let i = 0; i < total; i++) {
    const x = i / total;
    const f = 450 * (10000 / 450) ** x ** 1.25;
    if ((i & 7) === 0) {
      bpL.set(f, 0.7);
      bpR.set(f * 1.05, 0.7);
    }
    flutter += (TAU * (5 + 20 * x)) / SR;
    const w = hp.run(rng.signed());
    bpL.run(w);
    bpR.run(w * 0.85 + rng.signed() * 0.15);
    const env = x ** 2.2 * (1 - 0.3 * (0.5 + 0.5 * Math.sin(flutter)));
    out.l[i] = bpL.bp * env;
    out.r[i] = bpR.bp * env;
  }
  fadeEdges(out.l, n(0.01), n(0.004));
  fadeEdges(out.r, n(0.01), n(0.004));
  return normalizeStereo(out, 0.8 * vel);
}

/**
 * The tonal riser: two detuned saws that glide from `f0` to `f1` Hz through a low-pass that opens from 600 Hz to
 * 5.2 kHz, swelling.  Stereo (one saw a side); peak = 0.7 * vel.
 */
export function riserTone(len: number, f0: number, f1: number, vel: number): Stereo {
  const total = n(len);
  const out = newStereo(total);
  const fl = new SVF(600, 0.9);
  const fr = new SVF(600, 0.9);
  let pl = 0.1;
  let pr = 0.6;
  const dl = centsToRatio(-9);
  const dr = centsToRatio(9);
  for (let i = 0; i < total; i++) {
    const x = i / total;
    const f = f0 * (f1 / f0) ** x;
    if ((i & 7) === 0) {
      const c = 600 + 4600 * x ** 1.5;
      fl.set(c, 0.9);
      fr.set(c, 0.9);
    }
    pl += (f * dl) / SR;
    pr += (f * dr) / SR;
    if (pl >= 1) pl -= 1;
    if (pr >= 1) pr -= 1;
    const env = x ** 1.8;
    out.l[i] = fl.run(saw(pl, (f * dl) / SR) + 0.35 * saw(pr, (f * dr) / SR)) * env;
    out.r[i] = fr.run(saw(pr, (f * dr) / SR) + 0.35 * saw(pl, (f * dl) / SR)) * env;
  }
  fadeEdges(out.l, n(0.01), n(0.004));
  fadeEdges(out.r, n(0.01), n(0.004));
  return normalizeStereo(out, 0.7 * vel);
}

/**
 * The boom of the landing, tuned: a sine that falls two octaves, from A2 to A0 (110 Hz to 27.5 Hz), and rings for
 * about a second.  Saturated a little so the harmonics (55 and 110 Hz) carry on small speakers.  Peak = vel.
 */
export function subDrop(vel = 1, len = 1.4): Float32Array {
  const out = new Float32Array(n(len));
  let phase = 0;
  const sat = 1.7;
  const satNorm = Math.tanh(sat);
  for (let i = 0; i < out.length; i++) {
    const t = i / SR;
    phase += (TAU * (27.5 + 82.5 * Math.exp(-t / 0.16))) / SR;
    const amp = (1 - Math.exp(-t / 0.002)) * Math.exp(-t / 0.55);
    out[i] = (Math.tanh(sat * Math.sin(phase) * amp) / satNorm) * amp ** 0.4;
  }
  fadeEdges(out, 0, n(0.25));
  const sub = new Biquad("lowpass", 520, 0.7);
  sub.apply(out);
  return normalize(out, vel);
}

/** The air the landing moves: low-passed noise (220 Hz) with a 45 ms decay.  Peak = vel. */
export function noiseThump(rng: Rng, vel = 1): Float32Array {
  const out = new Float32Array(n(0.3));
  const lp = new SVF(220, 0.8);
  for (let i = 0; i < out.length; i++) {
    const t = i / SR;
    lp.run(rng.signed());
    out[i] = lp.lp * Math.exp(-t / 0.045) * (1 - Math.exp(-t / 0.0008));
  }
  fadeEdges(out, 0, n(0.06));
  return normalize(out, vel);
}
