#!/usr/bin/env bash
# Build the voice audio probe, run it on an Android emulator, and record
# what the platform did with the audio.
#
#   tool/voice_audio_probe.sh [--device SERIAL] [--no-build] [--apk PATH]
#   tool/voice_audio_probe.sh --real-device SERIAL --owner-permission [options]
#
# An emulator, and only an emulator, is chosen on its own.  A run installs
# an app, speaks aloud and moves the media volume; a phone in someone's
# pocket is not a machine to do that to because it happens to be attached.
# A physical phone is run only when it is named with --real-device AND
# --owner-permission says the person who owns it asked for this run, at this
# time.  On a phone the media volume is never raised above the level the
# phone had when the run started, and its own level is put back afterwards.
#
# It builds tool/voice_audio_probe.dart -- the app's own
# `PlatformVoiceAndroidAudio` and `FlutterTtsVoiceSpeech`, and no screen
# of the app -- into a package of its own (app.harness.client.probe, so it
# never replaces the app a person has paired with their harness),
# installs it, runs it, and moves the media volume while it speaks.  The
# probe's own account of the platform is read from logcat, and
# `dumpsys audio` is kept beside it.
#
# The probe measures two things, and prints them under the
# `HarnessVoiceProbe` tag:
#
#   live before / live after
#     flutter_webrtc's defaults, then the app's own output.  `mode=0` and
#     `stream=3` in the second are MODE_NORMAL and STREAM_MUSIC; `mode=3`
#     and `stream=0` in the first are the communication mode and the call
#     stream the app used to play in.
#   clip before / clip after playing
#     the speech engine's own attributes, then the app's session.  The
#     `playing=` field is the platform's report of the active player: its
#     usage, content type, the stream the usage maps to, and that
#     stream's volume.  `stream=3` is STREAM_MUSIC.
#
# What a run is meant to show: the reply's player names STREAM_MUSIC (3),
# the activity's volume control stream is 3, the mode is 0, and the
# player's own `volume` follows the media volume the script sets.  The
# audible level is the one thing a script cannot hear: a person listens
# for that, with the same run, and the script says so when it ends.
#
# Everything it printed is left in scripts/.dev/voice-audio-probe/.
#
# Options:
#   --device SERIAL       run on the attached emulator SERIAL (emulator-*).
#                         A phone's serial is refused here.
#   --real-device SERIAL  run on the attached phone SERIAL.  Never chosen on
#                         its own; needs --owner-permission.
#   --owner-permission    the owner of that phone asked for this run, now
#   --no-build            use the APK that is already built
#   --apk PATH            install PATH instead of the release APK
#   -h, --help            this
#
# Environment:
#   ADB                        adb executable (default: the SDK's, then PATH)
#   ANDROID_HOME               where to find adb
#   HARNESS_VOICE_PROBE_OUT    where to keep what the run printed
#   HARNESS_VOICE_PROBE_PACE   multiply the waits between volume changes
#                              (default 1; 0 is a test that changes nothing)
#
# Exit status: 0 the probe ran and the platform named the media stream;
# 1 the platform named another stream (the bug); 2 a bad option, a missing
# permission, or more than one emulator; 3 no toolchain or no APK; 4 no
# device.

set -uo pipefail

tool_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(dirname "$tool_dir")"
out="${HARNESS_VOICE_PROBE_OUT:-$(dirname "$project_dir")/scripts/.dev/voice-audio-probe}"
device=""
real_device=""
owner_permission=0
build=1
apk=""
pace="${HARNESS_VOICE_PROBE_PACE:-1}"

usage() {
  sed -n '2,/^set -uo/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//'
}

die() {
  echo "probe: $*" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --device) [ $# -ge 2 ] || die '--device needs a serial'; device="$2"; shift ;;
    --real-device) [ $# -ge 2 ] || die '--real-device needs a serial'; real_device="$2"; shift ;;
    --owner-permission) owner_permission=1 ;;
    --no-build) build=0 ;;
    --apk) [ $# -ge 2 ] || die '--apk needs a path'; apk="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
  shift
done

case "$pace" in
  ''|*[!0-9]*) die 'HARNESS_VOICE_PROBE_PACE must be a number of seconds' ;;
esac

# The two flags that reach a person's phone are weighed before anything
# else runs: either one alone is a mistake, and a mistake must not become
# a run on a phone.
if [ -n "$real_device" ] && [ "$owner_permission" != 1 ]; then
  die '--real-device runs on a phone someone owns and needs --owner-permission: its owner asked for this run, now'
fi
if [ -z "$real_device" ] && [ "$owner_permission" = 1 ]; then
  die '--owner-permission is for a --real-device run; an emulator needs none'
fi
if [ -n "$device" ] && [ -n "$real_device" ]; then
  die 'give one of --device (an emulator) and --real-device (a phone), not both'
