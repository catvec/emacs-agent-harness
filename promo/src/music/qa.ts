/**
 * Measurements for the score.  Nobody can listen to the build, so the build listens to itself: loudness and
 * peaks (its own BS.1770 and ffmpeg's ebur128), whether every cue of the timeline has an onset on its frame
 * (on the instrument's own stem, and in the final mix for the loud ones), whether the typing is audible and
 * under the music, the shape of the film (a quiet first bar, a gap, an impact that is the loudest moment, an
 * outro that stops), the beat grid, the spectrum and the key.  Writes score-report.json, score-cues.json,
 * score-spectrogram.png and score-waveform.png next to the WAV, and exits non-zero when a check fails.
 *
 *   npx tsx src/music/qa.ts        rebuild the score from the timeline, compare it with build/score.wav, check it
 */
// The footage log is chosen while the timeline is imported: this import must stay first.
import "./footage-source.js";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { MAX_NUDGE_FRAMES, MAX_TICKS_PER_SECOND, MIN_TICK_GAP, type Expectation, type Timeline } from "./compose.js";
import { Biquad, SR, newStereo, type Stereo } from "./dsp.js";
import { FOOTAGE_LOG, FOOTAGE_SOURCE } from "./footage-source.js";
import { integratedLufs, kPrefix, loudnessBlocks, prefixLufs, rangeLufs, samplePeak, truePeak } from "./master.js";
import { CEILING_DBTP, TARGET_LUFS, buildScore, type ScoreBuild } from "./score.js";
import { GROOVE_BUSES, type BusName } from "./session.js";

// ---------------------------------------------------------------------------
// Reading the WAV back
// ---------------------------------------------------------------------------

export interface Wav {
  l: Float32Array;
  r: Float32Array;
  sampleRate: number;
  channels: number;
  bits: number;
  /** Full-scale samples (|x| = 32767 or 32768): clipping. */
  fullScale: number;
}

export function readWav(file: string): Wav {
  const buf = fs.readFileSync(file);
  if (buf.toString("ascii", 0, 4) !== "RIFF" || buf.toString("ascii", 8, 12) !== "WAVE") throw new Error("not a WAV");
  let pos = 12;
  let fmt: { channels: number; sampleRate: number; bits: number } | null = null;
  let data: { start: number; size: number } | null = null;
  while (pos + 8 <= buf.length) {
    const id = buf.toString("ascii", pos, pos + 4);
    const size = buf.readUInt32LE(pos + 4);
    if (id === "fmt ") fmt = { channels: buf.readUInt16LE(pos + 10), sampleRate: buf.readUInt32LE(pos + 12), bits: buf.readUInt16LE(pos + 22) };
    if (id === "data") data = { start: pos + 8, size };
    pos += 8 + size + (size & 1);
  }
  if (!fmt || !data) throw new Error("WAV without fmt or data chunk");
  if (fmt.channels !== 2 || fmt.bits !== 16) return { l: new Float32Array(0), r: new Float32Array(0), sampleRate: fmt.sampleRate, channels: fmt.channels, bits: fmt.bits, fullScale: 0 };
  const n = data.size / 4;
  const l = new Float32Array(n);
  const r = new Float32Array(n);
  let fullScale = 0;
  for (let i = 0; i < n; i++) {
    const a = buf.readInt16LE(data.start + i * 4);
    const b = buf.readInt16LE(data.start + i * 4 + 2);
    l[i] = a / 32768;
    r[i] = b / 32768;
    if (Math.abs(a) >= 32767) fullScale++;
    if (Math.abs(b) >= 32767) fullScale++;
  }
  return { l, r, sampleRate: fmt.sampleRate, channels: fmt.channels, bits: fmt.bits, fullScale };
}

// ---------------------------------------------------------------------------
// FFT and spectra
// ---------------------------------------------------------------------------

function fft(re: Float64Array, im: Float64Array): void {
  const n = re.length;
  for (let i = 1, j = 0; i < n; i++) {
    let bit = n >> 1;
    for (; j & bit; bit >>= 1) j ^= bit;
    j ^= bit;
    if (i < j) {
      [re[i], re[j]] = [re[j], re[i]];
      [im[i], im[j]] = [im[j], im[i]];
    }
  }
  for (let len = 2; len <= n; len <<= 1) {
    const ang = (-2 * Math.PI) / len;
    const wr = Math.cos(ang);
    const wi = Math.sin(ang);
    for (let i = 0; i < n; i += len) {
      let cr = 1;
      let ci = 0;
      for (let k = 0; k < len / 2; k++) {
        const a = i + k;
        const b = a + len / 2;
        const tr = re[b] * cr - im[b] * ci;
        const ti = re[b] * ci + im[b] * cr;
        re[b] = re[a] - tr;
        im[b] = im[a] - ti;
        re[a] += tr;
        im[a] += ti;
        const ncr = cr * wr - ci * wi;
        ci = cr * wi + ci * wr;
        cr = ncr;
      }
    }
  }
}

/** Average power spectrum (bins of SR/size Hz) of a sample range, Hann windows, 50 % overlap. */
function powerSpectrum(x: Float32Array, from: number, to: number, size = 4096): Float64Array {
  const acc = new Float64Array(size / 2 + 1);
  const re = new Float64Array(size);
  const im = new Float64Array(size);
  const win = new Float64Array(size);
  for (let i = 0; i < size; i++) win[i] = 0.5 - 0.5 * Math.cos((2 * Math.PI * i) / size);
  let frames = 0;
  for (let s = from; s + size <= to; s += size / 2) {
    for (let i = 0; i < size; i++) {
      re[i] = x[s + i] * win[i];
      im[i] = 0;
    }
    fft(re, im);
    for (let k = 0; k <= size / 2; k++) acc[k] += re[k] * re[k] + im[k] * im[k];
    frames++;
  }
  for (let k = 0; k < acc.length; k++) acc[k] /= Math.max(1, frames);
  return acc;
}

const BANDS: Array<[string, number, number]> = [
  ["sub 20-60", 20, 60],
  ["bass 60-250", 60, 250],
  ["low-mid 250-500", 250, 500],
  ["mid 0.5-2k", 500, 2000],
  ["upper-mid 2-5k", 2000, 5000],
  ["presence 5-10k", 5000, 10000],
  ["air 10-16k", 10000, 16000],
  ["above 16k", 16000, 24000],
];

/** Share of the energy in each band, as a fraction of 1. */
function bandShares(spec: Float64Array, size = 4096): Record<string, number> {
  const hz = SR / size;
  let total = 0;
  const raw: Record<string, number> = {};
  for (const [name, lo, hi] of BANDS) {
    let e = 0;
    for (let k = Math.max(1, Math.floor(lo / hz)); k <= Math.min(spec.length - 1, Math.floor(hi / hz)); k++) e += spec[k];
    raw[name] = e;
    total += e;
  }
  const out: Record<string, number> = {};
  for (const [name] of BANDS) out[name] = raw[name] / Math.max(total, 1e-30);
  return out;
}

const shareDb = (share: number) => Math.round(10 * Math.log10(Math.max(share, 1e-12)) * 10) / 10;

// ---------------------------------------------------------------------------
// Onsets
// ---------------------------------------------------------------------------

const HOP = 96; // 2 ms
const HOP_MS = (HOP / SR) * 1000;

interface Onsets {
  /** Onset strength per hop (dB of fresh energy), all bands. */
  flux: Float32Array;
  low: Float32Array;
  mid: Float32Array;
  high: Float32Array;
}

function bandEnergyDb(x: Float32Array, stages: Biquad[]): Float32Array {
  const hops = Math.floor(x.length / HOP);
  const out = new Float32Array(hops);
  for (let k = 0; k < hops; k++) {
    let e = 0;
    for (let i = 0; i < HOP; i++) {
      let v = x[k * HOP + i];
      for (const st of stages) v = st.run(v);
      e += v * v;
    }
    out[k] = Math.max(-100, 10 * Math.log10(e / HOP + 1e-12));
  }
  return out;
}

function fluxOf(e: Float32Array, lookback = 7): Float32Array {
  const f = new Float32Array(e.length);
  for (let k = lookback; k < e.length; k++) {
    let m = -200;
    for (let j = 1; j <= lookback; j++) if (e[k - j] > m) m = e[k - j];
    f[k] = Math.max(0, e[k] - m);
  }
  return f;
}

