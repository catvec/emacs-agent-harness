#!/usr/bin/env bash
# The review's pictures: true comparison sheets at the sizes the design is
# judged at, and a short motion capture.
#
#   scripts/voice-ribbon-motion.sh [OUTDIR]
#
# OUTDIR defaults to docs/media/voice-ribbon-review.  Every sheet puts a crop
# of one of Noah's approved originals above a real screenshot of the app's own
# widget.  The crops are cut from the delivered originals by
# scripts/voice-ribbon-reference-crops.py, which verifies each file's SHA-256
# first and records the exact rectangle it cut, so a sheet shows approved
# pixels rather than a redrawn impression of them.  The motion frames come
# from harness_client/test/voice_pipeline_motion_shots_test.dart, whose frames
# are one per real stage change and are joined here.
#
# Every picture is a fixture: the protocol's own events, scripted rather than
# captured from a live microphone, and each sheet says so.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:-$ROOT/docs/media/voice-ribbon-review}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

FLUTTER=${FLUTTER:-$ROOT/harness_client/tool/flutter}
[ -x "$FLUTTER" ] || FLUTTER=$ROOT/.git/harness-client-toolchain/flutter-versions/3.47.7/bin/flutter
command -v ffmpeg >/dev/null || { echo "voice-ribbon-motion: ffmpeg is not on PATH" >&2; exit 1; }

# The approved originals are delivered in a gitignored directory; the crops
# that the sheets show are cut from them and committed.
python3 "$ROOT/scripts/voice-ribbon-reference-crops.py"

mkdir -p "$OUT"
cd "$ROOT/harness_client"
HARNESS_SHOTS="$WORK" "$FLUTTER" test test/voice_pipeline_reference_shots_test.dart
HARNESS_SHOTS="$WORK" "$FLUTTER" test test/voice_pipeline_motion_shots_test.dart

cp "$WORK"/voice-ribbon-versus-*.png "$OUT"/
ffmpeg -y -loglevel error -framerate 2 -i "$WORK/voice-pipeline-motion-%02d.png" \
       -vf 'scale=690:-1:flags=neighbor,split[a][b];[a]palettegen[p];[b][p]paletteuse' \
       -loop 0 "$OUT/voice-ribbon-motion.gif"
# The same frames as a video, for a player that does not open a GIF.
ffmpeg -y -loglevel error -i "$OUT/voice-ribbon-motion.gif" \
       -vf 'scale=690:-2:flags=neighbor' -pix_fmt yuv420p -movflags +faststart \
       "$OUT/voice-ribbon-motion.mp4"
# The breath: the one motion with no event behind it.  Sixteen redraws across
# more than one breath, so a reader sees a waiting run swell and settle in
# place.  It is a separate capture because the handoff frames hold the clock
# still and therefore show no breath at all.
ffmpeg -y -loglevel error -framerate 10 -i "$WORK/voice-ribbon-breath-%02d.png" \
       -vf 'scale=690:-1:flags=neighbor,split[a][b];[a]palettegen[p];[b][p]paletteuse' \
       -loop 0 "$OUT/voice-ribbon-breath.gif"
ffmpeg -y -loglevel error -i "$OUT/voice-ribbon-breath.gif" \
       -vf 'scale=690:-2:flags=neighbor' -pix_fmt yuv420p -movflags +faststart \
       "$OUT/voice-ribbon-breath.mp4"
# A segmented waiting run: the agent's work and a handed reply.  Their
# approved shape is a fixed height with the dashes inside changing, so a
# breath that only changed the dashes left them looking still.
ffmpeg -y -loglevel error -framerate 10 -i "$WORK/voice-ribbon-segmented-%02d.png" \
       -vf 'scale=690:-1:flags=neighbor,split[a][b];[a]palettegen[p];[b][p]paletteuse' \
       -loop 0 "$OUT/voice-ribbon-segmented.gif"
ffmpeg -y -loglevel error -i "$OUT/voice-ribbon-segmented.gif" \
       -vf 'scale=690:-2:flags=neighbor' -pix_fmt yuv420p -movflags +faststart \
       "$OUT/voice-ribbon-segmented.mp4"
echo "voice-ribbon-motion: pictures in $OUT"
