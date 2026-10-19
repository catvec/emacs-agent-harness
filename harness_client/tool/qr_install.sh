#!/usr/bin/env bash
# Build the Harness Android app and install it on a phone over Wi-Fi, with no
# USB cable.  The phone pairs as a wireless debugging device with the six-digit
# pairing code it shows; adb then installs the APK over the local network.
#
#   tool/qr_install.sh                 build a release APK if needed, pair, install, launch
#   tool/qr_install.sh --build         build first even if the APK is there
#   tool/qr_install.sh --debug         use/build the debug APK
#   tool/qr_install.sh --qr            pair by scanning a QR code instead of the
#                                      six-digit code
#   tool/qr_install.sh --serve         do not use adb: serve the APK and show its URL
#                                      as a QR code, so a phone can download it
#
# On Android 11 or newer, turn on Developer options -> Wireless debugging and
# open "Pair device with pairing code" (or, with --qr, "Pair device with QR
# code").  The phone and this computer must be on the same network.
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
image=auto
connect_hint=""
pair_mode=code
pair_code=""
pair_address=""
# Tests set this to a known mDNS pairing name; normally it is random.
pair_name_override="${QR_INSTALL_PAIR_NAME:-}"

usage() {
  cat <<EOF
Usage: tool/qr_install.sh [options]

Build the Harness Android APK if needed and install it on a phone over Wi-Fi.
The phone pairs with adb through Wireless debugging; this terminal asks for the
six-digit pairing code the phone shows.

Options:
  --build          build the APK even when it already exists
  --no-build       never build; fail when the APK is missing
  --debug          use and build the debug APK instead of the release one
  --apk PATH       install PATH (implies --no-build)
  --device SERIAL  install on an already connected device (its adb serial)
  --connect ADDR   connect to ADDR (IP:PORT, e.g. from Wireless debugging)
                   instead of pairing
  --qr             pair by scanning a wireless-debugging QR code instead of
                   typing the six-digit code
  --pair-code CODE the six digits shown by "Pair device with pairing code"
                   (otherwise asked for when the phone is found)
  --pair-address ADDR  the IP:PORT shown in that dialog, when mDNS cannot
                   find the phone
  --no-launch      do not open the app after installing it
  --no-image       do not open the large QR image in a viewer (with --qr)
  --serve          serve the APK over HTTP and show its URL as a QR code
                   instead of pairing adb (the phone downloads and installs it)
  --address ADDR   with --serve, put ADDR in the URL instead of detecting it
  --timeout N      seconds to wait for the phone to pair and connect (default 180)
  -h, --help       show this help

Environment:
  ADB              adb executable to use (default: adb on PATH, then the
                   platform-tools of ANDROID_HOME, ANDROID_SDK_ROOT and the
                   usual SDK locations)
  FLUTTER          flutter executable to build with (default: tool/flutter,
                   which selects the SDK pinned in .flutter-version)

Examples:
  tool/qr_install.sh                  # release build, pair by code, install, open
  tool/qr_install.sh --build          # rebuild, then install
  tool/qr_install.sh --qr             # pair by scanning a QR code instead
  tool/qr_install.sh --connect 192.168.1.7:41234  # skip pairing, use this port
  tool/qr_install.sh --serve          # download over HTTP instead of adb

Android 11 or newer: Settings -> System -> Developer options -> Wireless
debugging -> Pair device with pairing code.  Keep that dialog open; this script
finds the phone with mDNS, asks for the six digits, then installs the app.  The
phone and this computer must be on the same network.

--qr shows the Android Studio-style pairing QR code instead.  That code is
stored in Android's Wi-Fi QR format (WIFI:T:ADB;...), so scan it only from the
Wireless debugging screen: a camera app can read it as a Wi-Fi network and take
the phone off its current network.  The default pairing-code flow never sends a
Wi-Fi QR code to the phone.
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
    --connect)
      [ $# -ge 2 ] || die "--connect needs IP:PORT"
      connect_hint="$2"
      shift
      ;;
    --qr) pair_mode=qr ;;
    --pair-code)
      [ $# -ge 2 ] || die "--pair-code needs the six digits shown on the phone"
      pair_code="$2"
      shift
      ;;
    --pair-address)
      [ $# -ge 2 ] || die "--pair-address needs IP:PORT"
      pair_address="$2"
      shift
      ;;
    --no-launch) launch=0 ;;
    --no-image) image=0 ;;
    --image) image=1 ;;
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

