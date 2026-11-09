#!/usr/bin/env bash
# Run the buddy-window probe on the Linux desktop: the real card in its real
# native window, with a scripted call and no harness.
#
#   tool/buddy_window_probe.sh [--failed] [--capture=PATH]
#
# `--failed` shows the taller card of a call that could not start, which is
# the state the window has to grow for.  `--capture=PATH` writes a PNG of the
# card from the window's own layer tree.  Drag the card by its header and
# click its controls; the window is frameless and does not take the keyboard.
set -euo pipefail
cd "$(dirname "$0")/.."
eval "$(tool/client_toolchain.sh)"
version="$(sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' .flutter-version | head -n 1)"
sdk="$FLUTTER_VERSIONS_DIR/$version"
exec "$sdk/bin/flutter" run -d linux -t tool/buddy_window_probe.dart "$@"
