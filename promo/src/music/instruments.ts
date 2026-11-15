/**
 * The score's instruments.  Each function renders ONE note or hit offline into
 * a Float32Array (mono unless it says Stereo) with explicit envelopes at both
 * ends, so nothing clicks.  Oscillators are band-limited (PolyBLEP), noise
 * comes from a seeded Rng, and everything harsh passes through a low-pass.
 * Levels here are "natural" (peak around 0.5..0.9); the arrangement sets the
 * balance with bus gains.
 */
import { Biquad, Rng, SR, SVF, TAU, centsToRatio, clamp, dcBlock, fadeEdges, newStereo, normalizeStereo, panGains, saw, square, type Stereo } from "./dsp.js";

const n = (sec: number) => Math.max(1, Math.round(sec * SR));

// ---------------------------------------------------------------------------
// Drums
// ---------------------------------------------------------------------------

/** Four-on-the-floor kick: a sine falling from ~175 Hz to A1 (55 Hz), saturated, with a short click. */
export function kick(vel = 1, rng: Rng, opts: { len?: number; f0?: number; f1?: number; sweep?: number; sat?: number } = {}): Float32Array {
  const len = opts.len ?? 0.46;
  const f0 = opts.f0 ?? 175;
  const f1 = opts.f1 ?? 55;
  const sweep = opts.sweep ?? 0.03;
  const sat = opts.sat ?? 1.9;
  const out = new Float32Array(n(len));
  const hp = new Biquad("highpass", 2200, 0.7);
  const satNorm = Math.tanh(sat);
  let phase = 0;
  for (let i = 0; i < out.length; i++) {
    const t = i / SR;
    phase += (TAU * (f1 + (f0 - f1) * Math.exp(-t / sweep))) / SR;
    const amp = (1 - Math.exp(-t / 0.0007)) * (0.86 * Math.exp(-t / 0.1) + 0.14 * Math.exp(-t / 0.2));
    const body = Math.tanh(sat * Math.sin(phase) * amp) / satNorm;
    const click = hp.run(rng.signed()) * Math.exp(-t / 0.0011) * 0.3 * (1 - Math.exp(-t / 0.00012));
    out[i] = (body + click) * vel;
  }
  fadeEdges(out, 0, n(0.012));
  return dcBlock(out, 18);
}

/** A soft sub "heartbeat" for the plain intro: no click, slow attack. */
export function subPulse(vel = 1, f = 55): Float32Array {
  const out = new Float32Array(n(0.5));
  let phase = 0;
  for (let i = 0; i < out.length; i++) {
    const t = i / SR;
    phase += (TAU * (f * (1 + 0.35 * Math.exp(-t / 0.05)))) / SR;
    out[i] = Math.sin(phase) * (1 - Math.exp(-t / 0.012)) * Math.exp(-t / 0.16) * vel;
  }
  fadeEdges(out, 0, n(0.02));
  return dcBlock(out, 18);
}

/** Hand clap: three quick noise bursts and a short tail, band-passed around 1.4 kHz. */
export function clap(vel = 1, rng: Rng): Float32Array {
  const out = new Float32Array(n(0.34));
  const bp = new SVF(1400, 1.0);
  const hp = new Biquad("highpass", 480, 0.7);
  for (let i = 0; i < out.length; i++) {
    const t = i / SR;
    let env = 0;
    for (const b of [0, 0.0095, 0.019]) if (t >= b) env += 0.85 * Math.exp(-(t - b) / 0.0042);
    if (t >= 0.0285) env += Math.exp(-(t - 0.0285) / 0.07);
    bp.set(1250 + 700 * Math.exp(-t / 0.04), 1.0);
    bp.run(rng.signed());
    out[i] = Math.tanh(hp.run(bp.bp) * env * 2.4) * 0.62 * vel;
  }
  fadeEdges(out, n(0.0005), n(0.02));
  return out;
}

/** Closed or open hi-hat: high-passed noise, rolled off at 13 kHz so there is no hash. */
export function hat(vel = 1, open = false, rng: Rng): Float32Array {
  const tau = open ? 0.085 : 0.011;
  const out = new Float32Array(n(open ? 0.4 : 0.1));
  const hp = new Biquad("highpass", 8400, 0.75);
  const hp2 = new Biquad("highpass", 6400, 0.6);
  const lp = new Biquad("lowpass", 13000, 0.7);
  for (let i = 0; i < out.length; i++) {
    const t = i / SR;
    const env = (1 - Math.exp(-t / 0.0004)) * Math.exp(-t / tau);
    out[i] = lp.run(hp2.run(hp.run(rng.signed()))) * env * 0.9 * vel;
  }
  fadeEdges(out, 0, n(0.01));
  return out;
}

