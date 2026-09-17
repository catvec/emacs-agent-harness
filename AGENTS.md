# AGENTS.md — working guide

Conventions for any agent (or human) changing this repository.

## Source of truth

- `SPEC.md` — original requirements. Do not edit; it is history.
- `DESIGN.md` — canonical design. **If you change an interface, update
  `DESIGN.md` in the same commit.**
- `tasks/` — progress tracking. Never delete a completed task file.

## Non-negotiable constraints

1. Never block the Emacs main thread. Network I/O is
   `make-network-process` + `:nowait t` + filters/sentinels. No
   `accept-process-output`, `sleep-for`, or `url-retrieve-synchronously` in
   runtime paths (tests excepted).
2. No expensive work on the main thread. Streaming rendering is incremental;
   output is truncated before insertion; search uses the SQLite index.
3. Built-in Emacs APIs only. Optional third-party integration must be guarded
   with `with-eval-after-load`.
4. `lexical-binding: t` in every file. All public symbols `harness-` prefixed,
   private ones `harness--`. `defcustom` for anything user-visible, in the
   `harness` group. Docstrings on every public function, with `\\[...]` for
   interactive commands.

## Architecture rules

- `harness-core.el` defines structs, registries and hooks. It must not require
  any other `harness-` module.
- Lower modules (`harness-http`, `harness-provider*`, `harness-tools`,
  `harness-agent`) must not require UI modules. They communicate upwards only
  through the hooks in DESIGN.md §3.1 and the registries in §9.
- A feature is added to the core only if it cannot be expressed as a tool, a
  renderer, a hook function, a provider, or a transport. If you add a special
  case, add a registry instead.
- Every buffer gets a major mode derived from an existing one
  (`special-mode`, `tabulated-list-mode`, `outline-mode`, `text-mode`).

## Adding a provider

Implement the `cl-defgeneric`s in DESIGN.md §5.1 on your own struct and register
it with `harness-provider-register`. Do not add provider-specific `if`s to the
agent loop or the UI: `harness-provider-chat-async` and `harness-model-stats`
are the only entry points they use. A provider that cannot stream must say so in
`harness-provider-capabilities` and emit a single `:on-delta` with the whole
response instead — the agent loop does not care.

## Commits

- One logical change per commit, imperative subject, 72-column body.
- Format: `harness-<module>: imperative summary` (e.g.
  `harness-agent: keep the run loop asynchronous while a tool awaits approval`).
- Every commit must byte-compile without warnings and pass `scripts/test.sh`.
- Include an ERT test for new behaviour in the same commit as the behaviour.

## Review

Work is reviewed over the private mailing list in `$LLM_CONTRIB_MAILING_LIST`
using `git format-patch` / `git send-email` (see the `mailing-list-review`
skill). Resend revised series with `--in-reply-to` and a versioned subject
prefix.

## Gotchas discovered so far

- Emacs process filters can split a multibyte character across segments. Use
  `binary` process coding and decode UTF-8 yourself.
- `open-network-stream` with `:nowait t` reports connection failure through the
  sentinel, not through a raised error.
- `read-only` text properties together with `buffer-read-only nil` is the only
  way to have a `special-mode`-derived buffer with an editable input area.
- `tabulated-list-mode` reverts by re-running `tabulated-list-print`; keep
  `tabulated-list-entries` generation cheap and free of I/O.
- SQLite handles owned by a buffer must be closed in `kill-buffer-hook` or the
  file stays locked.
