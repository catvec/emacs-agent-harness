#!/usr/bin/env bash
# Install the Flutter SDK pinned in .flutter-version and, optionally, a
# ~/.local/bin/flutter launcher that selects it per project.
#
#   tool/install_flutter.sh              the SDK, and the launcher
#   tool/install_flutter.sh --sdk-only   the SDK alone (tool/client_toolchain.sh
#                                        installs it so, under a cache directory
#                                        of its own, and touches no launcher)
#
# The launcher makes a plain `flutter build apk` use the version this project
# needs, while other projects keep using the default SDK in
# ~/.local/share/flutter. Run this script again after changing .flutter-version.
set -euo pipefail

sdk_only=0
for arg in "$@"; do
  case "$arg" in
    --sdk-only) sdk_only=1 ;;
    -h|--help) sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "install_flutter: unknown option: $arg (try --help)" >&2; exit 2 ;;
  esac
done

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version_file="$project_dir/.flutter-version"
version="$(sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$version_file" | head -n 1)"
version="${version#v}"
if [ -z "$version" ]; then
  echo "install_flutter: $version_file is empty" >&2
  exit 1
fi

versions_dir="${FLUTTER_VERSIONS_DIR:-$HOME/.local/share/flutter-versions}"
sdk="$versions_dir/$version"

if [ ! -x "$sdk/bin/flutter" ]; then
  case "$(uname -s)/$(uname -m)" in
    Linux/x86_64) platform=linux; archive="flutter_linux_${version}-stable.tar.xz" ;;
    Darwin/x86_64) platform=macos; archive="flutter_macos_${version}-stable.zip" ;;
    Darwin/arm64) platform=macos; archive="flutter_macos_arm64_${version}-stable.zip" ;;
    *)
      echo "install_flutter: no official Flutter $version archive for $(uname -s)/$(uname -m)." >&2
      echo "Install Flutter $version yourself and set FLUTTER_VERSIONS_DIR." >&2
      exit 1
      ;;
  esac

  base="https://storage.googleapis.com/flutter_infra_release/releases/stable/$platform"
  # The checksum is in the release index; keep a fallback for the Linux x64
  # archive this project is tested with.
  sha256=""
  if [ "$platform" = linux ] && [ "$version" = 3.47.7 ]; then
    sha256="af7455f540df951184c7953fbe3cf884766e7541dacf8571f9f582db03dd6230"
  fi
  if [ -z "$sha256" ]; then
    sha256="$(curl -fsSL "https://storage.googleapis.com/flutter_infra_release/releases/releases_${platform}.json" |
      python3 -c 'import json,sys; v=sys.argv[1]; print(next(r["sha256"] for r in json.load(sys.stdin)["releases"] if r["version"] == v))' "$version")"
  fi

  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  echo "Downloading Flutter $version ..."
  # A progress bar for a person; a log gets no thousand redraws of it.
  progress=-sS
  [ ! -t 2 ] || progress=--progress-bar
  curl -fL --retry 3 "$progress" -o "$tmp/$archive" "$base/$archive"
  echo "$sha256  $tmp/$archive" | sha256sum -c -
  mkdir -p "$versions_dir"
  if [ "$platform" = linux ]; then
    tar -xJf "$tmp/$archive" -C "$tmp"
  else
    unzip -q "$tmp/$archive" -d "$tmp"
  fi
  rm -rf "$sdk"
  mv "$tmp/flutter" "$sdk"
  echo "Installed Flutter $version at $sdk"
fi

if [ "$sdk_only" = 1 ]; then
  "$sdk/bin/flutter" --version
  exit 0
fi

# Install the per-project launcher. Back up whatever `flutter` resolved to
# before, so the default SDK is still reachable if this script is removed.
target="${FLUTTER_WRAPPER:-$HOME/.local/bin/flutter}"
mkdir -p "$(dirname "$target")"
if [ -e "$target" ] || [ -L "$target" ]; then
  if ! cmp -s "$project_dir/tool/flutter" "$target"; then
    backup="$target.before-harness"
    if [ -e "$backup" ] || [ -L "$backup" ]; then
      backup="$backup.$(date +%s)"
    fi
    mv "$target" "$backup"
    echo "Kept the previous flutter launcher as $backup"
  fi
fi
cp "$project_dir/tool/flutter" "$target"
chmod +x "$target"
echo "Installed $target (selects Flutter $version in this project)"

"$sdk/bin/flutter" --version
