/**
 * Mastering and measurement: ITU-R BS.1770-4 loudness (K-weighting, 400 ms
 * blocks, absolute and relative gates), a 4x-oversampled true-peak estimate,
 * and a lookahead peak limiter.  The film is mastered to about -14 LUFS with
 * true peak at or below -1 dBTP, and these functions are how the score checks
 * itself (ffmpeg's ebur128 cross-checks them in the QA report).
 */
import { SR, Biquad, type Stereo } from "./dsp.js";

/** K-weighting at 48 kHz: the shelf and the RLB high-pass of BS.1770-4. */
class KWeight {
  private x1a = 0;
  private x2a = 0;
  private y1a = 0;
  private y2a = 0;
  private x1b = 0;
  private x2b = 0;
  private y1b = 0;
  private y2b = 0;
  run(x: number): number {
    // Stage 1: high shelf (+4 dB above ~1.5 kHz).
    const ya = 1.53512485958697 * x - 2.69169618940638 * this.x1a + 1.19839281085285 * this.x2a + 1.69065929318241 * this.y1a - 0.73248077421585 * this.y2a;
    this.x2a = this.x1a;
    this.x1a = x;
    this.y2a = this.y1a;
    this.y1a = ya;
    // Stage 2: high-pass (~38 Hz).
    const yb = ya - 2 * this.x1b + this.x2b + 1.99004745483398 * this.y1b - 0.99007225036621 * this.y2b;
    this.x2b = this.x1b;
    this.x1b = ya;
    this.y2b = this.y1b;
    this.y1b = yb;
    return yb;
  }
}

/** K-weighted copy of a channel. */
function kWeighted(ch: Float32Array): Float64Array {
  const k = new KWeight();
  const out = new Float64Array(ch.length);
  for (let i = 0; i < ch.length; i++) out[i] = k.run(ch[i]);
  return out;
}

export interface LoudnessBlocks {
  /** Mean square of each 400 ms block (summed over channels, G = 1), hop 100 ms. */
  z: Float64Array;
  /** Sample index where each block starts. */
  starts: Int32Array;
}

export function loudnessBlocks(l: Float32Array, r: Float32Array): LoudnessBlocks {
  const kl = kWeighted(l);
  const kr = kWeighted(r);
  const block = Math.round(0.4 * SR);
  const hop = Math.round(0.1 * SR);
  const count = Math.max(0, Math.floor((l.length - block) / hop) + 1);
  // Prefix sums of squares make every block O(1).
  const pl = new Float64Array(l.length + 1);
  const pr = new Float64Array(l.length + 1);
  for (let i = 0; i < l.length; i++) {
    pl[i + 1] = pl[i] + kl[i] * kl[i];
    pr[i + 1] = pr[i] + kr[i] * kr[i];
  }
  const z = new Float64Array(count);
  const starts = new Int32Array(count);
  for (let b = 0; b < count; b++) {
    const s = b * hop;
    z[b] = (pl[s + block] - pl[s] + pr[s + block] - pr[s]) / block;
    starts[b] = s;
  }
  return { z, starts };
}

const lufs = (z: number) => -0.691 + 10 * Math.log10(Math.max(z, 1e-12));

/** Integrated loudness (LUFS) with the absolute (-70) and relative (-10 LU) gates. */
export function integratedLufs(l: Float32Array, r: Float32Array): number {
  const { z } = loudnessBlocks(l, r);
  const above = Array.from(z).filter((v) => lufs(v) > -70);
  if (!above.length) return -Infinity;
  const mean = above.reduce((a, b) => a + b, 0) / above.length;
  const gate = lufs(mean) - 10;
  const kept = above.filter((v) => lufs(v) > gate);
  if (!kept.length) return -Infinity;
  return lufs(kept.reduce((a, b) => a + b, 0) / kept.length);
}

/** Loudness (LUFS) of a sample range, ungated: for per-section figures. */
export function rangeLufs(l: Float32Array, r: Float32Array, from: number, to: number): number {
  const kl = kWeighted(l.subarray(from, to));
  const kr = kWeighted(r.subarray(from, to));
  let s = 0;
  for (let i = 0; i < kl.length; i++) s += kl[i] * kl[i] + kr[i] * kr[i];
  return lufs(s / Math.max(1, kl.length));
}

/** Prefix sums of the K-weighted power of both channels: the loudness of any range in constant time (see `prefixLufs`). */
export function kPrefix(l: Float32Array, r: Float32Array): Float64Array {
  const kl = kWeighted(l);
  const kr = kWeighted(r);
  const p = new Float64Array(l.length + 1);
  for (let i = 0; i < l.length; i++) p[i + 1] = p[i] + kl[i] * kl[i] + kr[i] * kr[i];
  return p;
}

