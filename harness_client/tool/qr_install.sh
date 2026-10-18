#!/usr/bin/env bash
# Build the Harness Android app and install it on a phone over Wi-Fi, with no
# USB cable.  The phone pairs as a wireless debugging device by scanning a QR
# code shown here; adb then installs the APK over the local network.
#
#   tool/qr_install.sh                 build a release APK if needed, pair, install, launch
#   tool/qr_install.sh --build         build first even if the APK is there
#   tool/qr_install.sh --debug         use/build the debug APK
#   tool/qr_install.sh --serve         do not use adb: serve the APK and show its URL
#                                      as a QR code, so a phone can download it
#
# On Android 11 or newer, turn on Developer options -> Wireless debugging and
# tap "Pair device with QR code", then scan the code printed here.  The phone
# and this computer must be on the same network.
set -euo pipefail

tool_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(dirname "$tool_dir")"
invocation_dir="$PWD"
cd "$project_dir"

build=auto
build_mode=release
apk=""
device=""
launch=1
serve=0
serve_address=""
timeout=180

usage() {
  cat <<EOF
Usage: tool/qr_install.sh [options]

Build the Harness Android APK if needed and install it on a phone over Wi-Fi.
The phone pairs with adb by scanning a QR code shown in this terminal.

Options:
  --build          build the APK even when it already exists
  --no-build       never build; fail when the APK is missing
  --debug          use and build the debug APK instead of the release one
  --apk PATH       install PATH (implies --no-build)
  --device SERIAL  install on an already connected device (its adb serial)
  --no-launch      do not open the app after installing it
  --serve          serve the APK over HTTP and show its URL as a QR code
                   instead of pairing adb (the phone downloads and installs it)
  --address ADDR   with --serve, put ADDR in the URL instead of detecting it
  --timeout N      seconds to wait for the phone to scan and connect (default 180)
  -h, --help       show this help

Environment:
  ADB              adb executable to use (default: adb on PATH, then the
                   platform-tools of ANDROID_HOME, ANDROID_SDK_ROOT and the
                   usual SDK locations)
  FLUTTER          flutter executable to build with (default: tool/flutter,
                   which selects the SDK pinned in .flutter-version)

Examples:
  tool/qr_install.sh                  # release build, install, open
  tool/qr_install.sh --build          # rebuild, then install
  tool/qr_install.sh --serve          # download over HTTP instead of adb

Android 11 or newer: Settings -> System -> Developer options -> Wireless
debugging -> Pair device with QR code.  The phone and this computer must be on
the same network.
EOF
}

die() {
  printf 'qr_install: %s\n' "$*" >&2
  exit 1
}

note() {
  printf '%s\n' "$*"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --build) build=always ;;
    --no-build) build=never ;;
    --debug) build_mode=debug ;;
    --apk)
      [ $# -ge 2 ] || die "--apk needs a path"
      apk="$2"
      build=never
      shift
      ;;
    --device)
      [ $# -ge 2 ] || die "--device needs an adb serial"
      device="$2"
      shift
      ;;
    --no-launch) launch=0 ;;
    --serve) serve=1 ;;
    --address)
      [ $# -ge 2 ] || die "--address needs an IP address or host name"
      serve_address="$2"
      shift
      ;;
    --timeout)
      [ $# -ge 2 ] || die "--timeout needs a number of seconds"
      timeout="$2"
      shift
      ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
  shift
done

command -v python3 >/dev/null 2>&1 || die "python3 is required (it draws the QR code)"

case "$timeout" in
  ""|*[!0-9]*) die "--timeout needs a positive number of seconds" ;;
esac
[ "$timeout" -gt 0 ] || die "--timeout needs a positive number of seconds"

if [ -z "$apk" ]; then
  apk="$project_dir/build/app/outputs/flutter-apk/app-$build_mode.apk"
