#!/usr/bin/env bash
# Record the footage of the promo film: the real harness, frame by frame.
#
#   promo/capture/capture.sh                 every segment of the story -> promo/build/footage/
#   promo/capture/capture.sh intro tasks     only these segments (each needs those before it, so
#                                            the earlier ones are recorded too, off camera)
#
# A fresh `emacs -Q' on a private display runs promo-rec.el and promo-story.el: the harness of this
# checkout, started with `harness-enabled-modules' nil (the core and nothing else), a scratch HOME with
# the demo project, and the scripted stand-in for the model that the README pictures use
# (scripts/harness-media.el).  Nothing talks to a network, and nothing outside the scratch
# directories is written until the run has passed.
#
# Output, in promo/build/footage/ (gitignored: `scripts/render-all.sh' makes it when it is missing):
#   NAME.mp4        each segment, 2400x1350, 30 fps, H.264 4:4:4 at a visually lossless quality
#   NAME-first.png  its first frame and NAME-last.png its last, for the film's crash and its freeze
#   footage.json    what the film needs to know: segments, marks, keys, clicks, zoom targets
#
# Needs an Emacs built with Cairo (for `x-export-frames'), git, ffmpeg, python3 and a display to draw
# on, chosen as scripts/media.sh chooses it: Xvfb when it is installed, else a headless kwin_wayland
# with a rootful Xwayland (KDE), else $DISPLAY, where a frame then shows while the run lasts.
#
# Environment:
#   PROMO_CAPTURE_OUT      where the footage goes (default promo/build/footage)
#   PROMO_CAPTURE_WORK     scratch directory (default $TMPDIR/promo-capture)
#   PROMO_CAPTURE_CACHE    where the harness's compiled files are kept between runs (default
#                          $PROMO_CAPTURE_WORK-cache); the first run compiles the harness
#   PROMO_CAPTURE_RUNTIME  where the private display's sockets go (default the scratch
#                          directory); a Unix socket path must stay under 108 bytes
#   PROMO_CAPTURE_DISPLAY  draw on this X display rather than a private one
#   PROMO_CAPTURE_KEEP     keep the frames (PNG) in the scratch directory: they are always kept
#                          when the run fails, for a look
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
OUT=${PROMO_CAPTURE_OUT:-$ROOT/promo/build/footage}
WORK=${PROMO_CAPTURE_WORK:-${TMPDIR:-/tmp}/promo-capture}
CACHE=${PROMO_CAPTURE_CACHE:-$WORK-cache}
RUNTIME_BASE=${PROMO_CAPTURE_RUNTIME:-$WORK}
# The frame is 2400x1350; the display must be a little larger.
WIDTH=2560 HEIGHT=1440

for tool in emacs git ffmpeg python3; do
  command -v "$tool" >/dev/null || { echo "capture: $tool is not on PATH" >&2; exit 1; }
done

rm -rf "$WORK"
mkdir -p "$WORK" "$WORK/frames" "$CACHE/elc" "$RUNTIME_BASE"

# shellcheck source=lib/display.sh
source "$HERE/lib/display.sh"
trap display_stop EXIT
display_start "$WIDTH" "$HEIGHT" "$WORK" "$RUNTIME_BASE"

# A HOME of its own: the demo project and the harness state live there, so paths read ~/src/acme-api
# and nothing touches the real ones.  The compiled harness is kept between runs.
home=$WORK/home
mkdir -p "$home/.emacs.d/harness"
ln -s "$CACHE/elc" "$home/.emacs.d/harness/elc"
cat >"$home/.gitconfig" <<'EOF'
[user]
	name = Sam Rivera
	email = sam@acme.example
[init]
	defaultBranch = main
[commit]
	gpgsign = false
EOF

status=0
env -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_CACHE_HOME -u XDG_STATE_HOME -u WAYLAND_DISPLAY \
    HOME="$home" DISPLAY="$display" GDK_SCALE=1 GDK_DPI_SCALE=1 \
    PROMO_REC_OUT="$WORK/frames" PROMO_STORY_SEGMENTS="$*" \
    timeout 3000 emacs -Q -l "$HERE/promo-rec.el" -l "$HERE/promo-story.el" -f promo-rec-main \
    2> >(tee "$WORK/emacs.log" | grep --line-buffered '^rec: ' >&2) || status=$?

if [ "$status" -ne 0 ]; then
  echo "capture: failed (status $status); the last lines Emacs printed:" >&2
  tail -n 20 "$WORK/emacs.log" >&2
  echo "capture: the frames so far are in $WORK/frames" >&2
  trap - EXIT
  display_stop
  exit "$status"
fi

# Encode every segment.  4:4:4 keeps the colour of one-pixel text edges, which 4:2:0 would smear; the
# film decodes it as it would any video.
mkdir -p "$OUT"
for dir in "$WORK"/frames/*/; do
  name=$(basename "$dir")
  frames=$(ls "$dir" | grep -c '^f[0-9]*\.png$')
  echo "capture: encoding $name ($frames frames)"
  ffmpeg -v error -y -framerate 30 -i "$dir/f%05d.png" \
    -c:v libx264 -preset medium -crf 10 -pix_fmt yuv444p -profile:v high444 -movflags +faststart \
    "$OUT/$name.mp4"
  cp "$dir/f00000.png" "$OUT/$name-first.png"
  cp "$dir/f$(printf %05d $((frames - 1))).png" "$OUT/$name-last.png"
done
cp "$WORK/frames/footage.json" "$OUT/footage.json"

if [ -z "${PROMO_CAPTURE_KEEP:-}" ]; then rm -rf "$WORK/frames"; fi
echo "capture: footage in $OUT"
ls -l "$OUT"
