/**
 * What the film draws ON the footage, in the footage's own pixels (so that it follows the camera): a pointer that goes to what the
 * person clicks and the ripple of the click, a glow around a card that has changed, and callouts that label what the eye
 * should see.  All of it comes from the recorder's log: where the click was, which lines the card took.
 */
import { ACTS, type Act } from "../timeline.js";
import { loadFootage, type CalloutEvent, type ClickEvent, type HighlightEvent } from "../footage.js";
import { MODULES } from "../story.js";
import { MAGENTA, MON_SCALE, SHOT_H, SHOT_W, STYLE } from "../theme.js";
import { loadManifest } from "../kit/manifest.js";
import { box, img, type Node } from "../kit/layers.js";
import type { Key } from "../kit/anim.js";

const accentOf = (a: Act) => MODULES.find((m) => m.id === a.id)?.accent ?? MAGENTA;
const inv = 1 / MON_SCALE;

/** The pointer: it is seen from a little before the first click of an act to a little after the last. */
export function pointer(): Node[] {
  const m = loadManifest();
  const footage = loadFootage();
  const out: Node[] = [];
  const sprite = m.pointer;
  const w = sprite.w * inv;
  const h = sprite.h * inv;
  const [hotX, hotY] = sprite.hot ?? [0, 0];
  const tipX = hotX * inv;
  const tipY = hotY * inv;

  for (const a of ACTS) {
    const seg = footage.segments.find((s) => s.name === a.segment)!;
    const clicks = seg.events.filter((e): e is ClickEvent => e.type === "click");
    if (!clicks.length) continue;
    const frames = clicks.map((c) => a.from + c.f);
    const first = frames[0];
    const from = first - 40;
    const to = frames[frames.length - 1] + 36;
    // The pointer comes in from below and to the right, as a hand would.
    const start: [number, number] = [Math.min(SHOT_W - 60, clicks[0].xy[0] + 520), Math.min(SHOT_H - 60, clicks[0].xy[1] + 420)];
    const xs: Key[] = [[from, start[0]]];
    const ys: Key[] = [[from, start[1]]];
    const scale: Key[] = [[from, 1]];
    let prev = start;
    let prevFrame = from;
    clicks.forEach((c, i) => {
      const f = frames[i];
      const arrive = f - 3;
      const depart = Math.max(prevFrame + 3, Math.min(arrive - 16, prevFrame + 12));
      xs.push([depart, prev[0]], [arrive, c.xy[0], "power3.inOut"]);
      ys.push([depart, prev[1]], [arrive, c.xy[1], "power3.inOut"]);
      // The press.
      scale.push([f - 4, 1], [f - 1, 0.84, "power2.out"], [f + 4, 1, "back.out(2)"]);
      prev = c.xy;
      prevFrame = f + 4;
    });
    out.push(
      img(sprite.file, {
        id: `pointer-${a.id}`,
        x: start[0] - tipX,
        y: start[1] - tipY,
        width: w,
        height: h,
        anchorX: hotX / sprite.w,
        anchorY: hotY / sprite.h,
        from,
        to,
        zIndex: 5,
        tracks: {
          x: xs.map(([f, v, e]) => [f, (v as number) - tipX, e] as Key),
          y: ys.map(([f, v, e]) => [f, (v as number) - tipY, e] as Key),
          scale,
          opacity: [[from, 0], [from + 8, 1], [to - 10, 1], [to, 0, "power2.in"]],
        },
      }),
    );
    // The ripple of each click.
    const ring = m.ripple;
    const rs = ring.w * inv;
    clicks.forEach((c, i) => {
      const f = frames[i];
      out.push(
        img(ring.file, {
          id: `ripple-${a.id}-${i}`,
          x: c.xy[0] - rs / 2,
          y: c.xy[1] - rs / 2,
          width: rs,
          height: rs,
          anchorX: 0.5,
          anchorY: 0.5,
          blendMode: STYLE.blend,
          from: f - 1,
          to: f + 18,
          tracks: { scale: [[f - 1, 0.12], [f + 16, 0.8, "expo.out"]], opacity: [[f - 1, 0.95], [f + 17, 0, "power2.out"]] },
        }),
      );
    });
  }
  return out;
}

