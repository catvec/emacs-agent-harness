/**
 * The film's clock: the one place that says WHEN things happen.  The picture (film.ts, scenes/) and the
 * score (music/) are both driven from here, so a crash on screen and the hit under it are the same number.
 *
 * 120 BPM at 30 fps: a beat is exactly 15 frames, a bar 60 frames (2 s).  Bars and beats are 0-based:
 * `at(4, 0)` is the first beat of the fifth bar, frame 240.
 *
 * The film is acts.  The first is the plain harness: real footage of a person asking it what it can do.
 * Each module after it is an act too: its UI falls onto the frame (the fall, then the impact on a
 * downbeat), and from the impact on the footage of the harness with that module is shown, in use.
 * What happens inside an act -- a key pressed, a task finished -- is as the recorder logged it
 * (promo/capture/), placed on this clock by the act's first frame.
 */
import { loadFootage, type CalloutEvent, type ClickEvent, type HighlightEvent, type KeyEvent, type TypingEvent } from "./footage.js";
import { MODULES } from "./story.js";

export const FPS = 30;
export const BPM = 120;
export const BEAT = (FPS * 60) / BPM; // 15 frames
export const BAR = BEAT * 4; // 60 frames

/** Frame of a bar/beat position (beat may be fractional: 0.5 = an eighth note). */
export const at = (bar: number, beat = 0): number => Math.round(bar * BAR + beat * BEAT);
export const seconds = (frame: number): number => frame / FPS;

/** Frames a UI element is in the air before it lands. */
export const FALL = 24;
/** Frames of tension before that: the frame trembles, the screen glitches, the score rises. */
export const TENSION = 36;

// ---------------------------------------------------------------------------
// The acts
// ---------------------------------------------------------------------------

export interface Act {
  id: string;
  kind: "plain" | "module";
  /** The footage segment shown. */
  segment: string;
  /** First film frame of the segment. */
  from: number;
  /** Frames of footage. */
  frames: number;
  /** One past the last film frame the segment's footage plays. */
  to: number;
  /** For a module act: the frame its UI lands (== from); for the plain act, the frame it ends (== to). */
  impact: number;
}

/** The plan: which segment goes where, as the bar its first frame is on. */
const PLAN: { id: string; kind: "plain" | "module"; bar: number }[] = [
  { id: "intro", kind: "plain", bar: 0 },
  { id: "tasks", kind: "module", bar: 6 },
];

const footage = loadFootage();

export const ACTS: Act[] = PLAN.map((p) => {
  const seg = footage.segments.find((s) => s.name === p.id);
  if (!seg) throw new Error(`the footage has no segment ${p.id}: record it with promo/capture/capture.sh`);
  const from = at(p.bar, 0);
  const to = from + seg.frames;
  return { id: p.id, kind: p.kind, segment: seg.name, from, frames: seg.frames, to, impact: p.kind === "module" ? from : to };
});

// Every act must be over before the next UI starts to fall.
ACTS.forEach((a, i) => {
  const next = ACTS[i + 1];
  if (next && a.to > next.impact - FALL) {
    throw new Error(`act ${a.id} runs to frame ${a.to}, but ${next.id} starts to fall at ${next.impact - FALL}: shorten its footage or move ${next.id} later`);
  }
});

export const act = (id: string): Act => {
  const a = ACTS.find((x) => x.id === id);
  if (!a) throw new Error(`no act ${id}`);
  return a;
};

/** Bars the outro takes after the last act: the name and its line sit for four seconds. */
export const OUTRO_BARS = 2;
export const BARS = Math.ceil(Math.max(...ACTS.map((a) => a.to)) / BAR) + OUTRO_BARS;
export const DURATION = BARS * BAR;
export const SECONDS = DURATION / FPS;
/** First frame of the outro. */
export const OUTRO = at(BARS - OUTRO_BARS, 0);

// ---------------------------------------------------------------------------
// Form, for the score
// ---------------------------------------------------------------------------

