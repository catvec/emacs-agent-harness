/**
 * The brand's chrome over the full-screen capture: the name, the count of
 * modules and the keys the person presses.  Nothing here shrinks the capture:
 * the bars and plates are overlays on the picture, the way a broadcast lower
 * third is.
 */
import { ACTS, DURATION, OUTRO } from "../timeline.js";
import { loadFootage, type KeyEvent } from "../footage.js";
import { MODULES, moduleCount } from "../story.js";
import { DISPLAY, H, MUTED, STYLE, TEXT, W } from "../theme.js";
import { rgba } from "../kit/draw.js";
import { keycapKey, loadManifest } from "../kit/manifest.js";
import { box, img, text, type Node } from "../kit/layers.js";
import type { Key } from "../kit/anim.js";

const MARGIN = 48;
const BAND = 56;
const LOWER = 160;

function counts(): { from: number; to: number; n: number; accent: string }[] {
  const out: { from: number; to: number; n: number; accent: string }[] = [];
  let n = 0;
  let from = 0;
  let accent = MUTED;
  for (const a of ACTS.filter((x) => x.kind === "module")) {
    out.push({ from, to: a.impact, n, accent });
    const story = MODULES.find((x) => x.id === a.id)!;
    n += moduleCount(story);
    from = a.impact;
    accent = story.accent;
  }
  out.push({ from, to: DURATION, n, accent });
  return out;
}

/** The value of the count, popping in as each module lands; EDGE is its right end. */
function countValues(edge: number, y: number, size: number): Node[] {
  const width = size * 3;
  return counts().map((c, i) => {
    const pop: Record<string, Key[]> = i === 0 ? { opacity: [[4, 0], [16, 1]] } : { scale: [[c.from, 1.7], [c.from + 9, 1, "back.out(2)"]], opacity: [[c.from, 0], [c.from + 2, 1]] };
    return text(String(c.n).padStart(2, "0"), {
      id: `count-${i}`,
      x: edge - width,
      y,
      width,
      height: size * 1.4,
      anchorX: 1,
      anchorY: 0,
      fontFamily: DISPLAY,
      fontSize: size,
      fontWeight: STYLE.displayWeight,
      fill: i === 0 ? TEXT : c.accent,
      align: "end",
      from: c.from,
      to: c.to,
      tracks: pop,
    });
  });
}

function countLabel(x: number, y: number): Node {
  return text("MODULES", { id: "count-label", x, y, width: 200, height: 20, fontFamily: STYLE.mono, fontSize: 13, fill: STYLE.muted, align: "end", letterSpacing: 3, from: 4, to: DURATION });
}

export function hud(): Node[] {
  const m = loadManifest();
  const brand = m.titles.brand;
  const out: Node[] = [];

  if (STYLE.hud === "bare") {
    // No plates and no bars: the brand and the count sit on the picture.
    out.push(
      img(brand.file, { id: "brand", x: MARGIN - brand.pad, y: 18, width: brand.w, height: brand.h, from: 4, to: DURATION, tracks: { opacity: [[4, 0], [16, 0.96]] } }),
      countLabel(W - MARGIN - 240, 18),
      ...countValues(W - MARGIN, 30, 30),
    );
  } else if (STYLE.hud === "overlay") {
    const bw = brand.w - brand.pad * 2 + 30;
    const bh = brand.h - brand.pad * 2 + 22;
    out.push(
      box({ id: "brand-plate", x: 34, y: 8, width: bw, height: bh, background: rgba(STYLE.panel, 0.86), borderColor: rgba(STYLE.accent, 0.7), borderWidth: 2 }),
      img(brand.file, { id: "brand", x: MARGIN - brand.pad, y: 18, width: brand.w, height: brand.h, from: 4, to: DURATION, tracks: { opacity: [[4, 0], [16, 0.96]] } }),
      box({ id: "count-plate", x: W - MARGIN - 250, y: 8, width: 250, height: 56, background: rgba(STYLE.panel, 0.86), borderColor: rgba(STYLE.accent, 0.7), borderWidth: 2 }),
      text("MODULES", { id: "count-label", x: W - MARGIN - 232, y: 18, width: 120, height: 20, fontFamily: STYLE.mono, fontSize: 13, fill: STYLE.muted, letterSpacing: 3, from: 4, to: DURATION }),
      ...countValues(W - MARGIN - 18, 26, 30),
    );
  } else if (STYLE.hud === "bar") {
    out.push(
      box({ id: "top-bar", x: 0, y: 0, width: W, height: BAND, background: STYLE.hudFill ?? STYLE.panel }),
      box({ id: "bar-rule", x: 0, y: BAND, width: W, height: 3, background: STYLE.accent }),
      img(brand.file, { id: "brand", x: MARGIN - brand.pad, y: BAND / 2 - brand.h / 2, width: brand.w, height: brand.h, from: 4, to: DURATION, tracks: { opacity: [[4, 0], [16, 0.96]] } }),
      countLabel(W - MARGIN - 240, 18),
      ...countValues(W - MARGIN, 30, 30),
    );
  } else if (STYLE.hud === "lower") {
    out.push(
      box({ id: "lower-band", x: 0, y: H - LOWER, width: W, height: LOWER, background: STYLE.hudFill ?? STYLE.panel }),
      box({ id: "lower-rule", x: 0, y: H - LOWER, width: W, height: 4, background: STYLE.accent }),
      img(brand.file, { id: "brand", x: 64 - brand.pad, y: H - LOWER + 22, width: brand.w, height: brand.h, from: 4, to: DURATION, tracks: { opacity: [[4, 0], [16, 0.96]] } }),
      countLabel(W - 64 - 240, H - LOWER + 26),
      ...countValues(W - 64, H - LOWER + 38, 28),
    );
  } else if (STYLE.hud === "status") {
    const bar = 48;
    out.push(
      box({ id: "status-bar", x: 0, y: H - bar, width: W, height: bar, background: STYLE.hudFill ?? STYLE.panel }),
      box({ id: "status-rule", x: 0, y: H - bar, width: W, height: 2, background: STYLE.accent }),
      img(brand.file, { id: "brand", x: MARGIN - brand.pad, y: H - bar / 2 - brand.h / 2, width: brand.w, height: brand.h, from: 4, to: DURATION, tracks: { opacity: [[4, 0], [16, 0.96]] } }),
      countLabel(W - MARGIN - 240, H - bar + 15),
      ...countValues(W - MARGIN, H - bar + 25, 24),
    );
  } else {
    // bands: a solid band at the top and bottom, the way a scoreboard frames a game.
    out.push(
      box({ id: "top-band", x: 0, y: 0, width: W, height: BAND, background: STYLE.hudFill ?? STYLE.panel }),
      box({ id: "bottom-band", x: 0, y: H - BAND, width: W, height: BAND, background: STYLE.hudFill ?? STYLE.panel }),
      box({ id: "top-rule", x: 0, y: BAND, width: W, height: 3, background: STYLE.accent }),
      box({ id: "bottom-rule", x: 0, y: H - BAND - 3, width: W, height: 3, background: STYLE.accent }),
      img(brand.file, { id: "brand", x: MARGIN - brand.pad, y: BAND / 2 - brand.h / 2, width: brand.w, height: brand.h, from: 4, to: DURATION, tracks: { opacity: [[4, 0], [16, 0.96]] } }),
      countLabel(W - MARGIN - 240, 18),
      ...countValues(W - MARGIN, 30, 30),
    );
  }

  return [
    box({
      id: "hud",
      x: 0,
      y: 0,
      width: W,
      height: H,
      children: out,
      tracks: { opacity: [[OUTRO - 4, 1], [OUTRO + 6, 0, "power2.in"]] },
    }),
  ];
}

