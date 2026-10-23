#!/usr/bin/env bash
# Find, or install, what a build of the Android app needs, and say how to use it.
#
#   eval "$(tool/client_toolchain.sh [--accept-android-licenses])"
#
# The app is built with the Flutter SDK pinned in .flutter-version, a JDK
# (17 to 21) and an Android SDK that holds the components android/gradle.properties
# pins (platform, build-tools, NDK, CMake).  A machine that has them already --
# FLUTTER_VERSIONS_DIR, JAVA_HOME and ANDROID_HOME name where -- uses them as
# they are.  What it lacks is installed under one cache directory, once, and
# found there afterwards:
#
#   $HARNESS_CLIENT_TOOLCHAIN, else <repository>/.git/harness-client-toolchain,
#   else <repository>/scripts/.dev/client-toolchain
#
# (the repository's .git directory is shared by every worktree of it, so a task
# in a worktree installs nothing a task before it installed already).
#
# stdout is `export` lines for FLUTTER_VERSIONS_DIR, JAVA_HOME, ANDROID_HOME,
# ANDROID_SDK_ROOT, GRADLE_USER_HOME, PUB_CACHE and PATH; stderr says what is
# found and what is installed.  Pub's and Gradle's caches are the toolchain's
# own, never ~/.pub-cache or ~/.gradle: a build that is a check of the tree must
# not depend on, or damage, what the machine has collected.  (A sandboxed shell
# that sees only part of ~/.pub-cache makes pub delete the real files of the
# directories it can see; see README.md, "Building the apps".)
#
# Installing the Android SDK means accepting its licences (sdkmanager
# --licenses): the script does so, for the SDK it installs and no other, only
# with --accept-android-licenses or HARNESS_CLIENT_ACCEPT_ANDROID_LICENSES=1.
# It installs for Linux on x86_64 only; elsewhere install the JDK and the
# Android SDK yourself and set JAVA_HOME and ANDROID_HOME.
#
# HARNESS_CLIENT_NO_SYSTEM_TOOLS=1 looks only where the environment says
# (FLUTTER_VERSIONS_DIR, JAVA_HOME, ANDROID_HOME, ANDROID_SDK_ROOT), not in the
# usual places (/usr/lib/jvm, /opt/android-sdk, ~/Android/Sdk, ...): the tests
# of this script use it, and so can anyone who wants the cache's own toolchain.
#
# Exit status: 0 when the toolchain is complete, 2 for a bad option, 3 when it
# could not be made complete (stderr says why).
set -euo pipefail

tool_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(dirname "$tool_dir")"

# Pinned downloads: the exact releases this was tried with, and their checksums
# (Temurin's from api.adoptium.net, the command-line tools' from Google's
# repository2-3.xml, which lists a SHA-1; the SHA-256 is of the same file).
jdk_dir_name="jdk-21.0.13+9"
jdk_url="https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.13%2B9/OpenJDK21U-jdk_x64_linux_hotspot_21.0.13_9.tar.gz"
jdk_sha256="d7f5d5cf865a2902b70ff549b97586a7d3f234e016f041ab447ea740c7d66d1c"
cmdline_url="https://dl.google.com/android/repository/commandlinetools-linux-13114758_latest.zip"
cmdline_sha256="7ec965280a073311c339e571cd5de778b9975026cfcbe79f2b1cdcb1e15317ee"

accept_licenses="${HARNESS_CLIENT_ACCEPT_ANDROID_LICENSES:-0}"
system_tools=1
[ -z "${HARNESS_CLIENT_NO_SYSTEM_TOOLS:-}" ] || system_tools=0

usage() {
  sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//'
}

die() {
  printf 'client_toolchain: %s\n' "$*" >&2
  exit 3
}

say() {
  printf 'client_toolchain: %s\n' "$*" >&2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --accept-android-licenses) accept_licenses=1 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'client_toolchain: unknown option: %s (try --help)\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

# --- what the project pins ---------------------------------------------------

property() {
  local value
  value="$(sed -n "s/^$1=//p" "$project_dir/android/gradle.properties" | head -n 1)"
  [ -n "$value" ] || die "android/gradle.properties does not set $1"
  printf '%s' "$value"
}

flutter_version="$(sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
  "$project_dir/.flutter-version" | head -n 1)"
flutter_version="${flutter_version#v}"
[ -n "$flutter_version" ] || die "$project_dir/.flutter-version names no Flutter version"

compile_sdk="$(property harness.compileSdk)"
build_tools="$(property harness.buildToolsVersion)"
ndk_version="$(property harness.ndkVersion)"
cmake_version="$(property harness.cmakeVersion)"

# --- where things go ---------------------------------------------------------

writable_dir() {
  mkdir -p "$1" 2>/dev/null && [ -w "$1" ]
}