fi
case "$device" in
  ''|emulator-*) ;;
  *) die "--device is for an emulator; a phone is run with --real-device $device --owner-permission" ;;
esac
if [ -n "$real_device" ]; then
  case "$real_device" in
    emulator-*) die "--real-device is for a phone; an emulator is run with --device $real_device" ;;
  esac
fi

mkdir -p "$out" || { echo "probe: cannot make $out" >&2; exit 2; }
[ -n "$apk" ] || apk="$project_dir/build/app/outputs/flutter-apk/app-release.apk"

if [ "$build" = 1 ]; then
  env_lines="$("$tool_dir/client_toolchain.sh")" || {
    status=$?
    echo 'probe: no toolchain to build with (see above)' >&2
    exit $((status == 2 ? 2 : 3))
  }
  eval "$env_lines"
  FLUTTER="${FLUTTER:-$FLUTTER_VERSIONS_DIR/$(sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$project_dir/.flutter-version" | head -n 1)/bin/flutter}"
  echo 'probe: building the probe APK'
  ( cd "$project_dir" && "$FLUTTER" build apk --release --target=tool/voice_audio_probe.dart -PvoiceProbe=true ) \
    > "$out/build.log" 2>&1 || {
      echo "probe: the build failed; see $out/build.log" >&2
      exit 3
    }
fi

[ -f "$apk" ] || { echo "probe: no APK at $apk" >&2; exit 3; }

if [ -z "${ANDROID_HOME:-}" ]; then
  ANDROID_HOME="${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}"
fi
adb_bin="${ADB:-$ANDROID_HOME/platform-tools/adb}"
[ -x "$adb_bin" ] || adb_bin="$(command -v adb || true)"
[ -n "$adb_bin" ] && [ -x "$adb_bin" ] || { echo 'probe: no adb' >&2; exit 4; }

attached_serials() {
  "$adb_bin" devices | awk 'NR > 1 && $2 == "device" { print $1 }'
}

# A loop rather than a pipe into grep -q: a pipeline that ends early can
# SIGPIPE adb, and under pipefail that reads as "not attached".
attached() { # SERIAL
  local serial
  while IFS= read -r serial; do
    [ "$serial" = "$1" ] && return 0
  done <<< "$(attached_serials)"
  return 1
}

# A phone is not an emulator, whatever its serial looks like: an emulator
# adb made is emulator-N, and that is the only kind this script picks.
emulators() {
  attached_serials | grep -E '^emulator-[0-9]+$' || true
}

on_phone=0
if [ -n "$real_device" ]; then
  attached "$real_device" || { echo "probe: $real_device is not attached (adb devices)" >&2; exit 4; }
  device="$real_device"
  on_phone=1
elif [ -n "$device" ]; then
  attached "$device" || { echo "probe: $device is not attached (adb devices)" >&2; exit 4; }
else
  found="$(emulators)"
  if [ -z "$found" ]; then
    echo 'probe: no emulator is attached, and a phone is never chosen on its own:' >&2
    echo 'probe: start an emulator, or run a phone with --real-device SERIAL --owner-permission' >&2
    exit 4
  fi
  if [ "$(printf '%s\n' "$found" | wc -l | tr -d ' ')" != 1 ]; then
    echo 'probe: more than one emulator is attached; choose one with --device:' >&2
    printf '%s\n' "$found" | sed 's/^/  /' >&2
    exit 2
  fi
  device="$found"
fi

adb() { "$adb_bin" -s "$device" "$@"; }

if [ "$on_phone" = 1 ]; then
  echo "probe: PHONE $device -- its owner asked for this run"
  echo 'probe: it installs a probe app and speaks aloud; the media volume is never raised above the level the phone has now'
else
  echo "probe: emulator $device"
  while IFS= read -r other; do
    case "$other" in
      ''|emulator-*) ;;
      *) echo "probe: leaving the phone $other alone (it needs --real-device and --owner-permission)" ;;
    esac
  done <<< "$(attached_serials)"
fi
# The probe is a package of its own (app.harness.client.probe), never the
# app a person has paired with their harness, so replacing it outright is
# safe: a debug keystore made fresh on each build has another signature,
# and `install -r` would refuse it.
adb uninstall app.harness.client.probe > /dev/null 2>&1 || true
adb install -r "$apk" > "$out/install.log" 2>&1 || {
  echo "probe: the install failed; see $out/install.log" >&2
  exit 4
}

model="$(adb shell getprop ro.product.model | tr -d '\r')"
release="$(adb shell getprop ro.build.version.release | tr -d '\r')"
sdk="$(adb shell getprop ro.build.version.sdk | tr -d '\r')"
echo "probe: $model, Android $release (API $sdk)" | tee "$out/device.txt"