/** Snare: a 190 Hz body with a short pitch drop and band-passed noise. */
export function snare(vel = 1, rng: Rng, opts: { tone?: number; len?: number } = {}): Float32Array {
  const len = opts.len ?? 0.28;
  const tone = opts.tone ?? 190;
  const out = new Float32Array(n(len));
  const bp = new SVF(2100, 0.8);
  const hp = new Biquad("highpass", 260, 0.7);
  let phase = 0;
  for (let i = 0; i < out.length; i++) {
    const t = i / SR;
    phase += (TAU * (tone * (1 + 0.5 * Math.exp(-t / 0.018)))) / SR;
    const body = Math.sin(phase) * Math.exp(-t / 0.045) * 0.7;
    bp.run(rng.signed());
    const noise = hp.run(bp.bp) * Math.exp(-t / 0.085) * 2.2;
    out[i] = Math.tanh((body + noise) * 1.2) * 0.75 * vel * (1 - Math.exp(-t / 0.0005));
  }
  fadeEdges(out, 0, n(0.02));
  return out;
}

/** A crash cymbal: six metallic square oscillators plus high-passed noise, decaying over `len`. */
export function crash(vel = 1, rng: Rng, len = 1.6): Float32Array {
  const out = new Float32Array(n(len));
  const freqs = [205.3, 304.4, 369.6, 522.7, 540.0, 800.0].map((f) => f * 1.7);
  const phases = freqs.map(() => rng.next());
  const hp = new Biquad("highpass", 6200, 0.7);
  const hp2 = new Biquad("highpass", 4800, 0.7);
  const nhp = new Biquad("highpass", 5400, 0.6);
  const lp = new Biquad("lowpass", 13500, 0.7);
  const lp2 = new Biquad("lowpass", 13500, 0.7);
  for (let i = 0; i < out.length; i++) {
    const t = i / SR;
    let m = 0;
    for (let k = 0; k < freqs.length; k++) {
      phases[k] += freqs[k] / SR;
      if (phases[k] >= 1) phases[k] -= 1;
      m += square(phases[k], freqs[k] / SR);
    }
    const metal = hp.run(m) * 0.16;
    const noise = nhp.run(rng.signed()) * 0.55;
    const env = (1 - Math.exp(-t / 0.0008)) * (0.6 * Math.exp(-t / 0.22) + 0.4 * Math.exp(-t / (len * 0.34)));
    out[i] = lp2.run(lp.run(hp2.run(metal + noise))) * env * vel;
  }
  fadeEdges(out, 0, n(0.08));
  return out;
}

// ---------------------------------------------------------------------------
// Pitched things
// ---------------------------------------------------------------------------

/** A marimba-ish ping: three partials, a hint of click.  `tau` is the decay time of the fundamental. */
export function ping(freq: number, vel = 1, rng: Rng, tau = 0.075): Float32Array {
  const len = Math.min(1.2, tau * 7);
  const out = new Float32Array(n(len));
  const hp = new Biquad("highpass", 4200, 0.7);
  for (let i = 0; i < out.length; i++) {
    const t = i / SR;
    const s = Math.sin(TAU * freq * t) * Math.exp(-t / tau) + 0.38 * Math.sin(TAU * freq * 2 * t) * Math.exp(-t / (tau * 0.5)) + 0.14 * Math.sin(TAU * freq * 3.01 * t) * Math.exp(-t / (tau * 0.28));
    const click = hp.run(rng.signed()) * Math.exp(-t / 0.0008) * 0.12 * (1 - Math.exp(-t / 0.00012));
    out[i] = (s * (1 - Math.exp(-t / 0.0005)) + click) * vel * 0.8;
  }
  fadeEdges(out, 0, n(0.03));
  return out;
}

/** A glassy bell: harmonic partials plus one inharmonic shimmer, long decay.  Used for dings and the final tail. */
export function bell(freq: number, vel = 1, len = 2.4, shimmer = 1): Float32Array {
  const out = new Float32Array(n(len));
  const parts: Array<[number, number, number]> = [
    [1, 1.0, len * 0.5],
    [2, 0.42, len * 0.26],
    [3, 0.2, len * 0.15],
    [4.07, 0.1, len * 0.1],
    [2.76, 0.16 * shimmer, len * 0.12],
  ];
  for (let i = 0; i < out.length; i++) {
    const t = i / SR;
    let s = 0;
    for (const [r, a, tau] of parts) s += a * Math.sin(TAU * freq * r * t) * Math.exp(-t / tau);
    out[i] = s * (1 - Math.exp(-t / 0.0007)) * vel * 0.55;
  }
  fadeEdges(out, 0, n(0.2));
  return out;
}