if [ -n "$pair_code" ]; then
  case "$pair_code" in
    [0-9][0-9][0-9][0-9][0-9][0-9]) ;;
    *) die "--pair-code must be the six digits shown on the phone" ;;
  esac
fi
if [ "$pair_mode" = qr ] && { [ -n "$pair_code" ] || [ -n "$pair_address" ]; }; then
  die "--qr pairs by scanning a code; --pair-code and --pair-address are for the default code pairing"
fi

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
  [ -n "$serve_address" ] && serve_args+=(--address "$serve_address")
  [ "$image" = 0 ] && serve_args+=(--no-image)
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

# Clear/status escapes need a real terminal, not a pipe or an Emacs comint
# buffer (which sets TERM=dumb and shows control characters literally).
tty_ok=0
if [ -t 1 ] && [ -n "${TERM:-}" ] && [ "${TERM}" != dumb ]; then
  tty_ok=1
fi

device_serials() {
  "$adb" devices 2>/dev/null | awk 'NR > 1 && $2 == "device" { print $1 }'
}

device_rows() {
  "$adb" devices 2>/dev/null | awk 'NR > 1 && NF >= 2 { print $1 "\t" $2 }'
}

# The mDNS services adb has seen: instance name, service type, address.
mdns_rows() {
  "$adb" mdns services 2>/dev/null |
    awk 'NF >= 3 && $2 ~ /^_adb-tls-(pairing|connect)\._tcp\.?$/ {
           print $1 "\t" $2 "\t" $3
         }'
}

pairing_addrs() {
  mdns_rows | awk -F '\t' '$2 ~ /pairing/ { print $3 }'
}

status_line() {
  [ "$tty_ok" = 1 ] || return 0
  printf '\r%s\033[K' "$1"
}

clear_status() {
  [ "$tty_ok" = 1 ] || return 0
  printf '\r\033[K'
}

# Draw the code on a clean screen, so an older code from a previous run is not
# beside it for the camera to pick, and keep the terminal QR and a large image
# window showing the same thing while the phone scans.
show_qr() {
  local qrtext="$1" args=(--level L)
  if [ "$image" != 0 ] &&
      { [ "$image" = 1 ] || { [ "$tty_ok" = 1 ] && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; }; }; then
    args+=(--open)
  fi
  if [ "$tty_ok" = 1 ]; then
    printf '\033[2J\033[H'
    note "Wireless debugging > Pair device with QR code"
    note "Scan it there, not with the camera app: a camera reads it as a Wi-Fi network."
  fi
  python3 "$tool_dir/qr_terminal.py" ${args[@]+"${args[@]}"} "$qrtext"
  note ""
}

# A serial belongs to the phone just paired if it carries the phone's address
# or its mDNS guid.  Never accept another device that happens to be connected.
serial_matches() {
  case "$1" in
    "$paired_host":*) return 0 ;;
  esac
  [ -n "$guid" ] || return 1
  case "$1" in
    "$guid"*|*"$guid"*) return 0 ;;
  esac
  return 1
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

# An explicit address is the recovery path when the phone shows its debugging
# port in Settings but mDNS has gone quiet.
if [ -z "$serial" ] && [ -n "$connect_hint" ]; then
  if "$adb" -s "$connect_hint" get-state >/dev/null 2>&1; then
    serial="$connect_hint"
  else
    note "Connecting to $connect_hint ..."
    output="$("$adb" connect "$connect_hint" 2>&1 || true)"
    case "$output" in
      *"connected to"*|*"already connected"*) note "$output" ;;
      *) die "could not connect to $connect_hint: $output" ;;
    esac
    hint_host="${connect_hint%:*}"
    deadline=$((SECONDS + 30))
    while [ "$SECONDS" -lt "$deadline" ] && [ -z "$serial" ]; do
      while IFS=$'\t' read -r cand state; do
        [ "$state" = device ] || continue
        case "$cand" in
          "$connect_hint"|"$hint_host":*) serial="$cand"; break ;;
        esac
      done < <(device_rows)
      [ -n "$serial" ] || sleep 1
    done
    [ -n "$serial" ] || die "connected to $connect_hint, but adb does not list it as a device"
  fi
