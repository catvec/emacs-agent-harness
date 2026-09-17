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
