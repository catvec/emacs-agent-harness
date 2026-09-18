---
name: reading-harness-logs
description: How to read the log written by the bundled harness-log plugin so you can debug a harness session running in an Emacs you cannot operate. Use when a harness session errors, hangs, or hits an HTTP/provider failure and you need the diagnostics, or when you need to locate, enable, or tail the harness log file.
license: GPLv3
metadata:
  version: "1.0"
compatibility: Designed for Claude Code and similar AI coding assistants
---

# Reading harness logs

The harness ships `plugins/harness-log.el` and loads it by default. It mirrors
the Emacs `*Messages*` buffer to a file on a timer, and it writes request
failures and aborts itself (those never reach `*Messages*`). That file is how
you see what an unattended, background, or crashed harness session did.

## Finding the log

The option is `harness-log-file`.  Its default is
`agent-harness/harness.log` under `user-emacs-directory`, i.e.
`~/.emacs.d/agent-harness/harness.log` on a stock setup.

Do not trust the default blindly: Doom and custom configs move
`user-emacs-directory` (Doom points it at its cache directory) or set the
option directly.  The log sits next to the harness's other state
(`index.sqlite`, `sessions/`), so that directory is the place to look.  If the
Emacs has a server, the authoritative answer is one eval away:

```sh
emacsclient -e 'harness-log-file'
```

## Reading it

```sh
tail -f "$(emacsclient -e 'harness-log-file' | tr -d '"')"
# or, with no server:
tail -f ~/.emacs.d/agent-harness/harness.log
```

The plugin appends; when the file passes `harness-log-rotate-size` the
previous one becomes `harness.log.1`.  The file has no timestamps, because it
mirrors `*Messages*` verbatim; use the position of other events to orient
yourself.

Lines worth grepping for:

- `[error] harness request failed for <session>: ...` — a provider or HTTP
  error (written from `harness-request-failed-hook`).
- `[abort] harness run aborted for <session>` — a cancelled run
  (`harness-run-aborted-hook`).
- `error in process filter:` / `error in process sentinel:` /
  `Error running timer:` — errors Emacs swallowed from C: they are not
  signalled to Lisp and `debug-on-error` gives no backtrace, so this file is
  the only record.
- ordinary `*Messages*` lines, including harness setup and provider traffic.

## When the file is not enough: ask the live Emacs

The mirror flushes on a timer (`harness-log-interval`, default 1s) and the
plugin only writes request failures as they happen, so the newest failure may
not be on disk yet.  If a server is running, the session transcript is
authoritative — and it holds the error string even when nothing was logged:

```sh
emacsclient -e '(let (out)
                  (dolist (s (harness-session-list))
                    (dolist (m (harness-session-messages s))
                      (let ((e (harness-message-error m)))
                        (when e (push (cons (harness-session-name s) e) out)))))
                  (nreverse out))'
```

For example, this returned:

```elisp
(("emacs-agent-harness session"
  . "harness-http: HTTP 400: ... messages[2]: invalid type: null ..."))
```

which pointed at an empty assistant message being serialised as JSON `null`.
Use the error text from here, then grep the log for the surrounding
`*Messages*` lines.

## If there is no log file

- The plugin loads with `harness-setup`.  In a running session run
  `M-x harness-reload` and then `M-x harness-load-plugins` (or restart Emacs).
- `harness-log-file` set to nil disables the plugin; `M-x harness-log-disable`
  stops the timer but leaves the file in place.
- `M-x harness-log-open` tails the file inside Emacs; `M-x
  harness-log-truncate` empties it and resumes from now.
- `M-x harness-reload-plugins` reloads it after an edit; a reload does not
  stack its timer or its hooks.
