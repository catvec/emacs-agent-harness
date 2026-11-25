# The fuzz plugin

A project plugin that fuzzes the harness's protocol boundaries with
[AFL++](https://github.com/AFLplusplus/AFLplusplus).  AFL++ owns the
exploration: it mutates each target's seed inputs, runs the harness on
whatever comes out, and saves the inputs that break it.  This plugin is
the adapter that lets it fuzz Emacs Lisp, and the report that says what
broke.

Most targets check raw bytes. The `acp-conversation` target instead decodes
AFL's bytes into valid ACP actions and supplies live session IDs and typed
parameters. AFL++ decides which command sequences and arguments to try; it
does not have to rediscover valid JSON syntax before reaching the state layer.

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

From this checkout, run a bounded campaign without starting a live harness:

```sh
# Target, seconds per target (1–60), seed, optional artifact directory.
TMPDIR=/var/tmp .harness/plugins/fuzz/run.sh all 60 20261126
TMPDIR=/var/tmp .harness/plugins/fuzz/run.sh openai-sse 60 42 /var/tmp/my-fuzz-runs
```

The runner allows four targets at a time and at most 10,000 executions per
target. It saves the revision, dirty-tree status, report and inputs needed for
replay. Exit 0 means no findings, 1 means findings, and 2 means the campaign
could not run. Seeds are probed and findings may be minimized after fuzzing,
so total time exceeds the per-target mutation budget. The default artifact
directory is `scripts/.dev/fuzz/`; AFL's raw work directory is retained and
named in `report.el`. Campaigns call no real provider and use no user sessions.

To use the report's numbered replay calls in another Emacs, require
`harness-fuzz` and restore the saved report (read as data, without evaluating it):

```elisp
(setq harness-fuzz--last-report
      (with-temp-buffer
        (insert-file-contents "/path/to/campaign/report.el")
        (read (current-buffer))))
;; Then use the target and crash number printed in summary.txt.
(harness-fuzz-replay 'mcp-line :crash 1)
```

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
| `provider-events` | raw event envelopes, terminal normalization and the exactly-once callback guard |
| `openai-sse` | real SSE and OpenAI-compatible decoding, chunk invariance, mandatory terminal delivery and late-event fencing |
| `session-turns` | ordinary text/tool turns with inert implementations; every turn must succeed |
| `session-soak` | ordinary multi-step turns through real encoding, tool dispatch and persistence; cache changes between turns |
| `acp-conversation` | valid standard ACP command sequences through real wire codecs, dispatch, sessions, turns, tools and cold reload |

The raw targets are pure boundaries. The conversation target uses the
repository's test fixture helpers inside a fresh adapter and writes only to
temporary state. It refuses a live harness. A check signals when the harness
breaks an invariant; an inconsistency is saved as exit 42 even without a native
crash. Raw targets treat handled malformed input as success.

## Valid ACP conversations

```sh
TMPDIR=/var/tmp .harness/plugins/fuzz/run.sh acp-conversation 60 42
```

Each pair of bytes selects a command and its arguments, up to 32 actions.
The first byte chooses among all nine currently implemented standard methods:
initialize, authenticate, session/new, session/load, session/list,
session/prompt, session/cancel, session/set_mode and session/set_model.
The test suite checks that this catalog matches the server's standard-method
registry. Internal `_harness/` extensions are not part of this grammar.

The second byte selects a known session, a valid setting, a scripted model
response, and whether to release a held provider callback. Replies can be
released out of order across requests. All actions run on one thread with
an explicit deferred-callback queue. Cancellation is an ACP notification;
requests carry distinct IDs. Both directions use the actual JSON codecs and
server dispatcher through an in-process wire peer, without a TCP socket.

The state layer, agent and pure counting tool are real. The model is a fixture
that emits text, errors or duplicate tool calls; it contacts no model service.
Every scenario must have one reply per RPC, balanced turn starts/ends, no
repeated tool effect, observable setting changes and correct session listing.
After completion it checks for active turns and pending interactions, flushes
the store, forgets sessions, reloads them, and requires a successful new prompt.
Tests prove that the tool path actually executes and that the oracle fails on
lost RPC delivery. A failure prints its decoded command sequence for replay.

This is valid-command sequence fuzzing, not arbitrary parser fuzzing or a
complete ACP conformance suite. It omits TCP behavior, external providers,
real tools, permission-dialog interaction and extensions. The existing raw
ACP targets remain separate to exercise malformed framing and parameter data.

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

## Whole turn recovery

The pure targets do not create sessions. The complementary
[provider chaos suite](../../../docs/design/provider-chaos-testing.md) drives
malformed and seeded event sequences through the real agent and persistence,
then checks another prompt and a cold load of the same session. It runs in the
ordinary ERT suite without requiring AFL++. The provider-events target deliberately
passes malformed envelopes to the guard rather than filtering them out first.


## Ordinary session soak and cache breaks

```sh
TMPDIR=/var/tmp .harness/plugins/fuzz/run.sh session-turns 60 20261125
TMPDIR=/var/tmp .harness/plugins/fuzz/run.sh session-soak 60 20261124
```

`session-turns` runs ordinary text/tool turns with no deliberate cache changes.
`session-soak` adds the cache mutations below. Both use the same runner,
not per-tool adapters. Each runs one persisted session through ordinary prompts, text replies,
1–3 tool calls per step and 1–2 tool steps per turn. Each input controls up to
24 between-turn actions, plus an initial prompt and two prompts after a cold
session load. The main oracle is deliberately straightforward: **every turn
must finish successfully and the next prompt must work**. An error, unresolved
promise, tool error or leftover active interaction is a finding. Cancellation
and expected provider failures belong to the separate adversarial targets.

It loads the 78 built-in tool declarations currently in `lisp/modules`, replacing
all their implementation hooks (handlers, path/subject resolvers and computer
selectors) with inert handlers. Synchronous and deferred results both run through
the actual permission filter, dispatcher, tool result storage and agent loop.
Two corpus seeds together call every declaration, including `hand_in` under a
fixture task association. No real command, edit, notification, computer action,
subagent, task board or merge executes. Plugin tools and external MCP tools are
not in this catalog; their declarations need a separate opt-in fixture.

The provider uses the actual OpenAI body builder, tool-name mapping, frozen
replay seam, SSE parser and event decoder. Only HTTP is fake: it reads the real
serialized request and returns legal text or tool calls naming the offered
tools, in variable chunk boundaries. Responses can use a reasoning object or a
scalar reasoning field. No real model or network connection is used.

The cache target can revise a tool schema or
description under its settled name, deliver a late effort catalogue, change
thinking/model/system rendering, reset the settled schema, append a hint, change
the reasoning dialect or cold-load the session. These are valid state changes,
not malformed response injections. The late-effort action reproduces the
historical `reasoning.effort changed with no recorded reset` failure when the
old replay module is substituted. The tool definitions are reread each run,
so the catalog follows code changes without a bespoke adapter for each tool.

This exercises short sessions and in-process async callbacks on one thread.
It does not test actual tool implementations, real provider outages, network
sockets, process crashes or every compaction/permission workflow. Stock Emacs
is not AFL-instrumented, and a whole session per input is relatively slow.
AFL's crash exit 42 also represents the logical cannot-continue failures above.
