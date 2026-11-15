/**
 * Where the score reads the footage log from.  Import this module FIRST in an entry point: `timeline.ts`
 * reads the log while it is being imported, and ES modules evaluate their imports in order.
 *
 * The real log is `build/footage/footage.json`, written by `promo/capture/capture.sh` (it needs a display and
 * takes minutes).  `PROMO_FOOTAGE_LOG` names another log and always wins.  When neither the variable nor the
 * real log is there, the score is written against `footage-fixture.json` (a recorded log kept next to this
 * file) and says so loudly: good enough for working on the music, wrong for the finished film.
 */
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REAL = path.resolve(HERE, "../../build/footage/footage.json");
export const FIXTURE = path.join(HERE, "footage-fixture.json");

export type FootageSource = "env" | "recorded" | "fixture";

function pick(): FootageSource {
  const named = process.env.PROMO_FOOTAGE_LOG;
  if (named) {
    process.env.PROMO_FOOTAGE_LOG = path.resolve(named);
    return "env";
  }
  if (fs.existsSync(REAL)) return "recorded";
  process.env.PROMO_FOOTAGE_LOG = FIXTURE;
  console.warn(`[score] ${path.relative(process.cwd(), REAL)} is missing: scoring against the fixture ${path.relative(process.cwd(), FIXTURE)}.`);
  console.warn("[score] Record the footage (promo/capture/capture.sh) and run `npm run music` again before the finished film.");
  return "fixture";
}

/** Which log the timeline is read from (what the report says). */
export const FOOTAGE_SOURCE: FootageSource = pick();
export const FOOTAGE_LOG: string = process.env.PROMO_FOOTAGE_LOG ?? REAL;
