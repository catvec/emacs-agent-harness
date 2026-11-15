/**
 * A mixing session: named stereo buses the arrangement drops events into, two
 * send buses (reverb and delay), the sidechain duck computed from the kick
 * schedule, and the gap mutes the timeline asks for.  `mixdown` turns it all
 * into one stereo master (before mastering).
 *
 * The buses are the score's instruments in three families, so the QA can listen to each on its own:
 *   groove   kick sub bass clap snare hats pad arp lead pluck bell outro
 *   build    riser fall impact
 *   cues     type key click callout chime send   (the sounds of what the person and the footage do)
 */
import { Biquad, SR, addMono, addStereo, fadeEdges, newStereo, pingPong, reverb, type Stereo, clamp } from "./dsp.js";
import { limit, rangeLufs } from "./master.js";

export type BusName =
  | "kick" | "sub" | "bass" | "clap" | "snare" | "hats" | "pad" | "arp" | "lead" | "pluck" | "bell" | "outro"
  | "riser" | "fall" | "impact"
  | "type" | "key" | "click" | "callout" | "chime" | "send";

export const BUS_NAMES: BusName[] = [
  "kick", "sub", "bass", "clap", "snare", "hats", "pad", "arp", "lead", "pluck", "bell", "outro",
  "riser", "fall", "impact",
  "type", "key", "click", "callout", "chime", "send",
];

/** The buses that are music (the groove and its tails) as opposed to the sounds of the build and of the cues. */
export const GROOVE_BUSES: BusName[] = ["kick", "sub", "bass", "clap", "snare", "hats", "pad", "arp", "lead", "pluck", "bell", "outro"];

export interface Place {
  gain?: number;
  pan?: number;
  /** Reverb send (linear, relative to the placed level). */
  rv?: number;
  /** Ping-pong delay send. */
  dl?: number;
  /** Cut the event at this absolute sample (a 3 ms fade ends it): a note that must not ring across a gap or past the bar line. */
  until?: number;
}

const CUT_FADE = Math.round(0.003 * SR);

export class Session {
  readonly n: number;
  readonly bus: Record<BusName, Stereo>;
  readonly rvSend: Stereo;
  readonly dlSend: Stereo;
  /** Sample positions of every full kick, for the sidechain. */
  readonly kicks: Array<{ at: number; vel: number }> = [];
  /** Every placed event whose first or last sample is not near zero (a click at the note's edge). */
  readonly edgeOffenders: Array<{ bus: BusName; start: number; ratio: number }> = [];
  /** How many events were placed, for the audit's denominator. */
  placed = 0;

  constructor(n: number) {
    this.n = n;
    this.bus = Object.fromEntries(BUS_NAMES.map((b) => [b, newStereo(n)])) as Record<BusName, Stereo>;
    this.rvSend = newStereo(n);
    this.dlSend = newStereo(n);
  }

  /** Note the event's edges: a note that starts or stops away from zero clicks. */
  private audit(bus: BusName, start: number, a: Float32Array, b?: Float32Array): void {
    this.placed++;
    let peak = 1e-9;
    for (let i = 0; i < a.length; i++) peak = Math.max(peak, Math.abs(a[i]), b ? Math.abs(b[i]) : 0);
    const last = a.length - 1;
    const edge = Math.max(Math.abs(a[0]), Math.abs(a[last]), b ? Math.abs(b[0]) : 0, b ? Math.abs(b[last]) : 0);
    const ratio = edge / peak;
    if (ratio > 0.03 && start + last < this.n) this.edgeOffenders.push({ bus, start, ratio });
  }

  /** The part of a buffer that plays before `until`, faded out; the buffer itself when it ends sooner.  Null when nothing plays. */
  private cut(start: number, len: number, until: number | undefined): number | null {
    if (until === undefined) return len;
    const keep = until - start;
    if (keep <= 0) return null;
    return Math.min(len, keep);
  }

  /** Place a mono buffer on a bus at `start` (samples). */
  mono(bus: BusName, start: number, buf: Float32Array, o: Place = {}): void {
    const keep = this.cut(start, buf.length, o.until);
    if (keep === null) return;
    if (keep < buf.length) {
      buf = buf.slice(0, keep);
      fadeEdges(buf, 0, Math.min(keep, CUT_FADE));
    }
    this.audit(bus, start, buf);
    const gain = o.gain ?? 1;
    const pan = o.pan ?? 0;
    addMono(this.bus[bus], start, buf, gain, pan);
    if (o.rv) addMono(this.rvSend, start, buf, gain * o.rv, pan);
    if (o.dl) addMono(this.dlSend, start, buf, gain * o.dl, pan);
  }