/**
 * The title once it has docked: a second copy in the HUD group, so that a solid
 * bar or lower third cannot hide it.  It takes over on the frame the stage's
 * copy finishes shrinking, at the same size and place.
 */
export function dockTitles(): Node[] {
  const m = loadManifest();
  const out: Node[] = [];
  for (const a of ACTS.filter((x) => x.kind === "module")) {
    const t = m.titles[a.id];
    const dock = STYLE.titleDock;
    const w = t.w * dock.scale;
    const h = t.h * dock.scale;
    if (STYLE.hud === "overlay") {
      out.push(box({ id: `dock-plate-${a.id}`, x: dock.x - 18, y: dock.y - h / 2 - 10, width: w + 36, height: h + 20, background: rgba(STYLE.panel, 0.9), borderColor: rgba(STYLE.accent, 0.7), borderWidth: 2, from: a.impact + 66 + 17, to: OUTRO + 4, zIndex: 1 }));
    }
    out.push(
      img(t.file, {
        id: `dock-${a.id}`,
        x: dock.align === "left" ? dock.x : dock.x - w / 2,
        y: dock.y - h / 2,
        width: w,
        height: h,
        from: a.impact + 66 + 17,
        to: OUTRO + 4,
        zIndex: 2,
      }),
    );
  }
  return out;
}

/** Where a keycap sits for this HUD: a bottom its height is taken off. */
function keycapBottom(): number {
  if (STYLE.brandArt === "bars" || STYLE.brandArt === "slab") return H - 236 - 22;
  if (STYLE.hud === "lower") return H - LOWER - 18;
  if (STYLE.hud === "status") return H - 66;
  if (STYLE.hud === "bands") return H - 14;
  return H - 48;
}

/** The keys the person presses, one cap with what it does, for a moment. */
export function keycaps(): Node[] {
  const m = loadManifest();
  const footage = loadFootage();
  const out: Node[] = [];
  const bottom = keycapBottom();
  let n = 0;
  for (const a of ACTS) {
    const seg = footage.segments.find((s) => s.name === a.segment)!;
    for (const e of seg.events.filter((x): x is KeyEvent => x.type === "key")) {
      const s = m.keycaps[keycapKey(e.label, e.caption)];
      const f = a.from + e.f;
      const keep = 40;
      out.push(
        img(s.file, {
          id: `keycap-${n++}`,
          x: W - MARGIN - s.w + s.pad,
          y: bottom - s.h,
          width: s.w,
          height: s.h,
          anchorY: 0.5,
          from: f,
          to: f + keep + 8,
          tracks: {
            scale: [[f, 0.8], [f + 5, 1, "back.out(2.4)"]],
            opacity: [[f, 0], [f + 2, 1], [f + keep, 1], [f + keep + 7, 0, "power2.in"]],
          },
        }),
      );
    }
  }
  return out;
}
