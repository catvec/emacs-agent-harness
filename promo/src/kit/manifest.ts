/** What `npm run prep` baked: the sprites' files and sizes, read by the film. */
import fs from "node:fs";
import path from "node:path";
import { BAKED } from "../theme.js";
import type { Keycap, Sprite, TextSprite } from "./sprites.js";

export interface Manifest {
  monitor: Record<string, Sprite>;
  cards: Record<string, Sprite & { cw: number; ch: number }>;
  keycaps: Record<string, Keycap>;
  pointer: Sprite;
  ripple: Sprite;
  titles: Record<string, TextSprite>;
  lines: Record<string, TextSprite & { boxW?: number; boxH?: number }>;
  callouts: Record<string, TextSprite & { boxW: number; boxH: number }>;
  grid: Sprite;
  /** Present only in styles that draw a CRT rule over the page. */
  scanlines?: Sprite;
  /** The printed styles' textures: a halftone field, a burst, a sun. */
  halftone?: Sprite;
  burst?: Sprite;
  sun?: Sprite;
}

const file = path.join(BAKED, "manifest.json");

let cached: Manifest | undefined;

/** The manifest, with every sprite's file made absolute; throws, saying how to make it, when it is missing. */
export function loadManifest(): Manifest {
  if (cached) return cached;
  if (!fs.existsSync(file)) throw new Error(`${path.relative(process.cwd(), file)} is missing: run \`npm run prep\``);
  const m = JSON.parse(fs.readFileSync(file, "utf8")) as Manifest;
  const abs = (s: Sprite) => {
    s.file = path.join(BAKED, s.file);
  };
  for (const group of [m.monitor, m.cards, m.keycaps, m.titles, m.lines, m.callouts]) Object.values(group).forEach(abs);
  abs(m.pointer);
  abs(m.ripple);
  abs(m.grid);
  if (m.scanlines) abs(m.scanlines);
  if (m.halftone) abs(m.halftone);
  if (m.burst) abs(m.burst);
  if (m.sun) abs(m.sun);
  cached = m;
  return m;
}

/** The key under which a keycap is baked. */
export const keycapKey = (label: string, caption: string) => `${label}|${caption}`;
