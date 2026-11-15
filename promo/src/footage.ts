/**
 * The footage and what the recorder logged about it (promo/capture/): the segments of real Emacs,
 * and, per segment, the marks, keys, clicks, highlights and callouts the story set, all in
 * footage pixels and in segment frames.  The film places segments on its own clock (timeline.ts).
 */
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { FOOTAGE, STYLE } from "./theme.js";

/** [x, y, width, height] in footage pixels. */
export type Rect = [x: number, y: number, w: number, h: number];

interface Base {
  /** Frame of the segment the event happens at. */
  f: number;
}
export interface TypingEvent extends Base {
  type: "typing";
  text: string;
  /** The segment frame of each character's key press. */
  frames: number[];
  to: number;
}
export interface KeyEvent extends Base {
  type: "key";
  keys: string;
  label: string;
  caption: string;
}
export interface ClickEvent extends Base {
  type: "click";
  xy: [number, number];
  label: string;
}
export interface HighlightEvent extends Base {
  type: "highlight";
  rect: Rect;
  label: string;
}
export interface CalloutEvent extends Base {
  type: "callout";
  rect: Rect;
  text: string;
  side: "below" | "above" | "left" | "right";
  frames: number;
}
export type FootageEvent = TypingEvent | KeyEvent | ClickEvent | HighlightEvent | CalloutEvent;

export interface Segment {
  name: string;
  /** Frames of footage. */
  frames: number;
  /** Named frames of the segment. */
  marks: Record<string, number>;
  events: FootageEvent[];
}

export interface Footage {
  fps: number;
  width: number;
  height: number;
  /** Windows, in footage pixels: where the new UI lands. */
  rects: Record<string, Rect>;
  segments: Segment[];
}

/** PROMO_FOOTAGE_LOG names another log (a fixture to write the score to when the footage is not at hand). */
const logFile = process.env.PROMO_FOOTAGE_LOG ?? path.join(FOOTAGE, "footage.json");

let cached: Footage | undefined;

/** The footage's log; throws, saying how to make it, when it is not there. */
export function loadFootage(): Footage {
  if (cached) return cached;
  if (!fs.existsSync(logFile)) {
    throw new Error(`${path.relative(process.cwd(), logFile)} is missing: record the footage with promo/capture/capture.sh`);
  }
  cached = JSON.parse(fs.readFileSync(logFile, "utf8")) as Footage;
  return cached;
}

// ---------------------------------------------------------------------------
// The grade: the style's ffmpeg filter chain, applied to the real footage so a
// brand changes the tone of the whole frame and not just the colour of the
// chrome.  Graded copies live under build/footage/graded/<style>/ and are made
// on first use; a small stamp beside them holds the filter, so changing a
// grade re-grades instead of showing the old one.
// ---------------------------------------------------------------------------
const gradedDir = () => path.join(FOOTAGE, "graded", STYLE.id);

function graded(src: string, out: string, args: string[]): string {
  const filter = STYLE.grade;
  if (!filter) return src;
  fs.mkdirSync(path.dirname(out), { recursive: true });
  const stamp = `${out}.grade`;
  if (fs.existsSync(out) && fs.existsSync(stamp) && fs.readFileSync(stamp, "utf8") === filter) return out;
  execFileSync("ffmpeg", ["-v", "error", "-y", "-i", src, "-vf", filter, ...args, out], { stdio: "inherit" });
  fs.writeFileSync(stamp, filter);
  return out;
}

/** The clip, graded for the active style. */
export const segmentVideo = (name: string) =>
  graded(
    path.join(FOOTAGE, `${name}.mp4`),
    path.join(gradedDir(), `${name}.mp4`),
    ["-an", "-c:v", "libx264", "-preset", "medium", "-crf", "10", "-pix_fmt", "yuv444p", "-profile:v", "high444", "-movflags", "+faststart"],
  );
export const segmentFirst = (name: string) =>
  graded(path.join(FOOTAGE, `${name}-first.png`), path.join(gradedDir(), `${name}-first.png`), ["-frames:v", "1"]);
export const segmentLast = (name: string) =>
  graded(path.join(FOOTAGE, `${name}-last.png`), path.join(gradedDir(), `${name}-last.png`), ["-frames:v", "1"]);

export function segment(name: string): Segment {
  const s = loadFootage().segments.find((x) => x.name === name);
  if (!s) throw new Error(`the footage has no segment ${name}`);
  return s;
}
