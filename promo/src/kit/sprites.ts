/**
 * The film's sprites, drawn once with skia-canvas: the monitor's frame, the card
 * that falls, keycaps, the pointer and its ripple, titles and callouts, and the
 * textures of the page.  The look is data: every shape and treatment below comes
 * from the active style (`style.ts`), so a style is a record, not a redraw.
 */
import { Canvas, flatText, hardStroke, loadImage, newCanvas, rgba, savePng, useFonts } from "./draw.js";
import type { TitleKind } from "../style.js";
import { STYLE } from "../style.js";
import { DISPLAY, MON_H, MON_W, TEXT, WHITE, baked } from "../theme.js";

export interface Sprite {
  /** Path relative to build/baked/. */
  file: string;
  /** Pixel size of the PNG. */
  w: number;
  h: number;
  /** Transparent margin around the art, in px. */
  pad: number;
  /** Where the art's origin is in the PNG, when it is not the margin (the pointer's tip). */
  hot?: [number, number];
}

const save = async (name: string, canvas: Canvas): Promise<string> => {
  await savePng(canvas, baked(name));
  return name;
};

// ---------------------------------------------------------------------------
// The monitor's frame
// ---------------------------------------------------------------------------
export async function bakeMonitorFrame(name: string, color: string): Promise<Sprite> {
  const kind = STYLE.frame;
  if (kind === "none") {
    const { canvas } = newCanvas(2, 2);
    return { file: await save(name, canvas), w: 2, h: 2, pad: 1 };
  }
  const pad = kind === "registration" ? 30 : kind === "offset" ? 36 : kind === "thick" ? 18 : 12;
  const w = MON_W + pad * 2;
  const h = MON_H + pad * 2;
  const { canvas, ctx } = newCanvas(w, h);
  const x = pad;
  const y = pad;

  if (kind === "offset") {
    // A print shadow: a solid slab, then the frame, then a white hairline inside.
    ctx.fillStyle = STYLE.text;
    ctx.fillRect(x + 20, y + 20, MON_W, MON_H);
    hardStroke(ctx, () => ctx.rect(x, y, MON_W, MON_H), STYLE.text, STYLE.border);
    hardStroke(ctx, () => ctx.rect(x + STYLE.border + 4, y + STYLE.border + 4, MON_W - (STYLE.border + 4) * 2, MON_H - (STYLE.border + 4) * 2), rgba(WHITE, 0.9), 2);
    return { file: await save(name, canvas), w, h, pad };
  }

  if (kind === "thick") {
    // A hard offset shadow, a heavy cream frame, a hairline of accent inside.
    ctx.fillStyle = "rgba(0,0,0,0.5)";
    ctx.fillRect(x + 14, y + 14, MON_W, MON_H);
    hardStroke(ctx, () => ctx.rect(x, y, MON_W, MON_H), color, STYLE.border);
    hardStroke(ctx, () => ctx.rect(x + STYLE.border + 5, y + STYLE.border + 5, MON_W - (STYLE.border + 5) * 2, MON_H - (STYLE.border + 5) * 2), rgba(STYLE.accent, 0.55), 2);
    return { file: await save(name, canvas), w, h, pad };
  }

  if (kind === "registration") {
    // A drawing's crop marks: a hairline frame, long corner ticks and mid-edge ticks.
    hardStroke(ctx, () => ctx.rect(x, y, MON_W, MON_H), color, 1.5);
    ctx.strokeStyle = color;
    ctx.lineWidth = 2;
    const long = 26;
    const gap = 8;
    for (const [cx, cy, sx, sy] of [
      [x, y, -1, -1],
      [x + MON_W, y, 1, -1],
      [x, y + MON_H, -1, 1],
      [x + MON_W, y + MON_H, 1, 1],
    ] as const) {
      ctx.beginPath();
      ctx.moveTo(cx + sx * gap, cy);
      ctx.lineTo(cx + sx * (gap + long), cy);
      ctx.moveTo(cx, cy + sy * gap);
      ctx.lineTo(cx, cy + sy * (gap + long));
      ctx.stroke();
    }
    for (const [cx, cy, dx, dy] of [
      [x + MON_W / 2, y, 0, -1],
      [x + MON_W / 2, y + MON_H, 0, 1],
      [x, y + MON_H / 2, -1, 0],
      [x + MON_W, y + MON_H / 2, 1, 0],
    ] as const) {
      ctx.beginPath();
      ctx.moveTo(cx + dx * 4, cy + dy * 4);
      ctx.lineTo(cx + dx * 22, cy + dy * 22);
      ctx.stroke();
    }
    return { file: await save(name, canvas), w, h, pad };
  }

  // corners and hairline
  hardStroke(ctx, () => ctx.rect(x, y, MON_W, MON_H), color, kind === "hairline" ? Math.max(1, STYLE.border - 1) : STYLE.border);
  hardStroke(ctx, () => ctx.rect(x + 5, y + 5, MON_W - 10, MON_H - 10), rgba(color, kind === "hairline" ? 0.18 : 0.3), 1);
  if (kind === "corners") {
    const long = 24;
    const thick = 6;
    for (const [cx, cy] of [
      [x - 4, y - 4],
      [x + MON_W + 4 - thick, y - 4],
      [x - 4, y + MON_H + 4 - thick],
      [x + MON_W + 4 - thick, y + MON_H + 4 - thick],
    ]) {
      ctx.fillStyle = color;
      ctx.fillRect(cx, cy, long, thick);
      ctx.fillRect(cx, cy, thick, long);
    }
  }
  return { file: await save(name, canvas), w, h, pad };
}

