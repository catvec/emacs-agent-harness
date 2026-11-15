/**
 * What the brand paints over the full-screen capture: scrims that make the HUD
 * readable, an edge or a bracket or a burst, a solid slab the title sits in.
 * It is drawn after the footage and before the falling UI, so the capture stays
 * the whole screen and the brand is an overlay on it, never a frame around a
 * smaller picture.
 */
import { ACTS } from "../timeline.js";
import { H, STYLE, W } from "../theme.js";
import { rgba } from "../kit/draw.js";
import { box, img, type Node } from "../kit/layers.js";
import { loadManifest } from "../kit/manifest.js";

const PAD = 100;

function scrim(id: string, from: "top" | "bottom", height: number, color: string, alpha: number): Node {
  const gradient = from === "top"
    ? `linear-gradient(180deg, ${rgba(color, alpha)} 0%, ${rgba(color, alpha * 0.55)} 55%, ${rgba(color, 0)} 100%)`
    : `linear-gradient(0deg, ${rgba(color, alpha)} 0%, ${rgba(color, alpha * 0.55)} 55%, ${rgba(color, 0)} 100%)`;
  return box({ id, x: 0, y: from === "top" ? 0 : H - height, width: W, height, background: gradient });
}

function corner(id: string, x: number, y: number, dx: number, dy: number, size: number, color: string, width = 3): Node[] {
  return [
    box({ id: `${id}-h`, x: dx > 0 ? x : x - size, y: dy > 0 ? y : y - width, width: size, height: width, background: color }),
    box({ id: `${id}-v`, x: dx > 0 ? x : x - width, y: dy > 0 ? y : y - size, width, height: size, background: color }),
  ];
}

