/**
 * Offline DSP primitives for the score: a seeded PRNG, band-limited oscillators,
 * filters, an FDN reverb and a ping-pong delay.  Everything here is deterministic:
 * no Math.random, no clocks, no I/O.  Buffers are Float32Array, 48 kHz.
 */

export const SR = 48000;
export const TAU = Math.PI * 2;

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

export const clamp = (x: number, lo: number, hi: number) => (x < lo ? lo : x > hi ? hi : x);
export const dbToGain = (db: number) => 10 ** (db / 20);
export const gainToDb = (g: number) => 20 * Math.log10(Math.max(g, 1e-12));
export const midiToHz = (m: number) => 440 * 2 ** ((m - 69) / 12);
export const centsToRatio = (c: number) => 2 ** (c / 1200);
export const lerp = (a: number, b: number, t: number) => a + (b - a) * t;
export const smoothstep = (x: number) => {
  const t = clamp(x, 0, 1);
  return t * t * (3 - 2 * t);
};

/** Piecewise-linear automation: points are [x, y], sorted by x; clamps outside. */
export function curve(points: Array<[number, number]>): (x: number) => number {
  return (x: number) => {
    if (x <= points[0][0]) return points[0][1];
    for (let i = 1; i < points.length; i++) {
      if (x <= points[i][0]) {
        const [x0, y0] = points[i - 1];
        const [x1, y1] = points[i];
        return y0 + ((y1 - y0) * (x - x0)) / (x1 - x0 || 1);
      }
    }
    return points[points.length - 1][1];
  };
}

/** mulberry32: tiny, fast, seedable. */
export class Rng {
  private s: number;
  constructor(seed: number) {
    this.s = seed >>> 0;
  }
  /** Uniform in [0, 1). */
  next(): number {
    this.s = (this.s + 0x6d2b79f5) >>> 0;
    let t = this.s;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  }
  /** Uniform in [-1, 1). */
  signed(): number {
    return this.next() * 2 - 1;
  }
  /** Uniform in [lo, hi). */
  range(lo: number, hi: number): number {
    return lo + (hi - lo) * this.next();
  }
  /** One element of a non-empty array. */
  pick<T>(items: readonly T[]): T {
    return items[Math.min(items.length - 1, Math.floor(this.next() * items.length))];
  }
}

/** A seed for an event from its position, so changing one event never changes another (unlike a shared stream). */
export const seedOf = (...parts: number[]): number => {
  let h = 2166136261;
  for (const p of parts) {
    h = Math.imul(h ^ (p | 0), 16777619);
    h = Math.imul(h ^ (h >>> 15), 2246822507);
  }
  return (h ^ (h >>> 13)) >>> 0;
};

// ---------------------------------------------------------------------------
// Stereo buffers
// ---------------------------------------------------------------------------

export interface Stereo {
  l: Float32Array;
  r: Float32Array;
}

export const newStereo = (n: number): Stereo => ({ l: new Float32Array(n), r: new Float32Array(n) });

/** Equal-power pan gains for pan in [-1 (left), 1 (right)]. */
export function panGains(pan: number): [number, number] {
  const a = ((clamp(pan, -1, 1) + 1) * Math.PI) / 4;
  return [Math.cos(a), Math.sin(a)];
}

/** Add a mono buffer into a stereo bus at sample `start`, with gain and pan. Out-of-range parts are dropped. */
export function addMono(dst: Stereo, start: number, src: Float32Array, gain = 1, pan = 0): void {
  const [gl, gr] = panGains(pan);
  const s0 = Math.max(0, -start);
  const n = Math.min(src.length, dst.l.length - start);
  const l = dst.l;
  const r = dst.r;
  for (let i = s0; i < n; i++) {
    const v = src[i] * gain;
    l[start + i] += v * gl;
    r[start + i] += v * gr;
  }
}

/** Add a stereo pair of buffers at `start` with a gain. */
export function addStereo(dst: Stereo, start: number, srcL: Float32Array, srcR: Float32Array, gain = 1): void {
  const s0 = Math.max(0, -start);
  const n = Math.min(srcL.length, dst.l.length - start);
  for (let i = s0; i < n; i++) {
    dst.l[start + i] += srcL[i] * gain;
    dst.r[start + i] += srcR[i] * gain;
  }
}

/** Add a whole stereo bus into another, with gain. */
export function addBus(dst: Stereo, src: Stereo, gain = 1): void {
  const n = Math.min(dst.l.length, src.l.length);
  for (let i = 0; i < n; i++) {
    dst.l[i] += src.l[i] * gain;
    dst.r[i] += src.r[i] * gain;
  }
}