/** Sub-bass voice: a band-limited saw through an envelope-swept low-pass, a sine under it, then mild saturation. */
export function bass(freq: number, len: number, vel = 1, bright = 1): Float32Array {
  const rel = 0.05;
  const out = new Float32Array(n(len + rel));
  const dt = freq / SR;
  const dt2 = (freq * centsToRatio(5)) / SR;
  let p1 = 0;
  let p2 = 0.3;
  let ps = 0;
  const f = new SVF(600, 1.2);
  const sustain = Math.round(len * SR);
  for (let i = 0; i < out.length; i++) {
    const t = i / SR;
    if ((i & 7) === 0) f.set(180 + (1500 * bright * vel) * Math.exp(-t / 0.1), 1.3);
    p1 += dt;
    if (p1 >= 1) p1 -= 1;
    p2 += dt2;
    if (p2 >= 1) p2 -= 1;
    ps += dt;
    if (ps >= 1) ps -= 1;
    const body = f.run(0.55 * saw(p1, dt) + 0.45 * saw(p2, dt2));
    const sub = Math.sin(TAU * ps);
    const raw = body * 0.78 + sub * 0.55;
    const env = (1 - Math.exp(-t / 0.003)) * (i < sustain ? 1 : Math.exp(-(i - sustain) / SR / 0.012));
    out[i] = (Math.tanh(1.6 * raw) / 1.35) * env * vel;
  }
  fadeEdges(out, 0, n(0.004));
  return out;
}

/** An arp pluck: two detuned saws through a falling low-pass, fast exponential decay. */
export function pluck(freq: number, vel = 1, bright = 1): Float32Array {
  const out = new Float32Array(n(0.34));
  const dt = freq / SR;
  const dt2 = (freq * centsToRatio(8)) / SR;
  let p1 = 0.1;
  let p2 = 0.6;
  const f = new SVF(3000, 1.1);
  for (let i = 0; i < out.length; i++) {
    const t = i / SR;
    if ((i & 7) === 0) f.set(700 + 3400 * bright * (0.35 + 0.65 * vel) * Math.exp(-t / 0.075), 1.1);
    p1 += dt;
    if (p1 >= 1) p1 -= 1;
    p2 += dt2;
    if (p2 >= 1) p2 -= 1;
    const s = f.run(0.5 * saw(p1, dt) + 0.5 * saw(p2, dt2));
    out[i] = s * (1 - Math.exp(-t / 0.0015)) * Math.exp(-t / 0.085) * vel * 0.9;
  }
  fadeEdges(out, 0, n(0.04));
  return out;
}

/**
 * Pad: for each chord tone, three detuned saws spread across the stereo field,
 * through a slowly moving low-pass.  `cutoff(t)` is the filter in Hz at time t
 * (seconds from the start of the chord).
 */
export function pad(freqs: number[], len: number, cutoff: (t: number) => number, opts: { attack?: number; release?: number; detune?: number } = {}): Stereo {
  const attack = opts.attack ?? 0.35;
  const release = opts.release ?? 0.55;
  const det = opts.detune ?? 9;
  const total = n(len + release);
  const out = newStereo(total);
  const voices: Array<{ dt: number; ph: number; gl: number; gr: number }> = [];
  const pans = [-0.7, 0, 0.7];
  const rng = new Rng(1234);
  freqs.forEach((fr, k) => {
    [-det, 0, det].forEach((c, d) => {
      const f = fr * centsToRatio(c);
      const [gl, gr] = panGains(pans[(d + k) % 3] * 0.9);
      voices.push({ dt: f / SR, ph: rng.next(), gl, gr });
    });
  });
  const fl = new SVF(800, 0.7);
  const fr2 = new SVF(800, 0.7);
  const norm = 0.5 / Math.sqrt(voices.length);
  const sustain = n(len);
  for (let i = 0; i < total; i++) {
    const t = i / SR;
    if ((i & 15) === 0) {
      const c = cutoff(t);
      fl.set(c, 0.8);
      fr2.set(c * 1.04, 0.8);
    }
    let l = 0;
    let r = 0;
    for (const v of voices) {
      v.ph += v.dt;
      if (v.ph >= 1) v.ph -= 1;
      const s = saw(v.ph, v.dt);
      l += s * v.gl;
      r += s * v.gr;
    }
    const env = (1 - Math.exp(-(t * 3.2) / attack)) * (i < sustain ? 1 : Math.exp(-(i - sustain) / SR / (release * 0.3)));
    out.l[i] = fl.run(l) * env * norm;
    out.r[i] = fr2.run(r) * env * norm;
  }
  fadeEdges(out.l, 0, n(0.02));
  fadeEdges(out.r, 0, n(0.02));
  return out;
}