// ---------------------------------------------------------------------------
// A card: a crop of the footage, inside the style's frame
// ---------------------------------------------------------------------------
export async function bakeCard(name: string, shot: string, rect: [number, number, number, number], color: string): Promise<Sprite & { cw: number; ch: number }> {
  const [sx, sy, cw, ch] = rect;
  const pad = 18;
  const w = cw + pad * 2 + (STYLE.frame === "offset" ? 12 : 0);
  const h = ch + pad * 2 + (STYLE.frame === "offset" ? 12 : 0);
  const { canvas, ctx } = newCanvas(w, h);
  if (STYLE.frame === "offset") {
    ctx.fillStyle = STYLE.text;
    ctx.fillRect(pad + 10, pad + 10, cw + 4, ch + 4);
  }
  const img = await loadImage(shot);
  ctx.drawImage(img, sx, sy, cw, ch, pad, pad, cw, ch);
  hardStroke(ctx, () => ctx.rect(pad - 2, pad - 2, cw + 4, ch + 4), color, STYLE.border);
  hardStroke(ctx, () => ctx.rect(pad, pad, cw, ch), rgba(WHITE, 0.22), 1);
  return { file: await save(name, canvas), w, h, pad, cw, ch };
}

// ---------------------------------------------------------------------------
// Keycaps: one shape per style
// ---------------------------------------------------------------------------
export interface Keycap extends Sprite {
  label: string;
  caption: string;
}

