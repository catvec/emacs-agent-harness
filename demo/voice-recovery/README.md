# Voice recovery — mock walkthrough

Run only in the separate development Emacs:

```sh
bash demo/voice-recovery/demo.sh
```

The real workspace mode, compose box, live transport, controls and audio
transcript run against `harness-voice-live-fixture`. It opens no microphone,
speaker or camera. Dictation and agent ACP replies are explicitly scripted;
no tool, real model, provider configuration or other task is touched. The
mock cancellation statuses demonstrate presentation only. The adjacent
agent/tools/shell regression suites verify the actual supported exact-run
cancellation contract separately.

The workspace initially has **no thread, episode or chat session ID**. On
its first prompt, the mock emits the real episode event payload before
updating the workspace cache, as the server does.

Press **C-c C-n** in the workspace for each step:

1. Dictation `Fix  only the parser test.` then `Hold on.` — an indefinite
   continuation hold, with the original double space preserved.
2. `Oh, actually send it.` — one workspace request containing only the
   dictated content. The scripted sidecar reports playback; there is no sound.
3. Playback interruption followed by late synthetic agent text/completion —
   `Listening`, `Playback interrupted`, no fabricated user message and no
   revived playback. The transcript on the right separates `Control` from
   genuine speech captions.
4. A second request — a new agent turn with the ordinary `Cancel work`
   control. Interrupt and cancellation remain separate actions.
5. Cancellation — a mock acknowledgement, with requested, completed and
   unsupported tool outcomes shown separately. Capture remains open.

The regular controls also work. `C-c V` interrupts, `C-c v` mutes/unmutes,
and **End** stops the fixture. Restart with `M-x harness-voice-recovery-demo`
to repeat. Inspect `harness-voice-recovery-demo--requests` in the demo Emacs
to see the exact `_harness/workspace/prompt` payloads.

The helper installs fixture advice in that disposable Emacs only. Stop it
when finished:

```sh
HARNESS_DEV_SOCKET=voice-recovery-demo scripts/dev.sh stop
```

Screenshots in `docs/evidence/voice-recovery/` were captured from this live
mock, not a physical device or a rendering assembled by a test.