export type SectionId = "plain" | "module" | "outro";

export interface Section {
  id: SectionId;
  act?: string;
  /** First bar, inclusive. */
  from: number;
  /** Last bar, exclusive. */
  to: number;
  note: string;
}

/** The score's form: what each stretch of bars is for. */
export const SECTIONS: Section[] = [
  ...ACTS.map((a, i): Section => {
    const next = ACTS[i + 1];
    const to = (next ? next.impact : OUTRO) / BAR;
    return a.kind === "plain"
      ? { id: "plain", act: a.id, from: a.from / BAR, to, note: "The plain harness. Sparse and curious: a pulse, a few notes; the person types, the agent answers. Builds through the last bar to the fall." }
      : { id: "module", act: a.id, from: a.impact / BAR, to, note: "The UI has landed and is in use. The drop on the impact, then a groove under the footage; accents on what the person does." };
  }),
  { id: "outro", from: OUTRO / BAR, to: BARS, note: "The groove stops on the bar line; a last bright hit and a tail, for the end card." },
];

/** Energy hint per bar, 0..1 (the arrangement density the picture expects). */
export const ENERGY: number[] = Array.from({ length: BARS }, (_, bar) => {
  const s = SECTIONS.find((x) => bar >= x.from && bar < x.to)!;
  if (s.id === "plain") return [0.12, 0.18, 0.28, 0.45][Math.min(3, bar - s.from)] ?? 0.45;
  if (s.id === "module") return bar === s.from ? 1 : 0.85;
  return 0.3;
});

// ---------------------------------------------------------------------------
// Cues: the moments a score, or a sound, may answer, on the film's clock
// ---------------------------------------------------------------------------

export type CueKind =
  /** A key of the person's typing: one per character. */
  | "type"
  /** A key press with a keycap (C-c C-c). */
  | "key"
  /** A pointer click. */
  | "click"
  /** A callout is drawn. */
  | "callout"
  /** A card is lit. */
  | "highlight"
  /** A named moment of the footage: a task ready for review, a merge (`label` says which). */
  | "mark"
  /** A UI element starts to fall. */
  | "fall"
  /** It lands: the hit. */
  | "impact";

export interface Cue {
  frame: number;
  kind: CueKind;
  act: string;
  label?: string;
  text?: string;
}

const MARKS_WORTH_A_SOUND = /^(sent|submit-\d+|review-\d+|verify-\d+)$/;

export const CUES: Cue[] = (() => {
  const cues: Cue[] = [];
  for (const a of ACTS) {
    const seg = footage.segments.find((s) => s.name === a.segment)!;
    if (a.kind === "module") {
      cues.push({ frame: a.impact - FALL, kind: "fall", act: a.id });
      cues.push({ frame: a.impact, kind: "impact", act: a.id, label: MODULES.find((m) => m.id === a.id)?.title });
    }
    for (const e of seg.events) {
      const frame = a.from + e.f;
      switch (e.type) {
        case "typing":
          for (const f of (e as TypingEvent).frames) cues.push({ frame: a.from + f, kind: "type", act: a.id });
          break;
        case "key":
          cues.push({ frame, kind: "key", act: a.id, label: (e as KeyEvent).label, text: (e as KeyEvent).caption });
          break;
        case "click":
          cues.push({ frame, kind: "click", act: a.id, label: (e as ClickEvent).label });
          break;
        case "callout":
          cues.push({ frame, kind: "callout", act: a.id, text: (e as CalloutEvent).text });
          break;
        case "highlight":
          cues.push({ frame, kind: "highlight", act: a.id, label: (e as HighlightEvent).label });
          break;
      }
    }
    for (const [name, f] of Object.entries(seg.marks)) {
      if (MARKS_WORTH_A_SOUND.test(name)) cues.push({ frame: a.from + f, kind: "mark", act: a.id, label: name });
    }
  }
  return cues.sort((x, y) => x.frame - y.frame || x.kind.localeCompare(y.kind));
})();