export function brandOverlay(): Node[] {
  const m = loadManifest();
  const out: Node[] = [];
  const art = STYLE.brandArt;

  // Readability scrims, under the brand and the words.
  switch (art) {
    case "frame":
      out.push(scrim("scrim-top", "top", 210, STYLE.scrim, 0.72), scrim("scrim-bottom", "bottom", 260, STYLE.scrim, 0.86));
      break;
    case "rail":
      out.push(scrim("scrim-top", "top", 190, STYLE.scrim, 0.78), scrim("scrim-bottom", "bottom", 240, STYLE.scrim, 0.82));
      break;
    case "band":
      // A printed page: a solid head in the paper's colour, a soft wash at the foot.
      out.push(box({ id: "head", x: 0, y: 0, width: W, height: 152, background: STYLE.bg }), scrim("scrim-band", "bottom", 260, STYLE.scrim, 0.6));
      break;
    case "brackets":
      out.push(scrim("scrim-top", "top", 190, STYLE.scrim, 0.78), scrim("scrim-bottom", "bottom", 220, STYLE.scrim, 0.85));
      break;
    case "burst":
      out.push(scrim("scrim-top", "top", 150, STYLE.scrim, 0.35), scrim("scrim-bottom", "bottom", 190, STYLE.scrim, 0.55));
      break;
    case "rule":
      // A paper page: the words sit on a wash of the page, not on the picture.
      out.push(scrim("scrim-top", "top", 170, STYLE.scrim, 0.86), scrim("scrim-bottom", "bottom", 230, STYLE.scrim, 0.9));
      break;
    case "hairline":
      out.push(scrim("scrim-top", "top", 180, STYLE.scrim, 0.7), scrim("scrim-bottom", "bottom", 140, STYLE.scrim, 0.55));
      break;
    case "slab":
    case "bars":
      out.push(scrim("scrim-top", "top", 120, STYLE.scrim, 0.5));
      break;
    default:
      out.push(scrim("scrim-top", "top", 200, STYLE.scrim, 0.8), scrim("scrim-bottom", "bottom", 260, STYLE.scrim, 0.86));
  }

  if (art === "frame") {
    // A hard edge frame and the two neon corner blocks: the brand is the screen's own edge.
    out.push(
      box({ id: "edge", x: 0, y: 0, width: W, height: H, borderColor: STYLE.accent, borderWidth: 4 }),
      box({ id: "edge-2", x: 8, y: 8, width: W - 16, height: H - 16, borderColor: rgba(STYLE.accent2, 0.4), borderWidth: 1 }),
      box({ id: "beam", x: 1320, y: 110, width: 760, height: 4, background: STYLE.accent, rotation: -28, anchorX: 0, anchorY: 0.5, opacity: 0.9 }),
      box({ id: "beam-2", x: 1380, y: 150, width: 620, height: 2, background: STYLE.accent2, rotation: -28, anchorX: 0, anchorY: 0.5, opacity: 0.75 }),
    );
    out.push(
      ...corner("corner-tl", 20, 20, 1, 1, 54, STYLE.accent2),
      ...corner("corner-tr", W - 20, 20, -1, 1, 54, STYLE.accent),
      ...corner("corner-bl", 20, H - 20, 1, -1, 54, STYLE.accent),
      ...corner("corner-br", W - 20, H - 20, -1, -1, 54, STYLE.accent2),
    );
  } else if (art === "rail") {
    // A cobalt rail, an off-screen arc, a yellow rule: a broadcast ident.
    out.push(
      box({ id: "rail", x: 0, y: 0, width: 18, height: H, background: STYLE.accent }),
      box({ id: "rail-2", x: 24, y: 0, width: 2, height: H, background: rgba(STYLE.accent2, 0.9) }),
      box({ id: "arc", x: 1390, y: -300, width: 820, height: 820, borderRadius: 410, borderColor: rgba(STYLE.accent, 0.55), borderWidth: 12 }),
      box({ id: "rule", x: 40, y: 88, width: 620, height: 4, background: STYLE.accent2 }),
    );
  } else if (art === "band") {
    // A printed page over the capture: a grain, a hairline, a hard edge.
    if (m.halftone) out.push(img(m.halftone.file, { id: "grain", x: 0, y: 0, width: W, height: H, opacity: 0.16 }));
    out.push(
      box({ id: "head-rule", x: 0, y: 152, width: W, height: 4, background: STYLE.accent2 }),
      box({ id: "left-rule", x: 26, y: 0, width: 2, height: H, background: rgba(STYLE.accent, 0.7) }),
      box({ id: "top-rule", x: 0, y: 0, width: W, height: 2, background: rgba(STYLE.text, 0.5) }),
      box({ id: "band-edge", x: 0, y: H - 4, width: W, height: 4, background: STYLE.accent2 }),
    );
  } else if (art === "brackets") {
    // A grid over the picture, brackets at the corners, one live label.
    if (STYLE.scanlines && m.scanlines) out.push(img(m.scanlines.file, { id: "scan", x: 0, y: 0, width: W, height: H, opacity: 0.45 }));
    for (let x = 160; x < W; x += 160) out.push(box({ id: `gx-${x}`, x, y: 0, width: 1, height: H, background: rgba(STYLE.accent, 0.07) }));
    for (let y = 120; y < H; y += 120) out.push(box({ id: `gy-${y}`, x: 0, y, width: W, height: 1, background: rgba(STYLE.accent, 0.07) }));
    out.push(
      box({ id: "edge", x: 0, y: 0, width: W, height: H, borderColor: rgba(STYLE.accent, 0.35), borderWidth: 2 }),
      ...corner("br-tl", 26, 26, 1, 1, 64, STYLE.accent),
      ...corner("br-tr", W - 26, 26, -1, 1, 64, STYLE.accent),
      ...corner("br-bl", 26, H - 26, 1, -1, 64, STYLE.accent),
      ...corner("br-br", W - 26, H - 26, -1, -1, 64, STYLE.accent),
      box({ id: "live", x: W - 316, y: H - 98, width: 12, height: 12, background: STYLE.accent }),
    );
  } else if (art === "burst") {
    // A printed riot over the capture: halftone, a burst, a black edge.
    if (m.halftone) out.push(img(m.halftone.file, { id: "halftone", x: -PAD, y: -PAD, width: W + PAD * 2, height: H + PAD * 2, opacity: 0.12 }));
    if (m.burst) {
      const impact = ACTS.find((a) => a.kind === "module")?.impact ?? 0;
      out.push(img(m.burst.file, { id: "burst", x: 960 - 600, y: 540 - 600, width: 1200, height: 1200, opacity: 0.5, tracks: { opacity: [[0, 0], [impact - 40, 0], [impact, 0.5], [impact + 30, 0.5], [impact + 110, 0, "power2.out"]] } }));
    }
    out.push(box({ id: "edge", x: 0, y: 0, width: W, height: H, borderColor: STYLE.ink, borderWidth: 8 }));
  } else if (art === "slab") {
    // A solid field of the accent along the bottom: the title is knocked out of it.
    out.push(
      box({ id: "slab", x: 0, y: H - 236, width: W, height: 236, background: STYLE.accent }),
      box({ id: "slab-rule", x: 0, y: H - 240, width: W, height: 4, background: STYLE.accent }),
      box({ id: "top-edge", x: 0, y: 0, width: W, height: 6, background: STYLE.accent }),
    );
    if (STYLE.scanlines && m.scanlines) out.push(img(m.scanlines.file, { id: "scan", x: 0, y: 0, width: W, height: H, opacity: 0.3 }));
  } else if (art === "bars") {
    // Solid bands top and bottom, like a broadcast safe area.
    out.push(
      box({ id: "bottom-bar", x: 0, y: H - 236, width: W, height: 236, background: STYLE.hudFill ?? STYLE.panel }),
      box({ id: "bottom-rule", x: 0, y: H - 240, width: W, height: 4, background: STYLE.accent }),
      box({ id: "bottom-edge", x: 0, y: H - 6, width: W, height: 6, background: STYLE.accent }),
    );
  } else if (art === "rule") {
    // An editorial page: a paper masthead, hairlines at the margins, a short red rule under the brand.
    out.push(
      box({ id: "masthead", x: 0, y: 0, width: W, height: 92, background: STYLE.bg }),
      box({ id: "masthead-rule", x: 0, y: 92, width: W, height: 2, background: rgba(STYLE.text, 0.55) }),
      box({ id: "bottom-hair", x: 0, y: H - 2, width: W, height: 2, background: rgba(STYLE.text, 0.35) }),
      box({ id: "left-hair", x: 64, y: 92, width: 2, height: H - 92, background: rgba(STYLE.text, 0.18) }),
      box({ id: "brand-rule", x: 48, y: 56, width: 210, height: 4, background: STYLE.accent }),
    );
  } else if (art === "hairline") {
    // A technical sheet: a black strip at the head, a hairline at the foot, one red mark.
    out.push(
      box({ id: "strip", x: 0, y: 0, width: W, height: 290, background: STYLE.bg }),
      box({ id: "strip-rule", x: 0, y: 290, width: W, height: 1, background: rgba(STYLE.text, 0.22) }),
      box({ id: "mark", x: W - 34, y: 26, width: 12, height: 12, background: STYLE.accent }),
      box({ id: "foot", x: 26, y: H - 44, width: W - 52, height: 1, background: rgba(STYLE.text, 0.25) }),
    );
  }

  return out;
}
