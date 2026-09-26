# The live development loop

DESIGN.md makes this the first priority: code that merely appears
implemented does not count; the agent must be able to launch, drive,
inspect and screenshot a live Emacs.

## Pieces

| script | purpose |
|---|---|
| `scripts/dev.sh` | run/drive a GUI Emacs daemon named `harness-dev` |
| `scripts/demo.sh` | run a complete scripted conversation and screenshot it |
| `scripts/media.sh` | regenerate the README screenshots and demo video |
| `scripts/harness-gui-demo.el` | the scripted provider used by `demo.sh` |
| `scripts/lint.sh` | byte-compile every `.el` out of tree |
| `scripts/test.sh` | run every ERT suite, one clean Emacs per file |

## Driving Emacs

```sh
scripts/dev.sh start                 # daemon + GUI frame, harness loaded
scripts/dev.sh eval '(+ 1 2)'        # evaluate anything in it
scripts/dev.sh keys 'C-x C-f ...'    # real keyboard input to the frame
scripts/dev.sh shot /tmp/shot.png    # screenshot the harness frame
scripts/dev.sh errors                # recent *Messages* (and backtraces)
scripts/dev.sh restart               # fresh daemon
```

Details that matter:

- The daemon runs `emacs -Q` (no user init) and loads only
  `harness-dev.el`, so results are reproducible.  `harness-dev-load`
  (re)loads the checkout.
- The dev frame is mapped without focus (`no-focus-on-map`) and lowered,
  so automation never steals the user's focus or sits in front of their
  work.  `M-x harness-dev-focus` raises it deliberately.
- `harness-dev-keys` runs a real `kbd` macro in the frame's selected
  window, so keybindings are exercised for real, not simulated; it does
  not need (or take) window focus.
- Screenshots and recordings export frames from Emacs itself with
  `x-export-frames` (`scripts/dev.sh shot`, `harness-dev-export-frame`,
  `harness-dev-record-start`).  No desktop portal or window grab is
  involved, and captures work with the frame behind other windows.
- The daemon loads `harness-auto-reload-mode`, so saving a source file
  reloads the harness in place.  Reloading is safe: sources are compiled
  first and a failed load restores the previous version.
- `harness-dev.el` disables the bell: automation must not beep at the
  human.

## The demo conversation

`scripts/demo.sh [THEME] [OUTPUT]` loads `harness-gui-demo.el`, which
registers a provider replaying a small conversation without a real model:

1. streamed thinking and text,
2. a tool call to `read` inside the session,
3. a tool call to `/etc/passwd` that triggers the approval panel,
4. streamed markdown (heading, bold, bullets, inline code, fenced block).

The script creates a session, sends the prompt, answers the approval,
scrolls to the top and screenshots.  Passing `modus-vivendi` or
`modus-operandi` verifies both themes (the harness faces are
theme-aware).  This is the standard way to verify rendering changes.

## Verification workflow

For a change to UI or cross-module behaviour:

1. `scripts/test.sh test/<affected>-test.el` — unit level.
2. `scripts/lint.sh` — every file still compiles.
3. `scripts/demo.sh` (with both themes when faces changed) — look at the
   screenshot, not just at the assertions.
4. `scripts/dev.sh errors` — there should be no backtraces.

For protocol-level changes, the ACP suites drive the real stack both
in-process (local UI) and over TCP (remote client); keep both green.

`scripts/dev.sh start` loads the checkout, starts the harness and opens a GUI
frame; the daemon reloads on source changes (or `scripts/dev.sh eval
'(harness-reload)'`).  The harness runs interpreted source there on purpose:
`harness-dev.el` turns off native compilation and prefers newer files, so a
stale `.eln` can never mask an edit.