export async function bakeKeycap(name: string, label: string, caption: string, color: string): Promise<Keycap> {
  useFonts();
  const kind = STYLE.keycap;
  const keySize = kind === "stamp" ? 26 : 27;
  const capSize = 22;
  const probe = newCanvas(10, 10).ctx;
  probe.font = `bold ${keySize}px ${STYLE.mono}`;
  const labelW = Math.ceil(probe.measureText(label).width);
  const keyW = labelW + (kind === "underline" ? 4 : 30);
  probe.font = `${capSize}px ${STYLE.mono}`;
  const capW = caption ? Math.ceil(probe.measureText(caption).width) + 22 : 0;
  const pad = kind === "stamp" ? 18 : 12;
  const boxH = kind === "underline" ? keySize + 12 : 42;
  const w = keyW + capW + pad * 2 + (caption ? 18 : 0);
  const h = boxH + pad * 2 + (kind === "stamp" ? 8 : 0);
  const { canvas, ctx } = newCanvas(w, h);
  const x = pad;
  const y = pad;

  if (kind === "stamp") {
    // A solid block with a hard black shadow: a sticker, not a key.
    ctx.fillStyle = STYLE.text;
    ctx.fillRect(x + 7, y + 7, keyW, boxH);
    ctx.fillStyle = color;
    ctx.fillRect(x, y, keyW, boxH);
    hardStroke(ctx, () => ctx.rect(x, y, keyW, boxH), STYLE.text, 3);
    ctx.font = `bold ${keySize}px ${STYLE.mono}`;
    ctx.fillStyle = STYLE.text;
    ctx.fillText(label, x + (keyW - labelW) / 2, y + boxH / 2 + keySize * 0.34);
  } else if (kind === "underline") {
    ctx.font = `bold ${keySize}px ${STYLE.mono}`;
    ctx.fillStyle = color;
    ctx.fillText(label, x, y + keySize);
    ctx.fillStyle = color;
    ctx.fillRect(x - 2, y + keySize + 5, keyW, 4);
  } else if (kind === "note") {
    ctx.fillStyle = STYLE.panel;
    ctx.fillRect(x, y, keyW, boxH);
    ctx.fillStyle = STYLE.text;
    ctx.fillRect(x, y, keyW, 5);
    ctx.font = `bold ${keySize}px ${STYLE.mono}`;
    ctx.fillStyle = STYLE.text;
    ctx.fillText(label, x + 10, y + boxH / 2 + keySize * 0.34);
  } else {
    // A square key: a panel face, a hard edge, a block of the neon on the left.
    ctx.fillStyle = STYLE.panel;
    ctx.fillRect(x, y, keyW, boxH);
    hardStroke(ctx, () => ctx.rect(x, y, keyW, boxH), color, Math.max(2, STYLE.border - 0.5));
    ctx.fillStyle = color;
    ctx.fillRect(x + 8, y + 8, 4, boxH - 16);
    ctx.font = `bold ${keySize}px ${STYLE.mono}`;
    ctx.fillStyle = color;
    ctx.fillText(label, x + 20, y + boxH / 2 + keySize * 0.34);
  }
  if (caption) {
    ctx.font = `${capSize}px ${STYLE.mono}`;
    ctx.fillStyle = kind === "underline" ? rgba(STYLE.text, 0.75) : rgba(TEXT, 0.82);
    ctx.fillText(caption, x + keyW + 18, y + boxH / 2 + capSize * 0.34);
  }
  return { file: await save(name, canvas), w, h, pad, label, caption };
}

// ---------------------------------------------------------------------------
// The pointer, and the ripple of a click
// ---------------------------------------------------------------------------
export async function bakePointer(name: string, _color: string): Promise<Sprite> {
  const pad = 22;
  const aw = 34;
  const ah = 50;
  const w = aw + pad * 2;
  const h = ah + pad * 2;
  const { canvas, ctx } = newCanvas(w, h);
  const arrow = () => {
    ctx.beginPath();
    ctx.moveTo(pad, pad);
    ctx.lineTo(pad, pad + ah * 0.84);
    ctx.lineTo(pad + aw * 0.27, pad + ah * 0.66);
    ctx.lineTo(pad + aw * 0.5, pad + ah);
    ctx.lineTo(pad + aw * 0.66, pad + ah * 0.93);
    ctx.lineTo(pad + aw * 0.43, pad + ah * 0.6);
    ctx.lineTo(pad + aw * 0.82, pad + ah * 0.6);
    ctx.closePath();
  };
  arrow();
  ctx.fillStyle = WHITE;
  ctx.fill();
  ctx.lineJoin = "miter";
  ctx.strokeStyle = STYLE.bg;
  ctx.lineWidth = 3;
  ctx.stroke();
  return { file: await save(name, canvas), w, h, pad, hot: [pad, pad] };
}

export async function bakeRipple(name: string, color: string): Promise<Sprite> {
  const size = 280;
  const { canvas, ctx } = newCanvas(size, size);
  hardStroke(ctx, () => { ctx.beginPath(); ctx.arc(size / 2, size / 2, size * 0.34, 0, Math.PI * 2); }, color, 4);
  hardStroke(ctx, () => { ctx.beginPath(); ctx.arc(size / 2, size / 2, size * 0.4, 0, Math.PI * 2); }, rgba(WHITE, 0.5), 1);
  return { file: await save(name, canvas), w: size, h: size, pad: 0 };
}

// ---------------------------------------------------------------------------
// Titles
// ---------------------------------------------------------------------------
export interface TextSprite extends Sprite {
  /** Width and height of the text itself (without the margin). */
  tw: number;
}