choose_cache() {
  local common
  if [ -n "${HARNESS_CLIENT_TOOLCHAIN:-}" ]; then
    printf '%s' "$HARNESS_CLIENT_TOOLCHAIN"
    return
  fi
  if common="$(git -C "$project_dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" &&
     writable_dir "$common/harness-client-toolchain"; then
    printf '%s' "$common/harness-client-toolchain"
    return
  fi
  printf '%s' "$(dirname "$project_dir")/scripts/.dev/client-toolchain"
}

cache="$(choose_cache)"
mkdir -p "$cache" || die "cannot make the toolchain directory $cache (set HARNESS_CLIENT_TOOLCHAIN)"
cache="$(cd "$cache" && pwd)"

# One installer at a time: two tasks that start together must not unpack the
# same archive into the same directory.
if command -v flock >/dev/null 2>&1; then
  exec 9>"$cache/.lock"
  flock 9
fi

# --- helpers -----------------------------------------------------------------

linux_x64() {
  [ "$(uname -s)/$(uname -m)" = Linux/x86_64 ]
}

fetch() { # URL FILE SHA256
  local url="$1" file="$2" sha256="$3"
  say "downloading $url"
  rm -f "$file.part"
  curl -fL --retry 3 --retry-delay 2 -sS -o "$file.part" "$url" ||
    die "could not download $url"
  printf '%s  %s\n' "$sha256" "$file.part" | sha256sum -c - >/dev/null 2>&1 ||
    die "the download of $url does not match its checksum $sha256"
  mv "$file.part" "$file"
}

java_major() { # JAVA_HOME -> major version, or nothing
  local home="$1" line
  [ -x "$home/bin/java" ] && [ -x "$home/bin/javac" ] || return 0
  # All of its output, then the first line: a pipe into `head` can end java
  # with SIGPIPE, which pipefail would turn into a failure.
  line="$("$home/bin/java" -version 2>&1)" || return 0
  line="${line%%$'\n'*}"
  case "$line" in
    *'"1.'*) echo 8 ;;
    *\"*) line="${line#*\"}"; echo "${line%%[.\"+-]*}" ;;
  esac
}

jdk_usable() { # JAVA_HOME
  local major
  major="$(java_major "$1")"
  case "$major" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$major" -ge 17 ] && [ "$major" -le 21 ]
}

sdk_complete() { # ANDROID_HOME
  local sdk="$1"
  [ -d "$sdk/platforms/android-$compile_sdk" ] &&
    [ -d "$sdk/build-tools/$build_tools" ] &&
    [ -d "$sdk/ndk/$ndk_version" ] &&
    [ -d "$sdk/cmake/$cmake_version" ]
}

# --- Flutter -----------------------------------------------------------------

ensure_flutter() {
  local dir="${FLUTTER_VERSIONS_DIR:-}"
  if [ -z "$dir" ] && [ "$system_tools" = 1 ]; then dir="$HOME/.local/share/flutter-versions"; fi
  if [ -n "$dir" ] && [ -x "$dir/$flutter_version/bin/flutter" ]; then
    say "Flutter $flutter_version: $dir/$flutter_version"
    flutter_versions_dir="$dir"
    return
  fi
  linux_x64 || die "Flutter $flutter_version is not installed at $dir/$flutter_version, and this script installs it for Linux on x86_64 only; run tool/install_flutter.sh --sdk-only with FLUTTER_VERSIONS_DIR set"
  flutter_versions_dir="$cache/flutter-versions"
  if [ ! -x "$flutter_versions_dir/$flutter_version/bin/flutter" ]; then
    say "installing Flutter $flutter_version under $flutter_versions_dir"
    FLUTTER_VERSIONS_DIR="$flutter_versions_dir" FLUTTER_SUPPRESS_ANALYTICS=true CI=true \
      "$tool_dir/install_flutter.sh" --sdk-only >&2 ||
      die "could not install Flutter $flutter_version"
  else
    say "Flutter $flutter_version: $flutter_versions_dir/$flutter_version"
  fi
}

# --- JDK ---------------------------------------------------------------------

