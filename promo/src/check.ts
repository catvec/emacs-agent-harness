/**
 * `npm run check`: hold the film against the repository and against its own footage.
 *
 *  - every module an act enables is one `docs/modules/README.md` lists, in its own group;
 *  - every claim in words (story.ts CLAIMS) is found in the file it names, and every callout the footage draws has a claim;
 *  - the footage is the size the film's layout assumes, and its events fit their segments;
 *  - the acts of the timeline are all there, and the footage rectangles each act needs.
 */
import fs from "node:fs";
import path from "node:path";
import { loadFootage } from "./footage.js";
import { CLAIMS, MODULES } from "./story.js";
import { REPO, SHOT_H, SHOT_W } from "./theme.js";
import { ACTS, FALL } from "./timeline.js";

const problems: string[] = [];
const fail = (s: string) => problems.push(s);
const read = (file: string) => fs.readFileSync(path.join(REPO, file), "utf8");
const plain = (s: string) => s.replace(/[*_`]/g, "").replace(/\s+/g, " ").trim().toLowerCase();

// --- the modules an act enables -------------------------------------------------------------------
const docs = read("docs/modules/README.md");
const block = /```elisp\n([\s\S]*?)\n```/.exec(docs)?.[1] ?? "";
const groups = new Map<string, Set<string>>();
let group = "";
for (const line of block.split("\n")) {
  const g = /^ :(\w+)$/.exec(line);
  if (g) {
    group = `:${g[1]}`;
    groups.set(group, new Set());
    continue;
  }
  const m = /^ ;;(\S+)/.exec(line);
  if (m && group) groups.get(group)!.add(m[1]);
}
if (!groups.size) fail("docs/modules/README.md has no `harness-enable-modules` form to check the modules against");
for (const m of MODULES) {
  for (const g of m.init) {
    for (const name of g.names) {
      if (!groups.get(g.group)?.has(name)) fail(`${m.id}: ${g.group} ${name} is not a module in docs/modules/README.md`);
    }
  }
}

// --- the claims -------------------------------------------------------------------------------------
for (const c of CLAIMS) {
  if (c.source === "footage" || !c.quote) continue;
  if (!fs.existsSync(path.join(REPO, c.source))) {
    fail(`claim "${c.shown}": ${c.source} does not exist`);
    continue;
  }
  if (!plain(read(c.source)).includes(plain(c.quote))) fail(`claim "${c.shown}": ${c.source} does not say "${c.quote}"`);
}
const footage = loadFootage();
for (const seg of footage.segments) {
  for (const e of seg.events) {
    if (e.type === "callout" && !CLAIMS.some((c) => c.shown === e.text)) fail(`segment ${seg.name}: the callout "${e.text}" has no claim in story.ts`);
  }
}

// --- the footage ---------------------------------------------------------------------------------
if (footage.width !== SHOT_W || footage.height !== SHOT_H) fail(`the footage is ${footage.width}x${footage.height}, the layout assumes ${SHOT_W}x${SHOT_H}`);
for (const seg of footage.segments) {
  for (const e of seg.events) {
    if (e.f < 0 || e.f >= seg.frames) fail(`segment ${seg.name}: a ${e.type} at frame ${e.f}, outside its ${seg.frames} frames`);
    if (e.type === "click" && (e.xy[0] < 0 || e.xy[0] > SHOT_W || e.xy[1] < 0 || e.xy[1] > SHOT_H)) fail(`segment ${seg.name}: a click at ${e.xy} is off the footage`);
    if ("rect" in e) {
      const [x, y, w, h] = e.rect;
      if (x < 0 || y < 0 || x + w > SHOT_W || y + h > SHOT_H) fail(`segment ${seg.name}: a ${e.type} rectangle ${e.rect} is off the footage`);
    }
  }
}
for (const m of MODULES) {
  if (!footage.rects[m.landing]) fail(`${m.id}: the footage has no rectangle ${m.landing}`);
  if (!ACTS.some((a) => a.id === m.id)) fail(`${m.id}: no act in the timeline`);
}
for (const a of ACTS.filter((x) => x.kind === "module")) {
  if (a.impact - FALL < 0) fail(`${a.id}: its UI would start to fall before the film does`);
}
for (const file of ACTS.map((a) => path.join("build", "footage", `${a.segment}.mp4`))) {
  if (!fs.existsSync(path.join(path.resolve(REPO, "promo"), file))) fail(`${file} is missing: record the footage with promo/capture/capture.sh`);
}

if (problems.length) {
  console.error(`check: ${problems.length} problem(s)\n${problems.map((p) => `  - ${p}`).join("\n")}`);
  process.exit(1);
}
console.log(`check: ok (${MODULES.length} module act(s), ${CLAIMS.length} claims, ${footage.segments.length} footage segments)`);
