# Popup-aware compose focus

## Shortcut and behavior

`harness-compose-focus`, bound to `PREFIX SPC` (`C-c h SPC` by default),
puts the selected window's cursor visibly inside an available compose box.
It does not send, submit, or change a draft. Consecutive presses cycle
through the current frame's composers and wrap around; an intervening
command starts a fresh choice.

On a fresh choice, the highest-priority kind wins:

1. Review comment and reply editors (`string-edit-mode` with an explicit
   `compose-quote-area-function`).
2. Popouts with a compose box, such as review feedback.
3. BTW side conversations.
4. Ordinary compose hosts, including chats and the task board.

Within the highest-priority kind, an already-selected composer stays
selected. Otherwise the first available window wins. Windows of equal
priority follow frame window order, anchored at `frame-first-window` so
selecting a target cannot reorder the cycle. A repeated press advances
from the last selected window only if that window still shows the same
buffer; closed or replaced targets are collected afresh, not cached.

## Focus and draft safety

The command preserves point when it is already inside the target's
editable bounds; otherwise it moves point to the end. It deactivates the
source and destination regions, resets horizontal and pixel scrolling,
and explicitly recenters the cursor into view. Shared compose padding
and follow state are invalidated even when point was already inside the
box: wheel scrolling can hide a composer without moving point.

Only windows in the current frame participate. Undisplayed buffers are
not opened. A chat's thread view may hide its compose box; that host
registers a reveal function with `harness-compose-hide`, allowing focus
to restore the box with its text and attachments intact. Insertion clears
the reveal function. Hosts that cannot restore a hidden box are not
candidates, and read-only popouts with no composer are skipped.

## Implementation boundary and alternatives

Selection and focus live in `harness-ui-compose.el`. Comment editors
expose their text bounds through the existing compose-quote interface,
so they need neither shared-compose markers nor changes to the vendored
review editor. The chat supplies only the reveal callback; the shared
compose layer does not inspect chat thread-view internals.

A side-window test alone cannot identify popups: ordinary chats also
use side windows. Setup alone cannot identify a composer: read-only
popouts also run compose setup. Likewise, a ring starting at the selected
window would reorder after every focus change. Explicit composer bounds,
host types, and a fixed frame-order anchor avoid those ambiguities.

Focusing scrolls only the chosen window. The ordinary chat bottom-scroll
command was not reused because it changes every window displaying that
chat. No new success message or persistent focus decoration is needed:
the selected window and visible editing cursor are the focus indicator.

## Discoverability and copy

The grouped Sessions menu contains `SPC Compose focus`. The compose
prompt's existing `❯` is a mouse target with the exact tooltip
`Compose focus (C-c h SPC)`, using the configured prefix when different.
No eligible composer produces `No compose box`. These are the only new
interface strings; there are no new loading or success states.

## Verification

Compose tests cover ordinary-window cycling, popup and BTW precedence,
the actual review comment editor, wraparound, closed and replaced
windows, unavailable composers, draft and cursor preservation, cleared
regions, scrolling, and exact menu/tooltip/error copy. A chat test covers
restoring a hidden thread-view composer. Sticky-compose tests cover
read-only host rendering.

The live check sends the real shortcut through a comment editor, review
feedback popout, and chat, checking cursor visibility and unchanged drafts
at each step. Screenshots show the composers and the Sessions menu; a
customized-prefix check confirms `C-c j SPC` resolves to the same command.
Lint and the full project test suite are checked against the final
committed tree.