const mono = (l: Float32Array, r: Float32Array): Float32Array => {
  const m = new Float32Array(l.length);
  for (let i = 0; i < l.length; i++) m[i] = (l[i] + r[i]) * 0.5;
  return m;
};

function onsets(l: Float32Array, r: Float32Array): Onsets {
  const m = mono(l, r);
  const low = fluxOf(bandEnergyDb(m, [new Biquad("lowpass", 160, 0.7), new Biquad("lowpass", 160, 0.7)]));
  const mid = fluxOf(bandEnergyDb(m, [new Biquad("highpass", 160, 0.7), new Biquad("lowpass", 2200, 0.7)]));
  const high = fluxOf(bandEnergyDb(m, [new Biquad("highpass", 2200, 0.7), new Biquad("highpass", 2200, 0.7)]));
  const flux = new Float32Array(low.length);
  for (let k = 0; k < flux.length; k++) flux[k] = Math.max(low[k], mid[k], high[k]);
  return { flux, low, mid, high };
}

interface Peak {
  /** Time in ms. */
  t: number;
  /** Fresh energy, dB. */
  v: number;
}

function pickPeaks(o: Onsets, minDb: number): Peak[] {
  const out: Peak[] = [];
  const f = o.flux;
  for (let k = 3; k < f.length - 3; k++) {
    const v = f[k];
    if (v < minDb) continue;
    let isMax = true;
    for (let j = 1; j <= 3; j++) if (f[k - j] > v || f[k + j] >= v) isMax = false;
    if (isMax) out.push({ t: ((k * HOP) / SR) * 1000, v });
  }
  return out;
}

/**
 * The time (ms) the sound near `tMs` really starts: the first sample whose smoothed envelope passes a fifth of the
 * loudest in the neighbourhood.  The flux peak only says which 2 ms hop; this says which sample.
 */
function refineOnset(x: Float32Array, tMs: number): number {
  const a = Math.max(0, Math.round(((tMs - 10) / 1000) * SR));
  const b = Math.min(x.length, Math.round(((tMs + 8) / 1000) * SR));
  const w = Math.round(0.0003 * SR);
  const env = new Float32Array(b - a);
  let acc = 0;
  for (let i = a; i < b; i++) {
    acc += Math.abs(x[i]);
    if (i - a >= w) acc -= Math.abs(x[i - w]);
    env[i - a] = acc / w;
  }
  let max = 0;
  for (const v of env) max = Math.max(max, v);
  if (max < 1e-9) return tMs;
  for (let i = 0; i < env.length; i++) if (env[i] > 0.2 * max) return ((a + i) / SR) * 1000;
  return tMs;
}

export interface Match {
  frame: number;
  kinds: string[];
  expectedMs: number;
  measuredMs: number | null;
  deltaMs: number | null;
  strengthDb: number | null;
}

interface CueIn {
  frame: number;
  kinds: string[];
  /** Where the sound was placed, in samples (a key press may sit up to a frame from its cue). */
  sample: number;
}

/**
 * One-to-one, order-preserving alignment of cues to detected peaks (sequence alignment by dynamic programming):
 * neighbouring cues cannot both claim the same peak, and a stronger peak beats a weaker one at equal distance.
 * `spf` is the samples in a frame; the times are those of the cue's FRAME, not of where its sound was placed.
 */
function align(cues: CueIn[], peaks: Peak[], winMs: number, spf: number, refine: Float32Array): Match[] {
  const C = cues.length;
  const P = peaks.length;
  const times = cues.map((c) => ((c.frame * spf) / SR) * 1000);
  const skip = winMs + 10;
  const W = P + 1;
  const dp = new Float32Array((C + 1) * W);
  const choice = new Uint8Array((C + 1) * W); // 0 = skip peak, 1 = match, 2 = skip cue
  for (let i = 1; i <= C; i++) {
    dp[i * W] = dp[(i - 1) * W] + skip;
    choice[i * W] = 2;
    for (let j = 1; j <= P; j++) {
      let best = dp[i * W + (j - 1)];
      let ch = 0;
      const d = Math.abs(peaks[j - 1].t - times[i - 1]);
      if (d <= winMs) {
        const c = dp[(i - 1) * W + (j - 1)] + d - 0.3 * Math.min(peaks[j - 1].v, 30);
        if (c < best) {
          best = c;
          ch = 1;
        }
      }
      const sk = dp[(i - 1) * W + j] + skip;
      if (sk < best) {
        best = sk;
        ch = 2;
      }
      dp[i * W + j] = best;
      choice[i * W + j] = ch;
    }
  }
  const assigned: Array<Peak | null> = new Array(C).fill(null);
  let i = C;
  let j = P;
  while (i > 0) {
    const ch = j === 0 ? 2 : choice[i * W + j];
    if (ch === 1) {
      assigned[i - 1] = peaks[j - 1];
      i--;
      j--;
    } else if (ch === 2) {
      i--;
    } else {
      j--;
    }
  }
  return cues.map((c, k) => {
    const p = assigned[k];
    const measured = p ? refineOnset(refine, p.t) : null;
    return {
      frame: c.frame,
      kinds: c.kinds,
      expectedMs: Math.round(times[k] * 10) / 10,
      measuredMs: measured === null ? null : Math.round(measured * 10) / 10,
      deltaMs: measured === null ? null : Math.round((measured - times[k]) * 10) / 10,
      strengthDb: p ? Math.round(p.v * 10) / 10 : null,
    };
  });
}

const median = (xs: number[]) => (xs.length ? [...xs].sort((a, b) => a - b)[Math.floor((xs.length - 1) / 2)] : NaN);

// ---------------------------------------------------------------------------
// Small measures
// ---------------------------------------------------------------------------

const rmsDb = (x: Float32Array, from: number, to: number) => {
  let s = 0;
  const a = Math.max(0, from);
  const b = Math.min(x.length, to);
  for (let i = a; i < b; i++) s += x[i] * x[i];
  return 10 * Math.log10(s / Math.max(1, b - a) + 1e-12);
};

function pearson(a: Float32Array, b: Float32Array, from: number, to: number): number {
  let ma = 0;
  let mb = 0;
  for (let i = from; i < to; i++) {
    ma += a[i];
    mb += b[i];
  }
  ma /= to - from;
  mb /= to - from;
  let sab = 0;
  let saa = 0;
  let sbb = 0;
  for (let i = from; i < to; i++) {
    sab += (a[i] - ma) * (b[i] - mb);
    saa += (a[i] - ma) ** 2;
    sbb += (b[i] - mb) ** 2;
  }
  return sab / Math.sqrt(saa * sbb + 1e-30);
}

function spearman(a: number[], b: number[]): number {
  /** Ranks, a tie sharing the mean of the places it covers (equal hints in the plan are not an order). */
  const rank = (x: number[]) => {
    const idx = x.map((v, i) => [v, i] as [number, number]).sort((p, q) => p[0] - q[0]);
    const r = new Array(x.length).fill(0);
    for (let i = 0; i < idx.length; ) {
      let j = i;
      while (j + 1 < idx.length && idx[j + 1][0] === idx[i][0]) j++;
      for (let k = i; k <= j; k++) r[idx[k][1]] = (i + j) / 2;
      i = j + 1;
    }
    return r;
  };
  const ra = rank(a);
  const rb = rank(b);
  const n = a.length;
  const mean = (n - 1) / 2;
  let sab = 0;
  let saa = 0;
  let sbb = 0;
  for (let i = 0; i < n; i++) {
    sab += (ra[i] - mean) * (rb[i] - mean);
    saa += (ra[i] - mean) ** 2;
    sbb += (rb[i] - mean) ** 2;
  }
  return sab / Math.sqrt(saa * sbb);
}

const midiName = (m: number) => `${["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"][((m % 12) + 12) % 12]}${Math.floor(m / 12) - 1}`;