/** A reversed copy (reverse cymbals, reverse swells). */
export function reversed(buf: Float32Array): Float32Array {
  const out = new Float32Array(buf.length);
  for (let i = 0; i < buf.length; i++) out[i] = buf[buf.length - 1 - i];
  return out;
}

/** Scale a buffer so its largest sample is `peak` (a silent buffer is left alone).  Returns the buffer. */
export function normalize(buf: Float32Array, peak: number): Float32Array {
  let p = 0;
  for (let i = 0; i < buf.length; i++) p = Math.max(p, Math.abs(buf[i]));
  if (p < 1e-12) return buf;
  const g = peak / p;
  for (let i = 0; i < buf.length; i++) buf[i] *= g;
  return buf;
}

/** Scale a stereo pair so the larger channel peak is `peak`. */
export function normalizeStereo(s: Stereo, peak: number): Stereo {
  let p = 0;
  for (let i = 0; i < s.l.length; i++) p = Math.max(p, Math.abs(s.l[i]), Math.abs(s.r[i]));
  if (p < 1e-12) return s;
  const g = peak / p;
  for (let i = 0; i < s.l.length; i++) {
    s.l[i] *= g;
    s.r[i] *= g;
  }
  return s;
}

/** Fade the first `inN` and last `outN` samples of a buffer with a raised cosine (no clicks at the edges). */
export function fadeEdges(buf: Float32Array, inN: number, outN: number): void {
  const n = buf.length;
  for (let i = 0; i < Math.min(inN, n); i++) buf[i] *= 0.5 - 0.5 * Math.cos((Math.PI * i) / inN);
  for (let i = 0; i < Math.min(outN, n); i++) buf[n - 1 - i] *= 0.5 - 0.5 * Math.cos((Math.PI * i) / outN);
}

/** Multiply a bus by a per-sample gain curve. */
export function applyGain(bus: Stereo, gain: Float32Array): void {
  const n = Math.min(bus.l.length, gain.length);
  for (let i = 0; i < n; i++) {
    bus.l[i] *= gain[i];
    bus.r[i] *= gain[i];
  }
}

// ---------------------------------------------------------------------------
// Oscillators (band-limited with PolyBLEP)
// ---------------------------------------------------------------------------

function polyBlep(t: number, dt: number): number {
  if (t < dt) {
    const x = t / dt;
    return x + x - x * x - 1;
  }
  if (t > 1 - dt) {
    const x = (t - 1) / dt;
    return x * x + x + x + 1;
  }
  return 0;
}

/** Band-limited sawtooth, phase in [0, 1), dt = freq / SR. */
export function saw(phase: number, dt: number): number {
  return 2 * phase - 1 - polyBlep(phase, dt);
}

/** Band-limited pulse, 50 % duty unless `pw` is given. */
export function square(phase: number, dt: number, pw = 0.5): number {
  let v = phase < pw ? 1 : -1;
  v += polyBlep(phase, dt);
  let p2 = phase - pw;
  if (p2 < 0) p2 += 1;
  v -= polyBlep(p2, dt);
  return v;
}

// ---------------------------------------------------------------------------
// Filters
// ---------------------------------------------------------------------------

/**
 * Trapezoidal-integrated state-variable filter (Cytomic / Zavalishin): stable
 * while its cutoff is modulated every few samples, which the plucks and
 * basses do.  Call `set(fc, q)` when the cutoff changes, `run(x)` per sample.
 */
export class SVF {
  private ic1 = 0;
  private ic2 = 0;
  private a1 = 0;
  private a2 = 0;
  private a3 = 0;
  private k = 1;
  lp = 0;
  bp = 0;
  hp = 0;
  constructor(fc = 1000, q = 0.707) {
    this.set(fc, q);
  }
  set(fc: number, q: number): void {
    const f = clamp(fc, 10, SR * 0.45);
    const g = Math.tan((Math.PI * f) / SR);
    this.k = 1 / Math.max(q, 0.05);
    this.a1 = 1 / (1 + g * (g + this.k));
    this.a2 = g * this.a1;
    this.a3 = g * this.a2;
  }
  run(x: number): number {
    const v3 = x - this.ic2;
    const v1 = this.a1 * this.ic1 + this.a2 * v3;
    const v2 = this.ic2 + this.a2 * this.ic1 + this.a3 * v3;
    this.ic1 = 2 * v1 - this.ic1;
    this.ic2 = 2 * v2 - this.ic2;
    this.lp = v2;
    this.bp = v1;
    this.hp = x - this.k * v1 - v2;
    return v2;
  }
}

export type BiquadType = "lowpass" | "highpass" | "bandpass" | "notch" | "peak" | "lowshelf" | "highshelf";

