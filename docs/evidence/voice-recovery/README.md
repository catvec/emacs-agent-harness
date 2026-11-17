# Voice recovery evidence

Captured with `scripts/dev.sh shot` from a disposable live harness running
[`demo/voice-recovery`](../../../demo/voice-recovery/README.md).

**Mock-only boundary:** the workspace mode, compose renderer, live controls,
JSON-lines fixture process and audio transcript are real. Utterances, agent
ACP replies, tool catalogue and cancellation statuses are fixtures. No real
speech service, tool, model, microphone, speaker, camera or phone is used.
These images demonstrate presentation and routing, not physical speech
recognition or a real command being terminated. The agent/tools/shell tests
separately exercise turn-scoped cancellation and the exact shared-run hook.

Captured on the merged tree (main's voice startup and turn recovery plus this
change), from a workspace that has no thread, episode or chat session ID.

| Image | Observable state |
| --- | --- |
| [Held](held.png) | `Live · Waiting for continuation` on a workspace with no episode; the draft is retained and does not contain `Hold on.` |
| [Interrupted](interrupted.png) | `Live · Listening` after barge-in and late completion; delivery of `Fix  only the parser test.` without control words; a separate `Control · Playback interrupted` entry and no fabricated user message |
| [New work](new-work.png) | `Live · Working` on a later request, capture still open, the separate `[Interrupt C-c V]` control |
| [Cancellation](cancelled.png) | `Live · Listening` with mock `Cancellation requested`, `Tool cancellation requested · Bash`, `Tool completed · Read file` and `Tool cancellation unavailable · Emacs Lisp` |

The first recorded workspace request is exactly:

```elisp
(:id "mock-voice-workspace" :text "Fix  only the parser test.")
```

The next request names the resolved workspace thread:

```elisp
(:id "mock-voice-workspace" :text "Second request."
 :opts (:thread "mock-thread"))
```

Copy verification is separate from functional verification: the live images
were inspected against the design inventory. Exact ERT assertions cover
control outcomes, tool labels/tooltips, validation states, held/send controls,
and real workspace compose eligibility. Responsive overflow uses the existing
controls; no layout or menu redesign is part of this change.