export interface TitleOptions {
  kind?: TitleKind;
  /** The case the type is set in; the story keeps its words. */
  case?: "upper" | "lower";
  weight?: number;
  tracking?: number;
  outline?: string;
  shadow?: string;
  shadowOffset?: number;
  plate?: string;
  second?: string;
  border?: number;
}

/**
 * A line of display type, treated as the style says: flat fill, outline, hard
 * offset shadow, a solid plate, a two-colour split or outline only.
 */
export async function bakeTitle(
  name: string,
  text: string,
  color: string,
  size: number,
  maxWidth = 1700,
  opts: TitleOptions = {},
): Promise<TextSprite> {
  useFonts();
  const shown = opts.case === "lower" ? text.toLowerCase() : text;
  const kind = opts.kind ?? STYLE.titleKind;
  const weight = opts.weight ?? STYLE.displayWeight;
  const tracking = opts.tracking ?? STYLE.displayTracking;
  const outlineColor = opts.outline ?? STYLE.titleOutline;
  const shadowColor = opts.shadow ?? STYLE.titleShadow;
  const shadowOffset = opts.shadowOffset ?? STYLE.titleShadowOffset;
  const second = opts.second ?? STYLE.titleSecond;
  const plateColor = opts.plate ?? STYLE.titlePlate;
  const probe = newCanvas(10, 10).ctx;
  probe.font = `${weight} ${size}px ${DISPLAY}`;
  probe.letterSpacing = `${tracking * size}px`;
  let fs = size;
  let tw = probe.measureText(shown).width;
  if (tw > maxWidth) {
    fs = Math.floor(size * (maxWidth / tw));
    probe.font = `${weight} ${fs}px ${DISPLAY}`;
    probe.letterSpacing = `${tracking * fs}px`;
    tw = probe.measureText(shown).width;
  }
  // A hard offset shadow is the whole treatment of `shadow`: no ring, just the offset.
  const outline = kind === "plain" || kind === "block" || kind === "shadow" ? 0 : Math.max(3, Math.round(fs * 0.05));
  const shift = kind === "plain" || kind === "block" ? 0 : Math.round(fs * shadowOffset);
  const platePadX = kind === "plate" || kind === "block" ? Math.round(fs * (kind === "block" ? 0.18 : 0.24)) : 0;
  const platePadY = kind === "plate" || kind === "block" ? Math.round(fs * (kind === "block" ? 0.1 : 0.1)) : 0;
  const border = opts.border ?? Math.max(3, Math.round(fs * 0.02));
  const pad = Math.round(fs * (kind === "plain" || kind === "block" ? 0.28 : 0.5)) + outline + shift + (kind === "plate" ? border : 0);
  const textW = Math.ceil(tw);
  const textH = Math.ceil(fs * 1.2);
  const w = textW + platePadX * 2 + pad * 2;
  const h = textH + platePadY * 2 + pad * 2;
  const { canvas, ctx } = newCanvas(w, h);
  ctx.font = `${weight} ${fs}px ${DISPLAY}`;
  ctx.letterSpacing = `${tracking * fs}px`;
  ctx.textBaseline = "alphabetic";
  const tx = pad + platePadX;
  const ty = pad + platePadY + fs * 0.9;

  if (kind === "block") {
    // A solid colour block with the words in it: no outline, no shadow.
    ctx.fillStyle = plateColor;
    ctx.fillRect(0, 0, w, h);
    ctx.fillStyle = color;
    ctx.fillText(shown, tx, ty);
  } else if (kind === "plate") {
    // A solid plate behind the words, with a hard shadow.
    if (shift) {
      ctx.fillStyle = shadowColor;
      ctx.fillRect(tx - platePadX + shift, ty - fs * 0.92 - platePadY + shift, textW + platePadX * 2, textH + platePadY * 2);
    }
    ctx.fillStyle = plateColor;
    ctx.fillRect(tx - platePadX, ty - fs * 0.92 - platePadY, textW + platePadX * 2, textH + platePadY * 2);
    hardStroke(ctx, () => ctx.rect(tx - platePadX, ty - fs * 0.92 - platePadY, textW + platePadX * 2, textH + platePadY * 2), outlineColor, border);
    ctx.fillStyle = color;
    ctx.fillText(shown, tx, ty);
  } else if (kind === "outlineOnly") {
    ctx.strokeStyle = color;
    ctx.lineWidth = Math.max(4, fs * 0.045);
    ctx.lineJoin = "miter";
    ctx.strokeText(shown, tx, ty);
  } else if (kind === "split") {
    if (shift) {
      ctx.fillStyle = shadowColor;
      ctx.fillText(shown, tx + shift, ty + shift);
    }
    if (outline) {
      ctx.strokeStyle = outlineColor;
      ctx.lineWidth = outline;
      ctx.lineJoin = "miter";
      ctx.strokeText(shown, tx, ty);
    }
    const mid = ty - fs * 0.36;
    ctx.save();
    ctx.beginPath();
    ctx.rect(0, 0, w, mid);
    ctx.clip();
    ctx.fillStyle = color;
    ctx.fillText(shown, tx, ty);
    ctx.restore();
    ctx.save();
    ctx.beginPath();
    ctx.rect(0, mid, w, h - mid);
    ctx.clip();
    ctx.fillStyle = second;
    ctx.fillText(shown, tx, ty);
    ctx.restore();
  } else {
    flatText(ctx, text, tx, ty, color, {
      outline: outline ? outlineColor : undefined,
      outlineWidth: outline,
      shadow: shift ? { dx: shift, dy: shift, color: shadowColor } : undefined,
    });
  }
  return { file: await save(name, canvas), w, h, pad, tw: textW };
}

