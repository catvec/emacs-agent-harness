/**
 * The end: the picture goes quiet behind the name, on the style's own page.
 */
import { DURATION, OUTRO } from "../timeline.js";
import { BG, H, STYLE, W } from "../theme.js";
import { rgba } from "../kit/draw.js";
import { loadManifest } from "../kit/manifest.js";
import { box, img, plane, text, type Node } from "../kit/layers.js";

export function outro(): Node[] {
  const m = loadManifest();
  const t = m.titles.outro;
  const tag = m.lines.outro;
  const big = STYLE.outroBig;
  const anchorX = big.align === "left" ? 0 : 0.5;
  const titleX = big.align === "left" ? big.x : big.x - t.w / 2;
  const titleY = big.y - t.h / 2;
  const tagX = big.align === "left" ? big.x : big.x - tag.w / 2;
  const tagY = big.y + t.h * 0.36 - tag.h / 2;
  const out: Node[] = [
    plane(rgba(BG, 0.965), { id: "outro-wash", zIndex: 10, from: OUTRO, to: DURATION, tracks: { opacity: [[OUTRO, 0], [OUTRO + 10, 1, "power2.out"]] } }),
  ];

  // A last look at the page's own furniture.
  if (STYLE.grid) out.push(img(m.grid.file, { id: "outro-grid", x: -100, y: -100, width: W + 200, height: H + 200, zIndex: 10, opacity: 0.16, from: OUTRO, to: DURATION, tracks: { opacity: [[OUTRO, 0], [OUTRO + 16, 0.16, "power2.out"]] } }));
  if (m.sun) out.push(img(m.sun.file, { id: "outro-sun", x: 960 - 590, y: 80, width: 1180, height: 1180, zIndex: 10, opacity: 0.45, from: OUTRO, to: DURATION }));
  if (m.burst) out.push(img(m.burst.file, { id: "outro-burst", x: 960 - 620, y: 540 - 620, width: 1240, height: 1240, zIndex: 10, opacity: 0.35, from: OUTRO, to: DURATION }));
  if (m.halftone) out.push(img(m.halftone.file, { id: "outro-halftone", x: -100, y: -100, width: W + 200, height: H + 200, zIndex: 10, opacity: 0.4, from: OUTRO, to: DURATION }));
  if (STYLE.scanlines && m.scanlines) out.push(img(m.scanlines.file, { id: "outro-scanlines", x: 0, y: 0, width: W, height: H, zIndex: 10, opacity: 0.6, from: OUTRO, to: DURATION }));
  if (STYLE.brandArt === "band") {
    out.push(
      box({ id: "outro-red", x: 0, y: H - 184, width: 456, height: 184, background: STYLE.accent, zIndex: 10, from: OUTRO, to: DURATION }),
      box({ id: "outro-rule", x: 64, y: 44, width: W - 128, height: 2, background: rgba(STYLE.text, 0.5), zIndex: 10, from: OUTRO, to: DURATION }),
      text("PLAIN EMACS. UNREASONABLE POWER.", { id: "outro-foot", x: 42, y: H - 58, width: 500, height: 22, fontFamily: STYLE.mono, fontSize: 14, fill: STYLE.white, letterSpacing: 2, zIndex: 12, from: OUTRO + 8, to: DURATION }),
    );
  }
  if (STYLE.brandArt === "rail") {
    out.push(
      box({ id: "outro-rail", x: 0, y: 0, width: 18, height: H, background: STYLE.accent, zIndex: 10, from: OUTRO, to: DURATION }),
      box({ id: "outro-arch", x: 1390, y: -300, width: 820, height: 820, borderRadius: 410, borderColor: rgba(STYLE.accent, 0.4), borderWidth: 12, zIndex: 10, from: OUTRO, to: DURATION }),
    );
  }
  if (STYLE.brandArt === "frame") {
    out.push(box({ id: "outro-edge", x: 0, y: 0, width: W, height: H, borderColor: STYLE.accent, borderWidth: 4, zIndex: 10, from: OUTRO, to: DURATION }));
  }

  out.push(
    img(t.file, {
      id: "outro-title",
      x: titleX,
      y: titleY,
      width: t.w,
      height: t.h,
      anchorX,
      anchorY: 0.5,
      from: OUTRO + 2,
      to: DURATION,
      zIndex: 12,
      tracks: { scale: [[OUTRO + 2, 1.14], [OUTRO + 14, 1, "expo.out"]], opacity: [[OUTRO + 2, 0], [OUTRO + 6, 1]] },
    }),
    img(tag.file, {
      id: "outro-tag",
      x: tagX,
      y: tagY,
      width: tag.w,
      height: tag.h,
      anchorX,
      anchorY: 0.5,
      from: OUTRO + 14,
      to: DURATION,
      zIndex: 12,
      tracks: {
        y: [[OUTRO + 14, tagY + 18], [OUTRO + 28, tagY, "expo.out"]],
        opacity: [[OUTRO + 14, 0], [OUTRO + 24, 1]],
      },
    }),
  );

  if (STYLE.blend === "screen") out.push(plane(STYLE.white, { id: "outro-flash", zIndex: 11, blendMode: "screen", from: OUTRO, to: OUTRO + 12, tracks: { opacity: [[OUTRO, 0.35], [OUTRO + 11, 0, "power2.out"]] } }));

  return out;
}
