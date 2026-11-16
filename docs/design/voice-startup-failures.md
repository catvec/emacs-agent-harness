# Voice mode's two startup failures

Two reports, one symptom each, and two unrelated causes:

- **Linux:** voice mode would not start. The task board's compose box showed
  `Live · Failed · [Start] · Live voice session unavailable`, and pressing
  Start again changed nothing.
- **macOS:** enabling voice signalled `Symbol's function definition is void:
  (setf harness-voice-pipeline-input)`. The same tree worked on Linux.

They are fixed together here because both are about starting a live voice
call, and each has a regression test that fails on the old code.

## 1. A compose box that is not a target

### What it is

`harness-voice-live--controls` drew the live voice controls in every compose
box: it asked whether the voice module was enabled and whether the selected
provider was live, and never whether the box could receive the words. A live
call's target is a session or a workspace thread
(`harness-voice-live--route-of-buffer`), and the start refuses without one:

```elisp
(let ((route (harness-voice-live--route-of-buffer (current-buffer))))
  (unless route (user-error "Live voice session unavailable")))
```

The task board (`harness-ui-tasks-mode`) and a popout (`harness-ui-popout-mode`)
both set up a compose box and neither sets `harness-ui-session-id` or
`harness-ui-workspace--id`. So the box drew a Start control, and Start could
only fail. `harness-voice-live--start-here` caught that error and wrote it into
the controls, which is the reported line; the failure stuck, so every later
press redrew the same failure.

### What it decides

A compose box is a live target exactly when the start has somewhere to go, and
that is one predicate both sides ask:

```elisp
(defun harness-voice-live--target-p (&optional buffer)
  (with-current-buffer (or buffer (current-buffer))
    (and (harness-compose-live-p)
         (harness-voice-live--route-of-buffer buffer)
         t)))
```

- **The controls** draw the status line and the Start control only where
  `--target-p` holds. A box that is not a target says `Voice · no session`,
  with the tooltip `Live voice · no session target`, and keeps only what works
  there: Transcript (when a call runs) and Setup.
- **`harness-voice`** (`C-c h V v`, the `[Voice]` control) falls back to the
  quick voice chat it already opens from an ordinary buffer, rather than
  failing. A board box is a reasonable place to ask for voice; the answer is a
  chat that can take it.
- **`harness-voice-dictate`** (`C-c v`) and **`harness-voice-hold`** (the mouse
  press) name the missing target in one echo-area line and touch no process,
  no sidecar and no permission.
- **`harness-voice-toggle`** opens the voice chat where it would otherwise have
  tried to start.

The wording follows the repository's copy rule: `Voice · no session` is a noun
phrase, and the tooltip names the thing that is missing. No sentence is added
to a compose box.

### The alternative rejected

Making the board and a popout name a session would give them a target they do
not have. A board's box submits a task; a popout's box answers the item it
shows. Neither is a conversation a voice call can delegate to, so the honest
answer is that there is no target, not an invented one.

## 2. A cross-file `setf` on a struct accessor

### What it is

`harness-voice-live.el` set the pipeline's input slot with

```elisp
(setf (harness-voice-pipeline-input harness-voice-live--pipeline)
      (harness-voice-live--input))
```

while the `cl-defstruct` that defines the accessor is in
`harness-ui-voice-pipeline.el`. A `cl-defstruct` accessor is a `define-inline`
function: its `setf` is a **compiler macro**, installed as a function property
when the struct definition is *evaluated*. Compile the using file in an Emacs
where the struct has not been evaluated -- a first compile, a stale cache, a
file compiled on its own -- and the compiler cannot expand the `setf`. It
emits a call of the function `(setf harness-voice-pipeline-input)` instead,
which no `cl-defstruct` ever defines. The `.elc` then fails at run time:

```
Symbol’s function definition is void: \(setf\ harness-voice-pipeline-input\)
```

Whether it breaks depends on compile order, which is why one machine was fine
and the other was not: the harness compiles every file into its state
directory (`harness--compile-file`) and loads the result, and the order the
cache happened to be built in decides whether the struct was evaluated first.

### What it decides

The module sets the slot through a plain function, defined beside the struct:

```elisp
(defun harness-voice-pipeline-set-input (p input)
  (setf (harness-voice-pipeline-input p) (or input 'mic))
  (harness-voice-pipeline-changed p))
```

Inside the struct's own file the `setf` is fine, because the struct is
evaluated by the time that file's forms run. Across files, only the function
crosses. The `setf` at the call site is gone, and a comment there says why, so
it does not come back.

### The alternative rejected

Requiring the pipeline file before compiling the live one would paper over the
order on this machine and leave the same trap for the next file. The harness's
own `harness--check-file` compiles each file separately, so any file can be
compiled without its dependencies' structs evaluated.

## Verification

- `harness-ui-voice-live-box-without-a-target-offers-no-start` pins the exact
  rendered copy and the tooltip, and asserts no `[Start]`, no `[Use here]` and
  no `Live · Failed`.
- `harness-ui-voice-live-box-without-a-target-refuses-the-start` asserts the
  one-line refusal from `C-c v` and the mouse press, and that nothing started.
- `harness-ui-voice-live-box-without-a-target-opens-a-voice-chat` asserts the
  fallback to a new voice chat.
- `harness-ui-voice-pipeline-input-setter-survives-compile-order` compiles a
  file in a fresh Emacs that never evaluated the struct, in the order that
  broke: the setter answers `camera`, and the `setf` it replaces is shown to
  fail with the exact void-function error. All four fail on the old code.

The live dev harness shows the two states side by side: the board's box reading
`Live · Failed · [Start] · Live voice session unavailable` before, and
`Voice · no session · [Setup]` after, while a real chat box still reads
`Live · Off · [Start] · [Transcript] · [Setup]`.
