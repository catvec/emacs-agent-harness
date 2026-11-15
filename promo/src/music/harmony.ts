/**
 * The score's harmony and tunes, as data.  A minor, 120 BPM, one chord a bar.
 * Everything stays inside A natural minor (and its relative C major) until the
 * outro, whose last bright hit lifts to A major.
 *
 * Notes are MIDI numbers (C4 = 60, A4 = 69).  Steps are sixteenths: 16 a bar.
 * Tunes are written for a phrase and placed by the arrangement (compose.ts), so they
 * do not depend on which bar the film puts a section on.
 */

export type ChordName = "Am" | "F" | "C" | "G" | "A";

export interface Chord {
  name: ChordName;
  /** Bass root (low octave) and the fifth above it. */
  root: number;
  fifth: number;
  /** Pad voicing: mid register, smooth between neighbours. */
  pad: number[];
  /** Warmer, lower voicing for the plain intro. */
  padLow: number[];
  /** Six ascending chord tones the arps walk. */
  arp: number[];
  /** Pitch classes of the pentatonic the ticks, pings and chimes play (always consonant over the chord). */
  pent: number[];
  /** Voicing of short chord stabs. */
  stab: number[];
  /** A wide voicing for the big hits: two octaves of the chord. */
  big: number[];
}

export const CHORDS: Record<ChordName, Chord> = {
  Am: { name: "Am", root: 33, fifth: 40, pad: [64, 69, 72], padLow: [57, 64, 69], arp: [57, 60, 64, 69, 72, 76], pent: [9, 0, 2, 4, 7], stab: [69, 72, 76], big: [45, 52, 57, 60, 64, 69, 72, 76] },
  F: { name: "F", root: 29, fifth: 36, pad: [65, 69, 72], padLow: [53, 60, 65], arp: [53, 57, 60, 65, 69, 72], pent: [5, 7, 9, 0, 2], stab: [65, 69, 72], big: [41, 48, 53, 57, 60, 65, 69, 72] },
  C: { name: "C", root: 36, fifth: 43, pad: [64, 67, 72], padLow: [55, 64, 67], arp: [55, 60, 64, 67, 72, 76], pent: [0, 2, 4, 7, 9], stab: [67, 72, 76], big: [48, 55, 60, 64, 67, 72, 76, 79] },
  G: { name: "G", root: 31, fifth: 38, pad: [62, 67, 71], padLow: [55, 62, 67], arp: [55, 59, 62, 67, 71, 74], pent: [7, 9, 11, 2, 4], stab: [67, 71, 74], big: [43, 50, 55, 59, 62, 67, 71, 74] },
  A: { name: "A", root: 33, fifth: 40, pad: [64, 69, 73, 71], padLow: [57, 64, 69, 73, 76], arp: [57, 61, 64, 69, 73, 76], pent: [9, 11, 1, 4, 6], stab: [69, 73, 76], big: [45, 52, 57, 61, 64, 69, 73, 76, 83] },
};

/** The loop the grooves ride: i - VI - III - VII.  Sections end on its last chord (G), which leans into the next downbeat. */
export const CYCLE: ChordName[] = ["Am", "F", "C", "G"];

/** Ascending notes of a chord's pentatonic from `low` (inclusive) upward. */
export function ladder(chord: Chord, low: number, count: number): number[] {
  const out: number[] = [];
  for (let m = low; out.length < count && m < low + 60; m++) if (chord.pent.includes(((m % 12) + 12) % 12)) out.push(m);
  return out;
}

// ---------------------------------------------------------------------------
// Patterns (16 steps a bar)
// ---------------------------------------------------------------------------

/** Arp patterns: indices into Chord.arp for each sixteenth. */
export const ARP_P1 = [0, 3, 2, 3, 1, 3, 2, 3, 0, 3, 2, 3, 1, 3, 4, 3];
export const ARP_P2 = [0, 2, 4, 5, 4, 2, 4, 5, 3, 2, 1, 2, 4, 5, 4, 2];
/** Accent shape shared by the arps: the 3-3-2 tresillo. */
export const ARP_VEL = [1.0, 0.5, 0.66, 0.92, 0.5, 0.6, 1.0, 0.5, 0.8, 0.5, 0.66, 0.92, 0.5, 0.6, 0.95, 0.58];

export interface BassNote {
  step: number;
  /** "root" | "fifth" | "octave" of the bar's chord, or "next" (the next chord's root, anticipated). */
  which: "root" | "fifth" | "octave" | "next" | "nextOct";
  len: number;
  vel: number;
}

/** Offbeat bass: the root on every "and", the next chord's root pushed in on the last. */
export const BASS_A: BassNote[] = [
  { step: 2, which: "root", len: 1.6, vel: 1 },
  { step: 6, which: "root", len: 1.6, vel: 0.95 },
  { step: 10, which: "root", len: 1.6, vel: 1 },
  { step: 14, which: "next", len: 1.5, vel: 0.95 },
];

