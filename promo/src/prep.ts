/**
 * `npm run prep`: bake the sprites the film shows into build/baked/<style>/ (gitignored), and write
 * build/baked/<style>/manifest.json with their sizes for film.ts.  What is baked follows from the footage log
 * (the keys pressed, the callouts drawn) and from story.ts (the titles), so a new module is data.
 *
 * A style (`style.ts`, chosen by `PROMO_STYLE`) changes the palette, the type and the weight of the
 * chrome; this pass bakes that style's sprites, so rendering a style is `PROMO_STYLE=x npm run prep &&
 * PROMO_STYLE=x npm run frames`.
 *
 * Deterministic: the same footage, style and code give the same sprites.
 */
import fs from "node:fs/promises";
import { loadFootage, segmentFirst, type CalloutEvent, type KeyEvent } from "./footage.js";
import { MODULES } from "./story.js";
import { CYAN, H, STYLE, VIOLET, W, BAKED } from "./theme.js";
import { keycapKey, type Manifest } from "./kit/manifest.js";
import {
  bakeBurst, bakeCallout, bakeCard, bakeGrid, bakeHalftone, bakeKeycap, bakeMonitorFrame, bakeMonoLine, bakePointer, bakeRipple, bakeScanlines, bakeTitle,
} from "./kit/sprites.js";
import { useFonts } from "./kit/draw.js";

useFonts();
await fs.rm(BAKED, { recursive: true, force: true });
await fs.mkdir(BAKED, { recursive: true });
const footage = loadFootage();
const t0 = Date.now();
const log = (s: string) => console.log(`[prep ${((Date.now() - t0) / 1000).toFixed(1)}s] ${s}`);

const manifest: Manifest = {
  monitor: {},
  cards: {},
  keycaps: {},
  pointer: await bakePointer("pointer.png", CYAN),
  ripple: await bakeRipple("ripple.png", CYAN),
  titles: {},
  lines: {},
  callouts: {},
  grid: await bakeGrid("grid.png", W + 200, H + 200, 60, STYLE.grid),
  scanlines: STYLE.scanlines ? await bakeScanlines("scanlines.png", W + 200, H + 200) : undefined,
  halftone: STYLE.brandArt === "burst" || STYLE.brandArt === "band" ? await bakeHalftone("halftone.png", W + 200, H + 200, 26, STYLE.ink, STYLE.brandArt === "burst" ? 0.2 : 0.1) : undefined,
  burst: STYLE.brandArt === "burst" ? await bakeBurst("burst.png", 1240, STYLE.accent2, STYLE.ink) : undefined,
  sun: undefined,
};

// The monitor's edge: violet while the harness is plain, then each module's neon.
manifest.monitor.plain = await bakeMonitorFrame("monitor-plain.png", VIOLET);
for (const m of MODULES) manifest.monitor[m.id] = await bakeMonitorFrame(`monitor-${m.id}.png`, m.accent);
log("monitor edges");

// The UI that falls: a crop of the footage's first frame of the act, at the rectangle the new UI takes.
for (const m of MODULES) {
  const rect = footage.rects[m.landing];
  if (!rect) throw new Error(`the footage has no rectangle ${m.landing}`);
  manifest.cards[m.id] = await bakeCard(`card-${m.id}.png`, segmentFirst(m.id), rect, m.accent);
}
log(`${MODULES.length} cards`);

// Keycaps: one per distinct key the footage logged.
let n = 0;
for (const seg of footage.segments) {
  for (const e of seg.events) {
    if (e.type !== "key") continue;
    const k = e as KeyEvent;
    const key = keycapKey(k.label, k.caption);
    if (!manifest.keycaps[key]) manifest.keycaps[key] = await bakeKeycap(`keycap-${n++}.png`, k.label, k.caption, CYAN);
  }
}
log(`${n} keycaps`);

// Callout labels, one per distinct text, in the neon of the act that draws it.
n = 0;
for (const seg of footage.segments) {
  const accent = MODULES.find((m) => m.id === seg.name)?.accent ?? CYAN;
  for (const e of seg.events) {
    if (e.type !== "callout") continue;
    const c = e as CalloutEvent;
    if (!manifest.callouts[c.text]) manifest.callouts[c.text] = await bakeCallout(`callout-${n++}.png`, c.text, accent);
  }
}
log(`${n} callouts`);

// Titles: what is slammed over the frame as the UI lands, and the lines under it.
for (const m of MODULES) {
  manifest.titles[m.id] = await bakeTitle(`title-${m.id}.png`, m.title, STYLE.titleFill, STYLE.titleSize, STYLE.titleMaxWidth, { case: STYLE.titleCase });
  // The one-liner under the title; the config itself is not shown: it is noise at README size.
  manifest.lines[`${m.id}-tag`] = await bakeCallout(`line-${m.id}-tag.png`, m.line, m.accent, 31);
}
manifest.titles.brand = await bakeTitle("title-brand.png", "EMACS AGENT HARNESS", STYLE.brandFill, 22, 700, { kind: "plain" });
manifest.titles.outro = await bakeTitle("title-outro.png", "EMACS AGENT HARNESS", STYLE.outroFill, 120, 1600, { kind: STYLE.outroKind, case: STYLE.titleCase });
manifest.lines.outro = await bakeMonoLine("line-outro.png", "plain Emacs. unreasonable power.", STYLE.outroTag, 38);
log("titles and lines");

await fs.writeFile(`${BAKED}/manifest.json`, `${JSON.stringify(manifest, null, 1)}\n`);
log("manifest written");