  /** Place a stereo buffer on a bus at `start`. */
  stereo(bus: BusName, start: number, s: Stereo, o: Place = {}): void {
    const keep = this.cut(start, s.l.length, o.until);
    if (keep === null) return;
    if (keep < s.l.length) {
      s = { l: s.l.slice(0, keep), r: s.r.slice(0, keep) };
      fadeEdges(s.l, 0, Math.min(keep, CUT_FADE));
      fadeEdges(s.r, 0, Math.min(keep, CUT_FADE));
    }
    this.audit(bus, start, s.l, s.r);
    const gain = o.gain ?? 1;
    addStereo(this.bus[bus], start, s.l, s.r, gain);
    if (o.rv) addStereo(this.rvSend, start, s.l, s.r, gain * o.rv);
    if (o.dl) addStereo(this.dlSend, start, s.l, s.r, gain * o.dl);
  }
}

/**
 * The sidechain duck: 1 normally, dipping to (1 - depth) at every kick and
 * recovering exponentially.  The dip takes ~2 ms so it never clicks.
 */
export function duckCurve(kicks: Array<{ at: number; vel: number }>, n: number, depth: number, tau: number): Float32Array {
  const env = new Float32Array(n).fill(1);
  const attack = Math.round(0.002 * SR);
  const length = Math.round(tau * 5 * SR);
  for (const k of kicks) {
    const d = depth * clamp(k.vel, 0, 1);
    for (let j = 0; j < length; j++) {
      const i = k.at + j;
      if (i >= n) break;
      const a = j < attack ? j / attack : 1;
      const v = 1 - d * a * Math.exp(-j / (tau * SR));
      if (v < env[i]) env[i] = v;
    }
  }
  return env;
}

/**
 * A gain curve that is 0 inside each [from, to) sample range and 1 elsewhere.  The mute is entered with a
 * short fade (so it never clicks) and left with none: what plays at `to` is the hit the gap was made for.
 */
export function gapCurve(ranges: Array<[number, number]>, n: number): Float32Array {
  const env = new Float32Array(n).fill(1);
  const fade = Math.round(0.004 * SR);
  for (const [from, to] of ranges) {
    for (let i = Math.max(0, from - fade); i < Math.min(n, to); i++) {
      const v = i < from ? 1 - (i - (from - fade)) / fade : 0;
      if (v < env[i]) env[i] = v;
    }
  }
  return env;
}

export interface MixConfig {
  /** Static trim of each bus, in dB. */
  trimDb: Partial<Record<BusName, number>>;
  /** Sidechain depth per bus (0..1), keyed by bus. */
  duck: Partial<Record<BusName, { depth: number; tau: number }>>;
  /** Reverb return level and delay return level (dB). */
  reverbDb: number;
  delayDb: number;
  /** Delay time in samples, feedback. */
  delaySamples: number;
  delayFeedback: number;
  reverbRt60: number;
  /** How much of the reverb return is ducked by the kick (0..1). */
  reverbDuck: number;
  /** A 4th-order low-pass per noisy bus (Hz), so nothing up there can hiss. */
  lowpassHz?: Partial<Record<BusName, number>>;
  /** A broad cut where the sounds of the cues live (their clicks are 2-6 kHz): the music steps aside, the cues are not touched. */
  pocket?: { hz: number; q: number; gainDb: number; buses: BusName[] };
  /**
   * The hits stand above everything else.  Everything but the `hits` buses (and the effect returns) passes a
   * peak limiter that holds it `plr` dB above its own loudness over `range` (samples): the groove, the typing
   * and the chimes can never reach the ceiling, so the hits are the only thing that does.
   */
  restLimit?: { hits: BusName[]; plr: number; range: [number, number] };
  /**
   * Saturation of a bus as a whole: its loudest sample stays where it is, everything quieter is lifted along
   * a tanh curve of this drive, so the bus is denser (louder for the same peak, and its tail has more body).
   */
  drive?: Partial<Record<BusName, number>>;
}

/**
 * Sum the buses (ducked, trimmed) plus the effect returns into a stereo master.
 * `stems` are the buses as they went into the sum (trim and sidechain applied),
 * for the QA's per-instrument loudness table.
 *
 * `flushAt` lists sample positions where the reverb and the delay are emptied: what rings before such a
 * position is cut off there, and what is sent after it starts in a clean room.  (A gap in the master is
 * only silent if the tail of the build cannot come back out of the reverb behind it.)
 */