/** A flat line of mono text (a tagline). */
export async function bakeMonoLine(name: string, text: string, color: string, size: number, opts: { bold?: boolean } = {}): Promise<TextSprite> {
  useFonts();
  const font = `${opts.bold ? "bold " : ""}${size}px ${STYLE.mono}`;
  const probe = newCanvas(10, 10).ctx;
  probe.font = font;
  const tw = Math.ceil(probe.measureText(text).width);
  const pad = Math.round(size * 0.4);
  const w = tw + pad * 2;
  const h = Math.ceil(size * 1.4) + pad * 2;
  const { canvas, ctx } = newCanvas(w, h);
  ctx.font = font;
  ctx.textBaseline = "alphabetic";
  flatText(ctx, text, pad, pad + size * 1.02, color);
  return { file: await save(name, canvas), w, h, pad, tw };
}

// ---------------------------------------------------------------------------
// Callouts: one shape per style
// ---------------------------------------------------------------------------
export async function bakeCallout(name: string, text: string, color: string, size = 36): Promise<TextSprite & { boxW: number; boxH: number }> {
  useFonts();
  const kind = STYLE.callout;
  const probe = newCanvas(10, 10).ctx;
  const font = `${size}px ${STYLE.mono}`;
  probe.font = font;
  const tw = Math.ceil(probe.measureText(text).width);
  const bar = kind === "box" ? 8 : 0;
  const boxH = Math.round(size * (kind === "terminal" ? 1.35 : kind === "note" ? 1.6 : 1.55));
  const lead = kind === "terminal" ? size * 1.35 : kind === "annotation" ? size * 1.2 : kind === "sticker" ? size * 0.9 : kind === "note" ? size * 0.9 : size * 1.1;
  const boxW = tw + Math.round(lead) + bar + 20;
  const shadow = kind === "sticker" ? 9 : kind === "ticket" ? 6 : 0;
  const pad = 10 + shadow;
  const w = boxW + pad * 2;
  const h = boxH + pad * 2;
  const { canvas, ctx } = newCanvas(w, h);
  const x = pad;
  const y = pad;

  if (kind === "terminal") {
    // A selection bar on a terminal: a black panel, a prompt, one rule under it.
    ctx.fillStyle = rgba(STYLE.calloutFill, 0.94);
    ctx.fillRect(x, y, boxW, boxH);
    ctx.fillStyle = color;
    ctx.fillRect(x, y + boxH - 2, boxW, 2);
    ctx.font = `bold ${size}px ${STYLE.mono}`;
    ctx.fillStyle = color;
    ctx.fillText(">", x + 14, y + boxH / 2 + size * 0.34);
    ctx.font = font;
    ctx.fillStyle = STYLE.calloutText;
    ctx.fillText(text, x + 14 + size * 0.9, y + boxH / 2 + size * 0.34);
  } else if (kind === "annotation") {
    // A drawing's label: a hairline box, a crosshair index, no fill but a wash.
    ctx.fillStyle = rgba(STYLE.calloutFill, 0.72);
    ctx.fillRect(x, y, boxW, boxH);
    hardStroke(ctx, () => ctx.rect(x, y, boxW, boxH), color, Math.max(1, STYLE.border - 1));
    ctx.fillStyle = color;
    ctx.fillRect(x, y + boxH / 2 - 1, 10, 2);
    ctx.strokeStyle = color;
    ctx.lineWidth = 2;
    ctx.strokeRect(x + boxW - 16, y + 6, 10, 10);
    ctx.font = font;
    ctx.fillStyle = STYLE.calloutText;
    ctx.fillText(text, x + 22, y + boxH / 2 + size * 0.34);
  } else if (kind === "ticket") {
    // A broadcast caption: solid cream, a red top rule, a hard shadow.
    ctx.fillStyle = "rgba(0,0,0,0.45)";
    ctx.fillRect(x + shadow, y + shadow, boxW, boxH);
    ctx.fillStyle = STYLE.calloutFill;
    ctx.fillRect(x, y, boxW, boxH);
    ctx.fillStyle = color;
    ctx.fillRect(x, y, boxW, 9);
    hardStroke(ctx, () => ctx.rect(x, y, boxW, boxH), color, 4);
    ctx.font = `bold ${size}px ${STYLE.mono}`;
    ctx.fillStyle = STYLE.calloutText;
    ctx.fillText(text, x + 18, y + boxH / 2 + size * 0.4);
  } else if (kind === "rule") {
    // A line of text on the page: a short rule in the act's colour, no box.
    ctx.fillStyle = color;
    ctx.fillRect(x, y + 4, 8, boxH - 8);
    ctx.font = font;
    ctx.fillStyle = STYLE.calloutText;
    ctx.fillText(text, x + 24, y + boxH / 2 + size * 0.34);
  } else if (kind === "note") {
    // A margin note: paper, a black top rule, a red index square.
    ctx.fillStyle = STYLE.calloutFill;
    ctx.fillRect(x, y, boxW, boxH);
    ctx.fillStyle = STYLE.calloutText;
    ctx.fillRect(x, y, boxW, 6);
    ctx.fillStyle = color;
    ctx.fillRect(x + 12, y + 16, 12, 12);
    ctx.font = font;
    ctx.fillStyle = STYLE.calloutText;
    ctx.fillText(text, x + 34, y + boxH / 2 + size * 0.34);
  } else if (kind === "sticker") {
    // A die-cut sticker: white fill, black outline, black shadow, a red tab.
    ctx.fillStyle = STYLE.calloutText;
    ctx.fillRect(x + shadow, y + shadow, boxW, boxH);
    ctx.fillStyle = STYLE.calloutFill;
    ctx.fillRect(x, y, boxW, boxH);
    hardStroke(ctx, () => ctx.rect(x, y, boxW, boxH), STYLE.calloutText, 5);
    ctx.fillStyle = color;
    ctx.fillRect(x, y, 12, boxH);
    ctx.font = `bold ${size}px ${STYLE.mono}`;
    ctx.fillStyle = STYLE.calloutText;
    ctx.fillText(text, x + 26, y + boxH / 2 + size * 0.34);
  } else {
    // The hard box: a panel, a solid edge, a neon bar.
    ctx.fillStyle = rgba(STYLE.calloutFill, 0.95);
    ctx.fillRect(x, y, boxW, boxH);
    hardStroke(ctx, () => ctx.rect(x, y, boxW, boxH), color, Math.max(2, STYLE.border - 1));
    ctx.fillStyle = color;
    ctx.fillRect(x + 1, y + 1, bar, boxH - 2);
    ctx.font = font;
    ctx.fillStyle = STYLE.calloutText;
    ctx.fillText(text, x + bar + 20, y + boxH / 2 + size * 0.34);
  }
  return { file: await save(name, canvas), w, h, pad, tw, boxW, boxH };
}

