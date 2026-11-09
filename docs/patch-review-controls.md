# Review controls: one model, every surface

The Ediff control panel had grown its own key legend: one long line of
`RET: … r: … c: …`, cut off at the window's edge, with the thread keys
mixed in among the diff's, while the threads view beside it kept the
vendor library's key legend and none of the review's own keys.  A
narrow window lost the end of every line, and each surface repeated the
same words.  This change gives the review one model of its controls and
one way to draw them, and every surface -- the Ediff panel, the report,
the banner, a chat's threads, the pane beside Ediff, and the threads view
opened on its own -- draws from it.

## Decisions

### One table of controls

`harness-ui-patch-review--control-definitions` names every command of the
review once: its group, its label (a string, or a function of the review
for the labels that depend on it), its tooltip, and the key it takes on
each surface (`:ediff`, `:threads`, `:pane`).  `--control-specs` turns an
entry into what a surface draws, and `--control-button` draws a label
with its key.  Nothing repeats a key legend: the panel's old one-line
hint and the threads view's hint variables are gone.

The groups are the nouns the controls belong to: **Threads** (Comment,
New thread, Reply, Close, Reviewed, Edit draft, Delete draft, Delete
thread, Fold thread), **Navigate** (Next/Previous thread, Next/Previous
comment, Diff, Source), **Diff** (Approve, Next file, Previous file) and
**View** (Skip approved, Auto-approve, Files, Expand all, Collapse all,
Send drafts, Filter, Keys, Report, Ediff).  Thread controls never appear
in the Diff group; the pane adds the way back to Ediff.

### Rows that wrap, never cut

`--control-lines` draws a group as a titled row, and wraps its controls
onto continuation lines under the group.  A row of long labels is drawn
only where the window has the room the longest control needs after the
title (31 columns for the pane, 32 for the panel); a narrower window
uses the `:short` forms (`Prev thread`, `Prev comment`, `Prev file`) and
hangs the controls under the group's title two columns in, so every
control is whole, clickable and inside the window down to 24 columns.

Width comes from the narrowest window showing the buffer
(`--text-width`, `window-max-chars-per-line`), not from one window that
happens to be selected, so the same buffer shown twice is drawn for the
worse case.  The Ediff panel's height follows its wrapped help: `--fit-control`
measures the help's pixels and grows the window to the lines it takes,
up to half the frame, because Ediff sizes the panel once before the
review's longer help exists.

### Information in one place

Each surface starts with one dim line of facts, built by `--info-line`
from `(TEXT PRIORITY SHORT)` segments: `File 1 of 6 · 0 viewed · 1
approved · 1 thread · 1 draft` in Ediff, and the title, version, thread
count and draft count at the top of the threads view.  As the line runs
out of room it first uses the short forms (`File 1/6`), then drops the
least important fact; the file the reviewer is on is never dropped.
Below it the filter line is the library's (`Threads  [open 2]  …`), and
below that the grouped controls.  `[Keys]` (`C-c ?`, `?` in the thread
view) opens one buffer listing every key, its label and its tooltip by
group, with Ediff's own keys at the end.  There is no second legend.

### The threads view is a full surface

The library's threads view gained the review's keymap and drawing
(`--prepare-threads-view`, `--thread-view-map`): c starts a thread, E/C
expand/collapse all, S sends drafts, T goes back to Ediff, TAB folds, and
`?`/`C-c ?` lists the keys; RET compares the thread's line in Ediff or
shows where a comment was made.  Its first lines are the facts of the
review and the same grouped controls, so it stands on its own in the
report, in a chat and in the pane beside Ediff.  The pane shares the same
buffer and the library's filter.

### Send drafts only where sending works

`[Send drafts]` is filtered by `:when`: `--sendable-p` is true only while
the task is at work.  A review waiting for feedback hides the control --
its drafts go with the feedback that sends the task back, which the
filter row counts (`3 drafts not sent`) -- and the working phase shows it
with the count (`[Send 2 drafts]`), or `[Send drafts]` with none.  The
command itself refuses outside the working phase rather than opening a
dead path.

## Alternatives

- **A sticky header line for the controls.**  It would stay while the
  threads scroll, but a header line cannot wrap, its buttons need
  header-line mouse bindings the vendor's filter buttons do not carry,
  and it would hide the threads in a short pane.  The controls sit in
  the text, reachable with C-v, as the threads heading always did.
