# 04 — Pluggable provider API, OpenAI provider, process transport

**Status:** completed

## Scope

Pluggable provider API, OpenAI provider, process transport.

## Acceptance criteria

- [x] cl-defgeneric interface: chat, cancel, models, capabilities
- [x] Model stats with price and context window, static plus discovered
- [x] OpenAI-compatible streaming with tool-call accumulation
- [x] Process transport for CLI providers (no CLI provider shipped)

## Notes

Behaviour and interfaces are described in DESIGN.md; this file only records
that the work is done and what "done" meant.
