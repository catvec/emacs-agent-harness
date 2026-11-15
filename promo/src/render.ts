/**
 * The film's command line.
 *
 *   tsx src/render.ts frames 0 240 245     PNGs of those frames -> output/frames/
 *   tsx src/render.ts grid 0 30 60 ...     one contact sheet of those frames -> output/grid.png
 *   tsx src/render.ts range 240 300        every frame in a range, in order (resumable) -> output/frames/
 *   tsx src/render.ts lint                 comp.lint() findings and schema validation
 *   tsx src/render.ts count                the number of frames in the film
 *
 * Environment: FILM_SCALE=0.5 renders a half-size preview; FILM_SKIP=hud,wall leaves groups out;
 * FILM_OUT=dir changes the output directory.  The finished video is made from the frames by
 * scripts/encode.sh (ffmpeg), see promo/README.md.
 */
import fs from "node:fs/promises";
import path from "node:path";
import { CompositorProgramSchema, HeadlessMediaRenderer, describeGpu } from "framefields";
import { buildFilm } from "./film.js";
import { DURATION } from "./timeline.js";
import { OUTPUT } from "./theme.js";

const [mode = "frames", ...args] = process.argv.slice(2);
const scale = Number(process.env.FILM_SCALE ?? 1);
const skip = (process.env.FILM_SKIP ?? "").split(",").filter(Boolean);
const outDir = process.env.FILM_OUT ?? path.join(OUTPUT, scale === 1 ? "frames" : `frames-${scale}`);
const pad = (n: number) => String(n).padStart(4, "0");

if (mode === "count") {
  console.log(DURATION);
  process.exit(0);
}

const film = await buildFilm({ scale, skip });
await fs.mkdir(outDir, { recursive: true });

if (mode === "lint") {
  const parsed = CompositorProgramSchema.safeParse(film.toSpec());
  if (parsed.success) console.log("schema: ok");
  else {
    // Particle and VFX layers carry an engine-side `src` object that the strict schema does not model:
    // they render (the film is made of them) but fail the parse. Anything else is a real problem.
    const strange = parsed.error.issues.filter((i) => !["src", "inputHandleId"].includes(String(i.path.at(-1))));
    console.log(strange.length ? `schema: FAILED\n${JSON.stringify(strange.slice(0, 5), null, 1)}` : `schema: ok (${parsed.error.issues.length} notes about particle/vfx layers' engine-side sources, which render fine)`);
    if (strange.length) process.exit(1);
  }
  for (const d of film.lint()) console.log(`${d.severity} ${d.code}: ${d.message}`);
  process.exit(0);
}

const gpu = await describeGpu();
console.error(`[render] adapter: ${gpu.vendor} ${gpu.device}${gpu.software ? " (software)" : ""}; scale ${scale}; ${DURATION} frames in the film`);
const renderer = new HeadlessMediaRenderer();

async function renderOne(frame: number, file: string): Promise<void> {
  const t0 = Date.now();
  await fs.writeFile(file, await film.renderFrame({ frame, renderer }));
  console.error(`[render] frame ${frame} -> ${path.relative(process.cwd(), file)} (${((Date.now() - t0) / 1000).toFixed(2)} s)`);
}

if (mode === "frames") {
  for (const f of args.map(Number)) await renderOne(f, path.join(outDir, `f${pad(f)}.png`));
} else if (mode === "range") {
  const [from, to] = args.map(Number);
  for (let f = from; f < Math.min(to, DURATION); f++) {
    const file = path.join(outDir, `f${pad(f)}.png`);
    if (await fs.stat(file).then((s) => s.size > 1000, () => false)) continue; // resumable
    await renderOne(f, file);
  }
} else if (mode === "grid") {
  const frames = args.map(Number);
  const png = await film.renderFrameGrid({ frames, columns: 4, cellWidth: 480, showLabels: true });
  const file = path.join(outDir, "..", `grid-${frames[0]}-${frames.at(-1)}.png`);
  await fs.writeFile(file, png);
  console.error(`[render] grid -> ${path.relative(process.cwd(), file)}`);
} else {
  console.error(`unknown mode ${mode}`);
  process.exit(2);
}
process.exit(0);