/** Lead voice: saw + square with delayed vibrato and a gentle filter; two slightly detuned copies for width. */
export function lead(freq: number, len: number, vel = 1, opts: { bright?: number; vibrato?: number } = {}): Stereo {
  const rel = 0.14;
  const total = n(len + rel);
  const out = newStereo(total);
  const bright = opts.bright ?? 1;
  const vib = opts.vibrato ?? 0.16;
  const voices = [-6, 6].map((c, k) => ({ ratio: centsToRatio(c), ph: 0.2 + 0.4 * k, ph2: 0.5 * k, pan: k === 0 ? -0.35 : 0.35 }));
  const filt = [new SVF(2800, 0.9), new SVF(2800, 0.9)];
  const sustain = n(len);
  for (let i = 0; i < total; i++) {
    const t = i / SR;
    const vibDepth = vib * clamp((t - 0.12) / 0.25, 0, 1);
    // Vibrato: +/- `vibDepth` semitones, ln(2)/12 = 0.05776 per semitone.
    const lfo = 1 + 0.05776 * vibDepth * Math.sin(TAU * 5.4 * t);
    const env =
      (1 - Math.exp(-t / 0.006)) * (i < sustain ? (0.82 + 0.18 * Math.exp(-t / 0.2)) : (0.82 + 0.18 * Math.exp(-sustain / SR / 0.2)) * Math.exp(-(i - sustain) / SR / 0.05));
    voices.forEach((v, k) => {
      const f = freq * v.ratio * lfo;
      const dt = f / SR;
      v.ph += dt;
      if (v.ph >= 1) v.ph -= 1;
      v.ph2 += dt;
      if (v.ph2 >= 1) v.ph2 -= 1;
      if ((i & 7) === 0) filt[k].set((1900 + 2600 * bright * Math.exp(-t / 0.18) + 700) * (0.8 + 0.2 * vel), 0.9);
      const s = filt[k].run(0.6 * saw(v.ph, dt) + 0.4 * square(v.ph2, dt, 0.42));
      const [gl, gr] = panGains(v.pan);
      out.l[i] += s * env * gl * 0.62 * vel;
      out.r[i] += s * env * gr * 0.62 * vel;
    });
  }
  fadeEdges(out.l, 0, n(0.003));
  fadeEdges(out.r, 0, n(0.003));
  return out;
}

/**
 * A big stab for the hits: every chord tone as three detuned saws spread across the field, through a
 * low-pass that snaps shut over a fraction of a second.  Normalized to a peak of 0.8 (then scaled by `vel`).
 */
export function bigStab(freqs: number[], vel = 1, len = 1.2, opts: { bright?: number } = {}): Stereo {
  const total = n(len);
  const out = newStereo(total);
  const bright = opts.bright ?? 1;
  const rng = new Rng(707);
  const voices = freqs.flatMap((f, k) =>
    [-12, 0, 12].map((c, d) => {
      const [gl, gr] = panGains((((k * 2 + d) % 5) - 2) * 0.38);
      return { dt: (f * centsToRatio(c)) / SR, ph: rng.next(), gl, gr };
    }),
  );
  const fl = new SVF(8000, 0.8);
  const fr = new SVF(8000, 0.8);
  for (let i = 0; i < total; i++) {
    const t = i / SR;
    if ((i & 7) === 0) {
      const c = 650 + 7600 * bright * Math.exp(-t / 0.14);
      fl.set(c, 0.8);
      fr.set(c * 1.04, 0.8);
    }
    let l = 0;
    let r = 0;
    for (const v of voices) {
      v.ph += v.dt;
      if (v.ph >= 1) v.ph -= 1;
      const s = saw(v.ph, v.dt);
      l += s * v.gl;
      r += s * v.gr;
    }
    const env = (1 - Math.exp(-t / 0.0015)) * (0.5 * Math.exp(-t / 0.16) + 0.5 * Math.exp(-t / 0.6));
    out.l[i] = fl.run(l) * env;
    out.r[i] = fr.run(r) * env;
  }
  fadeEdges(out.l, 0, n(0.12));
  fadeEdges(out.r, 0, n(0.12));
  normalizeStereo(out, 0.8 * vel);
  return out;
}