/** Estimate how far (in cents) the strongest harmonic series near `midi` is from it, and how clearly it beats the neighbouring notes. */
function pitchCheck(x: Float32Array, from: number, to: number, midi: number): { cents: number; margin: number } {
  const size = 32768;
  const seg = Math.min(to - from, size);
  const re = new Float64Array(size);
  const im = new Float64Array(size);
  for (let i = 0; i < seg; i++) re[i] = x[from + i] * (0.5 - 0.5 * Math.cos((2 * Math.PI * i) / seg));
  fft(re, im);
  const mag = new Float64Array(size / 2);
  for (let k = 0; k < size / 2; k++) mag[k] = Math.hypot(re[k], im[k]);
  const hz = SR / size;
  const at = (f: number) => {
    const b = f / hz;
    const k = Math.floor(b);
    if (k + 1 >= mag.length) return 0;
    const t = b - k;
    return mag[k] * (1 - t) + mag[k + 1] * t;
  };
  const score = (m: number) => {
    const f0 = 440 * 2 ** ((m - 69) / 12);
    let sum = 0;
    for (let h = 1; h <= 4; h++) sum += at(f0 * h) / Math.sqrt(h);
    return sum;
  };
  const scan = (centre: number, span: number) => {
    let best = -1;
    let bestC = 0;
    for (let c = -span; c <= span; c += 2) {
      const v = score(centre + c / 100);
      if (v > best) {
        best = v;
        bestC = c;
      }
    }
    return { best, bestC };
  };
  const own = scan(midi, 60);
  const others = [-2, -1, 1, 2].map((d) => scan(midi + d, 40).best);
  return { cents: own.bestC, margin: own.best / Math.max(...others, 1e-12) };
}

// ---------------------------------------------------------------------------
// ffmpeg: loudness, pictures
// ---------------------------------------------------------------------------

function ffmpegEbur(file: string): { i: number; lra: number; tp: number } {
  const res = spawnSync("ffmpeg", ["-hide_banner", "-nostats", "-i", file, "-af", "ebur128=peak=true", "-f", "null", "-"], { encoding: "utf8" });
  const summary = res.stderr.slice(res.stderr.lastIndexOf("Summary:"));
  const num = (re: RegExp) => Number.parseFloat((summary.match(re) ?? [])[1]);
  return { i: num(/I:\s+(-?[\d.]+)\s+LUFS/), lra: num(/LRA:\s+(-?[\d.]+)\s+LU/), tp: num(/Peak:\s+(-?[\d.]+)\s+dBFS/) };
}

function plots(file: string, build: string): void {
  const spec = spawnSync(
    "ffmpeg",
    ["-hide_banner", "-loglevel", "error", "-y", "-i", file, "-lavfi", "showspectrumpic=s=1920x700:legend=1:scale=log:fscale=log:color=fire:gain=1.4:drange=90:stop=20000", path.join(build, "score-spectrogram.png")],
    { encoding: "utf8" },
  );
  if (spec.status !== 0) console.warn("spectrogram failed:", spec.stderr);
  const wave = spawnSync("ffmpeg", ["-hide_banner", "-loglevel", "error", "-y", "-i", file, "-lavfi", "showwavespic=s=1920x420:split_channels=1:colors=#ff2bd6|#00f0ff", path.join(build, "score-waveform.png")], { encoding: "utf8" });
  if (wave.status !== 0) console.warn("waveform failed:", wave.stderr);
}

// ---------------------------------------------------------------------------
// A film with more modules than the real one, to check that the score is a function of the timeline
// ---------------------------------------------------------------------------

/** Three acts (plain, two modules) and an outro, with cues the real footage does not have where they fall. */
export function syntheticTimeline(): Timeline {
  const FPS = 30;
  const BEAT = 15;
  const BAR = 60;
  const bars = 14;
  const at = (bar: number, beat = 0) => Math.round(bar * BAR + beat * BEAT);
  const acts = [
    { id: "intro", kind: "plain" as const, segment: "intro", from: 0, frames: 216, to: 216, impact: 216 },
    { id: "alpha", kind: "module" as const, segment: "alpha", from: at(4), frames: 270, to: at(4) + 270, impact: at(4) },
    { id: "beta", kind: "module" as const, segment: "beta", from: at(9), frames: 220, to: at(9) + 220, impact: at(9) },
  ];
  const outroBar = 13;
  const sections = [
    { id: "plain" as const, act: "intro", from: 0, to: 4, note: "plain" },
    { id: "module" as const, act: "alpha", from: 4, to: 9, note: "module" },
    { id: "module" as const, act: "beta", from: 9, to: outroBar, note: "module" },
    { id: "outro" as const, from: outroBar, to: bars, note: "outro" },
  ];
  const ENERGY = Array.from({ length: bars }, (_, bar) => {
    const s = sections.find((x) => bar >= x.from && bar < x.to)!;
    if (s.id === "plain") return [0.12, 0.18, 0.28, 0.45][Math.min(3, bar - s.from)];
    if (s.id === "module") return bar === s.from ? 1 : 0.85;
    return 0.3;
  });
  const CUES: Timeline["CUES"][number][] = [];
  const cue = (frame: number, kind: Timeline["CUES"][number]["kind"], act: string, label?: string, text?: string) => CUES.push({ frame, kind, act, label, text });
  for (let f = 22; f < 112; f += 4) cue(f, "type", "intro");
  cue(124, "key", "intro", "C-c C-c", "send");
  cue(124, "mark", "intro", "sent");
  for (const a of acts.slice(1)) {
    cue(a.impact - 24, "fall", a.id);
    cue(a.impact, "impact", a.id, a.id.toUpperCase());
    for (let f = a.impact + 24; f < a.impact + 50; f += 3) cue(f, "type", a.id);
    cue(a.impact + 65, "key", a.id, "C-c C-c", "submit");
    cue(a.impact + 65, "mark", a.id, "submit-1");
    cue(a.impact + 90, "callout", a.id, undefined, "a caption");
    cue(a.impact + 100, "click", a.id, "card");
  }
  cue(at(7) + 10, "highlight", "alpha", "ready");
  cue(at(7) + 10, "mark", "alpha", "review-1");
  cue(at(7) + 40, "mark", "alpha", "verify-1");
  cue(at(11) + 20, "mark", "beta", "verify-2");
  CUES.sort((a, b) => a.frame - b.frame || a.kind.localeCompare(b.kind));
  return { FPS, BPM: 120, BEAT, BAR, FALL: 24, TENSION: 36, DURATION: bars * BAR, BARS: bars, OUTRO: outroBar * BAR, ACTS: acts, SECTIONS: sections, ENERGY, CUES };
}

// ---------------------------------------------------------------------------
// The report
// ---------------------------------------------------------------------------

export interface QaArgs {
  file: string;
  build: string;
  score: ScoreBuild;
  timeline: Timeline;
  /** Builds the score again from the same timeline (the determinism check). */
  rebuild: () => ScoreBuild;
}

interface Check {
  name: string;
  pass: boolean;
  detail: string;
}

const lufsOfZ = (z: number) => -0.691 + 10 * Math.log10(Math.max(z, 1e-12));
const r1 = (x: number) => Math.round(x * 10) / 10;
const r2 = (x: number) => Math.round(x * 100) / 100;

/** Which bus carries the sound of which cue (the QA's own table, from the cue's kind and label). */
const KIND_OF = (e: Expectation) => (e.cue.kind === "mark" ? `mark:${(e.cue.label ?? "").replace(/-\d+$/, "")}` : e.cue.kind);

