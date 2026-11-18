# A slot-change note that stays one line

## The problem

`tool-slots-load` tells every active session when the machine's load
changes the number of tool slots it allows.  A busy machine changes that
number often, so the changes of one stretch share one hint per session
-- the session's *note of slot changes*, a folding hint that reads
"Slots changed due to system load (3 changes)" and opens to the changes.

The note was closed when it held twenty changes, and the next change
started another.  That bound was meant for a load that moves for hours:
an ever longer note is rewritten whole at every change.  But a session
that stands still -- one the user left blocked, one running a long call
-- is a single stretch however long it lasts, and a machine busy through
it produces more than twenty changes.  The transcript then shows a row
of identical collapsed lines, "(20 changes)", "(20 changes)", "(10
changes)": the very clutter the note was meant to remove, and nothing on
the row says they are one stretch.

## The decision

A note is not closed.  It stays open for its whole stretch and counts
every change in its title, and it bounds only what it *keeps*: its
newest `harness-tool-slots-load--note-limit` changes as lines.  Opened,
it says how many it leaves out -- "27 earlier changes" -- above the
lines it keeps.

So a stretch that runs for a day is one line, "(400 changes)", that
opens to the newest twenty with a count of the rest.

### Alternatives

- **Raise the limit.**  A machine busy for a day still overflows it, and
  the note is rewritten whole at every change, so the write grows without
  bound.  It moves the row of lines later, it does not remove it.
- **Close a note only when the session moves on** (the window alone
  decides).  A session that stands still is exactly the case that
  produced the pile, and it is the case the window already exempts.
- **Drop the older changes silently.**  The count in the title would
  then lie about the stretch, or the title would have to stop counting.
  The count is what tells the user how busy the machine was.
- **Keep a second, older note per stretch.**  Two lines where one is
  meant, and the same growth problem in the older one.

## The shape of the change

The fold a hint carries (`harness-node-fold`, harness-util) gains an
optional `:total`:

```elisp
(:key KEY :title TITLE :items ((:ts TIME :text TEXT) …) :total N)
```

`ITEMS` are still the lines the hint keeps, oldest first, and `TOTAL`,
when it is more than the items, is how many lines the hint stands for.
A `:total` that is no number, or no more than the items, is left out, so
every fold written before this change reads exactly as it did and a
note written by the old code upgrades itself at its next change (its
items are its count).

- **tool-slots-load** (`lisp/modules/harness-tool-slots-load.el`):
  `--open-note` no longer refuses a full note; `--note-add` appends,
  keeps the newest `--note-limit` items, counts the total, and writes
  the "N earlier changes" line into the plain text that a client which
  does not fold reads.  `--note-limit` is now how many lines a note
  keeps.  The plain text is the title, the count of what is left out,
  then a line to a change with its time.
- **chat** (`lisp/ui/harness-ui-chat.el`): the folded hint draws the
  count of what it leaves out first, in the lines' indent, in the dim
  face; a fold that keeps one line but stands for more is drawn folded
  rather than as a plain note, so its count is not lost; and a run's
  "slots changed ×N" counts totals, not kept lines.

Nothing a model is sent changes: hints are never sent to a model.

## What it costs

The note is still rewritten whole at every change, so the write is
bounded by the kept lines rather than by the length of the stretch --
which is what the old limit bought, and it is kept.

## How it is checked

- `harness-util-node-fold` (harness-core-test): `:total` reads back
  through JSON, and one that is no number or no more than the items is
  left out.
- `harness-tool-slots-load-a-full-note-keeps-counting`: a note past its
  fill stays one note, counts every change, keeps the newest lines, and
  says "1 earlier change" and then "2 earlier changes" as it grows.
- `harness-ui-chat-a-slot-note-that-keeps-its-newest-says-what-it-leaves-out`
  and `…-a-fold-of-one-line-that-stands-for-more-is-folded`: the exact
  rendered copy, folded and opened.
- `harness-ui-chat-a-slot-notices-group-counts-the-changes-it-keeps`: a
  run's summary counts the changes a note stands for.
- `demo/slot-note-one-line/demo.sh`: the module's own note and the
  chat's own drawing of it, folded and opened, printed for a stretch of
  forty changes and one it keeps whole.
