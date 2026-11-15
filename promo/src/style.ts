/**
 * The film's look, as data.  A style is a brand: the whole screen is the real
 * Emacs capture, with no inset, no padding and no frame around it.  What
 * changes from brand to brand is the *grade of the capture itself*, the type,
 * the palette, the overlay language and the shape of the title lockup.  The
 * story, the clock and the footage are the same in every style; `PROMO_STYLE`
 * picks one by id.
 *
 * The grade is an ffmpeg filter chain applied to the footage before it is
 * shown (`footage.ts` caches it per style): a brand can turn the dark UI into
 * a cream page, a silver print or a lime duotone, so two brands never share a
 * screen tone.  Every style has to read at the size of a README clip: one bold
 * title, one bright accent, a composition that says what the film is in a
 * glance.
 */
export type BgArt = "grid" | "scan" | "blueprint" | "sun" | "swiss" | "pop";
export type BrandArt = "frame" | "rail" | "band" | "brackets" | "burst" | "scan" | "slab" | "bars" | "rule" | "hairline" | "none";
export type HudKind = "overlay" | "bar" | "lower" | "status" | "bands" | "bare";
export type FrameKind = "corners" | "hairline" | "registration" | "thick" | "offset" | "none";
export type CalloutKind = "box" | "terminal" | "annotation" | "ticket" | "note" | "sticker" | "rule";
export type KeycapKind = "key" | "underline" | "stamp" | "note";
export type TitleKind = "outline" | "plain" | "plate" | "split" | "outlineOnly" | "shadow" | "block";

/** Where the big title sits, in design pixels.  Left alignment means X is the left edge. */
export interface TitlePlace {
  x: number;
  y: number;
  align: "left" | "center";
  rotate?: number;
}
/** Where the title goes when it docks out of the way.  Scale is of the baked size. */
export interface DockPlace {
  x: number;
  y: number;
  scale: number;
  align: "left" | "center";
}

export interface Style {
  id: string;
  name: string;
  /** What it is, in one line, for the proposal reel. */
  blurb: string;
  /** The ffmpeg colour grade of the capture; it sets the whole frame's tone. */
  grade?: string;
  // The page, and the Emacs capture's own background for the hole the monitor cuts.
  bg: string;
  bg2: string;
  ink: string;
  dim: string;
  muted: string;
  text: string;
  white: string;
  // The brand's neon and its companions.
  accent: string;
  accent2: string;
  accent3: string;
  accent4: string;
  accent5: string;
  /** The fill of a keycap or a callout. */
  panel: string;
  /** How the brand paints over the footage. */
  brandArt: BrandArt;
  /** The page behind the capture (only visible while the stage shakes). */
  bgArt: BgArt;
  /** The grid's colour, or null. */
  grid: string | null;
  gridOpacity: number;
  scanlines: boolean;
  /** How dark the corners of the picture are. */
  vignette: number;
  // Type.
  display: string;
  displayWeight: number;
  /** Letter spacing, as a fraction of the type size.  Negative sets tight. */
  displayTracking: number;
  /** Upper case for the titles, or lower. */
  titleCase?: "upper" | "lower";
  mono: string;
  // Composition: the capture is the whole screen.
  mon: { scale: number; x?: number; y?: number; rotate?: number };
  frame: FrameKind;
  /** The card and highlight border, in pixels. */
  border: number;
  hud: HudKind;
  /** A solid band behind the HUD, or null for overlays only. */
  hudFill: string | null;
  // The big type.
  titleKind: TitleKind;
  titleSize: number;
  titleMaxWidth: number;
  /** The main fill, the second fill of a split title, the plate behind a plate title. */
  titleFill: string;
  titleSecond: string;
  titlePlate: string;
  titleOutline: string;
  titleShadow: string;
  /** The offset shadow, as a fraction of the type size. */
  titleShadowOffset: number;
  titleBig: TitlePlace;
  titleDock: DockPlace;
  /** How much the screen is dimmed behind the big title. */
  titleDim: number;
  // What darkens the footage behind a title, and how effects meet the picture.
  scrim: string;
  /** What shades the picture outside the focus while the camera is close, and how strongly. */
  shade?: string;
  shadeAlpha?: number;
  blend: "screen" | "normal";
  // Callouts and keys.
  callout: CalloutKind;
  calloutFill: string;
  calloutText: string;
  calloutInk: string;
  keycap: KeycapKind;
  // The brand, the end card, the rules.
  brandFill: string;
  brandOutline: string;
  brandShadow: string;
  outroFill: string;
  outroOutline: string;
  outroShadow: string;
  outroTag: string;
  outroKind: TitleKind;
  outroBig: TitlePlace;
  rule: string;
}

