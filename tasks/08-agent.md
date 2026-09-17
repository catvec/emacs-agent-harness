# 08 — Asynchronous run loop

**Status:** completed

## Scope

Asynchronous run loop.

## Acceptance criteria

- [x] Callback driven: request, stream, tools, request again
- [x] The streamed assistant message is a real transcript message
- [x] Abort cancels the request, tool calls and pending approvals
- [x] Providers without native tools get a text tool protocol

## Notes

Behaviour and interfaces are described in DESIGN.md; this file only records
that the work is done and what "done" meant.