- **Drop controls at narrow widths, or end them in `…`.**  The request is
  every function on a skinny buffer; wrapping and short labels keep all
  of them.
- **A key legend per surface, fitted.**  That is what was there: it cut
  off or grew a second line, and repeated the labels.  The table plus
  `[Keys]` says each thing once.
- **Keep the threads view as the vendor draws it and add the review's
  keys only.**  Then the view would still lack the review's controls and
  facts; it now draws the same heading as the report.

## Copy inventory

Interface text is nouns, noun phrases and adjectives; tooltips are help
and are one line.

| Where | Copy |
| --- | --- |
| Group titles | `Threads`, `Navigate`, `Diff`, `View` |
| Thread controls | `Comment`, `New thread`, `Reply`, `Close`, `Reviewed`, `Edit draft`, `Delete draft`, `Delete thread`, `Fold thread` |
| Navigation | `Next thread`, `Previous thread`, `Next comment`, `Previous comment`, `Diff`, `Source`; narrow: `Prev thread`, `Prev comment` |
| Diff controls | `Approve`, `Next file`, `Previous file`; narrow: `Prev file` |
| View controls | `✓/✗ Skip approved`, `✓/✗ Auto-approve`, `✓/✗ Files`, `Expand all`, `Collapse all`, `Send drafts` / `Send N drafts`, `Filter`, `Keys`, `Report`, `Ediff` |
| Tooltips | `Comment on the current difference`, `Thread of your own, nothing quoted`, `Reply in the thread at point`, `Close the thread or open it again`, `Mark the thread reviewed, or make it wait again`, `Edit the draft at point`, `Delete the draft at point`, `Delete a thread of drafts`, `Fold the thread, or open it`, `Next thread of the file`, `Previous thread of the file`, `Next comment`, `Previous comment`, `The thread's line in the diff view`, `The code the comment was written on`, `Approve the file; a second press takes it off`, `Next file to review`, `Previous file`, `Leave out the files already approved`, `Approve the files gone through without a comment`, `The files in a column beside Ediff`, `Open every file's threads and every thread`, `Fold every file's threads and every thread`, `Send the drafts to the agent together, while the task is at work`, `Which threads show`, `Every key of the review`, `Back to the report`, `Back to the comparison` |
| Facts line | `File 1 of 6` / `File 1/6`, `N viewed`, `N approved`, `at <commit>`, `N thread(s)`, `N draft(s)`; threads view: title, `vN of M`, `N thread(s)`, `N draft(s)` |
| Keys view | `Review keys`, group titles, `Ediff`, `Ediff's own keys, in its control panel` |
| Empty states | `No open threads`, `No closed threads`, `Nothing to review`, `Nothing reviewed this turn`, `No threads` |
| Errors | `No review here`, `No thread here`, `No draft to send`, `The task waits for review: its drafts go with the feedback that sends it back` |

The Ediff panel gives a control that acts on the difference a tooltip of
its own: `Reply in the thread at the difference`, `Close the thread at
the difference or open it again`, `Mark the thread at the difference
reviewed, or make it wait again`, `Edit the draft at the difference, or
the feedback box`, `Delete the draft at the difference`, `Delete a
thread of drafts at the difference`, `Fold the threads at the
difference, or open them`.

## Shape of the change

- `lisp/ui/harness-ui-patch-review.el`: the control table, specs,
  buttons, line/width fitting, facts line, the threads view drawing and
  keymap, panel help and height, the threads section and heading, text
  width, and the `:when` filter for Send drafts.
- `test/harness-ui-patch-review-test.el`: grouped controls at 80, 40 and
  24 columns; exact labels and tooltips of the table; the threads view's
  keys; the panel's grouped factual help; wrapping at window sizes; the
  keys buffer; Send drafts hidden while waiting for review; the report's
  heading order.
- `scripts/harness-media.el`: the `review-ediff` picture starts the pane
  at the facts and controls, with the threads below.
- `docs/architecture.md`, `docs/screenshots.md`, `docs/dev-loop.md`: the
  surfaces and the picture descriptions.

## Verification

- `scripts/test.sh test/harness-ui-patch-review-test.el` -- 158 tests,
  including the copy and narrow-width regressions.
- `scripts/lint.sh`.
- `scripts/media.sh review-ediff review-threads` for the two pictures;
  inspect them for a whole control in every group and no cut line, wide
  and in the 46-column pane.
