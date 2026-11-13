#!/usr/bin/env python3
"""Render demo.sh's output as the evidence image and its SVG source.

The image is a picture of what the demo printed, so the two cannot drift:
run this again after changing the demo.  Both files are written where the
demo README and docs/openrouter-pinning.md look for them, inside this
repository, from the demo's own output.

  demo/openrouter-pinning/render-evidence.py            # live catalogue
  demo/openrouter-pinning/render-evidence.py --offline  # stock catalogue

The demo itself makes one read-only GET of OpenRouter's public endpoint
listing (skipped with --offline); no completion request is sent, no
policy is installed and no Harness is touched.  This script sends nothing
at all: it renders what the demo printed.
"""

import html
import pathlib
import subprocess
import sys
import textwrap

HERE = pathlib.Path(__file__).resolve().parent
EVIDENCE = HERE.parent.parent / "docs" / "evidence" / "openrouter-pinning"
SVG = EVIDENCE / "policy-demo.svg"
PNG = EVIDENCE / "policy-demo.png"

COLUMNS = 108
FONT_SIZE = 14
LINE_HEIGHT = 22
PADDING = 24


def demo_output(offline):
    """Return what demo.sh printed, without Emacs's own progress lines."""
    env = {"HARNESS_DEMO_OFFLINE": "1"} if offline else {}
    import os

    result = subprocess.run(
        ["bash", str(HERE / "demo.sh")],
        cwd=str(HERE.parent.parent),
        capture_output=True,
        text=True,
        env={**os.environ, **env},
        timeout=180,
    )
    if result.returncode != 0:
        sys.exit(f"demo.sh failed ({result.returncode}):\n{result.stderr}")
    return "\n".join(
        line
        for line in result.stdout.rstrip("\n").split("\n")
        if not line.startswith("Contacting host")
    )


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
    offline = "--offline" in sys.argv[1:]
    lines = wrapped(demo_output(offline))
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
