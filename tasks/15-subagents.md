# 15 — Subagents, personalities and model inheritance

**Status:** completed

## Scope

Subagents, personalities and model inheritance.

## Acceptance criteria

- [x] spawn_subagent is asynchronous and can run in the background
- [x] Personalities carry a prompt, a tool allow-list and a model
- [x] An explicit model beats the personality, which beats the parent
- [x] Viewing a subagent is the ordinary conversation buffer

## Notes

Behaviour and interfaces are described in DESIGN.md; this file only records
that the work is done and what "done" meant.
