#!/usr/bin/env bash
# How long the shipped local voice sidecar takes to start the receipt of an
# accepted request, from the `acknowledge' event to the first write to the
# speaker.
#
#   scripts/analysis/bench-acknowledgment-sidecar.sh [SAMPLES]
#
# It runs `scripts/harness-voice-live-unmute' as Emacs runs it, with a stub
# microphone, a stub speaker and a stand-in speech service (no speech
# model), in a directory of its own under scripts/.dev/.  No real
# microphone records and no real speaker plays.  What the numbers mean, and
# what they do not, is stated in bench-acknowledgment-sidecar.py and in
# docs/analysis/spoken-acknowledgment-2026-11-09.md.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
out=scripts/.dev/bench-acknowledgment-sidecar
rm -rf "$out"
mkdir -p "$out"
exec python3 scripts/analysis/bench-acknowledgment-sidecar.py "$ROOT" "$out" "${1:-20}"