/** Loudness (LUFS, ungated) of the range [from, to) of a `kPrefix`. */
export function prefixLufs(p: Float64Array, from: number, to: number): number {
  return lufs((p[to] - p[from]) / Math.max(1, to - from));
}

/** Sample peak (linear) over both channels. */
export function samplePeak(l: Float32Array, r: Float32Array): number {
  let p = 0;
  for (let i = 0; i < l.length; i++) {
    const a = Math.abs(l[i]);
    const b = Math.abs(r[i]);
    if (a > p) p = a;
    if (b > p) p = b;
  }
  return p;
}

/** Polyphase 4x interpolation taps (12 per phase, Kaiser-ish window): the in-between points of a band-limited signal. */
const TP_TAPS = 12;
const TP_PHASES: Float64Array[] = [1, 2, 3].map((p) => {
  const h = new Float64Array(TP_TAPS);
  const frac = p / 4;
  for (let k = 0; k < TP_TAPS; k++) {
    const m = k - (TP_TAPS / 2 - 1); // -5 .. 6
    const x = m - frac;
    const sinc = Math.abs(x) < 1e-9 ? 1 : Math.sin(Math.PI * x) / (Math.PI * x);
    const w = 0.5 + 0.5 * Math.cos((Math.PI * x) / (TP_TAPS / 2 + 0.5)); // Hann over the tap span
    h[k] = sinc * w;
  }
  return h;
});

/** Estimated true peak (linear) over both channels, by 4x oversampling. */
export function truePeak(l: Float32Array, r: Float32Array): number {
  let peak = samplePeak(l, r);
  for (const ch of [l, r]) {
    for (let i = TP_TAPS / 2; i < ch.length - TP_TAPS / 2; i++) {
      for (let p = 0; p < 3; p++) {
        const h = TP_PHASES[p];
        let y = 0;
        for (let k = 0; k < TP_TAPS; k++) y += ch[i + k - (TP_TAPS / 2 - 1)] * h[k];
        const a = Math.abs(y);
        if (a > peak) peak = a;
      }
    }
  }
  return peak;
}

/**
 * Lookahead peak limiter, stereo-linked, in place.  The gain ramps down over
 * `lookahead` samples so it is exactly at its target when the peak arrives
 * (no overshoot, no delay), then releases exponentially.  The ramp is smoothed
 * by two cascaded moving averages of half the lookahead each (a triangular
 * kernel: every gain it applies is an average of values that already respect the
 * peak, so the guarantee holds), which leaves the gain curve far fewer
 * high-frequency sidebands than one boxcar of the whole length would.  Returns
 * the maximum gain reduction in dB.
 */
export function limit(bus: Stereo, ceiling: number, opts: { lookaheadMs?: number; releaseMs?: number; gainOut?: Float32Array } = {}): number {
  const n = bus.l.length;
  const W = Math.max(4, 2 * Math.round(((opts.lookaheadMs ?? 3) / 1000 / 2) * SR));
  const H = W / 2;
  const releaseCoef = 1 - Math.exp(-1 / (((opts.releaseMs ?? 90) / 1000) * SR));
  // Required gain per sample.
  const req = new Float32Array(n);
  for (let i = 0; i < n; i++) {
    const pk = Math.max(Math.abs(bus.l[i]), Math.abs(bus.r[i]));
    req[i] = pk > ceiling ? ceiling / pk : 1;
  }
  // Sliding minimum over the next W samples (monotone deque).
  const mn = new Float32Array(n);
  const dq = new Int32Array(n + 1);
  let head = 0;
  let tail = 0;
  for (let i = n - 1; i >= 0; i--) {
    while (tail > head && req[dq[tail - 1]] >= req[i]) tail--;
    dq[tail++] = i;
    while (dq[head] >= i + W) head++;
    mn[i] = req[dq[head]];
  }
  // Release smoothing, then two moving averages of the past H samples for the attack ramp.
  const rel = new Float32Array(n);
  let g = 1;
  for (let i = 0; i < n; i++) {
    g = Math.min(mn[i], g + (1 - g) * releaseCoef);
    rel[i] = g;
  }
  const avgPast = (x: Float32Array): Float32Array => {
    const out = new Float32Array(n);
    let acc = 0;
    for (let i = 0; i < n; i++) {
      acc += x[i];
      if (i >= H) acc -= x[i - H];
      out[i] = acc / Math.min(i + 1, H);
    }
    return out;
  };
  const smooth = avgPast(avgPast(rel));
  let maxReduction = 1;
  for (let i = 0; i < n; i++) {
    const gain = smooth[i];
    bus.l[i] *= gain;
    bus.r[i] *= gain;
    if (opts.gainOut) opts.gainOut[i] = gain;
    if (gain < maxReduction) maxReduction = gain;
  }
  return -20 * Math.log10(maxReduction);
}

