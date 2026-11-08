# The fuzz plugin

A project plugin that fuzzes the harness's protocol boundaries with
[AFL++](https://github.com/AFLplusplus/AFLplusplus).  AFL++ owns the
exploration: it mutates each target's seed inputs, runs the harness on
whatever comes out, and saves the inputs that break it.  This plugin is
the adapter that lets it fuzz Emacs Lisp, and the report that says what
broke.

There is no generator and no grammar here.  A target is a pure check
over one input's bytes plus a handful of seed inputs, as a normal fuzz
target is.  AFL++ decides what to try next.

This is not a working harness plugin: no `.dir-locals.el` here loads
it.  A project (or a test) opts in by requiring
`harness-fuzz-plugin.el` and naming module `tools-fuzz`:

```elisp
((nil . ((eval . (require 'harness-fuzz-plugin
                         (expand-file-name
                          ".harness/plugins/fuzz/harness-fuzz-plugin"
                          (locate-dominating-file default-directory ".dir-locals.el"))))
         (harness-plugin-modules . (tools-fuzz)))))
```

Trust the entries with `!`, as for any plugin.  A session whose project
names `tools-fuzz` gets the three tools; every other session gets none.

## Requirements

AFL++ must be installed: `afl-fuzz` and, for minimisation, `afl-tmin`.
Most distributions package it as `afl++` or `afl`.

```sh
# Arch
pacman -S afl++          # or: yay -S afl++
# Debian/Ubuntu
apt install afl++
# from source, without LLVM/LLVM-mode:
git clone https://github.com/AFLplusplus/AFLplusplus && cd AFLplusplus && make source-only
```

Point `harness-fuzz-afl-program` and `harness-fuzz-tmin-program` at
them when they are not on `exec-path`.

## Tools

- `fuzz_harness` — run a campaign.  Arguments: `target` (`all` or one
  name), `executions` (inputs per target, default 200), `seconds`
  (default 5, at most 60), `seed`, `shrink` (default true).
- `fuzz_targets` — list the targets, their seed count, and whether
  AFL++ is installed.
- `fuzz_replay` — run one input again.  Give `target` and either the
  printed `input`, or `crash`, the number of a crash in the last
  report.

A report names each target's executions and crash count, and for each
crash its message, its input, and the `fuzz_replay` call that runs it
again.  Crashes are minimised with `afl-tmin`; one per target first,
shortest input first, up to `harness-fuzz-max-shrink`.

## How a campaign runs

1. Every seed of every target is written to the campaign's temporary
   directory and run once through the adapter.  A broken adapter, a
   target that cannot be loaded, or a seed that hangs fails the whole
   campaign: a fuzzer that cannot start must not look like one that
   found nothing.  A seed that crashes is removed from the corpus and
   reported as a crash.
2. One `afl-fuzz` runs per target, in parallel up to
   `harness-fuzz-parallel-targets`, bounded by `-E executions` and
   `-V seconds`.
3. The crashes and hangs AFL++ saved are read back, the shortest
   crashes are minimised with `afl-tmin`, and each minimised input is
   run once more through the adapter, because an output that no longer
   crashes is not a minimisation.

Each execution starts an Emacs, so expect a handful of executions per
second rather than thousands: the defaults (a few seconds per target)
suit a tool call, and a longer campaign is one argument away.  The
seeds, `executions` and `seconds` are the knobs; there is no grammar to
write.

AFL++ in dumb mode cannot tell two crashes apart by coverage, so one
bug can leave several crash files.  The report prints up to
`harness-fuzz-max-crashes` of them and counts the rest; they are all in
`harness-fuzz-last-report`, and `fuzz_replay` runs any by number.

The adapter is a separate Emacs, started once per input:

```sh
emacs --batch -q -L ... -l harness-fuzz --eval \
  "(harness-fuzz--adapter-main 'links \"/tmp/.../@@\")"
```

It exits 0 when the check held, 42 when the check signalled or returned
nil, and 1 when the adapter itself could not run.  AFL++ is told 42 is
a crash (`AFL_CRASH_EXITCODE`), and keeps the adapter's stderr beside
the crashing input (`AFL_CRASH_TRACES`).  A crash that takes the whole
Emacs down is a signal, which AFL++ has always understood, so a check
may segfault Emacs and the campaign survives it.

## Targets

| Target | What it fuzzes |
| --- | --- |
| `mcp-serve` | JSON-RPC messages at an MCP server with hostile tools |
| `mcp-result` | malformed `CallToolResult`s from an untrusted MCP server |
| `mcp-line` | the MCP stdio line framing round-trip |
| `acp-lines` | ACP line framing under chunk boundaries it did not choose |
| `acp-params` | ACP params mapped onto method argument lists |
| `acp-normalise` | ACP wire normalisation of Lisp values code can hand it |
| `links` | harness links, handles and link scanning |
| `search-query` | the session search query parser |
| `http-headers` | HTTP headers, disposition and URL file names |
| `provider-events` | provider events through the guard that ends a turn once |

Each target is a pure boundary: it touches no session, file, process or
network.  A check must treat malformed input as handled (return non-nil)
and signal only when the harness itself breaks.

## Adding a target

```elisp
(harness-fuzz-define-target 'my-parser
  :description "The parser I want to break."
  :seeds '("{\"a\":1}" "plain text")
  :check (lambda (bytes)
           ;; BYTES is the raw input as a unibyte string.
           (my-parser bytes)       ; a signal is a crash
           t))                     ; nil is a crash too
```

Define it at the top level of a file and the adapter loads that file
automatically; otherwise put the file in `harness-fuzz-adapter-files`.
A target only the harness process knows cannot run, because the checks
run in the adapter, not in the harness.

## Dumb mode, and coverage

Emacs Lisp has no AFL++ instrumentation, so the default is AFL++'s dumb
mode (`-n`): the mutation engine, corpus, crash detection and
minimiser are AFL++'s, but it cannot tell which input reached new code.
That is still a real fuzzer -- it is the same mutations, run against
real seeds -- but a coverage-guided one is stronger.

To get one, build Emacs with AFL++'s compiler and point the plugin at
it:

```sh
# in an Emacs source tree
CC=/path/to/afl-cc ./configure --with-modules && make
```

```elisp
(setq harness-fuzz-emacs-program "/path/to/afl-instrumented/src/emacs")
(setq harness-fuzz-afl-mode 'instrumented)
```

`harness-fuzz-afl-mode` set to `qemu` uses AFL++'s QEMU mode (`-Q`)
with a stock Emacs when `afl-qemu-trace` is installed.

## Tests

`.harness/plugins/fuzz/harness-fuzz-test.el` covers the adapter, the seed probe, the
command lines, the report and replay without AFL++, and runs a short
campaign against the built-in targets when `afl-fuzz` is on `exec-path`
(and skips it otherwise).
