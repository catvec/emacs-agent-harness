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

The toolchain pieces above are reproducible: `tool/install_flutter.sh` installs
the pinned Flutter SDK under `~/.local/share/flutter-versions` and installs the
`tool/flutter` launcher as `~/.local/bin/flutter`, keeping the previous
launcher as `flutter.before-harness`.