const FULL = { scale: 0.8, x: 0, y: 0 } as const;

export const STYLES: Style[] = [
  {
    // A cream page: the capture is inverted, so the real UI reads as printed.
    id: "paper",
    name: "PAPER",
    blurb: "cream page, black serif · the capture printed on paper · red rules, no outline",
    grade: "negate,eq=contrast=1.14:brightness=-0.03,colorbalance=rs=0.055:gs=0.015:bs=-0.075",
    bg: "#f7f7ea",
    bg2: "#eeeede",
    ink: "#f7f7ea",
    dim: "#a8977a",
    muted: "#7d6d54",
    text: "#171208",
    white: "#fffdf6",
    accent: "#c8321e",
    accent2: "#1e2a4a",
    accent3: "#2f5d3a",
    accent4: "#8a6a1f",
    accent5: "#171208",
    panel: "#f7f7ea",
    brandArt: "rule",
    bgArt: "swiss",
    grid: null,
    gridOpacity: 0,
    scanlines: false,
    vignette: 0,
    display: "DM Serif Display",
    displayWeight: 400,
    displayTracking: -0.015,
    titleCase: "upper",
    mono: "Hack",
    mon: FULL,
    frame: "none",
    border: 3,
    hud: "bare",
    hudFill: null,
    titleKind: "plate",
    titleSize: 176,
    titleMaxWidth: 1500,
    titleFill: "#171208",
    titleSecond: "#171208",
    titlePlate: "#fffdf6",
    titleOutline: "#171208",
    titleShadow: "#f7f7ea",
    titleShadowOffset: 0,
    titleBig: { x: 108, y: 852, align: "left" },
    titleDock: { x: 560, y: 48, scale: 0.15, align: "left" },
    titleDim: 0.1,
    scrim: "#f7f7ea",
    shade: "#171208",
    shadeAlpha: 0,
    blend: "normal",
    callout: "note",
    calloutFill: "#f7f7ea",
    calloutText: "#171208",
    calloutInk: "#c8321e",
    keycap: "underline",
    brandFill: "#171208",
    brandOutline: "#f7f7ea",
    brandShadow: "#f7f7ea",
    outroFill: "#171208",
    outroOutline: "#f7f7ea",
    outroShadow: "#c8321e",
    outroTag: "#c8321e",
    outroKind: "plain",
    outroBig: { x: 108, y: 452, align: "left" },
    rule: "rgba(200,50,30,0.5)",
  },
  {
    // Silver capture, black bars, condensed caps: a title card from a film.
    id: "noir",
    name: "NOIR",
    blurb: "silver print, black bands · Bebas Neue caps in a solid bar · one crimson rule",
    grade: "hue=s=0,eq=brightness=0.18:contrast=0.9",
    bg: "#08080a",
    bg2: "#111114",
    ink: "#08080a",
    dim: "#4c4c52",
    muted: "#9a9aa2",
    text: "#f4f4f6",
    white: "#ffffff",
    accent: "#e11d2e",
    accent2: "#ffffff",
    accent3: "#c9c9cf",
    accent4: "#6a6a72",
    accent5: "#2a2a30",
    panel: "#0c0c0e",
    brandArt: "bars",
    bgArt: "scan",
    grid: null,
    gridOpacity: 0,
    scanlines: false,
    vignette: 0.25,
    display: "Bebas Neue",
    displayWeight: 400,
    displayTracking: 0.02,
    titleCase: "upper",
    mono: "Hack",
    mon: FULL,
    frame: "none",
    border: 3,
    hud: "bar",
    hudFill: "#08080a",
    titleKind: "plain",
    titleSize: 200,
    titleMaxWidth: 1700,
    titleFill: "#ffffff",
    titleSecond: "#ffffff",
    titlePlate: "#08080a",
    titleOutline: "#08080a",
    titleShadow: "#08080a",
    titleShadowOffset: 0,
    titleBig: { x: 104, y: 930, align: "left" },
    titleDock: { x: 960, y: 26, scale: 0.13, align: "center" },
    titleDim: 0.18,
    scrim: "#08080a",
    blend: "normal",
    callout: "terminal",
    calloutFill: "#101014",
    calloutText: "#f4f4f6",
    calloutInk: "#e11d2e",
    keycap: "key",
    brandFill: "#ffffff",
    brandOutline: "#08080a",
    brandShadow: "#08080a",
    outroFill: "#ffffff",
    outroOutline: "#08080a",
    outroShadow: "#e11d2e",
    outroTag: "#e11d2e",
    outroKind: "plain",
    outroBig: { x: 960, y: 470, align: "center" },
    rule: "rgba(225,29,46,0.6)",
  },
  {
    // A lime duotone: the screen is a print, the title is knocked out of a slab.
    id: "acid",
    name: "ACID",
    blurb: "lime duotone · Archivo Black knocked out of a lime slab · black chrome",
    grade: "format=gray,curves=all='0/0.03 0.3/0.42 0.7/0.8 1/1',colorchannelmixer=rr=0.70:gg=1.0:bb=0.02",
    bg: "#080d00",
    bg2: "#0d1500",
    ink: "#080d00",
    dim: "#3f5a00",
    muted: "#7d9a2a",
    text: "#eaffb0",
    white: "#ffffff",
    accent: "#c6ff00",
    accent2: "#ffffff",
    accent3: "#00ffd0",
    accent4: "#ff3d00",
    accent5: "#1a2600",
    panel: "#080d00",
    brandArt: "slab",
    bgArt: "scan",
    grid: null,
    gridOpacity: 0,
    scanlines: true,
    vignette: 0.18,
    display: "Archivo Black",
    displayWeight: 400,
    displayTracking: -0.025,
    titleCase: "upper",
    mono: "Hack",
    mon: FULL,
    frame: "none",
    border: 4,
    hud: "bar",
    hudFill: "#080d00",
    titleKind: "plain",
    titleSize: 198,
    titleMaxWidth: 1700,
    titleFill: "#080d00",
    titleSecond: "#080d00",
    titlePlate: "#080d00",
    titleOutline: "#080d00",
    titleShadow: "#080d00",
    titleShadowOffset: 0,
    titleBig: { x: 104, y: 900, align: "left" },
    titleDock: { x: 104, y: 1002, scale: 0.14, align: "left" },
    titleDim: 0.06,
    scrim: "#080d00",
    blend: "screen",
    callout: "box",
    calloutFill: "#080d00",
    calloutText: "#eaffb0",
    calloutInk: "#c6ff00",
    keycap: "stamp",
    brandFill: "#c6ff00",
    brandOutline: "#080d00",
    brandShadow: "#080d00",
    outroFill: "#c6ff00",
    outroOutline: "#080d00",
    outroShadow: "#080d00",
    outroTag: "#c6ff00",
    outroKind: "block",
    outroBig: { x: 960, y: 470, align: "center" },
    rule: "rgba(198,255,0,0.55)",
  },
  {
    // Quiet and technical: the capture is the hero, the brand is a label.
    id: "signal",
    name: "SIGNAL",
    blurb: "cool near-black · small tracked JetBrains Mono caps · hairline frame, red mark",
    grade: "eq=saturation=0.5:contrast=1.1,colorbalance=rs=-0.03:bs=0.06",
    bg: "#06070a",
    bg2: "#0a0c12",
    ink: "#06070a",
    dim: "#39404f",
    muted: "#8b93a6",
    text: "#eef1f8",
    white: "#ffffff",
    accent: "#ff2a1a",
    accent2: "#e8ecf6",
    accent3: "#5a8cff",
    accent4: "#9aa4b8",
    accent5: "#1a1e28",
    panel: "#0a0c12",
    brandArt: "hairline",
    bgArt: "scan",
    grid: null,
    gridOpacity: 0,
    scanlines: false,
    vignette: 0.22,
    display: "JetBrains Mono",
    displayWeight: 700,
    displayTracking: 0.14,
    titleCase: "upper",
    mono: "Hack",
    mon: FULL,
    frame: "none",
    border: 2,
    hud: "bare",
    hudFill: null,
    titleKind: "plain",
    titleSize: 120,
    titleMaxWidth: 1500,
    titleFill: "#eef1f8",
    titleSecond: "#eef1f8",
    titlePlate: "#06070a",
    titleOutline: "#06070a",
    titleShadow: "#06070a",
    titleShadowOffset: 0,
    titleBig: { x: 104, y: 152, align: "left" },
    titleDock: { x: 104, y: 152, scale: 0.72, align: "left" },
    titleDim: 0.1,
    scrim: "#06070a",
    blend: "normal",
    callout: "annotation",
    calloutFill: "#06070a",
    calloutText: "#eef1f8",
    calloutInk: "#ff2a1a",
    keycap: "underline",
    brandFill: "#eef1f8",
    brandOutline: "#06070a",
    brandShadow: "#06070a",
    outroFill: "#eef1f8",
    outroOutline: "#06070a",
    outroShadow: "#ff2a1a",
    outroTag: "#ff2a1a",
    outroKind: "plain",
    outroBig: { x: 104, y: 452, align: "left" },
    rule: "rgba(255,42,26,0.6)",
  },
  {
    // A broadcast lower third: white bars, navy type, a red ticker.
    id: "broadcast",
    name: "BROADCAST",
    blurb: "white bars, navy Space Grotesk · title in a white lower third · red ticker",
    grade: "eq=saturation=0.9:contrast=1.05,colorbalance=rs=-0.02:bs=0.05",
    bg: "#0a0f18",
    bg2: "#101827",
    ink: "#0a0f18",
    dim: "#4a5568",
    muted: "#93a0b4",
    text: "#ffffff",
    white: "#ffffff",
    accent: "#e02020",
    accent2: "#0a2a6b",
    accent3: "#00b3ff",
    accent4: "#ffd400",
    accent5: "#243044",
    panel: "#f7f7f2",
    brandArt: "bars",
    bgArt: "scan",
    grid: null,
    gridOpacity: 0,
    scanlines: false,
    vignette: 0,
    display: "Space Grotesk",
    displayWeight: 700,
    displayTracking: -0.01,
    titleCase: "upper",
    mono: "Hack",
    mon: FULL,
    frame: "none",
    border: 3,
    hud: "bar",
    hudFill: "#f7f7f2",
    titleKind: "plain",
    titleSize: 176,
    titleMaxWidth: 1640,
    titleFill: "#0a2a6b",
    titleSecond: "#0a2a6b",
    titlePlate: "#f7f7f2",
    titleOutline: "#f7f7f2",
    titleShadow: "#f7f7f2",
    titleShadowOffset: 0,
    titleBig: { x: 104, y: 930, align: "left" },
    titleDock: { x: 960, y: 26, scale: 0.12, align: "center" },
    titleDim: 0.05,
    scrim: "#0a0f18",
    blend: "normal",
    callout: "ticket",
    calloutFill: "#0a2a6b",
    calloutText: "#ffffff",
    calloutInk: "#e02020",
    keycap: "stamp",
    brandFill: "#0a0f18",
    brandOutline: "#f7f7f2",
    brandShadow: "#f7f7f2",
    outroFill: "#ffffff",
    outroOutline: "#0a0f18",
    outroShadow: "#e02020",
    outroTag: "#e02020",
    outroKind: "plain",
    outroBig: { x: 960, y: 470, align: "center" },
    rule: "rgba(224,32,32,0.55)",
  },
  {
    // A two-ink risograph: cream paper, pink and blue, halftone and misregistration.
    id: "riso",
    name: "RISÓ",
    blurb: "fluoro pink page · Noto Serif Black split in black and blue · halftone",
    grade: "negate,eq=contrast=1.2:brightness=-0.04,colorchannelmixer=rr=1.0:gg=0.62:bb=0.76",
    bg: "#fb9cb4",
    bg2: "#f48aa5",
    ink: "#fb9cb4",
    dim: "#c06a80",
    muted: "#8a3e52",
    text: "#1a0a12",
    white: "#fffaf0",
    accent: "#2b3bff",
    accent2: "#12100c",
    accent3: "#00a0a0",
    accent4: "#ffd400",
    accent5: "#12100c",
    panel: "#fb9cb4",
    brandArt: "band",
    bgArt: "pop",
    grid: null,
    gridOpacity: 0,
    scanlines: false,
    vignette: 0,
    display: "Noto Serif Black",
    displayWeight: 400,
    displayTracking: -0.02,
    titleCase: "upper",
    mono: "Hack",
    mon: FULL,
    frame: "none",
    border: 4,
    hud: "overlay",
    hudFill: null,
    titleKind: "split",
    titleSize: 190,
    titleMaxWidth: 1660,
    titleFill: "#12100c",
    titleSecond: "#2b3bff",
    titlePlate: "#fb9cb4",
    titleOutline: "#fb9cb4",
    titleShadow: "#fb9cb4",
    titleShadowOffset: 0,
    titleBig: { x: 960, y: 850, align: "center", rotate: -1.5 },
    titleDock: { x: 960, y: 44, scale: 0.12, align: "center" },
    titleDim: 0.08,
    scrim: "#fb9cb4",
    shade: "#2a0a14",
    shadeAlpha: 0,
    blend: "normal",
    callout: "sticker",
    calloutFill: "#fffaf0",
    calloutText: "#12100c",
    calloutInk: "#2b3bff",
    keycap: "note",
    brandFill: "#12100c",
    brandOutline: "#f7edda",
    brandShadow: "#f7edda",
    outroFill: "#12100c",
    outroOutline: "#fb9cb4",
    outroShadow: "#2b3bff",
    outroTag: "#2b3bff",
    outroKind: "split",
    outroBig: { x: 960, y: 470, align: "center" },
    rule: "rgba(18,16,12,0.5)",
  },
];

