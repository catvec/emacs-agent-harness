#!/usr/bin/env python3
"""Measure a rendered ribbon against the approved original's own ratios.

  scripts/voice-ribbon-fidelity.py RENDERED.png [--original NAME] [--json]

The approved bar geometry is measured from the delivered originals (their
SHA-256 sums are checked first) and the same measurements are taken from a
rendered picture of the implementation, so a claim about fidelity is a pair of
numbers rather than an impression.  The ratios are what matter, not the
pixels: the original is drawn at one size and the app at another, and only the
bar's proportions, its pitch and its silhouette can be compared directly.

Nothing is written unless --json names a file; the report goes to stdout.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
ORIGINALS = ROOT / "scripts" / ".dev" / "approved-voice-references"

# The approved geometry, measured from voice-pipeline-all-bars.png's Option A
# ribbon (the 690x111 pill at rows 532..642, columns 580..1269).  These are the
# numbers the implementation is compared against; they are re-derived from the
# file on every run, never typed in.
APPROVED = {
    "source": "voice-pipeline-all-bars.png",
    "box": (569, 525, 1280, 648),
}


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def bars(path, box=None, dark_max=170, light=260, margin=6):
    """Return the pill and the bars in PATH, as measurements."""
    from PIL import Image
    import numpy as np

    image = Image.open(path).convert("RGB")
    pixels = np.asarray(image).astype(int)
    if box is None:
        box = (0, 0, pixels.shape[1], pixels.shape[0])
    x0, y0, x1, y1 = box
    sub = pixels[y0:y1, x0:x1]
    dark = sub.sum(axis=2) < dark_max
    rows = np.where(dark.mean(axis=1) > 0.4)[0]
    if len(rows) == 0:
        return None
    top, bottom = int(rows[0]), int(rows[-1])
    cols = np.where(dark[top : bottom + 1].mean(axis=0) > 0.4)[0]
    left, right = int(cols[0]), int(cols[-1])
    height = bottom - top + 1
    width = right - left + 1
    inner = sub[top : bottom + 1, left : right + 1]
    is_bar = inner.sum(axis=2) > light
    is_bar[:margin, :] = False
    is_bar[-margin:, :] = False
    is_bar[:, :margin] = False
    is_bar[:, -margin:] = False
    lit = is_bar.any(axis=0)
    runs = []
    start = None
    for index, value in enumerate(lit):
        if value and start is None:
            start = index
        elif not value and start is not None:
            runs.append((start, index - 1))
            start = None
    if start is not None:
        runs.append((start, len(lit) - 1))
    marks = []
    for a, b in runs:
        column = is_bar[:, a : b + 1]
        lit_rows = np.where(column.any(axis=1))[0]
        patch = inner[lit_rows[0] : lit_rows[-1] + 1, a : b + 1]
        patch_lum = patch.sum(axis=2)
        mask = patch_lum > np.percentile(patch_lum, 85)
        colour = None
        if mask.any():
            colour = [int(round(v)) for v in patch[mask].mean(axis=0)]
        marks.append(
            {
                "x": a + left + x0,
                "width": b - a + 1,
                "top": int(lit_rows[0] + top + y0),
                "height": int(lit_rows[-1] - lit_rows[0] + 1),
                "colour": colour,
                "fill": round(float((patch_lum > light).mean()), 2),
            }
        )
    gaps = [marks[i + 1]["x"] - (marks[i]["x"] + marks[i]["width"]) for i in range(len(marks) - 1)]
    pitches = [marks[i + 1]["x"] - marks[i]["x"] for i in range(len(marks) - 1)]
    heights = [mark["height"] for mark in marks]
    widths = [mark["width"] for mark in marks]
    return {
        "path": str(path),
        "pill": {"width": width, "height": height, "x": left + x0, "y": top + y0},
        "marks": marks,
        "count": len(marks),
        "width_ratio": round(sum(widths) / len(widths) / height, 3) if widths else None,
        "pitch_ratio": round(sum(pitches) / len(pitches) / height, 3) if pitches else None,
        "gap_ratio": round(sum(gaps) / len(gaps) / height, 3) if gaps else None,
        "height_spread": round((max(heights) - min(heights)) / height, 3) if heights else None,
        "densest_run": max(widths) if widths else None,
    }


def approved() -> dict:
    path = ORIGINALS / APPROVED["source"]
    if not path.exists():
        raise SystemExit(f"{path} is not delivered")
    measured = bars(path, APPROVED["box"])
    measured["sha256"] = sha256(path)
    return measured


def summary(measured: dict) -> str:
    if measured is None:
        return "no pill found"
    pill = measured["pill"]
    return (
        f"pill {pill['width']}x{pill['height']}  marks {measured['count']}  "
        f"width/h {measured['width_ratio']}  pitch/h {measured['pitch_ratio']}  "
        f"gap/h {measured['gap_ratio']}  height spread/h {measured['height_spread']}"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("rendered", nargs="?", help="a rendered picture to measure")
    parser.add_argument(
        "--box",
        help="the rendered pill's rectangle, left,top,right,bottom in its own pixels",
    )
    parser.add_argument("--json", help="write the report here")
    args = parser.parse_args()

    report = {"approved": approved()}
    print("approved  ", summary(report["approved"]))
    if args.rendered:
        box = None
        if args.box:
            box = tuple(int(part) for part in args.box.split(","))
        measured = bars(pathlib.Path(args.rendered), box)
        report["rendered"] = measured
        print("rendered  ", summary(measured))
        if measured and report["approved"]:
            base = report["approved"]
            for key in ("width_ratio", "pitch_ratio", "gap_ratio"):
                was, now = base[key], measured[key]
                if was and now:
                    print(f"  {key}: {now} against {was} ({now / was:.2f}x)")
    if args.json:
        pathlib.Path(args.json).write_text(json.dumps(report, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
