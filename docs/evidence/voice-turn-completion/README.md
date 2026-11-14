# Voice turn completion: checks run

Logs from the runs this branch was handed in with, kept as they were printed.

| File | What it is |
| --- | --- |
| `focused-suites.log` | `scripts/test.sh` over the five voice suites the change touches: 84 + 3 + 26 + 40 (1 skipped) + 1 tests, all as expected |
| `full-suite.log` | `scripts/test.sh` with no arguments on `5b4c87c`, the last commit that changes anything outside this directory (a run cannot contain its own record): 219 suites, 1 failed (`harness-skills-scan-test`), exit 1. That failure is not this branch's: `lisp/harness-skills-scan.el` and its test are unchanged from the base `cb5621e`, and the same suite fails the same way in an archive of `cb5621e`. The case `harness-skills-scan-bounds-what-it-lists` expects `file-0.txt`, `file-1.txt`, `file-2.txt` and gets `file-0.txt`, `file-2.txt`, `file-3.txt`: it depends on the order the filesystem lists a directory in, so it is flaky by construction |
| `client-build.log` | `harness_client/tool/check_build.sh --accept-android-licenses` for the committed tree: pub get, analyze (no issues), 2005 app tests (1968 passed, 21 failed -- every one of them also fails at the base), the release APK, and a stamp covering the app as committed |
| `lint.log` | `scripts/lint.sh`, exit 0 (its byte-compile warnings are the tree's pre-existing ones) |
| `emacs-walkthrough.log` | `scripts/voice-turn-demo.sh` driven step by step in a development harness: the state and the committed messages after each scripted utterance. The trailing `*ERROR*: End of file during parsing` is the walkthrough driver's own malformed probe expression, after the last step it checked; it is not the feature's |

The screenshots are in `docs/media`: `voice-turn-completion-emacs.png` and
`voice-turn-cut-off-emacs.png` from the Emacs walkthrough, and the eight
`voice-pending-*` and `workspace-*-pending.png` pictures from the Flutter
screenshot test.
