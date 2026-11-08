# Reply editor placement

## Problem

A reply or quote editor could replace a terminal, appear in an unrelated
split or frame, or obscure an Ediff version. The compose quote editor used
`display-buffer-below-selected`, which can reuse an occupied window; review
comments used `string-edit`'s general-purpose display rules.

## Placement rule

Editors get a new window on the invoking frame, never an unrelated buffer's
window. An editor already visible on that frame is selected instead of
opening a duplicate.

| Context | New editor |
| --- | --- |
| Session stacked above/below another ordinary window | Below that session |
| Session beside another ordinary window | To that session's right |
| Lone ordinary window | Emacs's `split-window-preferred-direction`; `longest` follows frame shape |
| Left/right side-window session | New slot below the session on the same side |
| Top/bottom side-window session | New slot to the session's right on the same side |
| Task review with Ediff visible on this frame | Bottom half of the main area, below the versions and control panel |

An ordinary split takes half the session's window. If that direction has
no room, the other direction is tried **within the same session**. A side
window follows Emacs's side-slot axis and native space sharing. No room for
an editor means an error, not a fallback into another window or frame.

Ediff placement also applies to comments, replies and edits started from
its report or threads pane, not only its control panel and versions. Side
windows holding the file tree, threads and report remain visible.

## Implementation and lifecycle

`harness-ui-display-reply-buffer` in `lisp/ui/harness-ui.el` owns the common
display actions. It explicitly splits the invoking window, or Ediff's main
window, and records the new window with Emacs's normal `quit-restore`
bookkeeping. Side-window insertion uses the same native splitting mechanism
as `display-buffer-in-side-window`, but not that function's occupied-slot
fallback. A slot between neighboring slot numbers keeps both existing
windows intact, including reversed side-window ordering.

The compose quote editor uses the common helper; Apply and Cancel now quit
its windows as well as kill its buffer. Its header uses the existing fitted
header/overflow control: narrow right splits keep Cancel visible longest,
and every hidden shortcut remains available in the overflow menu. The
patch-review module wraps only
the default `change-review` string editor. A user-supplied reader is left
alone, and non-harness change sets retain their ordinary display behavior.
Disabling the module restores the default reader if it still owns it.

No placement option or new layout system is introduced. Generic popup
placement was rejected because it causes the reported inconsistency.
Splitting the unrelated main area for a side-window session was rejected
because the editor would still appear away from its session. Reusing an
Ediff version or the report's bottom-side slot would hide review content.

## Interface copy inventory

The only new interface text is the failure state:

- **No room for a reply window** — noun phrase, exact regression assertion.

The existing header wording remains: **Reply quote**, **M-RET split**,
**C-c [ elide**, **C-c C-c apply**, **C-c C-k cancel**. Its new overflow
control reuses **Overflow (mouse-1)**. Exact assertions cover wide/narrow
rendering, that tooltip and the commands in the overflow menu. Other labels,
menus, empty/loading states and success text are unchanged. Quoted messages
and comment prompts remain data.

## Verification and reproduction

Regression suites: `test/harness-ui-test.el`,
`test/harness-ui-compose-test.el` and
`test/harness-ui-patch-review-test.el`. Coverage includes both ordinary
orientations, explicit Emacs preferences, constrained-space fallback,
same-frame reuse, all four sides with normal/reversed slots, an occupied
neighbor, Apply/Cancel cleanup, the exact failure/header copy, and real
Ediff comment readers invoked from every visible review surface.

For manual checks in a separate development harness:

1. Open a session in an ordinary split, with a terminal below it. Start a
   thread with `C-c >`, then use `C-c e` to edit its quote. The editor belongs
   between the session and terminal. `C-c C-k` removes it.
2. Repeat with side-by-side ordinary windows: the editor belongs immediately
   to the session's right. With the default right-side session position,
   it belongs below the session in that same right-side column.
3. Open a task's changes in Ediff. Start a comment with `c` in the control
   panel, or a reply from a version/threads pane. The editor occupies the
   bottom half of the main area; both versions, controls, tree and report
   remain visible. `C-c C-k` returns the room to Ediff.