fi

# Find the phone's pairing dialog, or take the address the user read from it.
# Sets pairing_addr.
pairing_addr=""
resolve_pairing_address() {
  pairing_addr=""
  if [ -n "$pair_address" ]; then
    pairing_addr="$pair_address"
    return 0
  fi
  local baseline all addr new_addr last_addr count start deadline
  baseline=" $(pairing_addrs | tr '\n' ' ') "
  start=$SECONDS
  deadline=$((SECONDS + (timeout < 10 ? timeout : 10)))
  count=0
  last_addr=""
  while :; do
    all="$(pairing_addrs)"
    new_addr=""
    count=0
    while IFS= read -r addr; do
      [ -n "$addr" ] || continue
      count=$((count + 1))
      last_addr="$addr"
      case "$baseline" in *" $addr "*) ;; *) new_addr="$addr" ;; esac
    done <<< "$all"
    # One service is the dialog the user just opened.  With several, prefer
    # one that appeared after this run started; the others are stale.
    if [ "$count" -eq 1 ]; then
      pairing_addr="$(printf '%s\n' "$all" | head -n 1)"
      clear_status
      return 0
    fi
    if [ "$count" -gt 1 ] && [ -n "$new_addr" ]; then
      pairing_addr="$new_addr"
      clear_status
      return 0
    fi
    [ "$SECONDS" -lt "$deadline" ] || break
    status_line "Waiting for the phone's pairing dialog ... $((SECONDS - start))s"
    sleep 1
  done
  clear_status
  if [ "$count" -gt 0 ]; then
    note "Several pairing services are advertised:"
    while IFS= read -r addr; do
      [ -n "$addr" ] && note "  $addr"
    done <<< "$all"
    pairing_addr="$last_addr"
    note "Using the last one: $pairing_addr (pass --pair-address to choose another)."
    return 0
  fi
  printf 'Type the IP:PORT shown by "Pair device with pairing code" (or Enter to cancel): '
  read -r pairing_addr || true
  [ -n "$pairing_addr" ] || {
    note "Could not find the phone's pairing service with mDNS." >&2
    note "Pass the IP:PORT shown by Pair device with pairing code with --pair-address." >&2
    return 1
  }
  case "$pairing_addr" in
    *:*) return 0 ;;
    *) note "That is not an IP:PORT address." >&2; return 1 ;;
  esac
}

# Pair with the six-digit code from "Pair device with pairing code".  This
# sends no Wi-Fi QR code to the phone, so it cannot take it off its network.
pair_with_code() {
  cat <<EOF
On the phone:
  Settings -> System -> Developer options -> Wireless debugging
  -> Pair device with pairing code.

Keep that dialog open.  This computer finds the phone with mDNS, asks for the
six digits, then installs the app.  The phone and this computer must be on the
same network.
EOF
  resolve_pairing_address || exit 1
  note "Pairing address: $pairing_addr"
  local code="$pair_code" output
  if [ -z "$code" ]; then
    printf 'Six-digit pairing code shown on the phone: '
    if [ -t 0 ]; then
      read -r -s code || true
      printf '\n'
    else
      read -r code || true
      printf '\n'
    fi
  fi
  [ -n "$code" ] || die "no pairing code given; pass --pair-code CODE (the six digits shown on the phone)"
  case "$code" in
    [0-9][0-9][0-9][0-9][0-9][0-9]) ;;
    *) die "the pairing code must be six digits" ;;
  esac
  note "Pairing with $pairing_addr ..."
  if output="$("$adb" pair "$pairing_addr" "$code" 2>&1)"; then
    case "$output" in
      *[Ss]uccess*) ;;
      *) die "could not pair with $pairing_addr: $output" ;;
    esac
  else
    die "could not pair with $pairing_addr: $output"
  fi
  paired="$pairing_addr"
  guid="$(printf '%s\n' "$output" |
    sed -n 's/.*\[guid=\([^]]*\)\].*/\1/p' | tail -n 1)"
  paired_host="${paired%:*}"
  note "Paired with $paired_host."
}