ensure_jdk() {
  local candidate
  local candidates=("${JAVA_HOME:-}")
  [ "$system_tools" = 0 ] || candidates+=(/usr/lib/jvm/*)
  for candidate in "${candidates[@]}"; do
    [ -n "$candidate" ] || continue
    if jdk_usable "$candidate"; then
      say "JDK $(java_major "$candidate"): $candidate"
      java_home="$candidate"
      return
    fi
  done
  linux_x64 || die "no JDK 17 to 21 found (JAVA_HOME=${JAVA_HOME:-unset}), and this script installs one for Linux on x86_64 only; set JAVA_HOME"
  java_home="$cache/jdk/$jdk_dir_name"
  if ! jdk_usable "$java_home"; then
    say "installing JDK $jdk_dir_name under $cache/jdk"
    mkdir -p "$cache/jdk"
    local archive="$cache/jdk/jdk.tar.gz" tmp="$cache/jdk/unpack"
    fetch "$jdk_url" "$archive" "$jdk_sha256"
    rm -rf "$tmp" "$java_home"
    mkdir -p "$tmp"
    tar -xzf "$archive" -C "$tmp" || die "could not unpack $archive"
    mv "$tmp/$jdk_dir_name" "$java_home" || die "the JDK archive holds no $jdk_dir_name"
    rm -rf "$tmp" "$archive"
    jdk_usable "$java_home" || die "the JDK installed at $java_home does not run"
  else
    say "JDK 21: $java_home"
  fi
}

# --- Android SDK -------------------------------------------------------------

ensure_android_sdk() {
  local candidate
  local candidates=("${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}")
  [ "$system_tools" = 0 ] || candidates+=(/opt/android-sdk "$HOME/Android/Sdk" \
    "$HOME/Library/Android/sdk" /usr/lib/android-sdk)
  for candidate in "${candidates[@]}"; do
    [ -n "$candidate" ] || continue
    if sdk_complete "$candidate"; then
      say "Android SDK: $candidate"
      android_home="$candidate"
      return
    fi
  done
  linux_x64 || die "no Android SDK with platform $compile_sdk, build-tools $build_tools, NDK $ndk_version and CMake $cmake_version found, and this script installs one for Linux on x86_64 only; set ANDROID_HOME"
  android_home="$cache/android-sdk"
  if sdk_complete "$android_home" && [ -d "$android_home/platform-tools" ]; then
    say "Android SDK: $android_home"
    return
  fi
  say "installing the Android SDK under $android_home"
  local manager="$android_home/cmdline-tools/latest/bin/sdkmanager"
  if [ ! -x "$manager" ]; then
    local archive="$cache/cmdline-tools.zip" tmp="$cache/cmdline-tools-unpack"
    fetch "$cmdline_url" "$archive" "$cmdline_sha256"
    rm -rf "$tmp" "$android_home/cmdline-tools"
    mkdir -p "$tmp" "$android_home/cmdline-tools"
    unzip -q "$archive" -d "$tmp" || die "could not unpack $archive"
    mv "$tmp/cmdline-tools" "$android_home/cmdline-tools/latest" ||
      die "the command-line tools archive holds no cmdline-tools directory"
    rm -rf "$tmp" "$archive"
  fi
  if [ ! -f "$android_home/licenses/android-sdk-license" ]; then
    if [ "$accept_licenses" != 1 ]; then
      die "the Android SDK licences are not accepted for $android_home.  Run \"$manager --sdk_root=$android_home --licenses\" to read and accept them, or run this again with --accept-android-licenses (or HARNESS_CLIENT_ACCEPT_ANDROID_LICENSES=1) to accept them for this SDK, which only this toolchain uses"
    fi
    say "accepting the Android SDK licences for $android_home"
    JAVA_HOME="$java_home" "$manager" --sdk_root="$android_home" --licenses \
      < <(yes) >/dev/null 2>&1 || true
    [ -f "$android_home/licenses/android-sdk-license" ] ||
      die "sdkmanager did not accept the licences in $android_home"
  fi
  say "installing platform $compile_sdk, build-tools $build_tools, NDK $ndk_version, CMake $cmake_version"
  JAVA_HOME="$java_home" "$manager" --sdk_root="$android_home" \
    "platform-tools" "platforms;android-$compile_sdk" "build-tools;$build_tools" \
    "ndk;$ndk_version" "cmake;$cmake_version" >&2 ||
    die "sdkmanager could not install the Android SDK components"
  sdk_complete "$android_home" || die "the Android SDK at $android_home is still incomplete after the install"
}

# --- go ----------------------------------------------------------------------

flutter_versions_dir="" java_home="" android_home=""
ensure_flutter
ensure_jdk
ensure_android_sdk

mkdir -p "$cache/gradle-home" "$cache/pub-cache"

q() { printf '%q' "$1"; }
printf 'export FLUTTER_VERSIONS_DIR=%s\n' "$(q "$flutter_versions_dir")"
printf 'export JAVA_HOME=%s\n' "$(q "$java_home")"
printf 'export ANDROID_HOME=%s\n' "$(q "$android_home")"
printf 'export ANDROID_SDK_ROOT=%s\n' "$(q "$android_home")"
printf 'export GRADLE_USER_HOME=%s\n' "$(q "$cache/gradle-home")"
printf 'export PUB_CACHE=%s\n' "$(q "$cache/pub-cache")"
printf 'export PATH=%s:$PATH\n' "$(q "$java_home/bin")"
