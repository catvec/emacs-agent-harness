# Changing a lasting decision

A lasting decision is an answer that holds beyond its moment: a
permission prompt answered for the session or always, and the cold-cache
question answered "always" with a choice.  Until now a decision offered
[Undo] and [Redo] only.  Undo takes the rule, the grant or the default
back, but to give a *different* answer the user had to make the call
again, or wait for the next cold cache, to see the prompt that asked it.

[Change] offers the original prompt again, with the choices it had, and
the answer given there replaces what the decision records.

## What is decided

- A decision remembers the prompt that asked it.  `decision/record`
  takes `:change`, a snapshot of the prompt (data only: no closures, no
  session records, no request continuations), and marks the decision
  `:changeable` when its kind registered a change function.  The
  snapshot is saved with the decision and survives a restart.  It is
  the harness's alone: `decision/get`, `decision/list` and
  `decision/changed` carry `:changeable` but not `:change`, so a client
  that connects later learns that Change is offered without seeing the
  call's input again.
- The decisions module defines the protocol, not the prompt.
  `harness-decisions-define-kind` gains `:change FN`, which the kind
  uses to open its own prompt again and returns
  `(:session SESSION-ID :pending PID)`.  `decision/change` checks that
  the decision is `done` or `undone`, that its kind has a handler and
  that the prompt was kept, then calls the handler.  Nothing moves until
  an answer arrives.
- The kinds apply the new answer:
  - `permission` (`harness-perms--decision-change`) adds the original
    prompt payload to the session again, without its old `:call-id`, and
    without the summary placeholder, through
    `session/pending-add` + `permission/requested`, so the panel the UI
    would have drawn is the one it draws.  The waiting entry is marked
    `:changing` and `:user-only`, so yolo and the session's own gates do
    not answer it.  When the answer comes,
    `harness-perms--answer-change` takes back what the decision recorded
    and records the chosen rule or grant instead, then revises the
    decision and its note in place.
  - `cowboy` (`harness-cowboy--decision-change`) asks the original
    question again with `question/ask` (its text, options and panel
    data), and `harness-cowboy--apply-change` makes the choice the
    default, revises the decision's record and text, and rewrites the
    hint that tells of it.
- `decision/revise` replaces a decision's text, record, state, result
  and prompt in place.  It keeps the id, kind, session, note and time,
  so every note that refers to the decision follows the new answer, and
  the decision remains the same thing with a different answer.
- Answers are revalidated when they arrive, not only when the prompt
  opens:
  - A decision `done` is undone through its kind's own undo, which
    refuses if the setting was changed since.  A refusal ends the
    decision (`changed`/`gone`) and the new answer is not applied.
  - A decision `undone` is checked the same way a redo would be: its
    rule, grant or default must still be as the undo left it.  If
    something took its place, the decision ends and nothing is applied.
- Dismissal means "leave it alone".  The paths that answer a prompt
  nobody gave (`session/pending-dismiss`, the resilience sweep, ACP's
  cancelled outcome) now carry `:dismissed t`.  A changed permission
  prompt answered that way, and a cancelled changed cowboy question,
  leave the decision and the setting exactly as they were.
- Repeated [Change] clicks are coalesced: a permission decision with a
  pending change prompt reuses its pid; a cowboy decision keeps its
  pending question by id.  The prompt opens in the session the answer
  was made in, whichever session it was clicked from.
- The UI advertises [Change] only where the harness says the decision is
  `changeable` and only while it is `done` or `undone`: the note's
  buttons become `[Undo] [Change]` or `[Redo] [Change]`, and the global
  `harness-decision-change` command offers the decisions that can change.

## Alternatives rejected

- **Store a closure or the waiting request** so Change could replay the
  callback.  Not serializable, keeps session objects and turn
  continuations alive, and would rerun the call the answer answered.
- **Rerun the original tool call** to get its prompt back.  The call had
  effects; the decision is about the rule, not the call.