// ---------------------------------------------------------------------------
// PRESS: the picks from the six above, put together.  BROADCAST's Emacs (its
// cool, near-stock dark UI), PAPER's DM Serif, RISÓ's die-cut sticker for the
// line under the title, and RISÓ's electric blue as the ink.  One frame, three
// treatments of the same type: solid blue, warm white ringed in blue, warm
// white with a hard blue offset.
// ---------------------------------------------------------------------------
const PRESS: Style = {
  id: "press",
  name: "PRESS",
  blurb: "broadcast Emacs, PAPER serif, RISÓ sticker · electric blue ink on a night page",
  grade: "eq=saturation=0.9:contrast=1.05,colorbalance=rs=-0.02:bs=0.05",
  bg: "#0a0f18",
  bg2: "#101827",
  ink: "#0a0f18",
  dim: "#3c4a64",
  muted: "#8b97ad",
  text: "#f4f1e6",
  white: "#fffaf0",
  accent: "#2b3bff",
  accent2: "#fffaf0",
  accent3: "#e02020",
  accent4: "#ffd400",
  accent5: "#12100c",
  panel: "#0a0f18",
  brandArt: "rule",
  bgArt: "scan",
  grid: null,
  gridOpacity: 0,
  scanlines: false,
  vignette: 0.2,
  display: "DM Serif Display",
  displayWeight: 400,
  displayTracking: -0.015,
  titleCase: "upper",
  mono: "Hack",
  mon: FULL,
  frame: "none",
  border: 3,
  hud: "bare",
  hudFill: null,
  titleKind: "plain",
  titleSize: 160,
  titleMaxWidth: 900,
  titleFill: "#2b3bff",
  titleSecond: "#2b3bff",
  titlePlate: "#0a0f18",
  titleOutline: "#2b3bff",
  titleShadow: "#2b3bff",
  titleShadowOffset: 0,
  titleBig: { x: 1440, y: 350, align: "center" },
  titleDock: { x: 560, y: 48, scale: 0.15, align: "left" },
  titleDim: 0.12,
  scrim: "#0a0f18",
  shade: "#0a0f18",
  shadeAlpha: 0.88,
  blend: "normal",
  callout: "sticker",
  calloutFill: "#fffaf0",
  calloutText: "#12100c",
  calloutInk: "#2b3bff",
  keycap: "note",
  brandFill: "#fffaf0",
  brandOutline: "#0a0f18",
  brandShadow: "#0a0f18",
  outroFill: "#fffaf0",
  outroOutline: "#0a0f18",
  outroShadow: "#2b3bff",
  outroTag: "#2b3bff",
  outroKind: "plain",
  outroBig: { x: 108, y: 452, align: "left" },
  rule: "rgba(43,59,255,0.6)",
};