original="$(adb shell cmd media_session volume --stream 3 --get 2>/dev/null | sed -n 's/.*volume is \([0-9][0-9]*\) in range.*/\1/p' | head -n 1)"
restore() {
  if [ -n "$original" ] && [ "$original" != null ]; then
    level="$original"
    if [ "$on_phone" = 1 ]; then
      # Back to what the phone had, unless its owner turned it down while the
      # run spoke: putting that back up would be the run overruling them.
      now="$(adb shell cmd media_session volume --stream 3 --get 2>/dev/null | sed -n 's/.*volume is \([0-9][0-9]*\) in range.*/\1/p' | head -n 1)"
      if [ -n "$now" ] && [ "$now" != null ] && [ "$now" -lt "$level" ]; then
        level="$now"
      fi
    fi
    adb shell cmd media_session volume --stream 3 --set "$level" >/dev/null 2>&1 || true
  fi
  adb shell am force-stop app.harness.client.probe >/dev/null 2>&1 || true
}
trap restore EXIT

# A phone is never made louder than its owner left it: the run needs the
# volume to move, not to be a loud noise in a room somebody is sleeping in.
set_media_volume() { # LEVEL
  level="$1"
  if [ "$on_phone" = 1 ]; then
    # The level now, not only at the start: the phone's owner may have turned
    # it down while the run was speaking, and the run may not undo that.
    ceiling="$(adb shell cmd media_session volume --stream 3 --get 2>/dev/null | sed -n 's/.*volume is \([0-9][0-9]*\) in range.*/\1/p' | head -n 1)"
    [ -n "$ceiling" ] || ceiling="$original"
    if [ -n "$ceiling" ] && [ "$ceiling" != null ] && [ "$level" -gt "$ceiling" ]; then
      echo "probe: media volume $level would be louder than this phone is ($ceiling); staying at $ceiling"
      level="$ceiling"
    fi
  fi
  adb shell cmd media_session volume --stream 3 --set "$level" >/dev/null 2>&1
}

audio_dump() { # FILE LABEL
  {
    echo "=== dumpsys audio ($2) ==="
    adb shell dumpsys audio | grep -iE 'mode:|stream|volume|focus|AudioPlaybackConfiguration|usage=' | head -60
  } > "$1" 2>&1
}

# The probe measures the live path first (a few seconds), then
# speaks the same reply twice, reading the platform's active player
# from inside each utterance.  The media volume is moved between the
# two, so the player's own volume must move with it.
adb logcat -c
adb shell am start -n app.harness.client.probe/app.harness.harness_client.MainActivity > "$out/start.log" 2>&1
sleep $((3 * pace))
set_media_volume 7
audio_dump "$out/dumpsys-volume-7.txt" 'media volume 7, the live path'
sleep $((16 * pace))
set_media_volume 2
audio_dump "$out/dumpsys-volume-2.txt" 'media volume 2, the clip path'
sleep $((16 * pace))
set_media_volume 13
audio_dump "$out/dumpsys-volume-13.txt" 'media volume 13, the clip path'
sleep $((12 * pace))

adb logcat -d -s HarnessVoiceProbe:I HarnessVoiceAudio:I flutter:I '*:S' > "$out/logcat.txt" 2>&1

echo
echo "=== the probe's own account (logcat) ==="
grep -F 'HarnessVoiceProbe' "$out/logcat.txt" | sed 's/^.*HarnessVoiceProbe/HarnessVoiceProbe/' | head -60
echo
echo "probe: everything is in $out"

status=0
if grep -qE 'HarnessVoiceProbe live before .*mode=3' "$out/logcat.txt"; then
  echo 'probe: before the change, the live path held MODE_IN_COMMUNICATION (3)'
fi
if grep -qE 'HarnessVoiceProbe live before .*stream=0' "$out/logcat.txt"; then
  echo 'probe: before the change, the keys controlled STREAM_VOICE_CALL (0)'
fi
if ! grep -qE 'HarnessVoiceProbe live before .*mode=' "$out/logcat.txt"; then
  echo 'probe: the live before-reading is missing (no microphone to start it)'
fi
if grep -qE 'HarnessVoiceProbe live after .*mode=0 ' "$out/logcat.txt" && \
   grep -qE 'HarnessVoiceProbe live after .*stream=3 ' "$out/logcat.txt"; then
  echo 'probe: after the change, the live path holds MODE_NORMAL (0) on STREAM_MUSIC (3)'
else
  echo 'probe: the live path did not land on MODE_NORMAL on STREAM_MUSIC'; status=1
fi
if grep -qE 'HarnessVoiceProbe clip after playing .*playing=usage=[0-9]+/[a-zA-Z]+/contentType=[0-9]+/stream=3/' "$out/logcat.txt"; then
  echo 'probe: the reply is played on STREAM_MUSIC (3): media volume controls it'
else
  echo 'probe: the reply was not reported on STREAM_MUSIC'; status=1
fi
echo 'probe: whether it got quieter is for a person to hear, not for this script'
exit $status