- **Open a fresh prompt from the current settings** instead of the
  original one.  It could show different options or defaults, and the
  user asked for the prompt they saw.
- **Undo, then let the user answer the next prompt.**  That needs a call
  to happen first, and it loses the choice while waiting.
- **A second decision for the new answer.**  Undo/redo would then have
  two decisions for one setting, and notes would name the stale one.
- **Let the decisions module replay prompts generically.**  Only the
  kind knows what its prompt means and how to record the answer.
- **Offer Change only while `done`.**  An undone decision is still a
  decision; changing from there is the natural way to give a different
  answer instead of redoing the old one first.

## Shape of the change

- `lisp/modules/harness-decisions.el`: `:change` option on
  `decision/record`, `:changeable` state, `decision/change`,
  `decision/revise`, and the extended kind protocol.
- `lisp/modules/harness-perms.el`: prompt snapshots on the two pending
  prompt paths, the change handler and answer path, redo checks split
  from their side effects, note revision.
- `lisp/modules/harness-cowboy.el`: the question snapshot, the change
  handler and answer path, revalidation, note revision.
- `lisp/modules/harness-acp.el`, `harness-session.el`,
  `harness-resilience.el`: `:dismissed t` on the answers that mean "no
  answer was given".
- `lisp/ui/harness-ui-decisions.el`: the `[Change]` button, its tooltip,
  the `harness-decision-change` command, and showing the prompt's
  session.
- `lisp/ui/harness-ui-chat.el`: the chat's own decision button and tail
  draw `[Change]` the same way.
- Module pages in `docs/modules/` regenerate from those sources.

## Copy

- Buttons: `[Change]` beside `[Undo]`/`[Redo]` (and the switches'
  `[Turn off]`/`[Turn on]`, which keep no prompt and so have none).
- Tooltips: `The original permission prompt, with its choices`, `The
  original cold-cache question, with its choices`, else `The original
  prompt, with its choices`.
- Echo area after a click: `Prompt opened`; an answer that names nothing
  (`hold`, say) in a cold-cache prompt says `Answer unchanged`.
  The harness's refusals are
  result messages in the same voice as undo and redo's: `This decision
  ended, so it offers no change`, `This decision kept no prompt to ask
  again`, `No module here knows how to change decisions of kind KIND`,
  `The original prompt could not be opened`.  The UI-authored copy is
  noun phrases throughout; these are the harness's own results, as its
  undo and redo results are.

## Tests

- `test/harness-decisions-test.el`: change offered only with a handler
  and a kept prompt; the handler is called with the decision; errors for
  ended/unknown/no-prompt; the snapshot and `:changeable` survive a
  restart; `decision/revise` keeps id, kind, session and note.
- `test/harness-perms-test.el`: the original prompt reopens (payload,
  options, no call id), repeated clicks coalesce, answers change the
  rule/text/note/decision, dismissal is a no-op, changed-since ends it,
  undone decisions change and are checked, directory grants and denials,
  and decisions taken in from old notes offer no change.
- `test/harness-cowboy-test.el`: the question reopens with its options
  and panel data and after a restart, the answer changes default,
  decision and hint, dismissal and changed-since leave it alone.
- `test/harness-ui-decisions-test.el`: `[Undo] [Change]` / `[Redo]
  [Change]` render with their tooltips, non-changeable and ended
  decisions do not, a click sends `_harness/decision/change` and shows
  the session, and the command offers only changeable decisions.
- `test/harness-ui-chat-test.el`: the note draws `[Change]` in both
  states, with its tooltip, and a click asks again and shows the
  session.

## What it looks like

`[Change]` beside `[Undo]` and `[Redo]` in the notes, and the prompt it
opens again: the original permission prompt with its covers, and the
original cold-cache question with its choices and costs.

![A note offering [Undo] [Change], and the original permission prompt asked again](media/chat-decisions-change.png)

![A note offering [Undo] [Change], and the original cold-cache question asked again](media/chat-decisions-cold-change.png)