export function runQa(args: QaArgs): boolean {
  const { file, build, score, timeline: T } = args;
  const comp = score.comp;
  const SPF = SR / T.FPS;
  const BAR_S = T.BAR * SPF;
  const wav = readWav(file);
  const { l, r } = wav;
  const n = l.length;
  const checks: Check[] = [];
  const add = (name: string, pass: boolean, detail: string) => {
    checks.push({ name, pass, detail });
    console.log(`  ${pass ? "ok  " : "FAIL"} ${name}: ${detail}`);
  };
  const stems = score.stems;
  const frameMs = 1000 / T.FPS;

  // --- format ---------------------------------------------------------------
  const expectN = T.DURATION * SPF;
  add("format", wav.sampleRate === SR && wav.channels === 2 && wav.bits === 16 && n === expectN, `${wav.sampleRate} Hz, ${wav.channels} ch, ${wav.bits} bit, ${n} samples = ${(n / SR).toFixed(3)} s (the timeline's ${T.DURATION} frames = ${expectN} samples)`);

  // --- loudness / peaks -----------------------------------------------------
  const lufs = integratedLufs(l, r);
  const ff = ffmpegEbur(file);
  const sp = samplePeak(l, r);
  const tp = truePeak(l, r);
  const tpDb = 20 * Math.log10(tp);
  add("integrated loudness", Math.abs(lufs - TARGET_LUFS) <= 0.7 && Math.abs(ff.i - TARGET_LUFS) <= 0.7, `own ${lufs.toFixed(2)} LUFS, ffmpeg ebur128 ${ff.i} LUFS (target ${TARGET_LUFS} +/- 0.7)`);
  add("true peak", tpDb <= -1.0 && ff.tp <= -1.0, `own ${tpDb.toFixed(2)} dBTP, ffmpeg ${ff.tp} dBFS (ceiling -1.0; the master is limited to ${CEILING_DBTP})`);
  add("no clipping", sp < 0.891 && wav.fullScale === 0, `sample peak ${(20 * Math.log10(sp)).toFixed(2)} dBFS, ${wav.fullScale} full-scale samples`);
  let dcl = 0;
  let dcr = 0;
  let finite = true;
  for (let i = 0; i < n; i++) {
    dcl += l[i];
    dcr += r[i];
    if (!Number.isFinite(l[i]) || !Number.isFinite(r[i])) finite = false;
  }
  dcl /= n;
  dcr /= n;
  add("no DC offset", Math.abs(dcl) < 1e-3 && Math.abs(dcr) < 1e-3, `L ${dcl.toExponential(2)}, R ${dcr.toExponential(2)}`);
  add("finite samples", finite, finite ? "no NaN/Inf" : "NaN or Inf found");
  const corr = pearson(l, r, 0, n);
  add("mono compatible", corr > 0.2, `stereo correlation ${corr.toFixed(2)}`);

  // --- determinism ------------------------------------------------------------
  const again = args.rebuild();
  const onDisk = createHash("sha256").update(fs.readFileSync(file)).digest("hex");
  add("deterministic", again.sha256 === score.sha256 && onDisk === score.sha256, `two builds: ${score.sha256.slice(0, 16)} / ${again.sha256.slice(0, 16)}; the file on disk: ${onDisk.slice(0, 16)}`);

  // --- shape: bars and sections -----------------------------------------------
  const bars = Array.from({ length: T.BARS }, (_, bar) => ({
    bar,
    chord: comp.plans[bar].chord,
    energyHint: T.ENERGY[bar],
    lufs: r1(rangeLufs(l, r, bar * BAR_S, (bar + 1) * BAR_S)),
  }));
  const sections = T.SECTIONS.map((s) => ({ id: s.id, act: s.act ?? null, bars: [s.from, s.to], lufs: r1(rangeLufs(l, r, s.from * BAR_S, s.to * BAR_S)) }));
  const grooveBars = bars.filter((b) => comp.plans[b.bar].section.id === "module" && comp.plans[b.bar].local >= 1);
  const grooveMedian = median(grooveBars.map((b) => b.lufs));
  const rho = spearman(bars.map((b) => b.energyHint), bars.map((b) => b.lufs));
  add("energy follows the plan", rho > 0.8, `Spearman(rank of ENERGY hint, bar loudness) = ${rho.toFixed(2)}`);
  add("the first bar is quiet", bars[0].lufs <= grooveMedian - 14, `bar 0 ${bars[0].lufs} LUFS, the groove's median bar ${grooveMedian} LUFS (want at least 14 LU under)`);
  const firstLanding = comp.landings[0];
  const mix = mono(l, r);
  const gapRows = comp.gaps.map(([a, b]) => {
    const before = rmsDb(mix, a - Math.round(0.1 * SR), a - Math.round(0.01 * SR));
    const inside = rmsDb(mix, a + Math.round(0.006 * SR), b);
    return { from: a, to: b, frames: [a / SPF, b / SPF], beforeDb: r1(before), insideDb: r1(inside), dropDb: r1(before - inside) };
  });
  for (const g of gapRows) add(`the gap before frame ${g.frames[1]} is silent`, g.insideDb < -70 && g.dropDb > 25, `${g.beforeDb} dBFS before, ${g.insideDb} dBFS inside (${g.dropDb} dB down)`);

  // The tension builds: the loudness of equal thirds of the build rises.
  for (const L of comp.landings) {
    const a = L.buildS;
    const b = L.gap[0];
    const third = Math.floor((b - a) / 3);
    const thirds = [0, 1, 2].map((k) => rangeLufs(l, r, a + k * third, a + (k + 1) * third));
    add(`the tension builds into frame ${L.impactS / SPF}`, thirds[1] > thirds[0] + 0.5 && thirds[2] > thirds[1] + 0.5, `loudness of the thirds of frames ${a / SPF}-${b / SPF}: ${thirds.map((v) => v.toFixed(1)).join(" -> ")} LUFS`);
  }

  // The impact is the loudest moment: by K-weighted loudness over 100 ms, and by peak.
  const kp = kPrefix(l, r);
  const win = Math.round(0.1 * SR);
  const hop = Math.round(0.01 * SR);
  const loudTrack: number[] = [];
  for (let s0 = 0; s0 + win <= n; s0 += hop) loudTrack.push(prefixLufs(kp, s0, s0 + win));
  const awayFrom = (t: number, centres: number[], radius: number) => centres.every((c) => Math.abs(t - c) > radius);
  const peakIn = (a: number, b: number) => {
    let p = 0;
    for (let i = Math.max(0, a); i < Math.min(n, b); i++) p = Math.max(p, Math.abs(l[i]), Math.abs(r[i]));
    return 20 * Math.log10(p + 1e-9);
  };
  let impactInfo: Record<string, number> | null = null;
  {
    const L = firstLanding;
    let best = -200;
    let bestAt = 0;
    for (let k = 0; k < loudTrack.length; k++) {
      if (loudTrack[k] > best) {
        best = loudTrack[k];
        bestAt = k * hop;
      }
    }
    const away = [L.impactS, ...(comp.outroS !== null ? [comp.outroS] : [])];
    let rest = -200;
    let restAt = 0;
    for (let k = 0; k < loudTrack.length; k++) {
      const t = k * hop;
      if (awayFrom(t, [L.impactS], 0.75 * SR) && awayFrom(t, comp.outroS !== null ? [comp.outroS] : [], 0.4 * SR) && loudTrack[k] > rest) {
        rest = loudTrack[k];
        restAt = t;
      }
    }
    add(
      "the impact is the loudest moment",
      bestAt >= L.impactS - Math.round(0.03 * SR) && bestAt <= L.impactS + Math.round(0.3 * SR) && best >= rest + 2,
      `the loudest 100 ms of the film (K-weighted) starts ${(((bestAt - L.impactS) / SR) * 1000).toFixed(0)} ms from the impact at ${best.toFixed(1)} LUFS; the loudest 100 ms away from it is ${rest.toFixed(1)} LUFS at frame ${(restAt / SPF).toFixed(0)} (want 2 LU less)`,
    );
    const peakImpact = peakIn(L.impactS, L.impactS + Math.round(0.4 * SR));
    const peakRest = Math.max(...Array.from({ length: Math.floor(n / hop / 10) }, (_, k) => k * hop * 10).filter((t) => awayFrom(t + 0.25 * SR, away, 0.75 * SR)).map((t) => peakIn(t, t + hop * 10)));
    add("the impact holds the highest peak", peakImpact >= peakRest + 0.4, `peak in the 400 ms from the impact ${peakImpact.toFixed(2)} dBFS; the highest peak elsewhere ${peakRest.toFixed(2)} dBFS (want 0.4 dB more)`);
    impactInfo = { loudest100msLufs: r1(best), restLufs: r1(rest), restFrame: Math.round(restAt / SPF), peakDbfs: r2(peakImpact), peakElsewhereDbfs: r2(peakRest) };
    if (comp.outroS !== null) {
      const hit = Math.max(...loudTrack.slice(Math.round(comp.outroS / hop), Math.round((comp.outroS + 0.3 * SR) / hop)));
      add("the outro hit is smaller than the impact", hit <= best - 2, `the loudest 100 ms of the outro hit ${hit.toFixed(1)} LUFS vs the impact's ${best.toFixed(1)} LUFS (want 2 LU less)`);
    }
  }
  const lb = loudnessBlocks(l, r);
  let momMax = -200;
  let momAt = 0;
  for (let k = 0; k < lb.z.length; k++) {
    const v = lufsOfZ(lb.z[k]);
    if (v > momMax) {
      momMax = v;
      momAt = lb.starts[k] + Math.round(0.2 * SR);
    }
  }
  add("the loudest momentary loudness is around the impact", Math.abs(momAt - firstLanding.impactS) < 0.6 * SR, `momentary (400 ms) maximum ${momMax.toFixed(1)} LUFS, centred ${(((momAt - firstLanding.impactS) / SR) * 1000).toFixed(0)} ms from the impact`);

  // --- the outro stops on the bar line -----------------------------------------
  let outroInfo: Record<string, number> | null = null;
  if (comp.outroS !== null) {
    const o = comp.outroS;
    const names: BusName[] = ["kick", "bass", "hats", "clap", "snare", "arp", "lead"];
    const before = (b: BusName) => rmsDb(mono(stems[b].l, stems[b].r), o - 2 * BAR_S, o - Math.round(0.02 * SR));
    const afterFrom = o + Math.round(0.65 * SR); // after the last kick has rung out
    const after = (b: BusName) => rmsDb(mono(stems[b].l, stems[b].r), afterFrom, n);
    const rows = names.map((b) => ({ b, before: before(b), after: after(b) }));
    const worst = Math.max(...rows.map((x) => x.after - x.before));
    add("the groove stops on the bar line", rows.every((x) => x.after < -70 || x.after - x.before < -40), `after the outro hit: ${rows.map((x) => `${x.b} ${x.after.toFixed(0)} (was ${x.before.toFixed(0)})`).join(", ")} dBFS; worst ${worst.toFixed(0)} dB`);
    const hit = rmsDb(mix, o, o + Math.round(0.25 * SR));
    const groove = rmsDb(mix, o - 2 * BAR_S, o - Math.round(0.05 * SR));
    add("the last hit stands out", hit >= groove - 1.0, `the 250 ms from the bar line: ${hit.toFixed(1)} dBFS vs the groove before it ${groove.toFixed(1)} dBFS`);
    const last100 = rmsDb(mix, n - Math.round(0.1 * SR), n);
    add("ends in silence", last100 < -60 && l[n - 1] === 0 && r[n - 1] === 0, `last 100 ms ${last100.toFixed(1)} dBFS, final sample ${l[n - 1]}/${r[n - 1]}`);
    outroInfo = { hitDb: r1(hit), grooveDb: r1(groove), last100Db: r1(last100) };
  }

  // --- sync: every cue on its frame ---------------------------------------------
  const FIND_MIN_DB = 6;
  const byBus = new Map<BusName, Expectation[]>();
  for (const e of comp.expect) byBus.set(e.bus, [...(byBus.get(e.bus) ?? []), e]);
  interface Row extends Match {
    bus: BusName;
    placedMs: number;
    kind: string;
  }
  const stemRows: Row[] = [];
  for (const [bus, list] of byBus) {
    // One expectation per frame: the cues that share a frame share the sound (a highlight and a review chime).
    const byFrame = new Map<number, CueIn & { all: Expectation[] }>();
    for (const e of list) {
      const got = byFrame.get(e.cue.frame);
      if (got) {
        got.kinds.push(KIND_OF(e));
        got.all.push(e);
      } else byFrame.set(e.cue.frame, { frame: e.cue.frame, kinds: [KIND_OF(e)], sample: e.sample, all: [e] });
    }
    const cuesIn = [...byFrame.values()].sort((a, b) => a.frame - b.frame);
    const st = stems[bus];
    const o = onsets(st.l, st.r);
    const rows = align(cuesIn, pickPeaks(o, FIND_MIN_DB), 55, SPF, mono(st.l, st.r));
    rows.forEach((row, k) => {
      for (const kind of cuesIn[k].kinds) stemRows.push({ ...row, bus, kind, placedMs: r1((cuesIn[k].sample / SR) * 1000) });
    });
  }
  const kinds = [...new Set(stemRows.map((x) => x.kind))].sort();
  const syncByKind: Record<string, { bus: string; cues: number; found: number; withinOneFrame: number; medianAbsMs: number | null; maxAbsMs: number | null }> = {};
  for (const kind of kinds) {
    const rows = stemRows.filter((x) => x.kind === kind);
    const found = rows.filter((x) => x.deltaMs !== null);
    const within = found.filter((x) => Math.abs(x.deltaMs ?? 99) <= frameMs);
    const abs = found.map((x) => Math.abs(x.deltaMs ?? 0));
    syncByKind[kind] = { bus: rows[0].bus, cues: rows.length, found: found.length, withinOneFrame: within.length, medianAbsMs: abs.length ? r1(median(abs)) : null, maxAbsMs: abs.length ? r1(Math.max(...abs)) : null };
    const bad = rows.filter((x) => x.deltaMs === null || Math.abs(x.deltaMs) > frameMs);
    add(`sync: ${kind} on the ${rows[0].bus} stem`, within.length === rows.length, `${within.length}/${rows.length} cues have an onset within +/-${frameMs.toFixed(1)} ms of their frame (median |delta| ${syncByKind[kind].medianAbsMs} ms, max ${syncByKind[kind].maxAbsMs} ms)${bad.length ? `; off: ${bad.map((x) => `frame ${x.frame} (${x.deltaMs ?? "none"})`).join(", ")}` : ""}`);
  }

  // The loud cues must also show through the rest of the mix: a fresh onset within a frame of the cue, this many dB above what came just before it.
  const mixOnsets = onsets(l, r);
  const mixPeaks = pickPeaks(mixOnsets, 3);
  const loud = comp.expect.filter((e) => e.bus === "impact" || e.bus === "fall" || e.bus === "key" || e.bus === "send" || e.bus === "chime");
  const loudByFrame = new Map<number, CueIn>();
  for (const e of loud) {
    const got = loudByFrame.get(e.cue.frame);
    if (got) got.kinds.push(KIND_OF(e));
    else loudByFrame.set(e.cue.frame, { frame: e.cue.frame, kinds: [KIND_OF(e)], sample: e.sample });
  }
  const loudIn = [...loudByFrame.values()].sort((a, b) => a.frame - b.frame);
  const mixRows = align(loudIn, mixPeaks, 55, SPF, mix);
  const nearFlux = (frame: number) => {
    const c = Math.round((frame * SPF) / HOP);
    const w = Math.round((0.033 * SR) / HOP);
    let m = 0;
    for (let k = c - w; k <= c + w; k++) m = Math.max(m, mixOnsets.flux[k] ?? 0);
    return m;
  };
  const need = (kinds: string[]) => (kinds.some((k) => k === "impact" || k === "fall") ? 6 : 4);
  const mixFlux = loudIn.map((c) => ({ frame: c.frame, kinds: c.kinds, db: r1(nearFlux(c.frame)), need: need(c.kinds) }));
  const mixMiss = mixFlux.filter((x) => x.db < x.need);
  const timed = mixRows.filter((x) => x.deltaMs !== null);
  add(
    "loud cues show through in the final mix",
    mixMiss.length === 0,
    `${mixFlux.length - mixMiss.length}/${mixFlux.length} impacts, falls, key presses, sends and chimes have a fresh onset within +/-${frameMs.toFixed(0)} ms in the mix (>= 6 dB for impact and fall, >= 4 dB for the rest; weakest margin ${r1(Math.min(...mixFlux.map((x) => x.db - x.need)))} dB); the onset's own time is within ${r1(Math.max(...timed.map((x) => Math.abs(x.deltaMs ?? 0))))} ms for ${timed.length}${mixMiss.length ? `; too soft: ${mixMiss.map((x) => `frame ${x.frame} ${x.kinds[0]} ${x.db} dB`).join(", ")}` : ""}`,
  );
  const mixWithin = timed.filter((x) => Math.abs(x.deltaMs ?? 99) <= frameMs);
  // Expected-impulse-train cross-correlation over the whole film.
  const hops = mixOnsets.flux.length;
  const train = new Float32Array(hops);
  for (const c of loudIn) {
    const k = Math.round((c.frame * SPF) / HOP);
    if (k < hops) train[k] += 1;
  }
  let bestLag = 0;
  let bestSum = -1;
  for (let lag = -40; lag <= 40; lag++) {
    let sum = 0;
    for (let k = 0; k < hops; k++) {
      const j = k + lag;
      if (j >= 0 && j < hops && train[k] > 0) sum += train[k] * mixOnsets.flux[j];
    }
    if (sum > bestSum) {
      bestSum = sum;
      bestLag = lag;
    }
  }
  add("cue train aligned with the audio", Math.abs(bestLag * HOP_MS) <= HOP_MS * 1.5, `cross-correlation of the cue impulse train with the onset strength peaks at lag ${(bestLag * HOP_MS).toFixed(1)} ms (0 = exactly on the frames)`);

  // Key presses: nudged by at most a fraction of a frame.
  const maxNudge = comp.nudged.length ? Math.max(...comp.nudged.map((x) => Math.abs(x.frames))) : 0;
  add("key presses stay on their frame", maxNudge <= MAX_NUDGE_FRAMES + 1e-9, `${comp.nudged.length} of ${T.CUES.filter((c) => c.kind === "key").length} key presses moved onto the sixteenth beside them, by at most ${maxNudge.toFixed(2)} frames (limit ${MAX_NUDGE_FRAMES})`);

  // --- the typing -----------------------------------------------------------------
  const typed = T.CUES.filter((c) => c.kind === "type");
  const keptTicks = comp.expect.filter((e) => e.bus === "type").map((e) => e.cue.frame).sort((a, b) => a - b);
  let worstWindow = 0;
  for (const f of keptTicks) worstWindow = Math.max(worstWindow, keptTicks.filter((g) => g >= f && g < f + T.FPS).length);
  let minGap = Infinity;
  for (let i = 1; i < keptTicks.length; i++) minGap = Math.min(minGap, keptTicks[i] - keptTicks[i - 1]);
  add("the typing is thinned", keptTicks.length + comp.dropped.filter((c) => c.kind === "type").length === typed.length && worstWindow <= MAX_TICKS_PER_SECOND && minGap >= MIN_TICK_GAP, `${typed.length} typed keys: ${keptTicks.length} ticks kept, ${typed.length - keptTicks.length} thinned; at most ${worstWindow} ticks in any second (limit ${MAX_TICKS_PER_SECOND}), the closest two ${minGap} frames apart (limit ${MIN_TICK_GAP})`);

  // Audible: in the 2-6 kHz band, where the tick's click lives, the mix with the tick is at least this much louder in its first 8 ms than the music without it.
  const musicOnly = newStereo(n);
  const allBuses = Object.keys(stems) as BusName[];
  for (const b of allBuses) {
    if (b === "type") continue;
    for (let i = 0; i < n; i++) {
      musicOnly.l[i] += stems[b].l[i];
      musicOnly.r[i] += stems[b].r[i];
    }
  }
  for (const ret of [score.returns.reverb, score.returns.delay]) {
    for (let i = 0; i < n; i++) {
      musicOnly.l[i] += ret.l[i];
      musicOnly.r[i] += ret.r[i];
    }
  }
  const bandFilter = (x: Float32Array) => {
    const stages = [new Biquad("highpass", 2000, 0.7), new Biquad("highpass", 2000, 0.7), new Biquad("lowpass", 6000, 0.7), new Biquad("lowpass", 6000, 0.7)];
    const out = new Float32Array(x.length);
    for (let i = 0; i < x.length; i++) {
      let v = x[i];
      for (const st of stages) v = st.run(v);
      out[i] = v;
    }
    return out;
  };
  const bandMusic = bandFilter(mono(musicOnly.l, musicOnly.r));
  const bandTick = bandFilter(mono(stems.type.l, stems.type.r));
  const contrast: Array<{ frame: number; bar: number; db: number }> = [];
  for (const f of keptTicks) {
    const a = f * SPF;
    const b = a + Math.round(0.008 * SR);
    let em = 0;
    let et = 0;
    for (let i = a; i < b; i++) {
      em += bandMusic[i] * bandMusic[i];
      const tt = bandTick[i] + bandMusic[i];
      et += tt * tt;
    }
    contrast.push({ frame: f, bar: Math.floor(f / T.BAR), db: 10 * Math.log10((et + 1e-12) / (em + 1e-12)) });
  }
  const contrastIn = (pred: (c: { bar: number }) => boolean) => contrast.filter(pred).map((c) => c.db);
  const plainC = contrastIn((c) => comp.plans[c.bar].section.id === "plain");
  const moduleC = contrastIn((c) => comp.plans[c.bar].section.id === "module");
  add("the typing is audible over the plain music", plainC.length === 0 || median(plainC) >= 6, `the 2-6 kHz band at a tick's onset rises by a median ${r1(median(plainC))} dB over the music alone (${plainC.length} ticks; want >= 6)`);
  const weakest = [...moduleC].sort((a, b) => a - b)[Math.floor(moduleC.length * 0.1)] ?? Infinity;
  add("the typing is audible over the groove", moduleC.length === 0 || (median(moduleC) >= 3 && weakest >= 0.5), `rises by a median ${r1(median(moduleC))} dB; the weakest tenth of the ticks by ${r1(weakest)} dB or less (${moduleC.length} ticks; want median >= 3, the 10th percentile >= 0.5)`);
  // Under the music: over the runs of typing in the groove, the ticks are far quieter than everything else.
  const runs: Array<[number, number]> = [];
  for (const f of keptTicks) {
    const last = runs[runs.length - 1];
    if (last && f - last[1] <= 20) last[1] = f;
    else runs.push([f, f]);
  }
  const underDb: number[] = [];
  for (const [a, b] of runs) {
    if (comp.plans[Math.floor(a / T.BAR)].section.id !== "module") continue;
    const from = a * SPF;
    const to = Math.min(n, (b + 6) * SPF);
    underDb.push(rangeLufs(stems.type.l, stems.type.r, from, to) - rangeLufs(musicOnly.l, musicOnly.r, from, to));
  }
  add("the typing stays under the groove", underDb.length === 0 || Math.max(...underDb) <= -10, `the ticks' loudness against the music's over the typing runs in the groove: ${underDb.map((v) => v.toFixed(1)).join(", ")} LU (want <= -10)`);

  // --- the groove: grid, spectrum, key ---------------------------------------------
  const g0 = firstLanding.impactS + BAR_S;
  const g1 = comp.outroS ?? n;
  const t0 = Math.round(g0 / HOP);
  const t1 = Math.round(g1 / HOP);
  const seg = mixOnsets.flux.slice(t0, t1);
  const maxLag = Math.round((2.5 * SR) / HOP);
  const ac = new Float64Array(maxLag + 1);
  for (let lag = 0; lag <= maxLag; lag++) {
    let sum = 0;
    for (let k = 0; k + lag < seg.length; k++) sum += seg[k] * seg[k + lag];
    ac[lag] = sum / Math.max(1, seg.length - lag);
  }
  const lagAt = (sec: number) => Math.round((sec * SR) / HOP);
  let bestK = lagAt(0.4);
  for (let k = lagAt(0.4); k <= lagAt(0.6); k++) if (ac[k] > ac[bestK]) bestK = k;
  const den = ac[bestK - 1] - 2 * ac[bestK] + ac[bestK + 1];
  const refined = bestK + (den !== 0 ? (0.5 * (ac[bestK - 1] - ac[bestK + 1])) / den : 0);
  const period = (refined * HOP) / SR;
  const offGrid = (ac[lagAt(0.375)] + ac[lagAt(0.625)]) / 2;
  add("beat grid", Math.abs(period - 60 / T.BPM) < 0.004 && ac[bestK] > offGrid * 1.15, `onset autocorrelation of the groove peaks at ${(period * 1000).toFixed(1)} ms (grid ${(1000 * 60) / T.BPM} ms); on-grid/off-grid = ${(ac[bestK] / offGrid).toFixed(2)}`);
  const barLag = lagAt(2.0);
  let bestBar = barLag;
  for (let k = barLag - 6; k <= barLag + 6; k++) if (ac[k] > ac[bestBar]) bestBar = k;
  add("bar grid", Math.abs((bestBar * HOP) / SR - 2) < 0.01, `bar-length autocorrelation peak at ${(((bestBar * HOP) / SR) * 1000).toFixed(1)} ms (grid 2000 ms)`);

  const grooveFrom = Math.round(g0);
  const grooveTo = Math.round(g1 - 0.1 * SR);
  const drop = bandShares(powerSpectrum(mix, grooveFrom, grooveTo));
  const lowShare = drop["sub 20-60"] + drop["bass 60-250"];
  const presence = drop["upper-mid 2-5k"] + drop["presence 5-10k"];
  add("weight and sparkle", lowShare >= 0.45 && lowShare <= 0.75 && presence >= 0.04, `the groove: ${(lowShare * 100).toFixed(0)}% of the energy below 250 Hz (want 45-75%), ${(presence * 100).toFixed(1)}% in 2-10 kHz (want >= 4%)`);
  add("not piercing", drop["upper-mid 2-5k"] <= 0.14, `2-5 kHz holds ${(drop["upper-mid 2-5k"] * 100).toFixed(1)}% of the groove's energy (want <= 14%)`);
  // Above 17 kHz, measured on the spectrum itself (a high-pass filter at 16 kHz is too gentle: it lets the hats' 10-14 kHz through).
  const bandRmsDb = (from: number, to: number, lo: number, hi: number) => {
    const size = 4096;
    const spec = powerSpectrum(mix, from, to, size);
    let sum = 0;
    for (let k = Math.ceil((lo * size) / SR); k <= Math.floor((hi * size) / SR); k++) sum += spec[k];
    return 10 * Math.log10((16 / (3 * size * size)) * sum + 1e-14);
  };
  const above17 = T.SECTIONS.map((sec) => ({ id: sec.id, db: r1(bandRmsDb(sec.from * BAR_S, sec.to * BAR_S, 17000, 22000)) }));
  add("no hash above 17 kHz", Math.max(...above17.map((a) => a.db)) < -90, `RMS in 17-22 kHz per section: ${above17.map((a) => `${a.id} ${a.db}`).join(", ")} dBFS (want < -90, the dither floor is about -103; the groove itself is at ${r1(rmsDb(mix, grooveFrom, grooveTo))})`);
  add("highs are tamed", shareDb(drop["air 10-16k"]) < -20, `10-16 kHz: ${shareDb(drop["air 10-16k"])} dB of the groove's energy (want < -20 dB)`);
  const hl = [new Biquad("highpass", 250, 0.707), new Biquad("highpass", 250, 0.707)];
  const hr = [new Biquad("highpass", 250, 0.707), new Biquad("highpass", 250, 0.707)];
  const wl = new Float32Array(n);
  const wr = new Float32Array(n);
  for (let i = 0; i < n; i++) {
    let a = l[i];
    let b = r[i];
    for (const st of hl) a = st.run(a);
    for (const st of hr) b = st.run(b);
    wl[i] = a;
    wr[i] = b;
  }
  const widthCorr = pearson(wl, wr, grooveFrom, grooveTo);
  add("wide above the bass", widthCorr >= 0.2 && widthCorr <= 0.85, `correlation of the content above 250 Hz in the groove is ${widthCorr.toFixed(2)} (want 0.2-0.85: wide but safe in mono)`);
  // Crest factor of the groove: how punchy it is.
  let peakG = 0;
  for (let i = grooveFrom; i < grooveTo; i++) peakG = Math.max(peakG, Math.abs(l[i]), Math.abs(r[i]));
  const rmsG = rmsDb(mix, grooveFrom, grooveTo);
  const crest = 20 * Math.log10(peakG) - rmsG;
  add("punch", crest >= 8 && crest <= 17, `crest factor of the groove (peak over RMS of the mono sum) ${crest.toFixed(1)} dB (want 8-17)`);

  // Key: chroma of the tonal stems; the outro lifts to A major.
  const tonal = newStereo(n);
  for (const name of ["pad", "arp", "lead", "bass", "pluck", "bell", "chime", "outro"] as BusName[]) {
    const st = stems[name];
    for (let i = 0; i < n; i++) tonal.l[i] += st.l[i] + st.r[i];
  }
  const chroma = new Float64Array(12);
  const chromaFinal = new Float64Array(12);
  const size = 16384;
  const hzBin = SR / size;
  const accum = (acc: Float64Array, from: number, to: number) => {
    const spec = powerSpectrum(tonal.l, from, to, size);
    for (let k = Math.ceil(100 / hzBin); k < Math.floor(2400 / hzBin); k++) {
      const pc = (((Math.round(12 * Math.log2((k * hzBin) / 440)) + 9) % 12) + 12) % 12;
      acc[pc] += spec[k];
    }
  };
  accum(chroma, 0, comp.outroS ?? n);
  if (comp.outroS !== null) accum(chromaFinal, comp.outroS, Math.min(n, comp.outroS + Math.round(1.2 * SR)));
  const NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"];
  const total = chroma.reduce((a, b) => a + b, 0);
  const chromaRel = Object.fromEntries(NAMES.map((nme, i) => [nme, r1((chroma[i] / total) * 100)]));
  const inKey = [0, 2, 4, 5, 7, 9, 11].reduce((a, pc) => a + chroma[pc], 0) / total;
  const top = NAMES.map((nme, i) => [nme, chroma[i]] as [string, number]).sort((a, b) => b[1] - a[1]).slice(0, 4).map((x) => x[0]);
  const tonic = ["A", "C", "E"].map((p) => chroma[NAMES.indexOf(p)] / total);
  add("in key (A minor)", inKey > 0.94 && tonic.every((v) => v >= 0.06), `${(inKey * 100).toFixed(1)}% of the tonal energy before the outro is in A natural minor; the tonic triad A C E holds ${tonic.map((v) => `${(v * 100).toFixed(0)}%`).join(" ")}; strongest pitch classes ${top.join(" ")}`);
  let cSharp = 0;
  if (comp.outroS !== null) {
    const totalF = chromaFinal.reduce((a, b) => a + b, 0);
    cSharp = chromaFinal[1] / totalF;
    add("the last hit is A major", cSharp > 0.03, `C# is ${(cSharp * 100).toFixed(1)}% of the tonal energy of the outro (the bright third)`);
  }
  // The hook is in tune.
  const lead = mono(stems.lead.l, stems.lead.r);
  const tuned = comp.notes.map((nt) => ({ ...nt, ...pitchCheck(lead, nt.sample + Math.round(0.03 * SR), nt.sample + nt.len - Math.round(0.02 * SR), nt.midi) }));
  const bad = tuned.filter((x) => Math.abs(x.cents) > 12 || x.margin < 1.3);
  add("the hook is in tune", bad.length === 0, `${tuned.length - bad.length}/${tuned.length} lead notes measure within 12 cents of the intended pitch${bad.length ? `; off: ${bad.map((h) => `${midiName(h.midi)} ${h.cents}c x${h.margin.toFixed(1)}`).join(", ")}` : ""}`);

  // --- hygiene -----------------------------------------------------------------------
  const offenders = comp.session.edgeOffenders;
  const bySource: Record<string, number> = {};
  for (const o of offenders) bySource[o.bus] = (bySource[o.bus] ?? 0) + 1;
  add("no clicks at note edges", offenders.length === 0, `${comp.session.placed - offenders.length}/${comp.session.placed} events start and end within 3% of zero${offenders.length ? `; offenders: ${Object.entries(bySource).map(([k, v]) => `${k} ${v}`).join(", ")} (${offenders.slice(0, 4).map((o) => `${o.bus} at frame ${(o.start / SPF).toFixed(1)}: ${(o.ratio * 100).toFixed(0)}%`).join("; ")})` : ""}`);
  const gr = score.info.limiterGrByBar.filter((b) => comp.plans[b.bar]?.section.id === "module");
  const meanGr = gr.reduce((a, b) => a + b.meanDb, 0) / Math.max(1, gr.length);
  add("the limiter is gentle", score.info.limiterMaxGrDb <= 7 && meanGr <= 3.5, `the limiter's deepest gain reduction ${score.info.limiterMaxGrDb.toFixed(1)} dB, mean ${meanGr.toFixed(2)} dB over the module's bars`);

  // --- the score is a function of the timeline ---------------------------------------
  const syn = syntheticTimeline();
  let synDetail = "";
  let synPass = false;
  try {
    const sb = buildScore(syn);
    const sc = sb.comp;
    const sl = rangeLufs(sb.out.l, sb.out.r, 0, sc.n);
    const synImpacts = sc.expect.filter((e) => e.bus === "impact").map((e) => e.cue.frame);
    const st = sb.stems.impact;
    const rows = align(
      synImpacts.map((f) => ({ frame: f, kinds: ["impact"], sample: f * SPF })),
      pickPeaks(onsets(st.l, st.r), FIND_MIN_DB),
      55,
      SPF,
      mono(st.l, st.r),
    );
    const ok = rows.every((x) => x.deltaMs !== null && Math.abs(x.deltaMs) <= frameMs);
    const tpSyn = 20 * Math.log10(truePeak(sb.out.l, sb.out.r));
    synPass = sc.n === syn.DURATION * SPF && sc.landings.length === 2 && ok && Math.abs(sb.info.lufs - TARGET_LUFS) <= 0.7 && tpSyn <= -1.0 && sc.session.edgeOffenders.length === 0;
    synDetail = `${syn.BARS} bars, 2 modules: ${sc.landings.length} landings, impact onsets at ${rows.map((x) => x.deltaMs).join("/")} ms, ${sb.info.lufs.toFixed(2)} LUFS, ${tpSyn.toFixed(2)} dBTP, whole-file loudness ${sl.toFixed(1)}, ${sc.session.edgeOffenders.length} edge clicks`;
  } catch (err) {
    synDetail = `threw: ${(err as Error).message}`;
  }
  add("a film with two modules scores too", synPass, synDetail);

  // --- write -----------------------------------------------------------------------
  plots(file, build);
  const cueTable = T.CUES.map((c) => {
    const e = comp.expect.filter((x) => x.cue === c);
    const rows = e.flatMap((x) => stemRows.filter((row) => row.bus === x.bus && row.frame === c.frame && row.kind === KIND_OF(x)));
    return {
      frame: c.frame,
      kind: c.kind,
      label: c.label ?? null,
      text: c.text ?? null,
      sound: e.map((x) => x.what),
      bus: e.map((x) => x.bus),
      placedFrame: e.length ? r2(e[0].sample / SPF) : null,
      thinned: comp.dropped.includes(c),
      onsetDeltaMs: rows.length ? rows[0].deltaMs : null,
    };
  });
  const failed = checks.filter((c) => !c.pass);
  const report = {
    file: path.relative(process.cwd(), file),
    sha256: score.sha256,
    footage: { source: FOOTAGE_SOURCE, log: path.relative(process.cwd(), FOOTAGE_LOG) },
    timeline: { frames: T.DURATION, bars: T.BARS, seconds: T.DURATION / T.FPS, fps: T.FPS, bpm: T.BPM, outroFrame: T.OUTRO, landings: comp.landings.map((x) => ({ fall: x.fallS / SPF, impact: x.impactS / SPF, gapFrames: x.gap.map((g) => g / SPF), tensionFromFrame: x.buildS / SPF })) },
    format: { sampleRate: wav.sampleRate, channels: wav.channels, bitDepth: wav.bits, samplesPerChannel: n, seconds: n / SR },
    loudness: {
      integratedLufs: r2(lufs),
      ffmpegIntegratedLufs: ff.i,
      ffmpegLoudnessRangeLu: ff.lra,
      truePeakDbtp: r2(tpDb),
      ffmpegTruePeakDbfs: ff.tp,
      samplePeakDbfs: r2(20 * Math.log10(sp)),
      momentaryMaxLufs: r1(momMax),
      limiterMaxGainReductionDb: r1(score.info.limiterMaxGrDb),
      glueCompressorMeanReductionDb: r2(score.info.glueMeanGrDb),
      glueCompressorMaxReductionDb: r1(score.info.glueMaxGrDb),
      preLevelDb: r1(score.info.preLevelDb),
      masterGainDb: r2(score.info.gainDb),
      target: { lufs: TARGET_LUFS, ceilingDbtp: CEILING_DBTP },
    },
    dcOffset: { l: dcl, r: dcr },
    stereoCorrelation: r2(corr),
    stereoCorrelationAbove250HzGroove: r2(widthCorr),
    crestFactorDbGroove: r1(crest),
    rms17to22kHzDbfsBySection: above17,
    limiterGrByBar: score.info.limiterGrByBar,
    sections,
    bars,
    energyRankCorrelation: r2(rho),
    gaps: gapRows,
    impact: impactInfo,
    outro: outroInfo,
    sync: {
      byKind: syncByKind,
      finalMix: { cues: mixRows.length, timed: timed.length, withinOneFrame: mixWithin.length, onsetStrengthDb: mixFlux, rows: mixRows },
      cueTrainBestLagMs: r1(bestLag * HOP_MS),
      stemRows,
    },
    typing: {
      typed: typed.length,
      kept: keptTicks.length,
      thinned: typed.length - keptTicks.length,
      maxInAnySecond: worstWindow,
      closestFrames: minGap,
      bandContrastDb: { plainMedian: r1(median(plainC)), grooveMedian: r1(median(moduleC)), grooveMin: moduleC.length ? r1(Math.min(...moduleC)) : null },
      underTheGrooveLu: underDb.map(r1),
    },
    beatGrid: { periodMs: Math.round(period * 10000) / 10, gridMs: (1000 * 60) / T.BPM, onOffRatio: r2(ac[bestK] / offGrid) },
    spectrum: { grooveBandShareDb: Object.fromEntries(Object.entries(drop).map(([k, v]) => [k, shareDb(v)])) },
    key: { chromaPercentBeforeOutro: chromaRel, inKeyShare: Math.round(inKey * 1000) / 1000, outroCSharpShare: Math.round(cSharp * 1000) / 1000 },
    tune: tuned.map((x) => ({ midi: x.midi, name: midiName(x.midi), cents: x.cents, margin: r1(x.margin) })),
    stemLufsBySection: stemTable(score, T, BAR_S),
    checks,
  };
  fs.writeFileSync(path.join(build, "score-report.json"), `${JSON.stringify(report, null, 2)}\n`);
  fs.writeFileSync(path.join(build, "score-cues.json"), `${JSON.stringify(cueTable, null, 1)}\n`);
  console.log(`  ${checks.length - failed.length}/${checks.length} checks passed${failed.length ? `; FAILED: ${failed.map((f) => f.name).join(", ")}` : ""}`);
  console.log(`  bars (chord, energy hint, LUFS): ${bars.map((b) => `${b.bar} ${b.chord} ${b.energyHint} ${b.lufs}`).join(" | ")}`);
  printStemTable(report.stemLufsBySection, T);
  return failed.length === 0;
}