const press = (id: string, name: string, blurb: string, title: Partial<Style>): Style => ({ ...PRESS, id, name, blurb, ...title });

STYLES.push(
  press("press-fill", "PRESS · FILL", "the title solid in RISÓ's electric blue", {
    titleKind: "plain",
  }),
  press("press-outline", "PRESS · OUTLINE", "a warm white title ringed in electric blue", {
    titleKind: "outline",
    titleFill: "#fffaf0",
    titleOutline: "#2b3bff",
    titleShadow: "#fffaf0",
    titleShadowOffset: 0,
  }),
  press("press-offset", "PRESS · OFFSET", "a warm white title with a hard blue offset shadow", {
    titleKind: "shadow",
    titleFill: "#fffaf0",
    titleOutline: "#fffaf0",
    titleShadow: "#2b3bff",
    titleShadowOffset: 0.06,
  }),
);

/** The look the film ships in: the brand the review picked. `PROMO_STYLE` changes it. */
export const DEFAULT_STYLE = "press-offset";

const id = process.env.PROMO_STYLE ?? DEFAULT_STYLE;
const selected = STYLES.find((s) => s.id === id);
if (!selected) throw new Error(`no style ${id}: choose ${STYLES.map((s) => s.id).join(", ")}`);
/** The active style: `PROMO_STYLE`, or the one the film ships in. */
export const STYLE: Style = selected;
