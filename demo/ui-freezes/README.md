# Freeze regression demonstrations

These use **isolated Emacs and mock media**. No provider requests, audio,
phone input, permission changes, or edits to a running user's Harness.

## Offline before/after log storm

From this checkout:

```sh
bash demo/ui-freezes/benchmark.sh /tmp/harness-freeze-logs
```

This compiles the original `dd59e2a` core and the current core into that output
directory, then runs each in a fresh batch Emacs. It seeds a 4 MB log and
appends 80,000 1,000-character entries synchronously. It prints wall/GC totals
and keeps the complete compile and run logs. Set `HARNESS_FREEZE_LOG_ENTRIES`
for a smaller experiment. This deliberately stresses one synchronous caller;
it is not a claim that normal sliced ACP delivery is one such loop.

Recorded in this task: **18.701 s → 4.393 s**. Host scheduling affects wall time.

## Isolated graphical preview

Use the task's **Open harness** action/tool, then the `scripts/dev.sh eval`
command/socket it returns:

```sh
HARNESS_DEV_SOCKET=SOCKET scripts/dev.sh eval '(progn (load-file "demo/ui-freezes/show.el") (list :latency-file (harness-latency-file)))'
HARNESS_DEV_SOCKET=SOCKET scripts/dev.sh shot OUTPUT/harness-freeze-preview.png
```

The preview refuses to load outside a development Emacs. It calls the
production image API with a relative SVG source in one directory, inserts
the returned image string alongside rendered Markdown into a buffer in
another directory, then flushes the cache and asserts deferred image size.
It deliberately bypasses Markdown's path resolver, which would otherwise
normalize the path before it reached the viewer.
The green image is a **mock review fixture**, not a voice UI or recovered user
image. The absent file below it exercises the unchanged fallback. Zooming the
image uses the ordinary image viewer controls.

The preview also runs a synthetic 350 ms yielding handler and flushes its
content-free completion record to the isolated instance's `latency-PID.log`.
The evaluation result names the file. Normal startup installs this recorder;
no live instrumentation or user configuration change is needed for the demo.

To replay the targeted transport and large-output regressions:

```sh
scripts/test.sh lisp/harness-util-test.el lisp/modules/harness-acp-tcp-test.el
scripts/test.sh lisp/modules/harness-acp-test.el harness-acp-large-log-burst-yields-with-a-full-log
scripts/test.sh lisp/harness-latency-test.el
```

The transport tests use actual local sockets, a stopped reader, a healthy
concurrent RPC, independent deadlines and bounded queues. ERT also verifies
that filters, sentinels and application callbacks remain on the main thread.
The diagnostic tests distinguish yielding stack samples, completed boundaries,
GC records and event-loop gaps, and assert that arguments are not recorded.

For the historical evidence, measured limits and remaining uncertainties,
see [the diagnosis](../../docs/design/ui-freeze-isolation.md).
