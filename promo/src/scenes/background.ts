/**
 * The stage: the page each style lives on.  A grid and a drafting frame; a
 * terminal's scanlines; a blueprint's dimensions; a retro sun; a poster's
 * columns and red block; a printed halftone with a starburst.  Nothing here is
 * footage: this is the page the monitor sits on, and the shapes that give a
 * style its silhouette.
 */
import { BG, CYAN, H, MAGENTA, MON_H, MON_W, MON_X, MON_Y, MUTED, STYLE, VIOLET, W } from "../theme.js";
import { rgba } from "../kit/draw.js";
import { box, img, text, type Node } from "../kit/layers.js";
import { loadManifest } from "../kit/manifest.js";

/** The stage shakes: the background is bigger than the picture. */
const PAD = 100;

/** A hard line: three pixels of neon, square ends. */
function beam(id: string, color: string, x: number, y: number, length: number, angle: number, opacity: number): Node {
  return box({ id, x, y, width: length, height: 3, background: color, opacity, rotation: angle, anchorX: 0, anchorY: 0.5 });
}

/** A camera-framing corner: two hard ticks, 2 px thick. */
function corner(id: string, x: number, y: number, dx: number, dy: number, size: number, color: string): Node[] {
  return [
    box({ id: `${id}-h`, x: dx > 0 ? x : x - size, y: dy > 0 ? y : y - 2, width: size, height: 2, background: color }),
    box({ id: `${id}-v`, x: dx > 0 ? x : x - 2, y: dy > 0 ? y : y - size, width: 2, height: size, background: color }),
  ];
}

/** A dimension line with end ticks, the way a drawing measures a thing. */
function dimension(id: string, x: number, y: number, length: number, horizontal: boolean, color: string): Node[] {
  const out = [box({ id, x, y, width: horizontal ? length : 2, height: horizontal ? 2 : length, background: color })];
  const tick = 9;
  if (horizontal) {
    out.push(
      box({ id: `${id}-l`, x: x - 1, y: y - tick / 2, width: 2, height: tick, background: color }),
      box({ id: `${id}-r`, x: x + length - 1, y: y - tick / 2, width: 2, height: tick, background: color }),
    );
  } else {
    out.push(
      box({ id: `${id}-t`, x: x - tick / 2, y: y - 1, width: tick, height: 2, background: color }),
      box({ id: `${id}-b`, x: x - tick / 2, y: y + length - 1, width: tick, height: 2, background: color }),
    );
  }
  return out;
}

/** A small label in the page's margin. */
function label(id: string, content: string, x: number, y: number, size = 16, color = MUTED, align: "start" | "end" = "start"): Node {
  return text(content, {
    id,
    x: align === "end" ? x - 460 : x,
    y,
    width: 460,
    height: size * 2,
    fontFamily: STYLE.mono,
    fontSize: size,
    fill: color,
    letterSpacing: 2,
    align,
  });
}

