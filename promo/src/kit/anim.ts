/**
 * Small helpers over framefields' keyframes and signals.
 *
 * Keyframes are LOCAL to a layer's own window (startFrame), so every helper here takes
 * absolute film frames and subtracts the layer's `origin` for you: write the film in film time.
 */
import { LayerAnimation, Signal } from "framefields";
import { DURATION, FPS } from "../timeline.js";

export type Key = [frame: number, value: number | string, ease?: string];
export type Tracks = Record<string, Key[]>;

/** Sort keys by frame, drop duplicates (the later one wins) and shift by `origin`. */
export function normalize(keys: Key[], origin = 0): Key[] {
  const byFrame = new Map<number, Key>();
  for (const [f, v, e] of keys) {
    const local = Math.round(f) - origin;
    byFrame.set(local, e ? [local, v, e] : [local, v]);
  }
  return [...byFrame.values()].sort((a, b) => a[0] - b[0]);
}

/** A LayerAnimation from per-prop key lists in film frames; `origin` is the layer's startFrame. */
export function anim(tracks: Tracks, origin = 0): LayerAnimation {
  let a = LayerAnimation.create();
  for (const [prop, keys] of Object.entries(tracks)) {
    const ks = normalize(keys, origin);
    if (ks.length) a = a.keys(prop as never, ks as never);
  }
  return a;
}

/** A per-frame array over the whole film. */
export function curve(fn: (frame: number) => number, frames = DURATION): number[] {
  return Array.from({ length: frames }, (_, f) => fn(f));
}

/** Sum of decaying oscillating kicks: the camera shake / the frame's bounce. */
export interface Kick {
  frame: number;
  amp: number;
  /** Decay time constant in frames. */
  tau?: number;
  /** Oscillation in radians per frame (0 = a plain decaying push). */
  omega?: number;
  phase?: number;
}

export function kicks(list: Kick[], frames = DURATION): number[] {
  const out = new Array<number>(frames).fill(0);
  for (const k of list) {
    const tau = k.tau ?? 7;
    const omega = k.omega ?? 0.9;
    const phase = k.phase ?? 0;
    for (let f = Math.max(0, Math.round(k.frame)); f < frames; f++) {
      const t = f - k.frame;
      const env = Math.exp(-t / tau);
      if (env < 0.01) break;
      out[f] += k.amp * env * Math.cos(omega * t + phase);
    }
  }
  return out;
}

/** A signal over the whole film from per-frame values. */
export const fromArray = (values: number[]) => Signal.fromArray(values, FPS);

/** Clamp. */
export const clamp = (x: number, lo = 0, hi = 1) => Math.min(hi, Math.max(lo, x));
/** Linear interpolation. */
export const lerp = (a: number, b: number, t: number) => a + (b - a) * t;
/** Smooth 0..1 ramp between two frames. */
export const ramp = (f: number, from: number, to: number) => clamp((f - from) / (to - from));
export const smooth = (t: number) => t * t * (3 - 2 * t);

/** A small seeded PRNG (mulberry32): the film must be the same on every machine. */
export function rng(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
