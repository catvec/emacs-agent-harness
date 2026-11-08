#!/usr/bin/env bash
# Run the keys demo: Settings › Keys and a message box, in a window of their
# own, on the Linux desktop.  It starts no harness; the settings are the
# app's own, kept on this device.
#
#   harness_client/tool/keys_demo.sh
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
client=$(dirname "$here")
cd "$client"
eval "$(tool/client_toolchain.sh)"
exec tool/flutter run -d linux --target tool/keys_demo.dart
