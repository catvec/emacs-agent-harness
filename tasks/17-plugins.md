# 17 — Plugin loader, self-extension tools and hot reload

**Status:** completed

## Scope

Plugin loader, self-extension tools and hot reload.

## Acceptance criteria

- [x] harness-reload reloads modules in dependency order, keeping sessions
- [x] Registries remember their owner so a reload removes what it replaces
- [x] harness-plugin-mode reloads a saved file via file notifications
- [x] harness_eval, harness_define_tool, harness_write_plugin, harness_reload

## Notes

Behaviour and interfaces are described in DESIGN.md; this file only records
that the work is done and what "done" meant.
