#!/usr/bin/env bash
# Encode output/frames/f%04d.png and build/score.wav into the finished MP4, and make a poster frame (PNG, and a smaller JPEG
# for the README) and a contact sheet next to it.
#
#   scripts/encode.sh                 -> output/emacs-agent-harness-promo.mp4 (+ poster.png, poster.jpg, contact-sheet.png)
#   CRF=24 scripts/encode.sh          larger file, a little sharper
#   POSTER=700 scripts/encode.sh      another frame for the poster
#
# H.264 High, yuv420p, faststart: plays in every browser and phone.  AAC 192 kb/s.
set -euo pipefail
cd "$(dirname "$0")/.."

FRAMES=${FRAMES:-output/frames}
SCORE=${SCORE:-build/score.wav}
OUT=${OUT:-output/emacs-agent-harness-promo.mp4}
CRF=${CRF:-24}
POSTER=${POSTER:-620}
FPS=30

command -v ffmpeg >/dev/null || { echo "encode: ffmpeg is not on PATH" >&2; exit 1; }
[ -s "$SCORE" ] || { echo "encode: $SCORE is missing: run \`npm run music\`" >&2; exit 1; }
total=$(ls "$FRAMES" | grep -c '^f[0-9]*\.png$')
last=$(printf 'f%04d.png' $((total - 1)))
[ "$total" -gt 0 ] && [ -s "$FRAMES/$last" ] || { echo "encode: $FRAMES is incomplete: run scripts/render-all.sh frames" >&2; exit 1; }
mkdir -p "$(dirname "$OUT")"

# gradfun dithers the long dark gradients (aurora, glows) so 8-bit H.264 does not band them.
ffmpeg -v error -stats -y \
  -framerate "$FPS" -i "$FRAMES/f%04d.png" \
  -i "$SCORE" \
  -vf "gradfun=strength=0.9:radius=24,format=yuv420p" \
  -c:v libx264 -preset slow -crf "$CRF" -profile:v high -level 4.2 -tune animation \
  -x264-params "aq-mode=3:aq-strength=0.9" \
  -movflags +faststart \
  -c:a aac -b:a 192k -ar 48000 \
  -shortest "$OUT"

dir=$(dirname "$OUT")
poster=$(printf 'f%04d.png' "$POSTER")
ffmpeg -v error -y -i "$FRAMES/$poster" -frames:v 1 "$dir/poster.png"
ffmpeg -v error -y -i "$FRAMES/$poster" -vf scale=1600:-1 -q:v 3 -frames:v 1 "$dir/poster.jpg"
# contact sheet: one frame per second
ffmpeg -v error -y -framerate "$FPS" -i "$FRAMES/f%04d.png" \
  -vf "select='not(mod(n,30))',scale=320:-1,tile=6x6:padding=4:margin=4:color=0x07040f" -frames:v 1 "$dir/contact-sheet.png"

ls -l "$OUT" "$dir/poster.png" "$dir/poster.jpg" "$dir/contact-sheet.png"
ffprobe -v error -show_entries stream=codec_name,width,height,r_frame_rate,duration,bit_rate -of default=nw=1 "$OUT"
exit 0
