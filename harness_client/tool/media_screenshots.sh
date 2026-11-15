#!/usr/bin/env bash
# Draw the camera and screen-share states of the voice screen.
#
#   tool/media_screenshots.sh [OUTPUT_DIR]
#
# The pictures are fixtures: a scripted capture platform, a scripted backend
# and synthetic pixels.  No camera, microphone, screen or provider is used.
# They show the real widget, copy and layout, with the real fonts.
set -euo pipefail

project="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project"
out="${1:-screenshots}"

eval "$(tool/client_toolchain.sh)"
version="$(cat .flutter-version)"
export PATH="$FLUTTER_VERSIONS_DIR/$version/bin:$PATH"
HARNESS_SHOTS="$out" flutter test test/media_screenshots_test.dart

printf 'media_screenshots: %s/media/*.png\n' "$out"
