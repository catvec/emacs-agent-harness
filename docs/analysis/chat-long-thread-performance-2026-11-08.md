# Chat responsiveness in long threads

## Problem

A chat that holds long messages or many messages felt laggy while it was
typed in, while a turn streamed, and when the frame was resized.  The
rendering itself is incremental, so the cost was in measurements that ran
around every change:

- The compose box's follow measured from the start of the buffer to decide
  whether it was showing the end.  A window already scrolled to the bottom
  cannot be showing the whole buffer, so that layout only rediscovered what
  the window start said.
- The post-command hook measured every window for the newer-messages notice
  after every command, including a key typed in the compose box, which moves
  no window and changes no text outside the box.
- Each streamed chunk asked whether its window still showed the end.  A
  following window was laid out again for every chunk even though no scroll
  had happened, and a scrolled-up window was laid out again to answer the
  same "no" for every chunk.
- Table detection searched from a block's start to the end of the buffer and
  checked the block's end afterwards.  A window-width change therefore
  walked the remaining transcript once per block.

## Change

- `harness-ui-compose.el`: the follow measures from the buffer's start only
  when the window starts there.  When the box and the host's line under it
  already show, it does no layout at all.
- `harness-ui-chat.el`: the post-command notice check remembers the window
  starts, vscrolls, heights and the count of text changed outside the box.
  It measures again only when one changed, or while newer content waits.
- `harness-ui-chat.el`: `harness-chat--following-p` caches its at-bottom
  answer per window, keyed by the window's buffer, start, vscroll and size.
  Pinning records the window as following.  Text streamed at the end does
  not invalidate the answer; a scroll or resize does.  Point being on a
  panel or the todo list is still checked on every call, so following never
  takes the reader's point away.
- `harness-ui-chat.el`: table detection is narrowed to its block.

No interface text, labels, tooltips or visible layout changed.

## Measurements

A development harness frame, 140x41 text cells, a chat with 60 rendered
nodes of 20,000 characters each (877,022 characters in the buffer), measured
with `benchmark-run` and no profiler instrumentation:

| Operation | Before | After |
|---|---:|---:|
| 50 keys typed in the box, with redisplay | 0.29 s | 0.18 s |
| 100 streamed chunks in one burst, no redisplay | 0.56 s | 0.15 s |
| 10 table-detection passes over all 60 blocks | 2.0 s | 2.1 s |

The typing figure is the median of seven runs after discarding the first
redisplay.  The table figure is unchanged in this buffer, where the search
property is absent from most nodes; the narrowed search bounds the work
whatever the property layout is, but the measurement does not establish a
speedup for it.

## Alternatives considered

- Lower `harness-chat--message-limit`: it would make the visible text depend
  on performance numbers rather than on what the reader wants to see, and it
  would add more [Show more] rows to ordinary long answers.
- Insert hard line breaks into rendered paragraphs: it changes what copy and
  quote return, and the rendered text is expected to be the source text with
  properties.
- Re-render less of the transcript: the transcript is already rendered
  incrementally; the cost was in measuring windows, not in rendering nodes.

## Verification

Focused ERT tests cover the exact bounds and the following cache:

- `harness-ui-compose-follow-does-not-lay-out-the-whole-buffer`
- `harness-ui-compose-follow-leaves-a-visible-box-alone`
- `harness-ui-chat-notice-check-skips-unchanged-windows`
- `harness-ui-chat-following-windows-are-measured-once-until-they-move`
- `harness-ui-chat-table-detection-stays-inside-its-block`
- the existing footer, notice, auto-scroll, table-refit and redraw tests

The full suite and lint status is recorded with the hand-in.
