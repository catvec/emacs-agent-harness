/**
 * The style proposals, one picture and one short clip per style in `style.ts`.
 *
 *   tsx src/style-sheet.ts          output/styles/proposals/NN-<id>.png, .mp4, and output/styles-reel.mp4
 *   tsx src/style-sheet.ts stills   only the pictures
 *   tsx src/style-sheet.ts cards    only the reel's chapter cards
 *
 * The picture is frame 400 of the real cut in that style (the title slam), so
 * the story, the footage and the clock are the same in all six.  A clip is one
 * second of that style's card, then the frame held for three seconds.
 *
 * The frame has to exist first: `PROMO_STYLE=<id> npm run prep` then
 * `PROMO_STYLE=<id> FILM_OUT=output/styles/<id> npm run frames -- 400`.
 */
import { execFileSync } from "node:child_process";
import fs from "node:fs/promises";
import path from "node:path";
import { loadImage, newCanvas, savePng, useFonts, type Ctx } from "./kit/draw.js";
import { STYLES, type Style } from "./style.js";
import { BUILD, OUTPUT } from "./theme.js";

useFonts();

const FRAME = 400;
const W = 1920;
const H = 1080;
const pad = (n: number) => String(n).padStart(2, "0");
const dir = path.join(OUTPUT, "styles");
const proposals = path.join(dir, "proposals");

function styleType(ctx: Ctx, style: Style, size: number, weight: number): void {
  ctx.font = `${weight} ${size}px ${style.display}`;
}

function wrap(ctx: Ctx, s: string, max: number): string[] {
  const words = s.split(" ");
  const lines: string[] = [];
  let line = "";
  for (const w of words) {
    const next = line ? `${line} ${w}` : w;
    if (ctx.measureText(next).width > max && line) {
      lines.push(line);
      line = w;
    } else line = next;
  }
  if (line) lines.push(line);
  return lines;
}

function swatches(ctx: Ctx, style: Style, x: number, y: number): void {
  for (const [i, c] of [style.bg, style.accent, style.accent2, style.accent3, style.panel].entries()) {
    ctx.fillStyle = c;
    ctx.fillRect(x + i * 30, y, 26, 26);
    ctx.strokeStyle = style.rule;
    ctx.lineWidth = 1;
    ctx.strokeRect(x + i * 30 + 0.5, y + 0.5, 26, 26);
  }
}

/** The still of frame 400, copied next to the others under its number. */
async function stills(): Promise<void> {
  await fs.mkdir(proposals, { recursive: true });
  for (const [i, style] of STYLES.entries()) {
    const src = path.join(dir, style.id, `f${String(FRAME).padStart(4, "0")}.png`);
    const out = path.join(proposals, `${pad(i + 1)}-${style.id}.png`);
    try {
      await fs.stat(src);
    } catch {
      throw new Error(`${path.relative(process.cwd(), src)} is missing: render frame ${FRAME} in ${style.id} first`);
    }
    await fs.copyFile(src, out);
    console.log(`[style-sheet] ${path.relative(process.cwd(), out)}`);
  }
}

/** A chapter card for a clip: the style's name and blurb, in the style itself. */
async function card(style: Style, i: number): Promise<string> {
  const { canvas, ctx } = newCanvas(W, H);
  ctx.fillStyle = style.bg;
  ctx.fillRect(0, 0, W, H);
  // The style's own texture, when it has one.
  for (const [name, alpha] of [["grid", 0.9], ["scanlines", 1], ["halftone", 0.8]] as const) {
    const f = path.join(BUILD, "baked", style.id, `${name}.png`);
    if (await fs.stat(f).then((s) => s.size > 1000, () => false)) {
      ctx.globalAlpha = alpha;
      ctx.drawImage(await loadImage(f), -100, -100, 2120, 1280);
      ctx.globalAlpha = 1;
    }
  }
  // A hard frame, the way the style frames the monitor.
  ctx.strokeStyle = style.rule;
  ctx.lineWidth = style.border;
  ctx.strokeRect(60, 60, 1800, 960);

  ctx.fillStyle = style.accent;
  ctx.font = `800 150px ${style.display}`;
  ctx.fillText(pad(i + 1), 120, 330);
  styleType(ctx, style, 96, style.displayWeight);
  ctx.fillStyle = style.text;
  ctx.fillText(style.name, 120, 500);
  ctx.font = "34px Hack";
  ctx.fillStyle = style.muted;
  const lines = wrap(ctx, style.blurb, 1400);
  lines.slice(0, 2).forEach((l, n) => ctx.fillText(l, 120, 586 + n * 44));
  swatches(ctx, style, 120, 780);
  ctx.font = "24px Hack";
  ctx.fillStyle = style.accent;
  ctx.fillText(`TASK BOARD · frame ${FRAME}`, 120, 900);
  const out = path.join(dir, "cards", `${style.id}.png`);
  await savePng(canvas, out);
  console.log(`[style-sheet] ${path.relative(process.cwd(), out)}`);
  return out;
}

/** One clip per style: its card for a second, then the still held for three. */
async function clips(): Promise<void> {
  await fs.mkdir(proposals, { recursive: true });
  const list: string[] = [];
  for (const [i, style] of STYLES.entries()) {
    const c = await card(style, i);
    const still = path.join(proposals, `${pad(i + 1)}-${style.id}.png`);
    const out = path.join(proposals, `${pad(i + 1)}-${style.id}.mp4`);
    execFileSync(
      "ffmpeg",
      [
        "-v", "error", "-y",
        "-loop", "1", "-framerate", "30", "-t", "1", "-i", c,
        "-loop", "1", "-framerate", "30", "-t", "3", "-i", still,
        "-filter_complex",
        "[0:v]scale=1920:1080,setsar=1,format=yuv420p[a];[1:v]scale=1920:1080,setsar=1,format=yuv420p[b];[a][b]concat=n=2:v=1:a=0[out]",
        "-map", "[out]", "-r", "30", "-c:v", "libx264", "-preset", "medium", "-crf", "20", "-movflags", "+faststart",
        out,
      ],
      { stdio: "inherit" },
    );
    console.log(`[style-sheet] ${path.relative(process.cwd(), out)}`);
    list.push(out);
  }
  // The whole set as one reel.
  const reel = path.join(OUTPUT, "styles-reel.mp4");
  const listFile = path.join(BUILD, "style-reel.txt");
  await fs.mkdir(BUILD, { recursive: true });
  await fs.writeFile(listFile, list.map((f) => `file '${path.resolve(f).replace(/'/g, "'\\''")}'`).join("\n") + "\n");
  execFileSync("ffmpeg", ["-v", "error", "-y", "-f", "concat", "-safe", "0", "-i", listFile, "-c", "copy", "-movflags", "+faststart", reel], { stdio: "inherit" });
  console.log(`[style-sheet] ${path.relative(process.cwd(), reel)}`);
}

const mode = process.argv[2] ?? "all";
if (mode === "stills") await stills();
else if (mode === "cards") {
  for (const [i, style] of STYLES.entries()) await card(style, i);
} else if (mode === "clips") {
  await stills();
  await clips();
} else {
  await stills();
  await clips();
}
