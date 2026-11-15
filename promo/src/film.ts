/**
 * The film, assembled.  `buildFilm()` only builds: no rendering, no writes, no process.exit.
 *
 * Draw order, back to front:
 *   stage (shakes with every impact):  background, the monitor with the footage, the UI that falls and the impact, the titles
 *   hud (steady):                      the bands above and below the monitor, the keys pressed
 *   outro:                             the name
 *   post:                              a chromatic split that spikes on impacts, and a vignette
 */
import { Composition, LayerAnimation, RGBSplit, Vignette } from "framefields";
import { DURATION, FPS, OUTRO } from "./timeline.js";
import { BG, FONT_PATHS, H, STYLE, W, registerFonts } from "./theme.js";
import { fromArray } from "./kit/anim.js";
import { box, plane, type Node } from "./kit/layers.js";
import { background } from "./scenes/background.js";
import { brandOverlay } from "./scenes/brand.js";
import { impactFx, crash } from "./scenes/crash.js";
import { dockTitles, hud, keycaps } from "./scenes/hud.js";
import { monitor } from "./scenes/monitor.js";
import { SHAKE_R, SHAKE_X, SHAKE_Y, SPLIT } from "./scenes/motion.js";
import { outro } from "./scenes/outro.js";
import { titles } from "./scenes/title.js";

export interface FilmOptions {
  /** Render smaller (previews): the design space stays 1920x1080, the canvas is scaled. */
  scale?: number;
  /** Leave out scene groups while developing (names as in this file). */
  skip?: string[];
}

export async function buildFilm(options: FilmOptions = {}): Promise<Composition> {
  await registerFonts();
  const S = options.scale ?? 1;
  const skip = new Set(options.skip ?? []);
  const use = (name: string, make: () => Node[]): Node[] => (skip.has(name) ? [] : make());

  const comp = new Composition({
    width: Math.round(W * S),
    height: Math.round(H * S),
    fps: FPS,
    durationFrames: DURATION,
    backgroundColor: BG,
    fonts: FONT_PATHS,
  });

  const stage = box({
    id: "stage",
    x: 0,
    y: 0,
    width: W,
    height: H,
    children: [...use("background", background), ...use("monitor", monitor), ...use("brand", brandOverlay), ...use("crash", crash), ...use("impact", impactFx), ...use("titles", titles)],
  }).animate(
    LayerAnimation.create()
      .signal("x", fromArray(SHAKE_X), { multiplier: 1, offset: 0 } as never)
      .signal("y", fromArray(SHAKE_Y), { multiplier: 1, offset: 0 } as never)
      .signal("rotation", fromArray(SHAKE_R), { multiplier: 1, offset: 0 } as never),
  ) as unknown as Node;

  const root = box({
    id: "root",
    x: 0,
    y: 0,
    width: W,
    height: H,
    scale: S,
    anchorX: 0,
    anchorY: 0,
    children: [
      stage,
      ...use("hud", hud),
      ...use("keycaps", keycaps),
      ...use("docktitles", dockTitles),
      ...use("outro", outro),
      // The last frames fade to black.
      plane(BG, { id: "fade-out", zIndex: 40, from: DURATION - 12, to: DURATION, tracks: { opacity: [[DURATION - 12, 0], [DURATION - 1, 1, "power2.in"]] } }),
    ],
  });
  comp.add(root);

  comp.apply(new RGBSplit({ amount: fromArray(SPLIT.map((v) => v * S)) as never, angle: 0 }));
  comp.apply(new Vignette({ strength: STYLE.vignette, radius: 0.9, softness: 0.6 }));
  void OUTRO;
  return comp;
}