/** RBJ cookbook biquad (static coefficients). */
export class Biquad {
  private b0 = 1;
  private b1 = 0;
  private b2 = 0;
  private a1 = 0;
  private a2 = 0;
  private x1 = 0;
  private x2 = 0;
  private y1 = 0;
  private y2 = 0;
  constructor(type: BiquadType, fc: number, q = 0.707, gainDb = 0) {
    const w0 = (TAU * clamp(fc, 5, SR * 0.49)) / SR;
    const cos = Math.cos(w0);
    const sin = Math.sin(w0);
    const alpha = sin / (2 * q);
    const A = 10 ** (gainDb / 40);
    let b0 = 1;
    let b1 = 0;
    let b2 = 0;
    let a0 = 1;
    let a1 = 0;
    let a2 = 0;
    switch (type) {
      case "lowpass":
        b0 = (1 - cos) / 2;
        b1 = 1 - cos;
        b2 = (1 - cos) / 2;
        a0 = 1 + alpha;
        a1 = -2 * cos;
        a2 = 1 - alpha;
        break;
      case "highpass":
        b0 = (1 + cos) / 2;
        b1 = -(1 + cos);
        b2 = (1 + cos) / 2;
        a0 = 1 + alpha;
        a1 = -2 * cos;
        a2 = 1 - alpha;
        break;
      case "bandpass":
        b0 = alpha;
        b1 = 0;
        b2 = -alpha;
        a0 = 1 + alpha;
        a1 = -2 * cos;
        a2 = 1 - alpha;
        break;
      case "notch":
        b0 = 1;
        b1 = -2 * cos;
        b2 = 1;
        a0 = 1 + alpha;
        a1 = -2 * cos;
        a2 = 1 - alpha;
        break;
      case "peak":
        b0 = 1 + alpha * A;
        b1 = -2 * cos;
        b2 = 1 - alpha * A;
        a0 = 1 + alpha / A;
        a1 = -2 * cos;
        a2 = 1 - alpha / A;
        break;
      case "lowshelf": {
        const s = 2 * Math.sqrt(A) * alpha;
        b0 = A * (A + 1 - (A - 1) * cos + s);
        b1 = 2 * A * (A - 1 - (A + 1) * cos);
        b2 = A * (A + 1 - (A - 1) * cos - s);
        a0 = A + 1 + (A - 1) * cos + s;
        a1 = -2 * (A - 1 + (A + 1) * cos);
        a2 = A + 1 + (A - 1) * cos - s;
        break;
      }
      case "highshelf": {
        const s = 2 * Math.sqrt(A) * alpha;
        b0 = A * (A + 1 + (A - 1) * cos + s);
        b1 = -2 * A * (A - 1 + (A + 1) * cos);
        b2 = A * (A + 1 + (A - 1) * cos - s);
        a0 = A + 1 - (A - 1) * cos + s;
        a1 = 2 * (A - 1 - (A + 1) * cos);
        a2 = A + 1 - (A - 1) * cos - s;
        break;
      }
    }
    this.b0 = b0 / a0;
    this.b1 = b1 / a0;
    this.b2 = b2 / a0;
    this.a1 = a1 / a0;
    this.a2 = a2 / a0;
  }
  run(x: number): number {
    const y = this.b0 * x + this.b1 * this.x1 + this.b2 * this.x2 - this.a1 * this.y1 - this.a2 * this.y2;
    this.x2 = this.x1;
    this.x1 = x;
    this.y2 = this.y1;
    this.y1 = y;
    return y;
  }
  /** Filter a whole buffer in place. */
  apply(buf: Float32Array): Float32Array {
    for (let i = 0; i < buf.length; i++) buf[i] = this.run(buf[i]);
    return buf;
  }
}

/** One-pole low-pass coefficient for a cutoff in Hz. */
export const onePole = (fc: number) => 1 - Math.exp((-TAU * fc) / SR);

/** DC blocker (one-pole high-pass at ~`fc` Hz), in place. */
export function dcBlock(buf: Float32Array, fc = 12): Float32Array {
  const r = 1 - (TAU * fc) / SR;
  let x1 = 0;
  let y1 = 0;
  for (let i = 0; i < buf.length; i++) {
    const x = buf[i];
    const y = x - x1 + r * y1;
    x1 = x;
    y1 = y;
    buf[i] = y;
  }
  return buf;
}

// ---------------------------------------------------------------------------
// Delay and reverb (whole-buffer processors)
// ---------------------------------------------------------------------------

/**
 * Stereo ping-pong delay: the first echo lands on the left, the second on the
 * right, and so on.  The feedback path is band-limited so repeats get softer
 * and darker.  Returns the wet signal only.
 */
