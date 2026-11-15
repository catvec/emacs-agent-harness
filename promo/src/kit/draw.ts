/**
 * Canvas drawing helpers for the baked sprites (neon strokes, pills, glows, text).
 *
 * Everything glowing in the film is drawn once here with skia-canvas and shown as an
 * image: a layer effect's glow costs ~0.5-0.8 s per layer per frame on the CPU adapter,
 * a baked sprite costs about nothing (see promo/README.md, "Why baked glow").
 */
import fs from "node:fs/promises";
import path from "node:path";
import { Canvas, FontLibrary, loadImage, type CanvasRenderingContext2D, type Image } from "skia-canvas";
import { asset } from "../theme.js";

export type Ctx = CanvasRenderingContext2D;
export { Canvas, loadImage };
export type { Image };

let fontsReady = false;
export function useFonts(): void {
  if (fontsReady) return;
  FontLibrary.use("Unbounded", [asset("fonts", "Unbounded.ttf")]);
  FontLibrary.use("Hack", [asset("fonts", "Hack-Regular.ttf"), asset("fonts", "Hack-Bold.ttf")]);
  FontLibrary.use("Noto Sans", [asset("fonts", "NotoSans-Bold.ttf")]);
  FontLibrary.use("Noto Sans Black", [asset("fonts", "NotoSans-Black.ttf")]);
  FontLibrary.use("Noto Serif Black", [asset("fonts", "NotoSerif-Black.ttf")]);
  FontLibrary.use("Anton", [asset("fonts", "Anton-Regular.ttf")]);
  FontLibrary.use("Bebas Neue", [asset("fonts", "BebasNeue-Regular.ttf")]);
  FontLibrary.use("DM Serif Display", [asset("fonts", "DMSerifDisplay-Regular.ttf")]);
  FontLibrary.use("Archivo Black", [asset("fonts", "ArchivoBlack-Regular.ttf")]);
  FontLibrary.use("Space Grotesk", [asset("fonts", "SpaceGrotesk[wght].ttf")]);
  FontLibrary.use("JetBrains Mono", [asset("fonts", "JetBrainsMono[wght].ttf")]);
  fontsReady = true;
}

export const hex = (c: string): [number, number, number] => {
  const h = c.replace("#", "");
  return [parseInt(h.slice(0, 2), 16), parseInt(h.slice(2, 4), 16), parseInt(h.slice(4, 6), 16)];
};
export const rgba = (c: string, a: number): string => {
  const [r, g, b] = hex(c);
  return `rgba(${r},${g},${b},${a})`;
};
/** Mix two #rrggbb colours (t = 0 -> a, t = 1 -> b), in sRGB: good enough for neon ramps. */
export const mix = (a: string, b: string, t: number): string => {
  const [ar, ag, ab] = hex(a);
  const [br, bg, bb] = hex(b);
  const f = (x: number, y: number) => Math.round(x + (y - x) * t);
  return `#${[f(ar, br), f(ag, bg), f(ab, bb)].map((v) => v.toString(16).padStart(2, "0")).join("")}`;
};

export function newCanvas(w: number, h: number): { canvas: Canvas; ctx: Ctx } {
  const canvas = new Canvas(Math.ceil(w), Math.ceil(h));
  const ctx = canvas.getContext("2d");
  ctx.textBaseline = "alphabetic";
  return { canvas, ctx };
}

export async function savePng(canvas: Canvas, file: string): Promise<void> {
  await fs.mkdir(path.dirname(file), { recursive: true });
  await fs.writeFile(file, await canvas.toBuffer("png"));
}

export function roundRectPath(ctx: Ctx, x: number, y: number, w: number, h: number, r: number): void {
  ctx.beginPath();
  ctx.roundRect(x, y, w, h, r);
}

/**
 * A neon tube: the path stroked several times, wide and faint to narrow and bright, with a
 * white-hot core, additively blended so overlapping glows build up like light.
 */
export function neonStroke(ctx: Ctx, path: () => void, color: string, opts: { width?: number; halo?: number; core?: number } = {}): void {
  const width = opts.width ?? 3;
  const halo = opts.halo ?? 40;
  const core = opts.core ?? 0.85;
  ctx.save();
  ctx.globalCompositeOperation = "lighter";
  ctx.lineJoin = "round";
  ctx.lineCap = "round";
  ctx.shadowColor = color;
  for (const [blur, alpha, wmul] of [
    [halo, 0.55, 1.6],
    [halo * 0.5, 0.7, 1.3],
    [halo * 0.2, 0.9, 1.0],
  ] as const) {
    ctx.shadowBlur = blur;
    ctx.strokeStyle = rgba(color, alpha);
    ctx.lineWidth = width * wmul;
    path();
    ctx.stroke();
  }
  ctx.shadowBlur = 0;
  ctx.strokeStyle = rgba("#ffffff", core);
  ctx.lineWidth = Math.max(1, width * 0.38);
  path();
  ctx.stroke();
  ctx.restore();
}

/** Glowing text: halo layers in the colour, then a brighter, whiter core. */
export function neonText(
  ctx: Ctx,
  text: string,
  x: number,
  y: number,
  color: string,
  opts: { halo?: number; core?: number; alpha?: number } = {},
): void {
  const halo = opts.halo ?? 22;
  const alpha = opts.alpha ?? 1;
  ctx.save();
  ctx.globalAlpha = alpha;
  ctx.shadowColor = color;
  ctx.fillStyle = color;
  ctx.shadowBlur = halo;
  ctx.fillText(text, x, y);
  ctx.shadowBlur = halo * 0.45;
  ctx.fillText(text, x, y);
  ctx.shadowBlur = 0;
  ctx.fillStyle = mix(color, "#ffffff", opts.core ?? 0.55);
  ctx.fillText(text, x, y);
  ctx.restore();
}

/**
 * A hard border: one solid stroke, square joins, no blur and no shadow.
 * The film's chrome is drawn with this, not with `neonStroke`: neon colours,
 * but the edge of a printed sticker.
 */
export function hardStroke(ctx: Ctx, path: () => void, color: string, width = 3): void {
  ctx.save();
  ctx.lineJoin = "miter";
  ctx.miterLimit = 2;
  ctx.lineCap = "butt";
  ctx.strokeStyle = color;
  ctx.lineWidth = width;
  path();
  ctx.stroke();
  ctx.restore();
}

/**
 * Text with hard edges: a flat fill, an optional solid outline around it, and
 * an optional solid copy offset behind it.  No glow, no blur.
 */
export function flatText(
  ctx: Ctx,
  text: string,
  x: number,
  y: number,
  fill: string,
  opts: { outline?: string; outlineWidth?: number; shadow?: { dx: number; dy: number; color: string }; alpha?: number } = {},
): void {
  ctx.save();
  ctx.globalAlpha = opts.alpha ?? 1;
  ctx.lineJoin = "miter";
  ctx.miterLimit = 2;
  if (opts.shadow) {
    ctx.fillStyle = opts.shadow.color;
    ctx.fillText(text, x + opts.shadow.dx, y + opts.shadow.dy);
  }
  // The outline goes on first: a centred stroke would otherwise cut into the fill.
  if (opts.outline) {
    ctx.strokeStyle = opts.outline;
    ctx.lineWidth = opts.outlineWidth ?? 3;
    ctx.strokeText(text, x, y);
  }
  ctx.fillStyle = fill;
  ctx.fillText(text, x, y);
  ctx.restore();
}
