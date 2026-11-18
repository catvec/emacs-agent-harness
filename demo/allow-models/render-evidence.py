#!/usr/bin/env python3
"""Render demo.sh's output as the evidence image and its SVG source.

The image is a picture of what the demo printed, so the two cannot drift:
run this again after changing the demo.  Both files are written where the
demo README and docs/design/provider-model-allowlist.md look for them,
inside this repository, from the demo's own output.

  demo/allow-models/render-evidence.py

The demo sends nothing at all -- every provider it registers is made up --
and so does this script: it renders what the demo printed.
"""

import html
import pathlib
import subprocess
import sys
import textwrap

HERE = pathlib.Path(__file__).resolve().parent
EVIDENCE = HERE.parent.parent / "docs" / "evidence" / "allow-models"
SVG = EVIDENCE / "allow-models-demo.svg"
PNG = EVIDENCE / "allow-models-demo.png"

COLUMNS = 108
FONT_SIZE = 14
LINE_HEIGHT = 22
PADDING = 24


def demo_output():
    """Return what demo.sh printed."""
    result = subprocess.run(
        ["bash", str(HERE / "demo.sh")],
        cwd=str(HERE.parent.parent),
        capture_output=True,
        text=True,
        timeout=180,
    )
    if result.returncode != 0:
        sys.exit(f"demo.sh failed ({result.returncode}):\n{result.stderr}")
    return result.stdout.rstrip("\n")


def wrapped(text):
    """Return TEXT's lines, each no longer than COLUMNS characters."""
    lines = []
    for line in text.split("\n"):
        if len(line) <= COLUMNS:
            lines.append(line)
            continue
        lines.extend(
            textwrap.wrap(
                line,
                COLUMNS,
                subsequent_indent="    ",
                break_long_words=False,
                break_on_hyphens=False,
            )
            or [""]
        )
    return lines


def svg_document(lines):
    """Return an SVG of LINES, monospaced on white, at their real width."""
    character_width = FONT_SIZE * 0.6
    width = 2 * PADDING + int(COLUMNS * character_width)
    height = 2 * PADDING + len(lines) * LINE_HEIGHT + LINE_HEIGHT
    rows = "\n".join(
        f'<text x="{PADDING}" y="{PADDING + (i + 1) * LINE_HEIGHT - 6}"'
        f' font-size="{FONT_SIZE}">{html.escape(line, quote=False)}</text>'
        for i, line in enumerate(lines)
    )
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}"'
        f' viewBox="0 0 {width} {height}">\n'
        '<rect width="100%" height="100%" fill="#ffffff"/>\n'
        '<g font-family="DejaVu Sans Mono, monospace" fill="#14171a">\n'
        f"{rows}\n"
        "</g>\n"
        "</svg>\n"
    )


def main():
    lines = wrapped(demo_output())
    EVIDENCE.mkdir(parents=True, exist_ok=True)
    SVG.write_text(svg_document(lines), encoding="utf-8")
    subprocess.run(
        ["rsvg-convert", "-w", "1200", str(SVG), "-o", str(PNG)],
        check=True,
        timeout=120,
    )
    print(f"{len(lines)} lines -> {SVG}")
    print(f"{len(lines)} lines -> {PNG}")


if __name__ == "__main__":
    main()
