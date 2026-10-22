# Verification

- `flutter-version.txt` — the `~/.local/bin/flutter` launcher selects the SDK
  pinned in `.flutter-version` (3.47.7) inside `harness_client`; from an
  unrelated directory it still selects the machine's default 3.16.4.
- `apk-build.txt` — release APK built with `flutter build apk` through that
  launcher and the system `/opt/android-sdk`, after pinning the installed NDK,
  Build-Tools, platform and CMake versions in `android/gradle.properties`.
- `analyze.txt` — `flutter analyze` on the final tree: *No issues found*.
- `test.txt` — `flutter test`: 21 unit, reducer and widget-flow tests.
- `e2e.txt` — the Playwright run on iPhone 13, Pixel 7 and a 1280×900 macOS
  layout; every flow completed and wrote a screenshot to `../screenshots/`.
- `real-harness-probe.txt` — the client core against a real
  `emacs-agent-harness` 3.0.0 (headless, demo provider) over ACP: initialize,
  capability discovery, `session/list`, `session/new`, a streamed
  `session/prompt`, activity, nodes and replay.
- `apk-inspect.txt` — package id, label, INTERNET permission, min/target SDK,
  ABIs and signer of the shipped APK.
- `web-build.txt` — release web build.
- `sha256.txt` — checksums of the test builds.
- `web-prod-smoke.txt` / `production-web.png` — the production web build,
  served as a static site and connected to the preview harness, with no page
  errors.
- `qr-install.txt` — the phone installer: the tool tests, the encoder checked
  against qrencode and the harness's own encoder, the foreign-host and
  stale-port mDNS regressions that caused `192.168.1.117:46037` to be tried,
  and a full install through a fake adb.  It covers the report "why doesn't qr
  install show a qr code anymore?": a plain run shows the QR code again (the
  six-digit code is `--code`), with what AOSP's Wireless debugging scanner does
  with it, and the Wi-Fi-disconnect hardening that stays (a service name longer
  than a Wi-Fi SSID, so a camera cannot join it as a network).
  `qr-install-default.png` is a plain run in a real terminal waiting for the
  scan, and `qr-install-default-done.png` the same run once paired;
  `qr-install-code.png` is the `--code` (six-digit) flow;
  `qr-install-scan.png` and `qr-install.png` are earlier renderings of the QR
  screen and a finished run; `qr-install-large.png` is the large image the
  viewer opens; `qr-install-serve.png` is the `--serve` download mode.  The QR
  decodes back to the exact pairing text in every capture.
- `phone-debugging-port.txt` — the report "i paired w qr code but now it is
  stuck waiting for phone's debugging port": the phone's real `adb mdns
  services` listing (the live service renamed `NAME (2)` beside an old record
  of the plain name on a closed port), why reading adb's tab-separated output
  by spaces dropped the live service, and the original and the fixed
  `tool/qr_install.sh` run on that listing (the original retries the closed
  port until it times out, the fixed one connects to the live port), with the
  new tests run against both scripts.  `phone-debugging-port.png` is the two
  runs' terminal screens, one above the other (rendered from the captured pty
  text).
- `pub-cache-repair.txt` — the build that stops with `Error when reading
  '.../.pub-cache/.../shared_preferences-2.5.6/lib/shared_preferences.dart': No
  such file or directory` right after `pub get` said "Got dependencies!": how a
  package loses its files without pub noticing, reproduced with the real
  Flutter SDK, and `tool/qr_install.sh` finding the package, reinstalling the
  packages of `pubspec.lock` with `flutter pub cache repair` and finishing the
  install.
- `r8-prefs-release-build.txt` — the report "I have to re-enter my address and
  token almost every time I open the app, although Remember is on": the
  release apk (`tool/qr_install.sh`) runs R8, and with
  `shared_preferences_android` 2.5.0 locked R8 renames the Kotlin classes the
  plugin looks up by name through JNI (`kotlin.Unit`, `kotlin.Result`,
  `Continuation`, ...), which kills the plugin at startup, so the app could
  neither read nor save anything on the phone.  The two release builds (2.5.0
  from `git archive HEAD`, and this tree with 2.5.2) and what each leaves of
  those classes in `mapping.txt`, with the merged keep rules.

The toolchain pieces above are reproducible: `tool/install_flutter.sh` installs
the pinned Flutter SDK under `~/.local/share/flutter-versions` and installs the
`tool/flutter` launcher as `~/.local/bin/flutter`, keeping the previous
launcher as `flutter.before-harness`.
