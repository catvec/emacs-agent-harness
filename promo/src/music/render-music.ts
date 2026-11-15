/**
 * `npm run music` -> build/score.wav (48 kHz stereo 16-bit, exactly the film's length), plus the QA's artefacts
 * in build/: score-report.json, score-cues.json, score-spectrogram.png, score-waveform.png.
 *
 * The score is generated, not sampled: this directory is the whole instrument.  Original work, part of the
 * harness (GPL-3.0-or-later).  Deterministic: the same timeline gives the same bytes (the report prints the SHA-256).
 * Exit status 1 when the QA finds a problem (the WAV is written first, so it can be looked at).
 */
// The footage log is chosen while the timeline is imported: this import must stay first.
import "./footage-source.js";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import * as timeline from "../timeline.js";
import { runQa } from "./qa.js";
import { buildScore } from "./score.js";

const HERE = path.dirname(fileURLToPath(import.meta.url));
export const BUILD = path.resolve(HERE, "../../build");

function main(): void {
  const t0 = Date.now();
  fs.mkdirSync(BUILD, { recursive: true });
  console.log("composing, mixing, mastering...");
  const score = buildScore(timeline);
  const c = score.comp;
  console.log(
    `  ${c.log.length} logged events, ${c.session.kicks.length} kicks, ${c.expect.length} cue sounds (${c.dropped.length} typing ticks thinned), ` +
      `${score.info.passes} level passes: ${score.info.lufs.toFixed(2)} LUFS, true peak ${score.info.truePeakDb.toFixed(2)} dBTP (${((Date.now() - t0) / 1000).toFixed(1)}s)`,
  );
  const file = path.join(BUILD, "score.wav");
  fs.writeFileSync(file, score.wav);
  console.log(`wrote ${path.relative(process.cwd(), file)} (${(score.wav.length / 1e6).toFixed(2)} MB, sha256 ${score.sha256})`);

  console.log("analysing...");
  const ok = runQa({ file, build: BUILD, score, timeline, rebuild: () => buildScore(timeline) });
  console.log(`done in ${((Date.now() - t0) / 1000).toFixed(1)}s`);
  if (!ok && !process.env.SCORE_QA_WARN_ONLY) process.exitCode = 1;
}

main();
