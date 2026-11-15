#!/usr/bin/env bash
# Make the film from nothing: record the footage, bake the sprites, make the score, render every frame as a PNG into
# output/frames/, then encode (scripts/encode.sh).
#
#   scripts/render-all.sh            footage and score if missing, sprites, render, encode
#   scripts/render-all.sh frames     only the frames
#   scripts/render-all.sh encode     only the encode
#   FILM_FROM=300 FILM_TO=400 scripts/render-all.sh frames    only a range (frames already on disk are kept)
#   FORCE=1 scripts/render-all.sh frames                       delete the frames first
#
# Frames are independent files, so the run is RESUMABLE: if the process dies (or you stop it), run it again and it carries
# on after the last good frame.  One process renders: on a CPU adapter (lavapipe) the renderer already uses every core, and
# measured throughput with several processes at once was lower than with one.
#
# No GPU?  Install a software Vulkan driver and point LAVAPIPE_ICD at its manifest; see scripts/dev-env.sh and promo/README.md.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=dev-env.sh
source scripts/dev-env.sh

mode=${1:-all}
OUT=${FILM_OUT:-output/frames}

if [ "$mode" = all ]; then
  [ -d node_modules ] || npm ci
  # The footage is the real harness, recorded: it needs Emacs and a display (capture/capture.sh).
  [ -f build/footage/footage.json ] || capture/capture.sh
  npm run --silent check
  npm run --silent prep
  [ -f build/score.wav ] || npm run --silent music
fi

TOTAL=$(npx tsx src/render.ts count 2>/dev/null | tail -n 1)
FROM=${FILM_FROM:-0}
TO=${FILM_TO:-$TOTAL}

if [ "${FORCE:-0}" = 1 ] && [ "$mode" != encode ]; then rm -rf "$OUT"; fi
mkdir -p "$OUT" build

missing_frames() {
  for f in $(seq "$FROM" $((TO - 1))); do [ -s "$OUT/f$(printf %04d "$f").png" ] || echo "$f"; done | wc -l
}

if [ "$mode" = all ] || [ "$mode" = frames ]; then
  # A run that dies half way is resumed (frames on disk are skipped) a few times before giving up.
  for attempt in 1 2 3 4 5; do
    missing=$(missing_frames)
    if [ "$missing" -eq 0 ]; then break; fi
    echo "[render-all] attempt $attempt: $missing frames to render in $FROM..$TO"
    FILM_OUT="$OUT" npx tsx src/render.ts range "$FROM" "$TO" || echo "[render-all] renderer exited with $?; resuming"
  done
  missing=$(missing_frames)
  if [ "$missing" -ne 0 ]; then echo "[render-all] $missing frames still missing" >&2; exit 1; fi
fi

if [ "$mode" = all ] || [ "$mode" = encode ]; then
  scripts/encode.sh
fi