export function mixdown(
  s: Session,
  cfg: MixConfig,
  kickDuckForReverb: Float32Array | null,
  flushAt: number[] = [],
): { master: Stereo; stems: Record<BusName, Stereo>; returns: { reverb: Stereo; delay: Stereo } } {
  const n = s.n;
  const master = newStereo(n);
  const hits = newStereo(n);
  const stems = {} as Record<BusName, Stereo>;
  const hitSet = new Set<BusName>(cfg.restLimit?.hits ?? []);
  const db = (b: BusName) => 10 ** ((cfg.trimDb[b] ?? 0) / 20);
  for (const name of Object.keys(s.bus) as BusName[]) {
    const bus = s.bus[name];
    const d = cfg.duck[name];
    const g = db(name);
    const stem = newStereo(n);
    const env = d ? duckCurve(s.kicks, n, d.depth, d.tau) : null;
    for (let i = 0; i < n; i++) {
      const v = env ? g * env[i] : g;
      stem.l[i] = bus.l[i] * v;
      stem.r[i] = bus.r[i] * v;
    }
    if (cfg.pocket?.buses.includes(name)) {
      for (const ch of [stem.l, stem.r]) new Biquad("peak", cfg.pocket.hz, cfg.pocket.q, cfg.pocket.gainDb).apply(ch);
    }
    const drive = cfg.drive?.[name];
    if (drive) {
      let peak = 1e-9;
      for (let i = 0; i < n; i++) peak = Math.max(peak, Math.abs(stem.l[i]), Math.abs(stem.r[i]));
      const norm = peak / Math.tanh(drive);
      for (let i = 0; i < n; i++) {
        stem.l[i] = Math.tanh((drive * stem.l[i]) / peak) * norm;
        stem.r[i] = Math.tanh((drive * stem.r[i]) / peak) * norm;
      }
    }
    const lp = cfg.lowpassHz?.[name];
    if (lp) {
      for (const ch of [stem.l, stem.r]) {
        new Biquad("lowpass", lp, 0.5412).apply(ch);
        new Biquad("lowpass", lp, 1.3066).apply(ch);
      }
    }
    const into = hitSet.has(name) ? hits : master;
    for (let i = 0; i < n; i++) {
      into.l[i] += stem.l[i];
      into.r[i] += stem.r[i];
    }
    stems[name] = stem;
  }
  // Effect returns, one clean room per stretch between flushes.
  const cuts = [0, ...flushAt.filter((f) => f > 0 && f < n).sort((a, b) => a - b), n];
  const delayOut = newStereo(n);
  const rv = newStereo(n);
  for (let k = 0; k + 1 < cuts.length; k++) {
    const a = cuts[k];
    const b = cuts[k + 1];
    const dl = pingPong(s.dlSend.l.subarray(a, b), s.dlSend.r.subarray(a, b), cfg.delaySamples, cfg.delayFeedback);
    delayOut.l.set(dl.l, a);
    delayOut.r.set(dl.r, a);
    // The delay feeds the reverb a little, so echoes sit in the room.
    const rvIn = newStereo(b - a);
    for (let i = 0; i < b - a; i++) {
      rvIn.l[i] = s.rvSend.l[a + i] + dl.l[i] * 0.18;
      rvIn.r[i] = s.rvSend.r[a + i] + dl.r[i] * 0.18;
    }
    const room = reverb(rvIn.l, rvIn.r, { rt60: cfg.reverbRt60 });
    rv.l.set(room.l, a);
    rv.r.set(room.r, a);
  }
  const rg = 10 ** (cfg.reverbDb / 20);
  const dg = 10 ** (cfg.delayDb / 20);
  for (let i = 0; i < n; i++) {
    const k = kickDuckForReverb ? 1 - cfg.reverbDuck * (1 - kickDuckForReverb[i]) : 1;
    master.l[i] += rv.l[i] * rg * k + delayOut.l[i] * dg;
    master.r[i] += rv.r[i] * rg * k + delayOut.r[i] * dg;
  }
  if (cfg.restLimit) {
    const [a, b] = cfg.restLimit.range;
    const ceiling = 10 ** ((rangeLufs(master.l, master.r, a, b) + cfg.restLimit.plr) / 20);
    limit(master, ceiling, { lookaheadMs: 1.5, releaseMs: 60 });
    for (let i = 0; i < n; i++) {
      master.l[i] += hits.l[i];
      master.r[i] += hits.r[i];
    }
  }
  return { master, stems, returns: { reverb: rv, delay: delayOut } };
}