/** Apply a gain in dB to a bus. */
export function gainDb(bus: Stereo, db: number): void {
  const g = 10 ** (db / 20);
  for (let i = 0; i < bus.l.length; i++) {
    bus.l[i] *= g;
    bus.r[i] *= g;
  }
}

/**
 * A gentle bus compressor ("glue"): RMS-ish detector on the stereo sum,
 * soft knee, program-dependent release.  In place.
 */
export function glue(bus: Stereo, opts: { thresholdDb: number; ratio: number; attackMs: number; releaseMs: number; kneeDb?: number; makeupDb?: number }): { maxDb: number; meanDb: number } {
  const n = bus.l.length;
  const att = 1 - Math.exp(-1 / ((opts.attackMs / 1000) * SR));
  const rel = 1 - Math.exp(-1 / ((opts.releaseMs / 1000) * SR));
  const knee = opts.kneeDb ?? 6;
  const makeup = 10 ** ((opts.makeupDb ?? 0) / 20);
  let env = 0;
  let gr = 1;
  let maxDb = 0;
  let sumDb = 0;
  let counted = 0;
  for (let i = 0; i < n; i++) {
    const level = Math.max(Math.abs(bus.l[i]), Math.abs(bus.r[i]));
    env += (level > env ? att : rel) * (level - env);
    const db = 20 * Math.log10(Math.max(env, 1e-9));
    const over = db - opts.thresholdDb;
    let reduction = 0;
    if (over > knee / 2) reduction = (over * (1 - 1 / opts.ratio));
    else if (over > -knee / 2) reduction = ((1 - 1 / opts.ratio) * (over + knee / 2) ** 2) / (2 * knee);
    const target = 10 ** (-reduction / 20);
    gr += (target - gr) * (target < gr ? 0.02 : 0.0008);
    bus.l[i] *= gr * makeup;
    bus.r[i] *= gr * makeup;
    const reductionDb = -20 * Math.log10(Math.max(gr, 1e-6));
    if (reductionDb > maxDb) maxDb = reductionDb;
    if (level > 1e-4) {
      sumDb += reductionDb;
      counted++;
    }
  }
  return { maxDb, meanDb: counted ? sumDb / counted : 0 };
}

/** Static tone shaping for the master: a low cut, a touch less mud, and a steep low-pass at 13.5 kHz so nothing above 16 kHz can hiss. */
export function masterEq(bus: Stereo): void {
  const stages: Array<[Biquad, Biquad]> = [
    [new Biquad("highpass", 28, 0.707), new Biquad("highpass", 28, 0.707)],
    [new Biquad("peak", 280, 0.9, -1.0), new Biquad("peak", 280, 0.9, -1.0)],
    // 8th-order Butterworth low-pass at 13.5 kHz: the clicks of the impacts and the hats end there.
    [new Biquad("lowpass", 13500, 0.5098), new Biquad("lowpass", 13500, 0.5098)],
    [new Biquad("lowpass", 13500, 0.6013), new Biquad("lowpass", 13500, 0.6013)],
    [new Biquad("lowpass", 13500, 0.9), new Biquad("lowpass", 13500, 0.9)],
    [new Biquad("lowpass", 13500, 2.5629), new Biquad("lowpass", 13500, 2.5629)],
  ];
  for (const [a, b] of stages) {
    a.apply(bus.l);
    b.apply(bus.r);
  }
}

/**
 * Stereo widening above `lowHz`: the side signal is high-passed (so bass and
 * kick stay dead centre and mono) and raised by `amount` (1 = unchanged).
 */
export function widen(bus: Stereo, amount: number, lowHz = 300): void {
  const hp = new Biquad("highpass", lowHz, 0.707);
  const hp2 = new Biquad("highpass", lowHz, 0.707);
  for (let i = 0; i < bus.l.length; i++) {
    const m = (bus.l[i] + bus.r[i]) * 0.5;
    const sRaw = (bus.l[i] - bus.r[i]) * 0.5;
    const sHigh = hp2.run(hp.run(sRaw));
    const s = sRaw - sHigh + sHigh * amount; // lows keep their original side, highs get the boost
    bus.l[i] = m + s;
    bus.r[i] = m - s;
  }
}