else
  case "$apk" in
    /*) ;;
    *) apk="$invocation_dir/$apk" ;;
  esac
fi

if [ "$build" != never ] && { [ "$build" = always ] || [ ! -f "$apk" ]; }; then
  [ "$build" = always ] || note "No APK at ${apk#"$project_dir"/}; building one."
  flutter="${FLUTTER:-$tool_dir/flutter}"
  if [ ! -x "$flutter" ]; then
    flutter="$(command -v flutter || true)"
  fi
  [ -n "$flutter" ] || die "Flutter not found; run tool/install_flutter.sh first or set FLUTTER"
  note "Building the $build_mode APK (this can take a minute)..."
  "$flutter" build apk "--$build_mode"
fi
[ -f "$apk" ] || die "APK not found: $apk (run without --no-build to build it)"

# Serve the APK over HTTP for phones without wireless debugging.
if [ "$serve" = 1 ]; then
  serve_args=()
  [ -n "$serve_address" ] && serve_args=(--address "$serve_address")
  exec python3 "$tool_dir/serve_apk.py" ${serve_args[@]+"${serve_args[@]}"} "$apk"
fi

find_adb() {
  local candidate
  if [ -n "${ADB:-}" ]; then
    candidate="$(command -v "$ADB" 2>/dev/null || true)"
    [ -n "$candidate" ] || die "ADB=$ADB is not an executable file"
    printf '%s\n' "$candidate"
    return 0
  fi
  for candidate in \
    adb \
    "${ANDROID_HOME:-}/platform-tools/adb" \
    "${ANDROID_SDK_ROOT:-}/platform-tools/adb" \
    "$HOME/Android/Sdk/platform-tools/adb" \
    "$HOME/Library/Android/sdk/platform-tools/adb" \
    /opt/android-sdk/platform-tools/adb \
    /usr/lib/android-sdk/platform-tools/adb \
    /usr/local/android-sdk/platform-tools/adb; do
    [ -n "$candidate" ] || continue
    if command -v "$candidate" >/dev/null 2>&1; then
      command -v "$candidate"
      return 0
    fi
  done
  die "adb not found; install Android SDK platform-tools, put adb on PATH, or set ADB (or use --serve to download the APK instead)"
}

adb="$(find_adb)"

device_serials() {
  "$adb" devices 2>/dev/null | awk 'NR > 1 && $2 == "device" { print $1 }'
}

pairing_services() {
  "$adb" mdns services 2>/dev/null |
    awk '$2 ~ /^_adb-tls-pairing\._tcp\.?$/ { print $3 }'
}

connect_services() {
  "$adb" mdns services 2>/dev/null |
    awk '$2 ~ /^_adb-tls-connect\._tcp\.?$/ { print $3 }'
}

# Pick a connected device, or pair one by QR code.
serial=""
if [ -n "$device" ]; then
  "$adb" -s "$device" get-state >/dev/null 2>&1 || die "device $device is not connected"
  serial="$device"
else
  serials=()
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    # An emulator is not the phone this tool is for; name it with --device.
    case "$line" in emulator-*) continue ;; esac
    serials+=("$line")
  done < <(device_serials)
  if [ ${#serials[@]} -eq 1 ]; then
    serial="${serials[0]}"
    note "Using the connected device $serial."
  elif [ ${#serials[@]} -gt 1 ]; then
    printf 'qr_install: more than one device is connected; choose one with --device:\n' >&2
    printf '  %s\n' "${serials[@]}" >&2
    exit 1
  fi
fi

if [ -z "$serial" ]; then
  read -r pair_name pair_password < <(python3 - <<'PY'
import secrets
import string

alphabet = string.ascii_letters + string.digits
name = "ADB_WIFI_" + "".join(secrets.choice(alphabet) for _ in range(14)) + "-" + \
    "".join(secrets.choice(alphabet) for _ in range(6))
password = "".join(secrets.choice(alphabet) for _ in range(21))
print(name, password)
PY
)
  [ -n "$pair_name" ] && [ -n "$pair_password" ] || die "could not generate the pairing code"
  qrtext="WIFI:T:ADB;S:$pair_name;P:$pair_password;;"

  cat <<EOF
On the phone:
  Settings -> System -> Developer options -> Wireless debugging
  -> Pair device with QR code, then scan this code.

The phone and this computer must be on the same network.  Waiting up to
$timeout seconds for the code to be scanned ...
EOF

  python3 "$tool_dir/qr_terminal.py" "$qrtext"
  note ""

  paired=""
  paired_host=""
  deadline=$((SECONDS + timeout))
  while [ "$SECONDS" -lt "$deadline" ]; do
    while IFS= read -r service; do
      [ -n "$service" ] || continue
      if output="$("$adb" pair "$service" "$pair_password" 2>&1)"; then
        case "$output" in
          *[Ss]uccess*)
            paired="$service"
            break
            ;;
        esac
      fi
    done < <(pairing_services)
    [ -n "$paired" ] && break
    printf '.'
    sleep 1
  done
  printf '\n'
  [ -n "$paired" ] || die "timed out waiting for the phone; check that wireless debugging is on and the network is the same"

  paired_host="${paired%:*}"
  note "Paired with ${paired_host}."

  # The phone advertises its wireless debugging port over mDNS once paired,
  # and adb may also auto-connect to that mDNS service by itself.
  connect_addr=""
  deadline=$((SECONDS + timeout))
  while [ "$SECONDS" -lt "$deadline" ]; do
    while IFS= read -r line; do
      case "$line" in emulator-*) continue ;; esac
      serial="$line"
      break
    done < <(device_serials)
    [ -n "$serial" ] && break
    fallback=""
    while IFS= read -r service; do
      [ -n "$service" ] || continue
      [ -n "$fallback" ] || fallback="$service"
      if [ "${service%:*}" = "$paired_host" ]; then
        connect_addr="$service"
        break
      fi
    done < <(connect_services)
    [ -n "$connect_addr" ] && break
    if [ -n "$fallback" ]; then
      connect_addr="$fallback"
      break
    fi
    sleep 1
  done

  if [ -z "$serial" ]; then
    [ -n "$connect_addr" ] || die "paired, but the phone did not advertise a debugging port; try again or use --serve"
    output="$("$adb" connect "$connect_addr" 2>&1 || true)"
    case "$output" in
      *"connected to"*|*"already connected"*) note "$output" ;;
      *) die "could not connect to $connect_addr: $output" ;;
    esac
    deadline=$((SECONDS + 30))
    while [ "$SECONDS" -lt "$deadline" ] && [ -z "$serial" ]; do
      while IFS= read -r line; do
        if [ "$line" = "$connect_addr" ]; then
          serial="$line"
          break
        fi
      done < <(device_serials)
      [ -n "$serial" ] || sleep 1
    done
    [ -n "$serial" ] || die "connected to $connect_addr, but adb does not list it as a device"
  fi
fi

note "Installing ${apk##*/} on $serial ..."
install_status=0
output="$("$adb" -s "$serial" install -r "$apk" 2>&1)" || install_status=$?
case "$output" in
  *Success*)
    [ "$install_status" -eq 0 ] || { printf '%s\n' "$output" >&2; die "adb install failed"; }
    note "Installed."
    ;;
  *INSTALL_FAILED_UPDATE_INCOMPATIBLE*)
    printf '%s\n' "$output" >&2
    note "The installed app was signed with another key.  Remove it, then try again:"
    note "  $adb -s $serial uninstall app.harness.client"
    exit 1
    ;;
  *)
    [ -z "$output" ] || printf '%s\n' "$output" >&2
    die "adb install failed"
    ;;
esac

if [ "$launch" = 1 ]; then
  if "$adb" -s "$serial" shell am start -W \
      -n app.harness.client/app.harness.harness_client.MainActivity >/dev/null 2>&1; then
    note "Opened Harness on the phone."
  else
    note "Installed, but the app could not be opened; start it from the phone's launcher."
  fi
fi

note ""
note "Harness is on the phone.  In the app, connect to the harness's ws:// address"
note "(Emacs: C-c h P, [start serving]) and its token from acp-token."
note "For hot reload while the phone is connected: tool/flutter run -d $serial"