/** Galloping bass: an octave pop after each offbeat. */
export const BASS_B: BassNote[] = [
  { step: 2, which: "root", len: 1.2, vel: 1 },
  { step: 3, which: "octave", len: 0.8, vel: 0.62 },
  { step: 6, which: "root", len: 1.2, vel: 0.95 },
  { step: 7, which: "octave", len: 0.8, vel: 0.6 },
  { step: 10, which: "root", len: 1.2, vel: 1 },
  { step: 11, which: "octave", len: 0.8, vel: 0.62 },
  { step: 14, which: "next", len: 1.2, vel: 0.95 },
  { step: 15, which: "nextOct", len: 0.8, vel: 0.6 },
];

// ---------------------------------------------------------------------------
// Tunes
// ---------------------------------------------------------------------------

export interface TuneNote {
  /** Bar of the phrase (0-based) and sixteenth step. */
  bar: number;
  step: number;
  midi: number;
  /** Length in sixteenths. */
  len: number;
  vel?: number;
}

/**
 * The hook: two bars over C | G (the third and fourth chords of the loop).  A syncopated 3-3-2 riff that
 * lands on chord tones (G G E over C), turns (D E G), then climbs to D and settles on B, the third of G.
 */
export const HOOK: TuneNote[] = [
  { bar: 0, step: 0, midi: 79, len: 3 },
  { bar: 0, step: 3, midi: 79, len: 3, vel: 0.9 },
  { bar: 0, step: 6, midi: 76, len: 2, vel: 0.85 },
  { bar: 0, step: 8, midi: 74, len: 3 },
  { bar: 0, step: 11, midi: 76, len: 3, vel: 0.9 },
  { bar: 0, step: 14, midi: 79, len: 2, vel: 0.95 },
  { bar: 1, step: 0, midi: 86, len: 4, vel: 1.05 },
  { bar: 1, step: 4, midi: 83, len: 2, vel: 0.85 },
  { bar: 1, step: 6, midi: 79, len: 2, vel: 0.85 },
  { bar: 1, step: 8, midi: 81, len: 4, vel: 0.95 },
  { bar: 1, step: 12, midi: 83, len: 4, vel: 1.0 },
];

/**
 * The climb: two bars over F | G, the last of a section that leads into the outro.  The same 3-3-2 shape as
 * the hook, rising; it ends on E, the fifth of the A major the outro lands on.
 */
export const CLIMB: TuneNote[] = [
  { bar: 0, step: 0, midi: 81, len: 3 },
  { bar: 0, step: 3, midi: 84, len: 3, vel: 0.9 },
  { bar: 0, step: 6, midi: 89, len: 2, vel: 0.95 },
  { bar: 0, step: 8, midi: 88, len: 3 },
  { bar: 0, step: 11, midi: 84, len: 3, vel: 0.9 },
  { bar: 0, step: 14, midi: 81, len: 2, vel: 0.9 },
  { bar: 1, step: 0, midi: 83, len: 3, vel: 1.0 },
  { bar: 1, step: 3, midi: 86, len: 3, vel: 0.95 },
  { bar: 1, step: 6, midi: 91, len: 2, vel: 1.0 },
  { bar: 1, step: 8, midi: 86, len: 3, vel: 0.9 },
  { bar: 1, step: 11, midi: 83, len: 3, vel: 0.9 },
  { bar: 1, step: 14, midi: 88, len: 2, vel: 1.0 },
];

/**
 * The pickup: the last half bar over G before the outro, when the climb has no room.  D B and then E, the
 * fifth of the A major that follows.
 */
export const PICKUP: TuneNote[] = [
  { bar: 0, step: 8, midi: 86, len: 3, vel: 0.9 },
  { bar: 0, step: 11, midi: 83, len: 3, vel: 0.9 },
  { bar: 0, step: 14, midi: 88, len: 2, vel: 1.0 },
];

/** Soft music-box plucks of the plain section: (bar of the section, step, midi, velocity).  Low, sparse, never on the person's send. */
export const PLAIN_PLUCKS: Array<[number, number, number, number]> = [
  [0, 10, 76, 0.4],
  [1, 2, 72, 0.5],
  [1, 8, 69, 0.45],
  [1, 12, 77, 0.45],
];

/**
 * The music's answer to the person's send: a rising C major figure (steps after the beat that follows the
 * send; midi, velocity), then a D that hangs unresolved over the G of the build.
 */
export const ANSWER: Array<[number, number, number]> = [
  [0, 76, 0.55],
  [2, 79, 0.55],
  [4, 84, 0.6],
  [6, 88, 0.65],
  [12, 86, 0.5],
];