export function pingPong(inL: Float32Array, inR: Float32Array, delaySamples: number, feedback: number, lpHz = 4200, hpHz = 220): Stereo {
  const n = inL.length;
  const out = newStereo(n);
  const bufL = new Float32Array(delaySamples);
  const bufR = new Float32Array(delaySamples);
  const lpA = onePole(lpHz);
  const hpR = 1 - (TAU * hpHz) / SR;
  let lpL = 0;
  let lpRs = 0;
  let hx1L = 0;
  let hy1L = 0;
  let hx1R = 0;
  let hy1R = 0;
  let pos = 0;
  for (let i = 0; i < n; i++) {
    const yl = bufL[pos];
    const yr = bufR[pos];
    out.l[i] = yl;
    out.r[i] = yr;
    // Band-limit what is fed back.
    lpL += lpA * (yl - lpL);
    lpRs += lpA * (yr - lpRs);
    const hl = lpL - hx1L + hpR * hy1L;
    hx1L = lpL;
    hy1L = hl;
    const hr = lpRs - hx1R + hpR * hy1R;
    hx1R = lpRs;
    hy1R = hr;
    const m = (inL[i] + inR[i]) * 0.5;
    bufL[pos] = m + feedback * hr;
    bufR[pos] = feedback * hl;
    pos++;
    if (pos >= delaySamples) pos = 0;
  }
  return out;
}

/**
 * A feedback delay network reverb (8 lines, Householder mixing, per-line
 * damping) behind a pre-delay and four input diffusers.  Wet output only,
 * band-limited to 170 Hz .. 7.5 kHz so it adds air, not mud or hiss.
 */
export function reverb(inL: Float32Array, inR: Float32Array, opts: { rt60?: number; preDelayMs?: number; dampHz?: number } = {}): Stereo {
  const n = inL.length;
  const rt60 = opts.rt60 ?? 1.9;
  const pre = Math.round(((opts.preDelayMs ?? 18) / 1000) * SR);
  const dampA = onePole(opts.dampHz ?? 5200);
  const lens = [1601, 1873, 2203, 2539, 2903, 3331, 3719, 4111];
  const N = lens.length;
  const lines = lens.map((d) => new Float32Array(d));
  const pos = new Int32Array(N);
  const lpState = new Float64Array(N);
  const gain = lens.map((d) => 10 ** ((-3 * d) / (SR * rt60)));
  // Input diffusers: Schroeder allpasses.
  const apLens = [142, 107, 379, 277];
  const apBuf = apLens.map((d) => new Float32Array(d));
  const apPos = new Int32Array(apLens.length);
  const apG = 0.62;
  const preL = new Float32Array(pre + 1);
  const preR = new Float32Array(pre + 1);
  let prePos = 0;
  const out = newStereo(n);
  const y = new Float64Array(N);
  const hpLow = new Biquad("highpass", 170, 0.7);
  const hpLow2 = new Biquad("highpass", 170, 0.7);
  const lpHigh = new Biquad("lowpass", 7500, 0.7);
  const lpHigh2 = new Biquad("lowpass", 7500, 0.7);
  const scale = 0.5;
  for (let i = 0; i < n; i++) {
    // Pre-delay.
    const dl = preL[prePos];
    const dr = preR[prePos];
    preL[prePos] = inL[i];
    preR[prePos] = inR[i];
    prePos++;
    if (prePos > pre) prePos = 0;
    // Diffuse the mono sum, keep a little stereo by differencing.
    let x = (dl + dr) * 0.5;
    for (let a = 0; a < apLens.length; a++) {
      const b = apBuf[a];
      const p = apPos[a];
      const d = b[p];
      const v = x - apG * d;
      b[p] = v;
      x = d + apG * v;
      apPos[a] = p + 1 >= apLens[a] ? 0 : p + 1;
    }
    const side = (dl - dr) * 0.5;
    // Read the lines, damp, mix.
    let sum = 0;
    for (let k = 0; k < N; k++) {
      const v = lines[k][pos[k]];
      lpState[k] += dampA * (v - lpState[k]);
      y[k] = lpState[k];
      sum += y[k];
    }
    const mix = (2 / N) * sum;
    let oL = 0;
    let oR = 0;
    for (let k = 0; k < N; k++) {
      const fb = (y[k] - mix) * gain[k];
      const inj = k < 4 ? x + side : x - side;
      lines[k][pos[k]] = fb + inj * 0.35;
      pos[k] = pos[k] + 1 >= lens[k] ? 0 : pos[k] + 1;
      // Decorrelated output taps.
      oL += (k & 1 ? -1 : 1) * y[k];
      oR += (k & 2 ? -1 : 1) * y[k];
    }
    out.l[i] = lpHigh.run(hpLow.run(oL * scale * 0.5));
    out.r[i] = lpHigh2.run(hpLow2.run(oR * scale * 0.5));
  }
  return out;
}
