# 09 — Conversation buffer and input area

**Status:** completed

## Scope

Conversation buffer and input area.

## Acceptance criteria

- [x] Incremental rendering: O(delta) streaming, per tool call refresh
- [x] Read-only output, editable input, approvals actionable in place
- [x] Renderers registered through a registry; bodies through a hook
- [x] Queue section and a header line with status, model, cost, context

## Notes

Behaviour and interfaces are described in DESIGN.md; this file only records
that the work is done and what "done" meant.

### Follow-up: input pinned to the window bottom

A short transcript left the prompt at the top of the window.  Blank, read-only
*filler* lines are now kept between the transcript and the prompt so the input
sits on the window's last line, and are removed once the transcript is taller
than the window.  The same change fixed the extras (approvals and queue)
boundary marker, which previously advanced past the extras and let a later
message land below them and re-render the queue twice.  See DESIGN.md §9.1 and
`harness-ui-test-input-pinned-to-window-bottom` /
`harness-ui-test-extras-stay-below-earlier-messages`.

### Follow-up: transient help menus, typeable compose area

Every harness major mode now reaches a `transient` help menu defined in the
new `lisp/harness-ui-menu.el`: `?` in the read-only views and on the
conversation transcript, `C-c ?` in the queue editor, and an input-aware `?`
in the conversation and ask buffers so it types in the compose area or a
widget field.  Fixing that exposed a pre-existing bug: the conversation mode
inherited `special-mode`'s keymap, which remaps `self-insert-command` to
`undefined` and binds `?`, `h`, `SPC`, the digits and others, so the compose
area could not be typed into at all interactively.  The mode now parents on
`text-mode-map` and routes the transcript-only keys
(`?`, `g`, `n`, `p`, `q`, `SPC`, `S-SPC`, `DEL`) through an input-aware
command.  See DESIGN.md §9.1/§9.4 and `harness-ui-test-compose-area-is-typable`
/ `harness-ui-test-every-mode-has-a-help-menu`.
