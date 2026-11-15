/**
 * The name of the module, slammed over the frame as its UI lands, with what it
 * is under it; then it shrinks to where the style keeps its title and stays
 * there for the act.  Where that is comes from the style: over the middle of a
 * neon frame, in the top-left of a drawing, in the lower-third of a broadcast.
 */
import { ACTS } from "../timeline.js";
import { MON_H, MON_W, MON_X, MON_Y, SCRIM, STYLE } from "../theme.js";
import { loadManifest } from "../kit/manifest.js";
import { box, img, type Node } from "../kit/layers.js";

export function titles(): Node[] {
  const m = loadManifest();
  const out: Node[] = [];
  for (const a of ACTS.filter((x) => x.kind === "module")) {
    const t = m.titles[a.id];
    const tag = m.lines[`${a.id}-tag`];
    const f = a.impact;
    const big = STYLE.titleBig;
    const dock = STYLE.titleDock;
    const anchorX = big.align === "left" ? 0 : 0.5;
    const bigX = big.x - (anchorX ? t.w / 2 : 0);
    const dockX = dock.x - (anchorX ? t.w / 2 : 0);
    const dockAt = f + 66;
    const to = dockAt + 17;
    const rotate = big.rotate ?? 0;
    out.push(
      // The frame dims behind the name, so that it can be read, and the line under it.
      box({
        id: `title-dim-${a.id}`,
        x: MON_X,
        y: MON_Y,
        width: MON_W,
        height: MON_H,
        background: SCRIM,
        from: f + 1,
        to: dockAt + 16,
        tracks: { opacity: [[f + 1, 0], [f + 5, STYLE.titleDim, "power2.out"], [dockAt, STYLE.titleDim], [dockAt + 15, 0, "power2.in"]] },
      }),
      img(t.file, {
        id: `title-${a.id}`,
        x: bigX,
        y: big.y - t.h / 2,
        width: t.w,
        height: t.h,
        anchorX,
        anchorY: 0.5,
        from: f + 2,
        to,
        zIndex: 6,
        tracks: {
          x: [[f + 2, bigX], [dockAt, bigX], [dockAt + 16, dockX, "power3.inOut"]],
          y: [[f + 2, big.y - t.h / 2], [dockAt, big.y - t.h / 2], [dockAt + 16, dock.y - t.h / 2, "power3.inOut"]],
          scale: [[f + 2, 1.9], [f + 8, 1, "expo.out"], [dockAt, 1], [dockAt + 16, dock.scale, "power3.inOut"]],
          rotation: [[f + 2, rotate - 3], [f + 10, rotate, "power3.out"]],
          opacity: [[f + 2, 0], [f + 4, 1], [dockAt, 1], [dockAt + 16, 0, "power2.in"]],
        },
      }),
      img(tag.file, {
        id: `tagline-${a.id}`,
        x: big.align === "left" ? big.x : big.x - tag.w / 2,
        y: big.y + t.h * 0.3 - tag.h / 2,
        width: tag.w,
        height: tag.h,
        anchorX,
        anchorY: 0.5,
        from: f + 12,
        to: dockAt + 8,
        zIndex: 6,
        tracks: {
          y: [[f + 12, big.y + t.h * 0.3 - tag.h / 2 + 16], [f + 22, big.y + t.h * 0.3 - tag.h / 2, "expo.out"]],
          opacity: [[f + 12, 0], [f + 20, 1], [dockAt - 2, 1], [dockAt + 7, 0, "power2.in"]],
        },
      }),
    );
  }
  return out;
}