# Pair by scanning a QR code.  Android stores this code in the Wi-Fi QR format
# (WIFI:T:ADB;...), even though it only carries a service name and password.
# The service name is longer than the 32-byte Wi-Fi SSID limit, so a camera app
# that reads the code as a network cannot join it; the wireless debugging
# scanner passes the full name to mDNS, where 63 bytes are allowed.
pair_with_qr() {
  read -r pair_name pair_password < <(
    python3 "$tool_dir/qr_terminal.py" --pairing "$pair_name_override"
  )
  [ -n "$pair_name" ] && [ -n "$pair_password" ] || die "could not generate the pairing code"
  qrtext="WIFI:T:ADB;S:$pair_name;P:$pair_password;;"

  cat <<EOF
On the phone:
  Settings -> System -> Developer options -> Wireless debugging
  -> Pair device with QR code, then scan this code.

Scan it from that screen, not with the camera app: the code is in Android's
Wi-Fi QR format, and a camera can read it as a network to join.  The phone and
this computer must be on the same network.  Waiting up to $timeout seconds.
EOF

  # A pairing server left over from a previous try is not ours; its password
  # will not match.  Ours is the one that asked for this service name.
  baseline_pairing=" $(pairing_addrs | tr '\n' ' ') "
  show_qr "$qrtext"

  paired=""
  guid=""
  last_pair_error=""
  pair_start=$SECONDS
  deadline=$((SECONDS + timeout))
  fallback_at=$((SECONDS + 8))
  last_pair_addr=""
  last_pair_try=-10
  while [ "$SECONDS" -lt "$deadline" ]; do
    services="$(mdns_rows)"
    candidate=""
    while IFS=$'\t' read -r name type addr; do
      [ -n "$addr" ] || continue
      case "$type" in _adb-tls-pairing*) ;; *) continue ;; esac
      case "$name" in
        "$pair_name"|"$pair_name"*) candidate="$addr"; break ;;
      esac
    done <<< "$(printf '%s\n' "$services" | awk -F '\t' '$2 ~ /pairing/')"

    if [ -z "$candidate" ] && [ "$SECONDS" -ge "$fallback_at" ]; then
      # Some Android versions add a suffix to the requested name; after a
      # few seconds accept a new pairing server, then any of them.
      while IFS=$'\t' read -r name type addr; do
        [ -n "$addr" ] || continue
        case "$type" in _adb-tls-pairing*) ;; *) continue ;; esac
        case "$baseline_pairing" in *" $addr "*) continue ;; esac
        candidate="$addr"
        break
      done <<< "$(printf '%s\n' "$services" | awk -F '\t' '$2 ~ /pairing/')"
      if [ -z "$candidate" ]; then
        candidate="$(printf '%s\n' "$services" |
          awk -F '\t' '$2 ~ /pairing/ { print $3; exit }')"
      fi
    fi

    if [ -n "$candidate" ] &&
        { [ "$candidate" != "$last_pair_addr" ] ||
          [ $((SECONDS - last_pair_try)) -ge 3 ]; }; then
      last_pair_addr="$candidate"
      last_pair_try=$SECONDS
      if output="$("$adb" pair "$candidate" "$pair_password" 2>&1)"; then
        case "$output" in
          *[Ss]uccess*)
            paired="$candidate"
            guid="$(printf '%s\n' "$output" |
              sed -n 's/.*\[guid=\([^]]*\)\].*/\1/p' | tail -n 1)"
            break
            ;;
        esac
      fi
      last_pair_error="$output"
    fi
    status_line "Waiting for the phone to scan the code ... $((SECONDS - pair_start))s"
    sleep 1
  done
  clear_status
  if [ -z "$paired" ]; then
    [ -z "$last_pair_error" ] || printf 'qr_install: last adb pair error: %s\n' "$last_pair_error" >&2
    die "timed out waiting for the phone; check that wireless debugging is on and the network is the same"
  fi

  paired_host="${paired%:*}"
  note "Paired with $paired_host."
}

