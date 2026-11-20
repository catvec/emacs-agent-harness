#!/usr/bin/env python3
"""Cut the approved pictures into the crops the review sheets compare against.

The approved originals are Noah's four pictures:

  voice-option-a-motion.gif              the Option A motion prototype
  voice-pipeline-all-bars.png            every stage, in bars (Round 02)
  voice-pipeline-client-comparison.png   one language, two clients
  voice-buddy-state-concept.png          a glance at the latest state

They are delivered in scripts/.dev/approved-voice-references/, which is
gitignored: the originals are Noah's, not this repository's.  This script cuts
named crops out of them and writes those crops under
docs/media/voice-ribbon-review/reference-crops/, which is committed, so a
comparison sheet can put the approved pixels themselves beside a screenshot of
the app instead of a redrawn impression of them.

  scripts/voice-ribbon-reference-crops.py [--check]

--check verifies the delivered originals against the recorded SHA-256 sums and
exits non-zero if one differs; nothing is written.  Without it the crops are
cut and written, and docs/media/voice-ribbon-review/reference-crops/CROPS.json
records, for every crop, the source file, its SHA-256, the exact source
rectangle and the crop's own SHA-256, so the provenance of a comparison sheet
can be checked rather than taken on trust.

The rectangles are in the originals' own pixels.  They were found by measuring
the pictures: every one is a whole dark pill, or a whole badge, with a margin,
so nothing of the approved drawing is cut off.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
ORIGINALS = ROOT / "scripts" / ".dev" / "approved-voice-references"
OUT = ROOT / "docs" / "media" / "voice-ribbon-review" / "reference-crops"

# The delivered files, with the SHA-256 sums Noah recorded for them.
SOURCES = {
    "voice-option-a-motion.gif": (
        "d15bd7d9ca321568e46d36fdc3aeace11b58bbef993b3054a5d792b81bc18d27",
        "Option A motion prototype",
    ),
    "voice-pipeline-all-bars.png": (
        "2aa1fb276be477687887b0f7ee5922b08977ef7272da188a7c34758b1f83bf8f",
        "Every stage, in bars",
    ),
    "voice-pipeline-client-comparison.png": (
        "0b83c0276cfd9276c5f673a31adbe7a13db23dc8822b2d0775f03535a75a7e69",
        "One language, two clients",
    ),
    "voice-buddy-state-concept.png": (
        "63263a502cc3dac8f8920722656118e87012510f66b6eeade2abd1cac0233337",
        "A glance at the latest state",
    ),
}

# name -> (source, rectangle (left, top, right, bottom), what it is)
# A rectangle is exclusive at right/bottom, in the source's own pixels, and
# carries a margin so the pill's own antialiased edge is inside the crop.
CROPS = {
    # The linear ribbon itself: the approved Option A bar, whole.
    "option-a-ribbon": (
        "voice-option-a-motion.gif",
        (58, 214, 966, 308),
        "The approved continuous ribbon, one pill of bars",
    ),
    # The same ribbon in the Emacs character-cell rendering.
    "option-a-emacs": (
        "voice-option-a-motion.gif",
        (58, 417, 966, 511),
        "The approved Emacs character-cell ribbon",
    ),
    # The bar language: the six stage shapes, side by side, whole.
    "bar-language": (
        "voice-pipeline-all-bars.png",
        (66, 267, 1534, 359),
        "The six approved stage shapes",
    ),
    # Option A on its own, without the page's words, at its own size.
    "panel-a-ribbon": (
        "voice-pipeline-all-bars.png",
        (569, 525, 1280, 648),
        "Option A, one continuous ribbon",
    ),
    # The approved state snapshots: speech to transcoding, and a drop.
    "state-speech-words": (
        "voice-pipeline-all-bars.png",
        (67, 1183, 388, 1281),
        "Approved snapshot: speech to transcoding",
    ),
    "state-drop": (
        "voice-pipeline-all-bars.png",
        (825, 1183, 1146, 1281),
        "Approved snapshot: a confirmed dropped chunk",
    ),
    # The Emacs ribbon as the approved client mockup draws it.
    "client-emacs": (
        "voice-pipeline-client-comparison.png",
        (78, 726, 1024, 842),
        "The approved Emacs ribbon",
    ),
    # The Flutter pill as the approved client mockup draws it.
    "client-flutter": (
        "voice-pipeline-client-comparison.png",
        (1124, 849, 1460, 923),
        "The approved Flutter ribbon",
    ),
    # The compact badge, all four approved states.
    "buddy-states": (
        "voice-buddy-state-concept.png",
        (162, 301, 1287, 446),
        "The four approved compact states",
    ),
    "buddy-audio": (
        "voice-buddy-state-concept.png",
        (168, 301, 293, 446),
        "Approved compact badge: audio",
    ),
    "buddy-words": (
        "voice-buddy-state-concept.png",
        (484, 301, 629, 446),
        "Approved compact badge: transcoding",
    ),
    "buddy-work": (
        "voice-buddy-state-concept.png",
        (810, 301, 955, 446),
        "Approved compact badge: processing",
    ),
    "buddy-drop": (
        "voice-buddy-state-concept.png",
        (1136, 301, 1281, 446),
        "Approved compact badge: dropped",
    ),
}

# The motion prototype's own transitions, as a strip of frames.  The GIF is
# the approved reference for movement, so the sheet shows its frames rather
# than a description of them.
MOTION_FRAMES = (0, 26, 52, 78, 104, 130, 156, 182, 208)
MOTION_RECT = (58, 214, 966, 308)


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify() -> int:
    """Check the delivered originals against the recorded sums."""
    missing = []
    for name, (sum_, _) in SOURCES.items():
        path = ORIGINALS / name
        if not path.exists():
            missing.append(f"{name}: not delivered")
            continue
        actual = sha256(path)
        if actual != sum_:
            missing.append(f"{name}: sha256 {actual}, expected {sum_}")
        else:
            print(f"ok   {name}  {sum_}")
    for line in missing:
        print(f"BAD  {line}", file=sys.stderr)
    return 1 if missing else 0


def cut() -> int:
    from PIL import Image

    if verify():
        return 1
    OUT.mkdir(parents=True, exist_ok=True)
    record = {}
    for name, (source, box, what) in CROPS.items():
        image = Image.open(ORIGINALS / source)
        image = image.convert("RGB")
        crop = image.crop(box)
        target = OUT / f"{name}.png"
        crop.save(target, optimize=True)
        record[name] = {
            "source": source,
            "source_sha256": SOURCES[source][0],
            "source_box": list(box),
            "what": what,
            "file": target.name,
            "size": list(crop.size),
            "sha256": sha256(target),
        }
        print(f"cut  {name}.png  {crop.size[0]}x{crop.size[1]}  from {source} {box}")

    # The motion prototype's own frames, stacked, so the approved movement is
    # in the picture rather than in a sentence about it.
    frames = []
    image = Image.open(ORIGINALS / "voice-option-a-motion.gif")
    for index in MOTION_FRAMES:
        image.seek(index)
        frames.append(image.convert("RGB").crop(MOTION_RECT))
    gap = 6
    width = max(frame.width for frame in frames)
    height = sum(frame.height for frame in frames) + gap * (len(frames) - 1)
    strip = Image.new("RGB", (width, height), (242, 243, 239))
    top = 0
    for frame in frames:
        strip.paste(frame, (0, top))
        top += frame.height + gap
    target = OUT / "option-a-motion-frames.png"
    strip.save(target, optimize=True)
    record["option-a-motion-frames"] = {
        "source": "voice-option-a-motion.gif",
        "source_sha256": SOURCES["voice-option-a-motion.gif"][0],
        "source_box": list(MOTION_RECT),
        "source_frames": list(MOTION_FRAMES),
        "what": "The approved motion, frame by frame",
        "file": target.name,
        "size": list(strip.size),
        "sha256": sha256(target),
    }
    print(f"cut  option-a-motion-frames.png  {strip.size[0]}x{strip.size[1]}")

    manifest = OUT / "CROPS.json"
    manifest.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")
    print(f"wrote {manifest.relative_to(ROOT)}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="verify only")
    args = parser.parse_args()
    return verify() if args.check else cut()


if __name__ == "__main__":
    raise SystemExit(main())
