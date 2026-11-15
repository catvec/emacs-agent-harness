/**
 * What the film says: the words, and which module each act brings.  Everything on screen that makes a
 * claim is here, so `npm run check` can hold it against the repository (README.md, docs/modules/).
 * Pictures and times are elsewhere: footage.ts, timeline.ts.
 */
import { AMBER, CYAN, LIME, MAGENTA, VIOLET } from "./theme.js";

export const BRAND = "EMACS AGENT HARNESS";

export interface ModuleStory {
  /** The footage segment of the act. */
  id: string;
  /** Slammed over the frame as the UI lands, then kept in the top band. */
  title: string;
  /** The bottom band for the act: one line of what it is. */
  line: string;
  /** The modules it enables, in `harness-enable-modules`'s own groups (docs/modules/README.md); what the count adds up. */
  init: { group: ":features" | ":providers" | ":tools" | ":ui"; names: string[] }[];
  /** The footage rectangle the new UI lands on (a key of footage.rects). */
  landing: string;
  /** The act's neon. */
  accent: string;
}

/** The modules in the order they land. */
export const MODULES: ModuleStory[] = [
  {
    id: "tasks",
    title: "TASK BOARD",
    line: "parallel agents, each in its own git worktree",
    init: [
      { group: ":features", names: ["tasks", "merge"] },
      { group: ":tools", names: ["handin"] },
    ],
    landing: "board",
    accent: MAGENTA,
  },
];

/** Neons for acts not written yet: the order the film's palette goes in. */
export const NEXT_ACCENTS = [CYAN, LIME, AMBER, VIOLET];

/** The modules an act enables: what the HUD counts. */
export const moduleCount = (m: ModuleStory): number => m.init.reduce((n, g) => n + g.names.length, 0);

// ---------------------------------------------------------------------------
// What the film claims, and where the repository says so
// ---------------------------------------------------------------------------

export interface Claim {
  /** The words on screen (a callout's text, a tagline, a line of config). */
  shown: string;
  /** The file, relative to the repository's root, that says it. */
  source: string;
  /** A passage of that file (whitespace and Markdown emphasis ignored), or nothing when what is shown is the footage itself. */
  quote?: string;
}

/**
 * Every claim in words that the film makes.  `npm run check` finds each `quote` in its `source`, and fails on a callout
 * the footage draws that has no claim here: a film that says what the README does not is a bug.
 */
export const CLAIMS: Claim[] = [
  { shown: "parallel agents, each in its own git worktree", source: "README.md", quote: "Run tasks in parallel, each in its own session and git worktree" },
  { shown: "each task in its own git worktree", source: "README.md", quote: "each in its own session and git worktree" },
  { shown: "three agents at work, side by side", source: "footage" },
  { shown: "finished work waits for your review", source: "docs/modules/tasks.md", quote: "finished work is not done until the user has looked at it" },
  { shown: "verify it, and it merges back", source: "docs/modules/tasks.md", quote: "its branch goes through the merge queue and the task is done once merged" },
  { shown: "Everything else is a module", source: "README.md", quote: "Every feature is a module" },
];
