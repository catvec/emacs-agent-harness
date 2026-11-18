# A slot-change note that stays one line

A batch demonstration of the note a session gets when the machine's
load moves the tool slots again and again:

```sh
demo/slot-note-one-line/demo.sh
```

It writes the note with the module's own code
(`harness-tool-slots-load--note-text` and `--note-meta`) and draws it
with the chat's own renderer (`harness-chat--render-block` and its
fold), so what it prints is what the transcript shows.  No model is
called, no harness is started, and no tool runs, so it is safe to run
anywhere Emacs is.

| Part | What it prints |
| --- | --- |
| 1. Forty changes | the title "(40 changes)", the `:total`, the 20 lines kept of 40, and the plain text a client that does not fold reads |
| 2. The chat's drawing | folded, the one line "▸ Slots changed due to system load (40 changes)"; opened, "20 earlier changes" above the newest 20 lines |
| 3. A stretch kept whole | three changes: no "earlier" line, because nothing is left out |

Before this change a note was closed at twenty changes and the next
started another, so part 1 printed a row of notes -- "(20 changes)",
"(20 changes)", the very clutter the note was meant to remove.  See
[the design document](../../docs/design/slot-change-note-stays-one-line.md).