export function background(): Node[] {
  const m = loadManifest();
  const out: Node[] = [];
  const art = STYLE.bgArt;

  // The page.
  out.push(box({ id: "bg", x: -PAD, y: -PAD, width: W + PAD * 2, height: H + PAD * 2, background: BG }));

  // A texture under everything, if the style has one.
  if (STYLE.grid) out.push(img(m.grid.file, { id: "grid", x: -PAD, y: -PAD, width: W + PAD * 2, height: H + PAD * 2, opacity: STYLE.gridOpacity }));
  if (art === "pop" && m.halftone) out.push(img(m.halftone.file, { id: "halftone", x: -PAD, y: -PAD, width: W + PAD * 2, height: H + PAD * 2, opacity: 0.95 }));

  if (art === "grid") {
    // The drafting frame, 38 px outside the monitor, with framing corners.
    const f = 38;
    out.push(
      box({ id: "blueprint", x: MON_X - f, y: MON_Y - f, width: MON_W + f * 2, height: MON_H + f * 2, borderColor: STYLE.rule, borderWidth: 2 }),
      ...corner("frame-tl", MON_X - f, MON_Y - f, 1, 1, 54, rgba(CYAN, 0.65)),
      ...corner("frame-tr", MON_X + MON_W + f, MON_Y - f, -1, 1, 54, rgba(CYAN, 0.65)),
      ...corner("frame-bl", MON_X - f, MON_Y + MON_H + f, 1, -1, 54, rgba(MAGENTA, 0.65)),
      ...corner("frame-br", MON_X + MON_W + f, MON_Y + MON_H + f, -1, -1, 54, rgba(MAGENTA, 0.65)),
    );
    // Laser lines crossing the void behind the monitor.
    out.push(
      beam("beam-cyan", CYAN, -140, 250, 760, 16, 0.4),
      beam("beam-violet", VIOLET, 1380, 140, 760, -22, 0.45),
      beam("beam-magenta", MAGENTA, -80, 860, 760, -12, 0.4),
      box({ id: "beam-cyan-band", x: -140, y: 256, width: 760, height: 10, background: rgba(CYAN, 0.07), rotation: 16, anchorX: 0, anchorY: 0.5 }),
      box({ id: "beam-violet-band", x: 1380, y: 146, width: 760, height: 10, background: rgba(VIOLET, 0.08), rotation: -22, anchorX: 0, anchorY: 0.5 }),
      box({ id: "beam-magenta-band", x: -80, y: 866, width: 760, height: 10, background: rgba(MAGENTA, 0.07), rotation: -12, anchorX: 0, anchorY: 0.5 }),
    );
    out.push(
      box({ id: "floor", x: -PAD, y: H - 66, width: W + PAD * 2, height: 2, background: STYLE.rule }),
      box({ id: "floor-tick-l", x: MON_X - f, y: H - 74, width: 2, height: 18, background: rgba(MAGENTA, 0.5) }),
      box({ id: "floor-tick-r", x: MON_X + MON_W + f - 2, y: H - 74, width: 2, height: 18, background: rgba(MAGENTA, 0.5) }),
    );
  } else if (art === "scan") {
    // A terminal's page: rules at the top and bottom, a column of ticks, no frame.
    out.push(
      box({ id: "scan-top", x: -PAD, y: 22, width: W + PAD * 2, height: 2, background: rgba(STYLE.accent, 0.5) }),
      box({ id: "scan-bottom", x: -PAD, y: H - 74, width: W + PAD * 2, height: 2, background: rgba(STYLE.accent, 0.32) }),
    );
    for (let i = 0; i < 14; i++) {
      out.push(box({ id: `scan-tick-${i}`, x: 22, y: 70 + i * 68, width: i % 4 === 0 ? 26 : 12, height: 2, background: rgba(STYLE.accent, 0.22) }));
    }
  } else if (art === "blueprint") {
    // A drawing sheet: a frame, dimensions, registration marks, and a title block.
    const f = 54;
    out.push(
      box({ id: "sheet", x: MON_X - f, y: MON_Y - f, width: MON_W + f * 2, height: MON_H + f * 2, borderColor: rgba(STYLE.accent, 0.55), borderWidth: 1.5 }),
      ...corner("sheet-tl", MON_X - f, MON_Y - f, 1, 1, 70, rgba(STYLE.accent, 0.8)),
      ...corner("sheet-tr", MON_X + MON_W + f, MON_Y - f, -1, 1, 70, rgba(STYLE.accent, 0.8)),
      ...corner("sheet-bl", MON_X - f, MON_Y + MON_H + f, 1, -1, 70, rgba(STYLE.accent, 0.8)),
      ...corner("sheet-br", MON_X + MON_W + f, MON_Y + MON_H + f, -1, -1, 70, rgba(STYLE.accent, 0.8)),
      ...dimension("dim-top", MON_X, MON_Y - 26, MON_W, true, rgba(STYLE.accent, 0.5)),
      ...dimension("dim-left", MON_X - 26, MON_Y, MON_H, false, rgba(STYLE.accent, 0.5)),
      label("dim-top-label", "1320", MON_X + MON_W / 2 - 40, MON_Y - 44, 15, rgba(STYLE.accent, 0.8)),
      label("dim-left-label", "742", MON_X - 82, MON_Y + MON_H / 2, 15, rgba(STYLE.accent, 0.8)),
      label("sheet-no", "DRAWING 03  /  TASK BOARD", 64, H - 158, 17, rgba(STYLE.text, 0.85)),
      label("sheet-scale", "SCALE 1:1", 64, H - 130, 14, rgba(STYLE.muted, 0.9)),
      label("sheet-fig", "FIG. 01", 64, H - 84, 14, rgba(STYLE.muted, 0.9)),
      label("sheet-rev", "REV. A  /  SHEET 03 OF 06", 64, H - 58, 14, rgba(STYLE.muted, 0.9)),
    );
    // Crosshair marks in the margins, the way a drawing finds a centre.
    for (const [cx, cy] of [[MON_X - 80, MON_Y - 80], [MON_X + MON_W + 80, MON_Y - 80], [MON_X - 80, MON_Y + MON_H + 80], [MON_X + MON_W + 80, MON_Y + MON_H + 80]] as const) {
      out.push(
        box({ id: `cross-${cx}-${cy}-h`, x: cx - 12, y: cy, width: 24, height: 1, background: rgba(STYLE.accent, 0.5) }),
        box({ id: `cross-${cx}-${cy}-v`, x: cx, y: cy - 12, width: 1, height: 24, background: rgba(STYLE.accent, 0.5) }),
      );
    }
  } else if (art === "sun") {
    // The sun, a horizon, stars and wide bands: a broadcast ident.
    if (m.sun) out.push(img(m.sun.file, { id: "sun", x: 960 - 590, y: 80, width: 1180, height: 1180, opacity: 0.95 }));
    for (const [i, [sx, sy, ss]] of [[80, 120, 4], [260, 70, 3], [1500, 110, 4], [1700, 210, 3], [1830, 90, 2], [740, 60, 3], [1180, 50, 2], [380, 250, 2], [1620, 330, 2], [90, 300, 3]].entries()) {
      out.push(box({ id: `star-${i}`, x: sx, y: sy, width: ss, height: ss, background: rgba(STYLE.accent4, 0.85) }));
    }
    out.push(
      box({ id: "horizon", x: -PAD, y: 812, width: W + PAD * 2, height: 3, background: rgba(STYLE.accent4, 0.65) }),
      box({ id: "horizon-2", x: -PAD, y: 832, width: W + PAD * 2, height: 1, background: rgba(STYLE.accent2, 0.4) }),
    );
    for (let i = 0; i < 6; i++) {
      out.push(box({ id: `sun-band-${i}`, x: -PAD, y: 860 + i * 34, width: W + PAD * 2, height: 12, background: rgba(STYLE.bg, 0.72 - i * 0.08) }));
    }
    out.push(box({ id: "floor", x: -PAD, y: H - 72, width: W + PAD * 2, height: 2, background: STYLE.rule }));
  } else if (art === "swiss") {
    // A poster: columns, a red block, a black rule, page numbers.  No texture.
    out.push(
      box({ id: "red-block", x: 0, y: H - 184, width: 456, height: 184, background: STYLE.accent }),
      box({ id: "red-circle", x: 330, y: H - 240, width: 190, height: 190, borderRadius: 95, background: STYLE.bg2 }),
      box({ id: "top-rule", x: 64, y: 44, width: W - 128, height: 2, background: rgba(STYLE.text, 0.55) }),
      box({ id: "bottom-rule", x: 520, y: H - 44, width: W - 64 - 520, height: 2, background: rgba(STYLE.text, 0.55) }),
      label("poster-kicker", "EMACS AGENT HARNESS  /  POSTER SERIES", 64, 30, 14, STYLE.text),
      label("poster-foot", "PLAIN EMACS. UNREASONABLE POWER.", 42, H - 58, 14, STYLE.white),
      label("poster-page", "05 / 06", W - 64, H - 28, 14, STYLE.text, "end"),
    );
    for (const x of [64, 300, 480, 960, 1440, 1856]) {
      out.push(box({ id: `col-${x}`, x, y: 44, width: 1, height: H - 88, background: rgba(STYLE.text, 0.08) }));
    }
    // A red rule under the title zone, and a black one under it.
    out.push(
      box({ id: "title-rule", x: 64, y: 286, width: 560, height: 8, background: STYLE.accent }),
      box({ id: "title-rule-2", x: 64, y: 302, width: 140, height: 2, background: STYLE.text }),
    );
  } else if (art === "pop") {
    // A printed riot: a starburst behind the monitor, black stars, a printed rule.
    if (m.burst) out.push(img(m.burst.file, { id: "burst", x: 960 - 620 + 20, y: 540 - 620 + 20, width: 1240, height: 1240, opacity: 0.92 }));
    for (const [i, [sx, sy, ss]] of [[90, 150, 70], [1760, 180, 56], [120, 900, 50], [1800, 840, 88], [1030, 80, 42]].entries()) {
      if (m.burst) out.push(img(m.burst.file, { id: `star-${i}`, x: sx, y: sy, width: ss, height: ss, opacity: 0.9 }));
    }
    out.push(
      box({ id: "pop-rule", x: -PAD, y: H - 68, width: W + PAD * 2, height: 4, background: STYLE.text }),
      box({ id: "pop-rule-2", x: -PAD, y: H - 56, width: W + PAD * 2, height: 2, background: rgba(STYLE.text, 0.35) }),
    );
  }

  // A CRT rule over the whole page, for the terminal styles.
  if (STYLE.scanlines && m.scanlines) out.push(img(m.scanlines.file, { id: "scanlines", x: -PAD, y: -PAD, width: W + PAD * 2, height: H + PAD * 2 }));

  return out;
}
