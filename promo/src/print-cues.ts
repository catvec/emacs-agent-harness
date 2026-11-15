/**
 * Print the film's clock and cue sheet: `npm run cues`.  For whoever writes sound to the picture.  It also writes
 * build/cues.json, which scripts/sync-check.py reads to hold the finished file against the clock.
 */
import fs from "node:fs";
import path from "node:path";
import { BUILD } from "./theme.js";
import { ACTS, BARS, BAR, CUES, DURATION, ENERGY, FALL, FPS, SECONDS, SECTIONS, TENSION, at } from "./timeline.js";

console.log(`${DURATION} frames, ${BARS} bars, ${SECONDS} s; 120 BPM: beat 15 frames, bar ${BAR}`);
console.log(`fall ${FALL} frames, tension ${TENSION} frames before it\n`);
console.log("acts:");
for (const a of ACTS) console.log(`  ${a.id.padEnd(8)} ${a.kind.padEnd(7)} frames ${a.from}..${a.to} (${a.frames}), impact ${a.impact} = bar ${a.impact / BAR}`);
console.log("\nsections:");
for (const s of SECTIONS) console.log(`  bars ${String(s.from).padStart(2)}..${String(s.to).padEnd(2)} ${s.id.padEnd(7)} ${s.note}`);
console.log(`\nenergy per bar: ${ENERGY.map((e) => e.toFixed(2)).join(" ")}`);
const counts = new Map<string, number>();
for (const c of CUES) counts.set(c.kind, (counts.get(c.kind) ?? 0) + 1);
console.log(`\ncues (${CUES.length}): ${[...counts].map(([k, n]) => `${k} ${n}`).join(", ")}`);
for (const c of CUES.filter((x) => x.kind !== "type")) {
  const bar = Math.floor(c.frame / BAR);
  const beat = ((c.frame - at(bar, 0)) / 15).toFixed(2);
  console.log(`  frame ${String(c.frame).padStart(4)}  bar ${String(bar).padStart(2)} beat ${beat}  ${c.kind.padEnd(9)} ${c.label ?? ""} ${c.text ?? ""}`);
}

fs.mkdirSync(BUILD, { recursive: true });
fs.writeFileSync(path.join(BUILD, "cues.json"), `${JSON.stringify({ fps: FPS, durationFrames: DURATION, acts: ACTS, cues: CUES.filter((c) => c.kind !== "type") }, null, 1)}\n`);