/** A glow around what has changed: two nested outlines, pulsing three times. */
export function highlights(): Node[] {
  const footage = loadFootage();
  const out: Node[] = [];
  let n = 0;
  for (const a of ACTS) {
    const seg = footage.segments.find((s) => s.name === a.segment)!;
    const color = accentOf(a);
    for (const e of seg.events.filter((x): x is HighlightEvent => x.type === "highlight")) {
      const [x, y, w, h] = e.rect;
      const f = a.from + e.f;
      const pulse = (peak: number): Key[] => {
        const keys: Key[] = [[f, 0]];
        for (let k = 0; k < 3; k++) keys.push([f + 2 + k * 11, peak, "power2.out"], [f + 9 + k * 11, peak * 0.25, "power2.in"]);
        keys.push([f + 38, 0]);
        return keys;
      };
      const id = n++;
      out.push(
        box({ id: `hl-outer-${id}`, x: x - 12, y: y - 9, width: w + 24, height: h + 18, borderColor: color, borderWidth: 2, from: f, to: f + 40, tracks: { opacity: pulse(0.7) } }),
        box({ id: `hl-${id}`, x: x - 4, y: y - 3, width: w + 8, height: h + 6, borderColor: color, borderWidth: 4, from: f, to: f + 40, tracks: { opacity: pulse(1) } }),
      );
    }
  }
  return out;
}

/** Callouts: a label with a short line to what it labels. */
export function callouts(): Node[] {
  const m = loadManifest();
  const footage = loadFootage();
  const out: Node[] = [];
  let n = 0;
  for (const a of ACTS) {
    const seg = footage.segments.find((s) => s.name === a.segment)!;
    const color = accentOf(a);
    for (const e of seg.events.filter((x): x is CalloutEvent => x.type === "callout")) {
      const s = m.callouts[e.text];
      const [rx, ry, rw, rh] = e.rect;
      const f = a.from + e.f;
      const end = f + e.frames;
      const gap = 44;
      let px = rx + rw / 2 - s.boxW / 2;
      let py = ry + rh + gap;
      let lx = 0;
      let ly = 0;
      let lw = 4;
      let lh = gap;
      const clampX = (v: number) => Math.min(SHOT_W - 40 - s.boxW, Math.max(40, v));
      if (e.side === "below") {
        px = clampX(px);
        lx = Math.min(rx + rw - 8, Math.max(rx + 8, px + s.boxW / 2));
        ly = ry + rh;
      } else if (e.side === "above") {
        px = clampX(px);
        py = ry - gap - s.boxH;
        lx = Math.min(rx + rw - 8, Math.max(rx + 8, px + s.boxW / 2));
        ly = ry - gap;
      } else {
        lw = gap;
        lh = 4;
        py = ry + rh / 2 - s.boxH / 2;
        px = e.side === "right" ? rx + rw + gap : rx - gap - s.boxW;
        lx = e.side === "right" ? rx + rw : rx - gap;
        ly = ry + rh / 2;
      }
      const id = n++;
      const rise = e.side === "above" ? -14 : 14;
      out.push(
        box({ id: `leader-${id}`, x: lx - 2, y: ly, width: lw, height: lh, anchorX: 0.5, anchorY: e.side === "above" ? 1 : 0, background: color, from: f, to: end + 6, tracks: { opacity: [[f, 0], [f + 4, 1], [end - 4, 1], [end + 5, 0]], scaleY: [[f, 0.01], [f + 7, 1, "expo.out"]] } }),
        img(s.file, {
          id: `callout-${id}`,
          x: px - s.pad,
          y: py - s.pad + rise,
          width: s.w,
          height: s.h,
          from: f,
          to: end + 6,
          tracks: {
            y: [[f, py - s.pad + rise], [f + 8, py - s.pad, "back.out(1.8)"]],
            opacity: [[f, 0], [f + 5, 1], [end - 2, 1], [end + 5, 0, "power2.in"]],
          },
        }),
      );
    }
  }
  return out;
}

