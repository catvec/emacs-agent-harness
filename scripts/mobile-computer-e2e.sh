#!/usr/bin/env bash
# Run the mobile-computer end-to-end check against a real harness server.
#
#   scripts/mobile-computer-e2e.sh [flutter test arguments...]
#
# The Flutter test starts `scripts/harness-server` with the demo provider,
# connects the app's ACP client and MobileComputerController over the remote
# WebSocket, registers this phone as a computer, and prompts a session that
# calls computer_camera, computer_view and computer_call over the app's MCP
# servers.  It needs emacs on PATH.
#
# HARNESS_SERVER_TOKEN is made here when it is not set: the test reads the
# same variable and the server it starts gets it.  It must be at least 16
# characters, because the remote listener trades it for a session secret.
#
# The Flutter SDK is the pinned one when the repository's toolchain has it,
# else `flutter` on PATH.  PUB_CACHE is the toolchain's own when it exists,
# so the test does not touch the user's pub cache.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

if [ -z "${HARNESS_SERVER_TOKEN:-}" ]; then
  HARNESS_SERVER_TOKEN=$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' || true)
  if [ -z "$HARNESS_SERVER_TOKEN" ]; then
    HARNESS_SERVER_TOKEN="mobile-e2e-$(date +%s)-token"
  fi
fi
export HARNESS_SERVER_TOKEN
export HARNESS_MOBILE_E2E=1

cache=${HARNESS_CLIENT_TOOLCHAIN:-$root/.git/harness-client-toolchain}
if [ -d "$cache/pub-cache" ]; then
  export PUB_CACHE="$cache/pub-cache"
fi

version=$(sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
  "$root/harness_client/.flutter-version" 2>/dev/null | head -n 1)
flutter=${FLUTTER:-}
if [ -z "$flutter" ] && [ -n "$version" ] && [ -x "$cache/flutter-versions/$version/bin/flutter" ]; then
  flutter="$cache/flutter-versions/$version/bin/flutter"
fi
if [ -z "$flutter" ] && [ -x "$root/scripts/.dev/flutter/bin/flutter" ]; then
  flutter="$root/scripts/.dev/flutter/bin/flutter"
fi
if [ -z "$flutter" ]; then
  flutter=$(command -v flutter || true)
fi
if [ -z "$flutter" ] || [ ! -x "$flutter" ]; then
  printf 'mobile-computer-e2e: no Flutter SDK; set FLUTTER or install the app toolchain\n' >&2
  exit 3
fi
if ! command -v emacs >/dev/null 2>&1; then
  printf 'mobile-computer-e2e: emacs is not on PATH; the test starts a harness server\n' >&2
  exit 3
fi

cd "$root/harness_client"
exec "$flutter" test test/mobile_computer_e2e_test.dart "$@"
