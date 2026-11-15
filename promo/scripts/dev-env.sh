#!/usr/bin/env bash
# Environment for rendering on a machine without a GPU (a sandbox, CI): `source scripts/dev-env.sh`.
#
# framefields draws with WebGPU (Dawn) on Vulkan.  With no GPU it needs a software Vulkan driver:
# Mesa's lavapipe (Debian/Ubuntu: apt-get install libvulkan1 mesa-vulkan-drivers; Arch: vulkan-swrast).
# Where the package is not installed system-wide, point LAVAPIPE_ICD at its manifest (lvp_icd*.json)
# and this script exports VK_ICD_FILENAMES for it.  With a real GPU, source nothing.
#
# It also drops DISPLAY/WAYLAND_DISPLAY (offscreen rendering needs neither, and a display that
# refuses the connection only prints noise) and gives skia-canvas a font configuration of its own.
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# build/lavapipe/lvp_icd.json is picked up when present (the folder is gitignored: put a copy of the
# driver there, or set LAVAPIPE_ICD to wherever it lives).
if [ -z "${LAVAPIPE_ICD:-}" ] && [ -f "$HERE/build/lavapipe/lvp_icd.json" ]; then LAVAPIPE_ICD="$HERE/build/lavapipe/lvp_icd.json"; fi
if [ -n "${LAVAPIPE_ICD:-}" ]; then export VK_ICD_FILENAMES="$LAVAPIPE_ICD"; fi
unset DISPLAY WAYLAND_DISPLAY
export FONTCONFIG_FILE="$HERE/assets/fonts/fonts.conf"
