# Verification

- `analyze.txt` — `flutter analyze` on the final tree: *No issues found*.
- `test.txt` — `flutter test`: 21 unit, reducer and widget-flow tests.
- `e2e.txt` — the Playwright run on iPhone 13, Pixel 7 and a 1280×900 macOS
  layout; every flow completed and wrote a screenshot to `../screenshots/`.
- `real-harness-probe.txt` — the client core against a real
  `emacs-agent-harness` 3.0.0 (headless, demo provider) over ACP: initialize,
  capability discovery, `session/list`, `session/new`, a streamed
  `session/prompt`, activity, nodes and replay.
- `apk-build.txt`, `web-build.txt` — release builds.
- `apk-inspect.txt` — package id, label, INTERNET permission, min/target SDK,
  ABIs and signer of the shipped APK.
- `sha256.txt` — checksums of the test builds.
- `web-prod-smoke.txt` / `production-web.png` — the production web build,
  served as a static site and connected to the preview harness, with no page
  errors.
