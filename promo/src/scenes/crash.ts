/**
 * The crash: the module's UI, cropped from the footage, falls onto the monitor and lands where it lives in the real frame.
 * On the frame it lands the monitor shows the footage of the harness WITH that UI, so what lands is what is there:
 * the card fades into the live thing.  The impact throws a shockwave along the floor, sparks, a flash, and (scenes/motion.ts)
 * shakes the stage.
 */
import { Layer } from "framefields";
import { ACTS, FALL } from "../timeline.js";
import { loadFootage } from "../footage.js";
import { MODULES } from "../story.js";
import { MON_SCALE, WHITE, CYAN, H, SCRIM, STYLE, W, screenX, screenY } from "../theme.js";
import { loadManifest } from "../kit/manifest.js";
import { img, plane, type Node } from "../kit/layers.js";

/** Where a module's UI lands: the middle of its bottom edge, on the screen. */
function floorPoint(rect: [number, number, number, number]): [number, number] {
  return [screenX(rect[0] + rect[2] / 2), screenY(rect[1] + rect[3])];
}

export function crash(): Node[] {
  const m = loadManifest();
  const footage = loadFootage();
  const out: Node[] = [];

  for (const a of ACTS.filter((x) => x.kind === "module")) {
    const story = MODULES.find((x) => x.id === a.id)!;
    const sprite = m.cards[a.id];
    const rect = footage.rects[story.landing];
    const f = a.impact;
    const from = f - FALL - 1;
    const to = f + 26;
    const sw = sprite.w * MON_SCALE;
    const sh = sprite.h * MON_SCALE;
    const x = screenX(rect[0]) - sprite.pad * MON_SCALE;
    const yLand = screenY(rect[1]) - sprite.pad * MON_SCALE;
    const yStart = -sh - 30;
    // The card squashes against its bottom edge.
    const anchorY = (sprite.pad + sprite.ch) / sprite.h;

    const card = (id: string, dy: number, opacity: number, blend?: string): Node =>
      img(sprite.file, {
        id,
        x,
        y: yStart,
        width: sw,
        height: sh,
        anchorX: 0.5,
        anchorY,
        from,
        to,
        blendMode: blend,
        zIndex: 3,
        tracks: {
          y: [
            [from, yStart - dy],
            [f, yLand - dy * 0.15, "power2.in"],
            [f + 3, yLand - 12, "power2.out"],
            [f + 8, yLand, "power2.in"],
            [f + 13, yLand],
          ],
          rotation: [[from, -4.5], [f, 0.5, "power1.in"], [f + 4, -0.3, "power2.out"], [f + 10, 0, "power2.out"]],
          scaleX: [[from, 1.12], [f - 1, 1.01, "power2.in"], [f, 1.02], [f + 6, 1, "back.out(2.2)"]],
          scaleY: [[from, 1.12], [f - 1, 1.01, "power2.in"], [f, 0.975], [f + 6, 1, "back.out(2.2)"]],
          opacity: [[from, 0], [from + 2, opacity], [f + 12, opacity], [f + 24, 0, "power2.in"]],
        },
      });

    // A trail behind the falling card: three fainter, higher copies that are gone as it lands.
    for (const [i, [dy, op]] of ([[70, 0.28], [150, 0.18], [240, 0.1]] as const).entries()) {
      const t = card(`card-${a.id}-trail-${i}`, dy, op, STYLE.blend);
      out.push(t);
    }
    out.push(card(`card-${a.id}`, 0, 1));
  }
  return out;
}

/** Shockwaves along the floor, sparks and flashes: the impact. */
export function impactFx(): Node[] {
  const footage = loadFootage();
  const out: Node[] = [];
  for (const a of ACTS.filter((x) => x.kind === "module")) {
    const story = MODULES.find((x) => x.id === a.id)!;
    const rect = footage.rects[story.landing];
    const f = a.impact;
    const [cx, cy] = floorPoint(rect);
    // No shockwave rings: in the hard style the spark burst and the flash carry the hit.

    out.push(
      Layer.particles({
        id: `sparks-${a.id}`,
        width: W,
        height: H,
        max: 1500,
        seed: 21,
        emitter: { shape: "rect", x: cx - 430, y: cy - 6, width: 860, height: 6, rate: 0, bursts: [{ frame: f, count: 170 }, { frame: f + 2, count: 90 }] },
        lifetime: [0.35, 0.95],
        speed: [320, 1250],
        direction: -90,
        spread: 150,
        gravity: 1900,
        drag: 0.8,
        size: [18, 4],
        sizeJitter: 0.5,
        fade: [0.05, 0.5],
        shape: "spark",
        color: [story.accent, WHITE, CYAN],
        blend: STYLE.blend === "screen" ? "add" : "normal",
      } as never) as unknown as Node,
    );

    out.push(
      plane(WHITE, { id: `flash-${a.id}`, blendMode: STYLE.blend, from: f, to: f + 9, tracks: { opacity: [[f, 0.42], [f + 8, 0, "power2.out"]] } }),
      plane(story.accent, { id: `tint-${a.id}`, blendMode: STYLE.blend, from: f, to: f + 14, tracks: { opacity: [[f, 0.22], [f + 13, 0, "power2.out"]] } }),
    );
    // The held breath: the picture dims for a few frames before the card lands.
    out.push(plane(SCRIM, { id: `breath-${a.id}`, from: f - 5, to: f, opacity: 0.35 }));
  }
  return out;
}

