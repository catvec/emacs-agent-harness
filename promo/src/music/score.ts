/**
 * The whole score as one pure function of the timeline: compose, mix, master, level, encode.  No file is
 * touched here, so the QA can build it again and compare the bytes (render-music.ts writes the file).
 *
 * The master chain: pre-level (so the compressor sees the same level whatever the trims are), EQ, widening, glue,
 * the gaps and the closing fade, then the level search: the gain that puts the integrated loudness on the target
 * with a lookahead limiter holding the true peak under the ceiling.
 */
import { createHash } from "node:crypto";
import { compose, type Composition, type Timeline } from "./compose.js";
import { Rng, SR, type Stereo } from "./dsp.js";
import { gainDb, glue, integratedLufs, limit, masterEq, rangeLufs, truePeak, widen } from "./master.js";
import { duckCurve, gapCurve, mixdown, type BusName, type MixConfig } from "./session.js";

/** Target loudness and ceiling (the film is delivered at about -14 LUFS with a true peak at or under -1 dBTP). */
export const TARGET_LUFS = -14;
export const CEILING_DBTP = -1.1;
/** The closing fade: the last seconds close like a door, whatever the reverb is still doing. */
export const FADE_OUT_SEC = 0.9;

export const MIX: MixConfig = {
  trimDb: {
    kick: -13,
    sub: -9,
    bass: -10.6,
    clap: -5.5,
    snare: -9,
    hats: -0.5,
    pad: -12.5,
    arp: -5,
    lead: -13.5,
    pluck: -9,
    bell: -19,
    outro: -7.5,
    riser: -13,
    fall: -11,
    impact: -8.5,
    type: -21.2,
    key: -15.5,
    click: -19,
    callout: -17,
    chime: -17,
    send: -17,
  },
  duck: {
    pad: { depth: 0.55, tau: 0.16 },
    arp: { depth: 0.35, tau: 0.12 },
    bass: { depth: 0.85, tau: 0.12 },
    lead: { depth: 0.25, tau: 0.12 },
    pluck: { depth: 0.2, tau: 0.1 },
    bell: { depth: 0.15, tau: 0.1 },
  },
  lowpassHz: { riser: 10500, hats: 10500, fall: 12000, impact: 12000, snare: 11500, clap: 11500, pluck: 12500, type: 11000, key: 11000, click: 12000, callout: 12500, chime: 12500, send: 11500 },
  pocket: { hz: 3300, q: 0.7, gainDb: -4, buses: ["arp", "lead", "pad", "clap", "hats", "pluck"] },
  reverbDb: -5,
  delayDb: -7,
  delaySamples: 18000, // a dotted eighth at 120 BPM
  delayFeedback: 0.36,
  reverbRt60: 1.9,
  reverbDuck: 0.3,
  restLimit: { hits: ["impact"], plr: 8.1, range: [0, 0] },
  drive: { impact: 2.4 },
};

export interface ScoreBuild {
  comp: Composition;
  /** The mastered result as floats (the 16-bit file decodes to this, plus dither). */
  out: Stereo;
  /** The buses as they went into the sum (trim, sidechain and filters applied), and the effect returns at their return gains. */
  stems: Record<BusName, Stereo>;
  returns: { reverb: Stereo; delay: Stereo };
  wav: Buffer;
  sha256: string;
  info: {
    lufs: number;
    truePeakDb: number;
    glueMeanGrDb: number;
    glueMaxGrDb: number;
    limiterMaxGrDb: number;
    passes: number;
    gainDb: number;
    limiterGrByBar: Array<{ bar: number; meanDb: number; maxDb: number }>;
    preLevelDb: number;
  };
}

const copyOf = (b: Stereo): Stereo => ({ l: b.l.slice(), r: b.r.slice() });

/** A 16-bit PCM RIFF/WAVE file of two channels. */
export function encodeWav16(l: Float32Array, r: Float32Array, sampleRate = SR): Buffer {
  const n = Math.min(l.length, r.length);
  const buf = Buffer.alloc(44 + n * 4);
  buf.write("RIFF", 0, "ascii");
  buf.writeUInt32LE(36 + n * 4, 4);
  buf.write("WAVE", 8, "ascii");
  buf.write("fmt ", 12, "ascii");
  buf.writeUInt32LE(16, 16);
  buf.writeUInt16LE(1, 20);
  buf.writeUInt16LE(2, 22);
  buf.writeUInt32LE(sampleRate, 24);
  buf.writeUInt32LE(sampleRate * 4, 28);
  buf.writeUInt16LE(4, 32);
  buf.writeUInt16LE(16, 34);
  buf.write("data", 36, "ascii");
  buf.writeUInt32LE(n * 4, 40);
  const q = (x: number) => Math.max(-32768, Math.min(32767, Math.round(x < 0 ? x * 32768 : x * 32767)));
  for (let i = 0; i < n; i++) {
    buf.writeInt16LE(q(l[i]), 44 + i * 4);
    buf.writeInt16LE(q(r[i]), 46 + i * 4);
  }
  return buf;
}

