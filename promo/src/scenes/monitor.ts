/**
 * The monitor: the footage of real Emacs, in a frame of neon, seen through a camera.
 *
 * The footage lives in a "world" the size of the capture, which the camera moves and scales inside the monitor's rectangle
 * (scenes/motion.ts); what the film draws on the footage (scenes/overlays.ts) is in that world too.  Where a module act
 * starts the monitor shows its footage in place of the one before, on the frame its UI lands (scenes/crash.ts).
 */
import { LayerAnimation } from "framefields";
import { ACTS, DURATION, OUTRO } from "../timeline.js";
import { segmentLast, segmentVideo } from "../footage.js";
import { MON_CX, MON_CY, MON_H, MON_ROTATE, MON_W, MON_X, MON_Y, SHOT_H, SHOT_W, STYLE, TEXT, W, H, INK, SCRIM } from "../theme.js";
import { rgba } from "../kit/draw.js";
import { fromArray } from "../kit/anim.js";
import { box, img, video, type Node } from "../kit/layers.js";
import { loadManifest } from "../kit/manifest.js";
import { BEAT_PULSE, FOCUS_SHADE, IMPACTS, POP, WORLD_SCALE, WORLD_X, WORLD_Y } from "./motion.js";
import { callouts, highlights, pointer } from "./overlays.js";

/** The footage, act after act: the clip, then its last frame held until the next UI lands (or the film ends). */
function footage(): Node[] {
  const out: Node[] = [];
  ACTS.forEach((a, i) => {
    const next = ACTS[i + 1];
    out.push(video(segmentVideo(a.segment), { id: `video-${a.id}`, x: 0, y: 0, width: SHOT_W, height: SHOT_H, fit: "cover", from: a.from, to: a.to }));
    out.push(img(segmentLast(a.segment), { id: `hold-${a.id}`, x: 0, y: 0, width: SHOT_W, height: SHOT_H, fit: "cover", from: a.to, to: next ? next.impact : DURATION }));
  });
  return out;
}

export function monitor(): Node[] {
  const m = loadManifest();
  const first = IMPACTS[0] ?? DURATION;

  // The neon edge: violet while the harness is plain, the module's own neon from its impact, breathing with the beat.
  const edges: Node[] = [];
  if (STYLE.frame !== "none") edges.push(
    // plain: on until the first impact, which hands the edge to the module's neon
    img(m.monitor.plain.file, {
      id: "edge-plain",
      x: MON_X - m.monitor.plain.pad,
      y: MON_Y - m.monitor.plain.pad,
      width: m.monitor.plain.w,
      height: m.monitor.plain.h,
      blendMode: STYLE.blend,
      from: 0,
      to: first + 24,
      tracks: { opacity: [[0, 0], [10, 1, "power2.out"], [first - 1, 1], [first + 3, 1], [first + 22, 0, "power2.in"]] },
    }),
  );
  for (const a of ACTS.filter((x) => x.kind === "module" && STYLE.frame !== "none")) {
    const s = m.monitor[a.id];
    edges.push(
      img(s.file, {
        id: `edge-${a.id}`,
        x: MON_X - s.pad,
        y: MON_Y - s.pad,
        width: s.w,
        height: s.h,
        blendMode: STYLE.blend,
        from: a.impact,
        to: OUTRO + 20,
        tracks: { opacity: [[a.impact, 1], [a.impact + 14, 1], [OUTRO - 1, 1], [OUTRO + 19, 0, "power2.in"]] },
      }).animate(LayerAnimation.create().signal("opacity", fromArray(BEAT_PULSE), { multiplier: 0.08, offset: 0.92 } as never)) as unknown as Node,
    );
  }

  // The world: the footage and what is drawn on it, moved and scaled by the camera.
  const world = box({
    id: "world",
    x: 0,
    y: 0,
    width: SHOT_W,
    height: SHOT_H,
    anchorX: 0,
    anchorY: 0,
    background: INK,
    children: [...footage(), ...highlights(), ...callouts(), ...pointer()],
  }).animate(
    LayerAnimation.create()
      .signal("x", fromArray(WORLD_X), { multiplier: 1, offset: 0 } as never)
      .signal("y", fromArray(WORLD_Y), { multiplier: 1, offset: 0 } as never)
      .signal("scale", fromArray(WORLD_SCALE), { multiplier: 1, offset: 0 } as never),
  ) as unknown as Node;

  // The screen: it opens like a CRT being switched on, and pops when a UI lands on it.
  const screen = box({
    id: "screen",
    x: MON_X,
    y: MON_Y,
    width: MON_W,
    height: MON_H,
    overflow: "hidden",
    anchorX: 0.5,
    anchorY: 0.5,
    background: INK,
    children: [
      world,
      // While the camera is close to one side, the other side is dimmed, so the eye stays where the camera is.
      box({
        id: "focus-shade-left",
        x: 0,
        y: 0,
        width: MON_W * 0.4,
        height: MON_H,
        background: `linear-gradient(90deg, ${rgba(STYLE.shade ?? SCRIM, STYLE.shadeAlpha ?? 0.88)} 0%, ${rgba(STYLE.shade ?? SCRIM, (STYLE.shadeAlpha ?? 0.88) * 0.8)} 55%, ${rgba(STYLE.shade ?? SCRIM, 0)} 100%)`,
      }).animate(LayerAnimation.create().signal("opacity", fromArray(FOCUS_SHADE.left), { multiplier: 1, offset: 0 } as never)) as unknown as Node,
      box({
        id: "focus-shade-right",
        x: MON_W * 0.6,
        y: 0,
        width: MON_W * 0.4,
        height: MON_H,
        background: `linear-gradient(270deg, ${rgba(STYLE.shade ?? SCRIM, STYLE.shadeAlpha ?? 0.88)} 0%, ${rgba(STYLE.shade ?? SCRIM, (STYLE.shadeAlpha ?? 0.88) * 0.8)} 55%, ${rgba(STYLE.shade ?? SCRIM, 0)} 100%)`,
      }).animate(LayerAnimation.create().signal("opacity", fromArray(FOCUS_SHADE.right), { multiplier: 1, offset: 0 } as never)) as unknown as Node,
    ],
    tracks: { scaleY: [[0, 0.004], [13, 1, "expo.out"]], opacity: [[0, 0], [2, 1]] },
  });

  const group = box({
    id: "monitor",
    x: 0,
    y: 0,
    width: W,
    height: H,
    anchorX: MON_CX / W,
    anchorY: MON_CY / H,
    rotation: MON_ROTATE,
    children: [...edges, screen],
  }).animate(LayerAnimation.create().signal("scale", fromArray(POP.map((p) => 1 + p)), { multiplier: 1, offset: 0 } as never)) as unknown as Node;

  // The line of light a CRT opens from.
  const line = box({
    id: "crt-line",
    x: MON_X,
    y: MON_CY - 2,
    width: MON_W,
    height: 4,
    background: TEXT,
    blendMode: STYLE.blend,
    from: 0,
    to: 16,
    tracks: { opacity: [[0, 0], [1, 1], [9, 0.9], [15, 0, "power2.in"]], scaleX: [[0, 0.05], [8, 1, "expo.out"]] },
  });

  return [group, line];
}