/** Per-bus loudness (K-weighted, ungated) by section, for the table of who is how loud where. */
function stemTable(score: ScoreBuild, T: Timeline, barS: number): Record<string, Record<string, number>> {
  const out: Record<string, Record<string, number>> = {};
  const table: Record<string, Stereo> = { ...score.stems, reverb: score.returns.reverb, delay: score.returns.delay };
  for (const name of Object.keys(table)) {
    out[name] = {};
    for (const s of T.SECTIONS) {
      const v = rangeLufs(table[name].l, table[name].r, s.from * barS, s.to * barS);
      out[name][s.id] = Number.isFinite(v) ? r1(v) : -99;
    }
  }
  return out;
}

function printStemTable(t: Record<string, Record<string, number>>, T: Timeline): void {
  console.log("  stem loudness (LUFS) by section:");
  const ids = [...new Set(T.SECTIONS.map((s) => s.id))];
  console.log(`    ${"".padEnd(8)}${ids.map((s) => s.padStart(8)).join("")}`);
  for (const name of [...GROOVE_BUSES, "riser", "fall", "impact", "type", "key", "click", "callout", "chime", "send", "reverb", "delay"]) console.log(`    ${name.padEnd(8)}${ids.map((s) => String(t[name][s]).padStart(8)).join("")}`);
}

// ---------------------------------------------------------------------------
// The command line: build the score from the timeline, compare it with build/score.wav, check it
// ---------------------------------------------------------------------------

async function main(): Promise<void> {
  const T = (await import("../timeline.js")) as unknown as Timeline;
  const HERE = path.dirname(fileURLToPath(import.meta.url));
  const build = path.resolve(HERE, "../../build");
  fs.mkdirSync(build, { recursive: true });
  const file = path.join(build, "score.wav");
  const score = buildScore(T);
  if (!fs.existsSync(file)) {
    fs.writeFileSync(file, score.wav);
    console.log(`(${path.relative(process.cwd(), file)} was missing: wrote it)`);
  } else if (createHash("sha256").update(fs.readFileSync(file)).digest("hex") !== score.sha256) {
    console.log(`${path.relative(process.cwd(), file)} is not what the timeline scores to now (stale, or another log): run \`npm run music\``);
    process.exitCode = 1;
    return;
  }
  const ok = runQa({ file, build, score, timeline: T, rebuild: () => buildScore(T) });
  if (!ok) process.exitCode = 1;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) await main();
