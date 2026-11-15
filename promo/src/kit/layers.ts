/**
 * Thin constructors over framefields' Layer.* so scenes read as design, not plumbing:
 * everything is absolutely positioned in the 1920x1080 design space, and a layer may
 * live only in a window of the film (`from`..`to`), where its keyframes are written in film frames.
 */
import { Layer, type LayerAnimation } from "framefields";
import { DURATION } from "../timeline.js";
import { anim, type Tracks } from "./anim.js";

export type Node = ReturnType<typeof Layer.box>;

export interface Placement {
  id?: string;
  x?: number;
  y?: number;
  width?: number;
  height?: number;
  opacity?: number;
  rotation?: number;
  scale?: number;
  scaleX?: number;
  scaleY?: number;
  anchorX?: number;
  anchorY?: number;
  blendMode?: string;
  zIndex?: number;
  /** First film frame the layer exists in (default 0). */
  from?: number;
  /** First film frame it no longer exists in (default: the end of the film). */
  to?: number;
  /** Keyframes in film frames. */
  tracks?: Tracks;
  [key: string]: unknown;
}

/** Split off the window and animation from the node options. */
function parts(p: Placement): { options: Record<string, unknown>; from: number; animation?: LayerAnimation } {
  const { from = 0, to = DURATION, tracks, ...rest } = p;
  const options: Record<string, unknown> = { position: "absolute", ...rest };
  if (from > 0 || to < DURATION) {
    options.startFrame = from;
    options.durationFrames = Math.max(1, to - from);
  }
  return { options, from, animation: tracks ? anim(tracks, from) : undefined };
}

function finish<T extends Node>(node: T, animation?: LayerAnimation): T {
  return (animation ? node.animate(animation) : node) as T;
}

export function box(p: Placement & { background?: string; borderRadius?: number; borderColor?: string; borderWidth?: number; overflow?: "hidden" | "visible"; children?: unknown[] }): Node {
  const { options, animation } = parts(p);
  return finish(Layer.box(options as never), animation);
}

export function img(file: string, p: Placement & { fit?: "cover" | "contain" }): Node {
  const { options, animation } = parts(p);
  return finish(Layer.image(file, options as never) as unknown as Node, animation);
}

/** A clip of footage, played from its first frame at `from`. */
export function video(file: string, p: Placement & { fit?: "cover" | "contain" }): Node {
  const { options, animation } = parts(p);
  return finish(Layer.video(file, { muted: true, ...options } as never) as unknown as Node, animation);
}

export function text(content: string, p: Placement & Record<string, unknown>): Node {
  const { options, animation } = parts(p);
  return finish(Layer.text(content, options as never) as unknown as Node, animation);
}

/** A full design-space plane of one colour or gradient (flashes, tints, washes). */
export function plane(background: string, p: Placement = {}): Node {
  return box({ x: 0, y: 0, width: 1920, height: 1080, background, ...p });
}
