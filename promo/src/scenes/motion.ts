/**
 * Motion, derived from the timeline: the camera, the shake of the stage, the pop of the monitor, the chromatic split and
 * the breathing of the light on the beat.  Pure functions of the timeline: no rendering here.
 */
import { ACTS, BEAT, DURATION, FALL, OUTRO, TENSION, act, type Act } from "../timeline.js";
import { MON_H, MON_SCALE, MON_W, SHOT_H, SHOT_W } from "../theme.js";
import { curve, kicks, lerp, ramp, rng, smooth, type Kick } from "../kit/anim.js";
import { loadFootage } from "../footage.js";

/** The frames the UI of each module act lands on. */
export const IMPACTS = ACTS.filter((a) => a.kind === "module").map((a) => a.impact);

/** Shake of the stage per impact (pixels). */
const SHAKE = 30;

const rx = rng(0x51);
const shakeKicks: Kick[] = IMPACTS.map((f) => ({ frame: f, amp: SHAKE, tau: 10, omega: 1.1 }));
const kickY = kicks(shakeKicks);
const kickX = kicks(shakeKicks.map((k) => ({ ...k, amp: k.amp * (0.4 + rx() * 0.3) * (rx() > 0.5 ? 1 : -1), omega: (k.omega ?? 1) * 0.8, phase: 0.6 })));
const kickR = kicks(shakeKicks.map((k) => ({ ...k, amp: k.amp * 0.012 * (rx() > 0.5 ? 1 : -1), omega: (k.omega ?? 1) * 0.7, phase: 1.1 })));

/** A rising tremor in the frames before each UI lands: the frame knows. */
const tremor = (f: number): number => {
  let v = 0;
  for (const i of IMPACTS) {
    const t = ramp(f, i - TENSION, i - 2);
    if (f < i - 1) v += t * t * 3.6 * Math.sin(f * 2.3);
  }
  return v;
};

export const SHAKE_Y = curve((f) => kickY[f] + tremor(f));
export const SHAKE_X = curve((f) => kickX[f] + tremor(f + 3) * 0.6);
export const SHAKE_R = curve((f) => kickR[f]);

/** The monitor's pop (a fraction of its scale) as the UI lands. */
const pop = kicks(IMPACTS.map((f) => ({ frame: f, amp: 0.028, tau: 11, omega: 0.55 })));
export const POP = curve((f) => pop[f]);

/** How hard the light breathes with the kick: four on the floor, from each impact to the outro. */
export const BEAT_PULSE = curve((f) => {
  let live = false;
  for (const i of IMPACTS) if (f >= i && f < OUTRO) live = true;
  if (!live) return 0;
  return Math.exp(-(f % BEAT) / 4.2);
});

/** Chromatic split, in design pixels: a glitch before the fall, a spike on the impact. */
const splitKicks = kicks(IMPACTS.map((f) => ({ frame: f, amp: 9, tau: 6, omega: 0 })));
export const SPLIT = curve((f) => {
  let glitch = 0;
  for (const i of IMPACTS) if (f >= i - FALL - 10 && f < i - 2) glitch += 2.2 * Math.abs(Math.sin(f * 4.1)) * ramp(f, i - FALL - 10, i - 2);
  return Math.max(0, splitKicks[f] + glitch);
});

// ---------------------------------------------------------------------------
// The camera: where in the footage the monitor looks, and how closely.
// ---------------------------------------------------------------------------

export interface CamKey {
  frame: number;
  /** Zoom: 1 shows the whole footage in the monitor. */
  zoom: number;
  /** The footage point at the monitor's middle. */
  cx: number;
  cy: number;
}

/** The camera that shows a footage rectangle as large as it fits the monitor, and no larger than `max`. */
export function frameRect(rect: [number, number, number, number], max = 1.45, margin = 1.04): { zoom: number; cx: number; cy: number } {
  const [x, y, w, h] = rect;
  const zoom = Math.max(1, Math.min(max, SHOT_W / (w * margin), SHOT_H / (h * margin)));
  const vw = SHOT_W / zoom;
  const vh = SHOT_H / zoom;
  // Keep the view inside the footage.
  const cx = Math.min(SHOT_W - vw / 2, Math.max(vw / 2, x + w / 2));
  const cy = Math.min(SHOT_H - vh / 2, Math.max(vh / 2, y + h / 2));
  return { zoom, cx, cy };
}

const WHOLE = { zoom: 1, cx: SHOT_W / 2, cy: SHOT_H / 2 };

/** The camera's keys: eased between, held outside. */
export function cameraKeys(): CamKey[] {
  const keys: CamKey[] = [{ frame: 0, ...WHOLE }];
  const intro = act("intro");
  const rects = loadFootage().rects;
  // The person types and the agent answers in the chat's lower part: come close, and stay.
  const chat = rects.chat;
  const lower: [number, number, number, number] = [chat[0], chat[1] + chat[3] * 0.38, chat[2], chat[3] * 0.62];
  const near = frameRect(lower, 1.42, 1.0);
  keys.push({ frame: 18, ...WHOLE }, { frame: 52, ...near });
  // Before the UI falls, pull back to the whole frame, so that it lands in its place.
  const fall = intro.to - 22;
  keys.push({ frame: fall, ...near }, { frame: intro.to + 4, ...WHOLE });
  keys.push({ frame: DURATION, ...WHOLE });
  return keys.sort((a, b) => a.frame - b.frame);
}

const ease = (t: number) => smooth(smooth(t));

function camAt(keys: CamKey[], f: number): CamKey {
  if (f <= keys[0].frame) return keys[0];
  for (let i = 1; i < keys.length; i++) {
    const a = keys[i - 1];
    const b = keys[i];
    if (f <= b.frame) {
      const t = ease((f - a.frame) / Math.max(1, b.frame - a.frame));
      // Zoom in log space so that a push and a pull feel alike.
      return { frame: f, zoom: Math.exp(lerp(Math.log(a.zoom), Math.log(b.zoom), t)), cx: lerp(a.cx, b.cx, t), cy: lerp(a.cy, b.cy, t) };
    }
  }
  return keys[keys.length - 1];
}

const KEYS = cameraKeys();
const cam = Array.from({ length: DURATION }, (_, f) => camAt(KEYS, f));

/** The world (the footage) as the monitor shows it, per frame: its top-left in the monitor and its scale. */
export const WORLD_SCALE = curve((f) => MON_SCALE * cam[f].zoom);
export const WORLD_X = curve((f) => MON_W / 2 - cam[f].cx * WORLD_SCALE[f]);
export const WORLD_Y = curve((f) => MON_H / 2 - cam[f].cy * WORLD_SCALE[f]);
export const ZOOM = curve((f) => cam[f].zoom);

/** How much of the side the camera looks away from is dimmed: more the closer it is, and only when it has moved to the other side. */
export const FOCUS_SHADE = {
  left: curve((f) => ramp(cam[f].cx, SHOT_W / 2 + 40, SHOT_W / 2 + 260) * ramp(cam[f].zoom, 1.02, 1.3)),
  right: curve((f) => ramp(SHOT_W / 2 - cam[f].cx, 40, 260) * ramp(cam[f].zoom, 1.02, 1.3)),
};

export type { Act };
