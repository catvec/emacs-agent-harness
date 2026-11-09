# Always compacting, from the menu, and turning it off again

## The problem

The automatic compaction asks what goes first before it compacts a
conversation near its context window, because a summary reads the whole
conversation again and the kind is the user's to pay for.  In a task's
session that question holds the task up until somebody looks at it, and
the only way to have the harness compact without asking was to set
`harness-compaction-ask` to nil: an Emacs option, in an init file or
with `M-x customize`, not something the person watching a session can
do.  The user asked for the answer to be in the UI: an "always" in the
menu, and then a way to turn that off again, for one session or for
every session.

The same question is already answered that way for the cold-cache
question: answering it "always" with a choice makes that choice the
default and stops the asking, keeps the answer as a lasting decision
the UI can undo, and the settings page holds the default it set.  The
compaction question deliberately had no "always" (`docs/design/
carried-on-compaction-answer.md`: "every automatic compaction is the
user's to decide").  That was the wrong trade: a user who has decided
should not have to decide again at every boundary.

## The decision

`Always` means what asking off has always meant: the automatic
compaction makes `harness-compaction-kind` without asking, where it
runs.  Turning it off means asking again -- not "never compact": a
conversation past the window cannot be sent as it is, and the fallback
that asks no model (a transcript) is still made when nobody is there
to ask.  "Never" would only fail closed later, in a worse place.

There are two scopes, the session's answer winning over the default:

- **The default**, for a session that has no answer of its own:
  `harness-compaction-ask` (on: ask) and `harness-compaction-kind` (the
  kind made unasked, and the kind marked the default in the question).
  Both are in Settings, section Compaction, and both are saved as any
  setting is.
- **The session's own answer**, in its `:ext` under `:compaction-ask`:
  `t` asks, `:false` compacts unasked, and no value follows the
  default.  `session/set-ext` keeps it with the session record, a fork
  takes none of its parent's (`session/set-ext` says so), and the
  session list shows it like the supervisor's switch.

The menu gets an "always" answer the way the cold-cache question has
one: capital keys on the panel (`harness-ui-carry`: `:always`), the
letters of the compaction kinds it offers and of carrying on, as the
merged menu draws them (`S` summary, `T` transcript, `F` fresh start,
`C` carrying on).  A capital answer:

1. compacts this conversation with that kind, as its key would;
2. makes the kind `harness-compaction-kind`, and turns
   `harness-compaction-ask` off, saved as the settings page saves them;
3. keeps the answer as a lasting decision of the kind `compaction`,
   with the settings before and after it, so every UI that draws the
   decision's note offers [Turn off], and then [Turn on], as
   `harness-ui-decisions` already does for the compaction before a
   prompt cache lapses (`precompact`).

The answer travels to the harness as the cowboy's does, the text
`always <choice>`, so one parser idiom serves both questions; the
answer's `:by` is `always`, and the compaction's hint says so in its
own words: "Context · transcript · default".  An answer nobody chose --
asking off in a non-interactive session, no `question/ask` -- keeps
saying "Context · summary · automatic" (`harness-compaction--say`).

Turning it off again is in the UI, in three places that are the same
setting:

- **This session**: `harness-toggle-compaction-ask`, and "Auto-compact"
  in the Session settings menu (the menu labels it with the state:
  "Auto-compact: always" / "Auto-compact: ask" / "Auto-compact: the
  default").  It writes the session's `:compaction-ask`, through
  `compaction/set-ask`, so it needs no restart and no Emacs option.
  In the session list it is the session at point, or every marked one.
- **Every session**: `harness-set-compaction-ask-all`, "Auto-compact
  for all sessions" in the same menu: it saves the default and clears
  every current session's own answer, so all of them follow it.
- **Settings**: `harness-compaction-ask` in the Compaction section,
  beside the kind it makes, for a user who goes looking there.

The evaluation is `harness-compaction--ask-value`: the session's own
answer when it has one, else the default; `harness-compaction--asks-p`
then takes `harness-compaction--non-interactive-p` and `question/ask`
into account as before, and `harness-compaction--by` says who decided
that a compaction is made unasked (`always` when the setting turned
asking off, `unasked` when nobody could be asked).

The previous change, which made a task's session and a sub-agent's
never asked (`harness-compaction--unattended-p`), is removed: the user
asked for the switch, not for a second rule that the switch cannot
override.  A task's session asks like any other until its session, or
the default, says otherwise; its session keeps the answer, and a task
returned to pending goes on in that same session.  What still holds
from main is narrower and separate: a lasting "always carry on"
(`harness-compaction-carry-on`) applies only where someone waits for
the user (`harness-compaction--carry-on-always-p`), so unattended work
still compacts rather than carrying on past the window.

## Alternatives

- **The capitals set only this session**, the default staying in
  Settings.  Rejected: the shared panel's capitals line already says,
  for both questions, "default for every session, no asking" -- the
  cold-cache answer and the compaction answer should mean the same
  thing -- and the user asked for the global scope as well.  A session
  that must not follow the default says so with its own switch.
- **A three-state mode, `ask` / `always` / `never`**.  Rejected: past
  the window the conversation cannot be sent, so `never` cannot hold;
  it would have to compact anyway, with a worse explanation.  "Always"
  and "ask" are the two states that can be kept.
- **A new field of the session record** for the session's answer.
  Rejected: the record's fields are the harness's own settings
  (`harness-session--settings`), and this one belongs to the compaction
  module; `:ext` is where a module keeps what it remembers about a
  session (the supervisor's mode is there too).  It needs no store
  change, and a fork takes none of it.
- **A decision per session** for a session's own switch.  Rejected for
  now: the decisions are the harness's and their undo moves settings,
  not session state; the session's switch is one click away in the
  menu, which is what the user asked for.  The decision kept is the
  global "always" answer, which is the one that changes every session.
- **Keeping `--unattended-p` under the setting** (task sessions always
  compact unless their own answer says ask).  Rejected: then turning
  auto-compact off for every session would leave new task sessions
  compacting unasked, and the switch the user asked for would not
  switch them.

## The shape of the change

- `lisp/modules/harness-compaction.el`: `harness-compaction--session-ask`
  and `harness-compaction--ask-value` (the precedence),
  `harness-compaction--by`, `--asks-p` rewritten on them,
  `--unattended-p` removed; `--decide` records an `always` answer
  (`harness-compaction--remember`, returning the decision's id in the
  answer's `:decision`) and reports `:by always`; `--say` says what
  `always` means and attaches the decision to its hint; the decision's
  undo and redo (`compaction` kind) and the methods `compaction/set-ask`
  (one session) and `compaction/set-ask-all` (the sessions a filter
  selects).
- `lisp/ui/harness-ui-compaction-ask.el`: the `:always` list in the
  panel's spec (the kinds and carrying on, never Pause), the answer
  passed on as `always <choice>`, and the message after it saying where
  to turn it off.
- `lisp/ui/harness-ui-carry.el`: `:always` as a list of the choices a
  capital may answer, so a question can offer "always" for some rows
  and not others; `hold` never takes one.
- `lisp/ui/harness-ui.el`: `harness-toggle-compaction-ask` (session)
  and `harness-set-compaction-ask-all` (every session), their labels
  in the Session settings menu (`C-c h o`), and the state in the label.
- `lisp/ui/harness-ui-sessions.el`: `:compaction-ask` among the marked
  sessions' settings, so the toggle works from the list too.
- `lisp/modules/harness-config.el`: `harness-compaction-ask` in the
  Compaction section.
- `lisp/ui/harness-ui-decisions.el`: `compaction` drawn as a switch,
  [Turn off] / [Turn on], with its labels in the undo and redo prompts.
- `docs/architecture.md`, `docs/modules/compaction.md`, and the module
  docs regenerated.
- Tests: the panel's capitals and the answer it sends; a capital answer
  saves the settings, keeps the decision and says why in the hint; a
  session's own answer asks again after a global always; the "all"
  command sets the default and clears the sessions' answers; the
  settings section offers the option; the decisions UI calls it a
  switch.  The strings the UI shows are asserted exactly.

## Verification

The compaction and UI suites, `scripts/lint.sh`,
`scripts/module-docs.sh --check`, then the whole suite on the committed
tree (every suite passing; `harness-ui-patch-review-tool-open-reveals-a-
closed-thread-by-prefix` fails on main's own commit too, and is not this
change's).  A live panel screenshot with the capitals line, the Session
settings menu with the auto-compact entries, and the hint's [Turn off]
on a decision.  The menu rewrite landed with `t-z4cwev5l` before this branch
merged, so the panel's rows, keys and shared menu are main's and the
capitals are drawn on them by this change.

## Collaboration

`t-z4cwev5l` ("Fix uncached reads and redesign compaction menu") is
merged: the compaction question now draws the shared five-row menu the
cold-cache question draws (Summary, Transcript, Fresh start,
Continuation, Pause), with `harness-carry-menu` supplying the rows and
their costs.  The split, agreed in the two sessions, held: that task
owns the panel's rows, its keys and the shared menu list; this one owns
the state, the `always` flag on the spec, the answer's path, the
decisions and the session and global switches.  On the wire the answer
is `always <choice>` with `:by always`.
