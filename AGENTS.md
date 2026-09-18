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
- The same rule applies to a feature that is part of the distribution: if it
  can be expressed through the plugin API, it ships as a plugin in `plugins/`
  and is loaded by default, rather than becoming another `harness-*` module.
  The core provides the loader and the registries, not the feature. See
  DESIGN.md §13.2.
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
- `read-only` text properties together with `buffer-read-only nil` is how a
  `special-mode`-derived buffer keeps an editable input area, but it is not
  enough on its own: `special-mode-map` goes through `suppress-keymap`, which
  maps every self-inserting key to `undefined`, and `define-derived-mode`
  splices that keymap in as the parent. A mode with an editable area needs a
  keymap whose parent is not `special-mode-map`, and its single-key commands
  must fall through to `self-insert-command` inside the editable area
  (`harness-conversation--input-p`). `insert` in a test does not catch this;
  type through `execute-kbd-macro` (the macro runs in the selected window's
  buffer, so `switch-to-buffer' first).
- `tabulated-list-mode` reverts by re-running `tabulated-list-print`; keep
  `tabulated-list-entries` generation cheap and free of I/O.
- `json-encode' cannot distinguish a one element array of objects from an
  object, and silently encodes the wrong one.  Any JSON array whose elements
  are objects or arrays must be built with `harness-json-array' (a vector).
- A `defun` argument list cannot use `&key' (the compiler treats `&key' as a
  parameter).  Use `cl-defun' when you want keyword arguments.
- A slot named `directory' or `capabilities' generates an accessor of that
  name, which then collides with any function you define.  Name the function
  differently (`harness-tool-session-directory').
- `decode-coding-string` with the `utf-8` coding system rewrites CRLF to LF.
  Use `utf-8-unix` for anything that came off the wire or out of a file.
- The Emacs 31 byte compiler sometimes reports a `let*' binding as unused when
  its init form is complex.  Assign with `setq' on the next line instead of in
  the binding list.
- `run-hook-with-args` **discards** return values.  A hook that threads a value
  (such as `harness-user-message-functions`) must be run with an explicit
  `dolist` over the hook variable, not with `run-hook-with-args`.
- Never `nreverse` a plist: it reverses the pairs and every later `plist-get`
  returns garbage.  Only reverse a plain list of entries.
- `(read-from-string "x")` returns `(OBJECT . POSITION)`, so a caller that
  wants the forms must take the `car`.
- Emacs variables that only exist during byte compilation (such as
  `byte-compile-current-file`) must be read with `(bound-and-true-p ...)`, or a
  freshly started Emacs signals a void-variable error.
- A module that is *optional* (like `harness-context`) is referenced through
  `fboundp`-guarded calls from the modules below it, so `harness-core` +
  `harness-provider` + `harness-agent` stay usable headless.
- Tests that run git must disable signing (`commit.gpgsign=false` in the temp
  repository, and via `GIT_CONFIG_*` in the environment).  A temporary
  repository inherits the user's global `commit.gpgsign`, and a test that pops
  up a pinentry dialog hangs forever and interrupts the user.
- SQLite handles owned by a buffer must be closed in `kill-buffer-hook` or the
  file stays locked.
- Emacs reports errors from process filters and sentinels from C, with
  `Fmessage`, so advice on the `message` function never sees them and
  `debug-on-error` produces no backtrace. The only sink they reach is
  `*Messages*`; `plugins/harness-log.el` mirrors it to a file.
- `unload-feature` unbinds the variables the file defined, so a plugin's
  `defcustom` values reset on every reload unless its `FEATURE-unload-function`
  removes them from `unload-function-defs-list`.
- A plugin with effects outside the registries (a timer, an advice, a hook)
  must define `FEATURE-unload-function` to undo them; `unload-feature` only
  knows the definitions the file itself made.
- `harness-json-write` (through `json-encode`) encodes nil as the string
  `"null"`, so `(delq nil ...)` over already-encoded JSON strings removes
  nothing and the null reaches the provider. Drop the wire form before
  encoding it: `harness-provider-openai--message-json` returns nil for a
  message that must not be sent.
