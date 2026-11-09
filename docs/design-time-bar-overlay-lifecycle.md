# The time line's overlay and the transcript rebuild

## The defect

A chat draws the time of the first message its window shows on a line
of its own under the header, as an overlay string on an overlay held
in `harness-chat--time-bars', a buffer-local alist of (WINDOW . OVERLAY).
`harness-chat--refresh-time-bar' maintains it from
`pre-redisplay-functions', so it follows scrolling, resizing and the
transcript growing.

Rebuilding the transcript -- `harness-chat--load' ->
`harness-chat--render-nodes' -> `harness-chat--reset-buffer', which a
reload, a redraw of every chat, a reconnect or a head moved by a
checkout runs -- deleted every overlay of the buffer with
`overlays-in', the time line's own included, but did not empty the
alist that held it.  The next redisplay asked for the window's line,
got the deleted overlay back, and compared its `overlay-start', which
is nil, to the window's first whole line:

    (= (overlay-start ov) start)   ; (wrong-type-argument number-or-marker-p nil)

`redisplay--pre-redisplay-functions' demotes that to a message, so the
chat kept working, but it signalled on every redisplay while a message
was pinned at the top -- that is, during a turn, as the agent streamed
and each chunk redrew the window -- and each signal stopped the rest
of the hook: `harness-compose-unscroll' and
`harness-compose-pad-window', the compose box's padding and follow.
That is the flood Noah saw (`*Messages*' counted it in the tens of
thousands of redisplays).

## What the fix decides

The lifecycle is repaired where the overlay's ownership is; no error
is swallowed, so a real defect in the line still reports.

1. The cache is emptied with the overlays the rebuild deletes.  The
   rebuild deletes the overlays of the buffer, so the buffer's record
   of them starts empty, in the same place (`harness-chat--reset-buffer').
2. An entry is reused only while it is still what it claims to be: an
   overlay of this buffer, made for that window
   (`harness-chat--time-bar-live-p').  Anything else is replaced by a
   fresh overlay, which also drops the stale entry so one window never
   holds two.
3. The redisplay prunes an entry whose overlay died behind the cache's
   back -- Emacs's `isearch' opening a hidden stretch, another module
   deleting overlays, a window that is gone -- and keeps only entries
   whose window shows this buffer and whose overlay is alive.

Together these cover the situations the report asked about: a rebuild
during streaming (1), scrolling while a window is replaced or split
(3), the same buffer in two windows (an overlay each, keyed by window),
and a killed window (its overlay is pruned with it).

## Alternatives considered

- Wrapping the body in `ignore-errors' or `condition-case': hides a
  real `overlay-start' nil from any future path, and leaves the line
  undrawn after each rebuild.  Rejected.
- Reusing the overlay and moving it after a rebuild: `erase-buffer'
  already collapsed it, and the rebuild creates its own overlays, so
  the cache would still need to know which survived.  A guard and a
  clear at the owner are smaller and exact.
- Storing the line in a text property instead of an overlay: the line
  is an overlay string precisely so it does not disturb positions and
  markers the way inserted text would, and two windows need two.

## The shape of the change

- `lisp/ui/harness-ui-chat.el': `harness-chat--reset-buffer' clears
  `harness-chat--time-bars'; new `harness-chat--time-bar-live-p';
  `harness-chat--time-bar' reuses only a live entry and replaces a dead
  one; `harness-chat--refresh-time-bar' prunes dead entries.
- `lisp/ui/harness-ui-chat-test.el': three regression tests -- the line
  after a whole rebuild, a dead cached entry replaced, and two windows
  where one is deleted.  The first two fail before the change, the
  second with the reported error itself.

No user-visible string changes: no label, tooltip, header, menu or
error text is added or altered, so the copy rules of `docs/ui-guide.md'
and `CLAUDE.md' do not apply beyond leaving them as they are.

