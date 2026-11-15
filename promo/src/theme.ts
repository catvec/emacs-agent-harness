/**
 * Design tokens for the film: the only place with magic numbers.
 * Design space is 1920x1080; `buildFilm({ scale })` renders it smaller for previews.
 */
import path from "node:path";
import { fileURLToPath } from "node:url";
import { FontManager } from "framefields";
import { STYLE } from "./style.js";

export { STYLE };

export const W = 1920;
export const H = 1080;

const HERE = path.dirname(fileURLToPath(import.meta.url));
export const ROOT = path.resolve(HERE, "..");
export const REPO = path.resolve(ROOT, "..");
export const ASSETS = path.join(ROOT, "assets");
export const BUILD = path.join(ROOT, "build");
export const BAKED = path.join(BUILD, "baked", STYLE.id);
export const FOOTAGE = path.join(BUILD, "footage");
export const OUTPUT = path.join(ROOT, "output");
export const DOCS_MEDIA = path.join(REPO, "docs", "media");

export const asset = (...p: string[]) => path.join(ASSETS, ...p);
export const baked = (...p: string[]) => path.join(BAKED, ...p);

// ---------------------------------------------------------------------------
// Colour: near-black violet, and neons.
// ---------------------------------------------------------------------------
// The palette is the style's (`style.ts`): every scene and every baked sprite
// reads these names, so a style is a data change, not a redraw.
export const BG = STYLE.bg; // the page
export const BG_2 = STYLE.bg2;
export const INK = STYLE.ink; // the hole the monitor cuts, as in the Emacs captures
export const DIM = STYLE.dim; // commented-out text
export const MUTED = STYLE.muted;
export const TEXT = STYLE.text;
export const WHITE = STYLE.white;
export const SCRIM = STYLE.scrim; // what darkens the footage behind a title

export const MAGENTA = STYLE.accent;
export const CYAN = STYLE.accent2;
export const LIME = STYLE.accent3;
export const AMBER = STYLE.accent4;
export const VIOLET = STYLE.accent5;

/** One neon per act, in the order the modules come: the film's accents. */
export const ACCENTS = [MAGENTA, CYAN, LIME, AMBER, VIOLET];

// ---------------------------------------------------------------------------
// Type
// ---------------------------------------------------------------------------
export const DISPLAY = STYLE.display; // the title face of the active style
export const DISPLAY_WEIGHT = STYLE.displayWeight;
export const TRACKING = STYLE.displayTracking;
export const MONO = STYLE.mono; // what the Emacs captures are set in

const FONT_FILES = [
  { family: "Unbounded", file: "Unbounded.ttf" },
  { family: "Hack", file: "Hack-Regular.ttf" },
  { family: "Noto Sans", file: "NotoSans-Bold.ttf" },
  { family: "Noto Sans Black", file: "NotoSans-Black.ttf" },
  { family: "Noto Serif Black", file: "NotoSerif-Black.ttf" },
  { family: "Anton", file: "Anton-Regular.ttf" },
  { family: "Bebas Neue", file: "BebasNeue-Regular.ttf" },
  { family: "DM Serif Display", file: "DMSerifDisplay-Regular.ttf" },
  { family: "Archivo Black", file: "ArchivoBlack-Regular.ttf" },
  { family: "Space Grotesk", file: "SpaceGrotesk[wght].ttf" },
  { family: "JetBrains Mono", file: "JetBrainsMono[wght].ttf" },
] as const;

export const FONT_PATHS = FONT_FILES.map((f) => asset("fonts", f.file));

export async function registerFonts(): Promise<void> {
  for (const f of FONT_FILES) await FontManager.register({ family: f.family, source: asset("fonts", f.file) });
}

// ---------------------------------------------------------------------------
// Layout: the Emacs footage is a monitor in the middle of the screen, with a band above and below
// it for the film's own words (the brand and the module count; what the keys do).
// ---------------------------------------------------------------------------
/** The footage is exactly this size (promo/capture/promo-rec.el). */
export const SHOT_W = 2400;
export const SHOT_H = 1350;

/** Footage pixels to screen pixels at rest, and where the monitor sits (`style.ts`). */
export const MON_SCALE = STYLE.mon.scale;
export const MON_W = SHOT_W * MON_SCALE;
export const MON_H = SHOT_H * MON_SCALE;
export const MON_X = STYLE.mon.x ?? (W - MON_W) / 2;
export const MON_Y = STYLE.mon.y ?? (H - MON_H) / 2;
export const MON_CX = MON_X + MON_W / 2;
export const MON_CY = MON_Y + MON_H / 2;
export const MON_ROTATE = STYLE.mon.rotate ?? 0;

/** The screen position of a point of the footage, at rest. */
export const screenX = (x: number) => MON_X + x * MON_SCALE;
export const screenY = (y: number) => MON_Y + y * MON_SCALE;

// ---------------------------------------------------------------------------
// Motion vocabulary
// ---------------------------------------------------------------------------
export const EASE_OUT = "expo.out";
export const EASE_IN = "power3.in";
export const EASE_FALL = "power2.in"; // gravity: speeds up into the hit
export const EASE_SNAP = "back.out(1.7)";