/** Mean and deepest limiter gain reduction in each bar, in dB. */
function limiterByBar(gain: Float32Array, spBar: number): Array<{ bar: number; meanDb: number; maxDb: number }> {
  const out: Array<{ bar: number; meanDb: number; maxDb: number }> = [];
  for (let bar = 0; bar * spBar < gain.length; bar++) {
    let sum = 0;
    let max = 0;
    const to = Math.min(gain.length, (bar + 1) * spBar);
    for (let i = bar * spBar; i < to; i++) {
      const db = -20 * Math.log10(Math.max(gain[i], 1e-6));
      sum += db;
      if (db > max) max = db;
    }
    out.push({ bar, meanDb: Math.round((sum / (to - bar * spBar)) * 100) / 100, maxDb: Math.round(max * 10) / 10 });
  }
  return out;
}

export function buildScore(T: Timeline, mix: MixConfig = MIX): ScoreBuild {
  const comp = compose(T);
  const s = comp.session;
  const N = comp.n;
  const spBar = T.BAR * (SR / T.FPS);

  // The stretch of the film under the groove (the bar after the landing up to the bar before the outro): where levels are judged.
  const grooveFrom = comp.plans.find((p) => p.section.id === "module")?.bar ?? 0;
  const grooveTo = comp.outroS !== null ? comp.outroS / spBar : T.BARS;
  const gA = Math.round((grooveFrom + 1) * spBar);
  const gB = Math.min(N, Math.round(Math.max(grooveFrom + 2, grooveTo - 1) * spBar));
  const kickDuck = duckCurve(s.kicks, N, 1, 0.16);
  const { master, stems, returns } = mixdown(s, { ...mix, restLimit: mix.restLimit && { ...mix.restLimit, range: [gA, gB] } }, kickDuck, comp.flush);
  const scaled = (b: Stereo, db: number): Stereo => {
    const g = 10 ** (db / 20);
    return { l: b.l.map((v) => v * g), r: b.r.map((v) => v * g) };
  };
  const returnsForQa = { reverb: scaled(returns.reverb, mix.reverbDb), delay: scaled(returns.delay, mix.delayDb) };

  // Pre-level: the stretch of the film under the groove sits at -17 LUFS before the glue, so the compressor works at
  // the same depth however the trims are set.
  const preLevelDb = -17 - rangeLufs(master.l, master.r, gA, gB);
  gainDb(master, preLevelDb);

  masterEq(master);
  widen(master, 1.5);
  const glueGr = glue(master, { thresholdDb: -13, ratio: 2.2, attackMs: 12, releaseMs: 150, kneeDb: 6, makeupDb: 0 });
  // The gaps: everything mutes (tails included) for a breath.  After the filters, so they cannot ring through it.
  const gap = gapCurve(comp.gaps, N);
  for (let i = 0; i < N; i++) {
    master.l[i] *= gap[i];
    master.r[i] *= gap[i];
  }
  // The closing fade.
  const fadeN = Math.round(FADE_OUT_SEC * SR);
  for (let i = 0; i < fadeN; i++) {
    const c = 0.5 + 0.5 * Math.cos((Math.PI * i) / fadeN);
    const g = c * c;
    master.l[N - fadeN + i] *= g;
    master.r[N - fadeN + i] *= g;
  }

  // Level: find the gain that lands the limited result on the target loudness, with the true peak under the ceiling.
  let gDb = 0;
  let ceilingDb = CEILING_DBTP - 0.25;
  let out = copyOf(master);
  let lufs = 0;
  let tp = 0;
  let grDb = 0;
  let passes = 0;
  const grGain = new Float32Array(N);
  for (let iter = 0; iter < 10; iter++) {
    passes = iter + 1;
    out = copyOf(master);
    gainDb(out, gDb);
    grDb = limit(out, 10 ** (ceilingDb / 20), { gainOut: grGain });
    lufs = integratedLufs(out.l, out.r);
    tp = 20 * Math.log10(truePeak(out.l, out.r));
    const err = TARGET_LUFS - lufs;
    let done = true;
    if (Math.abs(err) > 0.06) {
      gDb += err;
      done = false;
    }
    if (tp > CEILING_DBTP) {
      ceilingDb -= tp - CEILING_DBTP + 0.05;
      done = false;
    }
    if (done) break;
  }

  // Dither (TPDF, seeded) and the 16-bit file; the very last sample is exactly silent.
  const rng = new Rng(2024);
  const lsb = 1 / 32768;
  const l = new Float32Array(N);
  const r = new Float32Array(N);
  for (let i = 0; i < N; i++) {
    l[i] = out.l[i] + (rng.next() - rng.next()) * lsb;
    r[i] = out.r[i] + (rng.next() - rng.next()) * lsb;
  }
  l[N - 1] = 0;
  r[N - 1] = 0;
  const wav = encodeWav16(l, r);
  const sha256 = createHash("sha256").update(wav).digest("hex");
  return {
    comp,
    out,
    stems,
    returns: returnsForQa,
    wav,
    sha256,
    info: {
      lufs,
      truePeakDb: tp,
      glueMeanGrDb: glueGr.meanDb,
      glueMaxGrDb: glueGr.maxDb,
      limiterMaxGrDb: grDb,
      passes,
      gainDb: gDb,
      limiterGrByBar: limiterByBar(grGain, spBar),
      preLevelDb,
    },
  };
}