// ---------------------------------------------------------------------------
// The page's textures
// ---------------------------------------------------------------------------
/** The stage's grid, baked whole: 1 px lines, a brighter line every fourth. */
export async function bakeGrid(name: string, width: number, height: number, step: number, color: string | null): Promise<Sprite> {
  const { canvas, ctx } = newCanvas(width, height);
  if (!color) return { file: await save(name, canvas), w: width, h: height, pad: 0 };
  for (let x = 0; x < width; x += step) {
    ctx.strokeStyle = rgba(color, x % (step * 4) === 0 ? 0.3 : 0.14);
    ctx.lineWidth = x % (step * 4) === 0 ? 1.6 : 1;
    ctx.beginPath();
    ctx.moveTo(x + 0.5, 0);
    ctx.lineTo(x + 0.5, height);
    ctx.stroke();
  }
  for (let y = 0; y < height; y += step) {
    ctx.strokeStyle = rgba(color, y % (step * 4) === 0 ? 0.3 : 0.14);
    ctx.lineWidth = y % (step * 4) === 0 ? 1.6 : 1;
    ctx.beginPath();
    ctx.moveTo(0, y + 0.5);
    ctx.lineTo(width, y + 0.5);
    ctx.stroke();
  }
  return { file: await save(name, canvas), w: width, h: height, pad: 0 };
}