# Wireless debugging may publish its TLS port only after pairing.  The connect
# record can also be stale for a few seconds, so try every record for this
# phone, and only this phone, until one answers.  Sets serial.
wait_for_connection() {
  note "Waiting for the phone's debugging port ..."
  local connect_start deadline last_connect_try last_connect_error connect_ok
  connect_start=$SECONDS
  deadline=$((SECONDS + timeout))
  last_connect_try=-10
  last_connect_error=""
  connect_ok=""
  while [ "$SECONDS" -lt "$deadline" ]; do
    while IFS=$'\t' read -r cand state; do
      [ "$state" = device ] || continue
      if serial_matches "$cand"; then
        serial="$cand"
        break
      fi
    done < <(device_rows)
    [ -n "$serial" ] && break

    if [ $((SECONDS - last_connect_try)) -ge 3 ]; then
      last_connect_try=$SECONDS
      services="$(mdns_rows)"
      # First the service whose instance name carries the guid adb reported
      # when it paired; then any other connect service on the same address.
      if [ -n "$guid" ]; then
        while IFS=$'\t' read -r name type addr; do
          [ -n "$addr" ] || continue
          case "$type" in _adb-tls-connect*) ;; *) continue ;; esac
          case "$name" in "$guid"*) ;; *) continue ;; esac
          # The guid comes from this pairing, so this is the same phone even
          # if it moved to another address; only a foreign service without
          # its guid is refused.
          output="$("$adb" connect "$addr" 2>&1 || true)"
          case "$output" in
            *"connected to"*|*"already connected"*)
              if [ "$addr" != "$connect_ok" ]; then
                clear_status
                note "$output"
                connect_ok="$addr"
              fi
              ;;
            *) last_connect_error="$output" ;;
          esac
        done <<< "$(printf '%s\n' "$services" | awk -F '\t' '$2 ~ /connect/')"
      fi
      while IFS=$'\t' read -r name type addr; do
        [ -n "$addr" ] || continue
        case "$type" in _adb-tls-connect*) ;; *) continue ;; esac
        [ "${addr%:*}" = "$paired_host" ] || continue
        if [ -n "$guid" ]; then
          case "$name" in "$guid"*) continue ;; esac
        fi
        output="$("$adb" connect "$addr" 2>&1 || true)"
        case "$output" in
          *"connected to"*|*"already connected"*)
            if [ "$addr" != "$connect_ok" ]; then
              clear_status
              note "$output"
              connect_ok="$addr"
            fi
            ;;
          *) last_connect_error="$output" ;;
        esac
      done <<< "$(printf '%s\n' "$services" | awk -F '\t' '$2 ~ /connect/')"
    fi
    status_line "Waiting for the phone's debugging port ... $((SECONDS - connect_start))s"
    sleep 1
  done
  clear_status
  if [ -z "$serial" ]; then
    [ -z "$last_connect_error" ] ||
      printf 'qr_install: last adb connect error: %s\n' "$last_connect_error" >&2
    note "Paired with $paired_host, but its wireless debugging port did not open." >&2
    note "Open Developer options > Wireless debugging on the phone, read the" >&2
    note "'IP address & port' shown there, then run:" >&2
    note "  tool/qr_install.sh --connect IP:PORT" >&2
    exit 1
  fi
  note "Connected to $serial."
}

if [ -z "$serial" ]; then
  if [ "$pair_mode" = qr ]; then
    pair_with_qr
  else
    pair_with_code
  fi
  wait_for_connection
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