/** A full-page CRT rule: one dark line every four pixels. */
export async function bakeScanlines(name: string, width: number, height: number): Promise<Sprite> {
  const { canvas, ctx } = newCanvas(width, height);
  ctx.fillStyle = "rgba(0,0,0,0.16)";
  for (let y = 0; y < height; y += 4) ctx.fillRect(0, y, width, 1);
  return { file: await save(name, canvas), w: width, h: height, pad: 0 };
}

/** A staggered halftone dot field, for the printed styles. */
export async function bakeHalftone(name: string, width: number, height: number, step: number, color: string, alpha = 0.22): Promise<Sprite> {
  const { canvas, ctx } = newCanvas(width, height);
  ctx.fillStyle = rgba(color, alpha);
  for (let y = 0, row = 0; y < height + step; y += step, row++) {
    for (let x = (row % 2) * step * 0.5; x < width + step; x += step) {
      ctx.beginPath();
      ctx.arc(x, y, step * 0.14, 0, Math.PI * 2);
      ctx.fill();
    }
  }
  return { file: await save(name, canvas), w: width, h: height, pad: 0 };
}

/** A 16-point starburst, the comic shape behind the arcade frame. */
export async function bakeBurst(name: string, size: number, fill: string, outline: string): Promise<Sprite> {
  const { canvas, ctx } = newCanvas(size, size);
  const c = size / 2;
  const points = 16;
  ctx.beginPath();
  for (let i = 0; i < points * 2; i++) {
    const a = (i / (points * 2)) * Math.PI * 2 - Math.PI / 2;
    const r = i % 2 === 0 ? c * 0.94 : c * 0.66;
    const px = c + Math.cos(a) * r;
    const py = c + Math.sin(a) * r;
    if (i === 0) ctx.moveTo(px, py);
    else ctx.lineTo(px, py);
  }
  ctx.closePath();
  ctx.fillStyle = fill;
  ctx.fill();
  ctx.lineJoin = "miter";
  ctx.strokeStyle = outline;
  ctx.lineWidth = 10;
  ctx.stroke();
  return { file: await save(name, canvas), w: size, h: size, pad: 0 };
}

/** The retro sun: a hot disc cut by horizontal bands, for the broadcast style. */
export async function bakeSun(name: string, size: number, top: string, bottom: string, cut: string): Promise<Sprite> {
  const { canvas, ctx } = newCanvas(size, size);
  const c = size / 2;
  const g = ctx.createLinearGradient(0, 0, 0, size);
  g.addColorStop(0, top);
  g.addColorStop(1, bottom);
  ctx.beginPath();
  ctx.arc(c, c, c * 0.96, 0, Math.PI * 2);
  ctx.fillStyle = g;
  ctx.fill();
  // The classic cut: bands of the page across the lower half of the disc.
  ctx.fillStyle = cut;
  for (let i = 0; i < 9; i++) {
    const y = c + i * (c * 0.105);
    const h = 4 + i * 1.6;
    ctx.fillRect(c - c, y, size, h);
  }
  hardStroke(ctx, () => { ctx.beginPath(); ctx.arc(c, c, c * 0.96, 0, Math.PI * 2); }, "rgba(0,0,0,0.35)", 2);
  return { file: await save(name, canvas), w: size, h: size, pad: 0 };
}
