# Reading a transcript, and checking for updates, without the wait

2026-11-07.  This note records what was measured while looking into slow
session connection and transcript loading in Emacs and the Flutter app,
and in the version page's checking and updating rows.  The measurements
are aggregate: synthetic sessions of a known size and real timing runs,
never the contents of a real transcript.

## What was measured

Two kinds of number appear here.

- **Live** numbers come from the running harness on this machine, read
  from its log and from one authenticated ACP client.  They are a
  sample of a busy machine, not a controlled run.
- **Synthetic** numbers come from the benchmarks in this change
  (`scripts/analysis/bench-transcript-load.sh`,
  `harness_client/tool/bench_transcript.dart`) and from the chat
  benchmark that was run beside them.  They use generated sessions and
  nodes with markdown-like text; nothing private is read or kept.

The first live observation was connect/auth/initialize 1624 ms and
`task/list` 443 ms on a local authenticated bridge.  The server log for
a start shows module start-up work (provider probes, worktree scans,
resumed sessions) before the address is printed, so a cold connect is
gated by start-up, not by the ACP request handling.  Changing that ordering safely is a larger change than
the rest of this work, and is not part of it; the measurements below are
what the clients and the request path themselves cost.

### The session list

200 synthetic sessions, each with a 40 KB provider conversation, full
listing against the lean listing the clients now ask for:

| | full | lean |
|---|---:|---:|
| JSON bytes | 8,542,601 | 524,601 |
| bus call, plists (median) | 0.82 ms | 6.59 ms |
| build and encode (median) | 21.44 ms | 17.61 ms |

The lean plist is cheaper to send (16 times fewer bytes) and to encode,
even though it is built by removing keys from the full plist.  Serialising
8.5 MB is the cost that was paid on every home-screen refresh, for
provider state no view draws.

### A replay

400 synthetic nodes of about 5 KB, as `session/load` sends them:

| | standard replay | nodes alone |
|---|---:|---:|
| updates | 800 | 400 |
| JSON bytes | 3,731,646 | 1,672,090 |
| build updates (median) | 0.82 ms | 0.09 ms |

The standard replay sends each node's chunk and the whole node beside it.
A client that keeps the harness's own nodes can take the node alone: one
update per node, and half the bytes.

### The Emacs chat

Rendering 400 and 1200 synthetic markdown nodes (one node per block):

| nodes | before | after |
|---|---:|---:|
| 400 × ~5 KB | 222.22 ms | 177.46 ms |
| 1200 × ~5 KB | 606.83 ms | 470.92 ms |

The change is in finding session ids in a message.  The chat scanned every
message with `string-match` over a 36-character UUID regexp; a hyphen scan
that only looks at the hyphens, where every UUID has one, is cheaper,
and the linkification itself is unchanged.  In the benchmark of 400
messages of 5 KB, the regexp core took 9.45 ms and the hyphen scan 0.92 ms
(linkification with face properties: 3.92 ms).

The rest of the render time is markdown, code-block fontification and
quote marks; no supported change was found for those within this work.

### The Flutter app

Decoding 1200 synthetic nodes, applying them and ordering the transcript
(`dart run tool/bench_transcript.dart`, after JIT warm-up):

| | 400 nodes | 1200 nodes |
|---|---:|---:|
| JSON bytes | 1,669,220 | 5,007,900 |
| decode | 13.14 ms | 35.91 ms |
| apply every node | 14.44 ms | 20.20 ms |
| first displayed order | 1.08 ms | 2.76 ms |
| repeated displayed order | 0.000 ms | 0.000 ms |

The displayed order is worked out once per change now; a screen asks for
it on every build.  The app also reads a rich harness's conversation
with one `session/load` instead of a load, a `session/get` and a
`session/nodes` request; the last of those was sent with a parameter the
server refused, so it could not have helped.

### The update page

The update's own git work (status, fetch, rev-parse, rev-list,
fast-forward) took 63.47 ms on a local remote.  Verifying the commit —
archiving the tree and byte-compiling every source in a batch Emacs —
took 10,779.80 ms.  A version check's `ls-remote` against a local path
took 21.97 ms; a network remote adds its own wait.

So an update that looks stuck is usually verifying, and a check that looks
stuck is usually waiting on the network.  The page cannot make either
finish sooner; it can say where the time goes and keep saying it.

## What changed

- **Lean session listing.**  `_harness/session/list` takes a `filter`
  with `:lean`; `session/list` leaves out `:provider-state`,
  `:provider-node`, `:allowed-dirs` and `:move`, which no view draws.
  `session/get` keeps every key.  Both clients ask for lean; other
  callers, including the provider module that resumes conversations, get
  the full plist.
- **Nodes-only replay.**  A `session/load` whose `_harness.replay` is
  `"nodes"` sends one `_harness/node` update per node instead of the
  standard chunk plus node.  A harness that does not know the parameter
  ignores it, so the request is safe for an older server.  The Flutter
  app asks for it and draws the updates in the order they come: the
  server holds what is made during a replay and sends it after the
  nodes, so a note written then is neither lost nor placed below newer
  nodes.
- **One read in the app.**  `SessionController.open` no longer asks for
  `session/nodes` after `session/load`, and does not ask for the session
  record when the replay ended with it.  `HarnessApi.sessionNodes` sends
  its `limit`/`before` in `opts`, where the server reads them (the old
  top-level shape was refused).
- **Memoised display order.**  `TranscriptState.displayItems` keeps the
  list it worked out until the transcript changes, and invalidates it on
  every apply, reset, local echo and pending change.  It returns an
  unmodifiable list so a view cannot change that order in place.
- **Cheaper session-id scan** in the Emacs chat, described above.
- **The update page says where the time goes.**  `harness-update` records
  the stage it reached (`fetching`, `checking`, `installing`,
  `reloading`) and when; the remote row shows it with the seconds since.
  The page redraws once a second while a check or update runs, and runs
  no timer otherwise.  `harness--updating` is cleared in an
  `unwind-protect`, so a reload that fails cannot leave the page saying
  an update still runs.

### Alternatives considered

- **Only ACP's standard `session/list`.**  It carries no usage, todos,
  queue or plan, which the home screen and the tree draw; it would have
  replaced a slow listing with a less capable one.
- **A cache of the verification build.**  Verification compiles the
  commit being installed, which is new each time; a cache keyed by commit
  would not hit.
- **Printing the ACP address before module start-up.**  It would let a
  client connect earlier, but requests could then arrive before the
  modules that answer them are up.  That is a change to the start-up
  contract, not a measured, contained fix.
- **Rewriting the markdown renderer.**  It is the largest remaining Emacs
  cost, but the profile does not show a single avoidable operation; a
  rewrite is a larger risk than this work can support.

## UI copy

The changed visible strings, as they render:

- `Updating…` (unchanged), now with a stage and age:
  `Updating… checking · 3s`, `Updating… installing · 1s`,
  `Updating… reloading`.
- `Checking…` (unchanged), now with the seconds waited:
  `Checking… 4s`.
- No new labels, buttons, menus or headers.

These are status phrases, not sentences, and the page's existing exact
copy tests were extended with the stage and age strings.

## Reproducing

```sh
# Emacs: session list, replay payloads, chat session-id scan
scripts/analysis/bench-transcript-load.sh

# Flutter: decode, apply and displayed order, synthetic and aggregate
cd harness_client
eval "$(tool/client_toolchain.sh)"      # prints exports; use with eval
dart run tool/bench_transcript.dart
dart run tool/bench_transcript.dart 400 5000

# The tests of the behaviour these changes preserve
scripts/test.sh test/harness-session-test.el test/harness-acp-test.el \
  test/harness-ui-version-test.el test/harness-ui-test.el
cd harness_client && flutter test test/transcript_replay_test.dart \
  test/transcript_order_test.dart
```

The chat render numbers above came from a one-off benchmark in the
session's temporary directory, using 400 and 1200 generated nodes of
about 5 KB with markdown, code blocks and quotes.  It is not committed
because it needs the whole UI and a state directory to render into; the
committed benchmark measures the scan that changed.

## Limits

- The live numbers are samples, not a benchmark: the machine was busy
  with the harness's own start-up and other tasks.
- The synthetic transcripts are one shape of conversation (a chain of
  messages, thoughts and tool calls).  A transcript with many branches
  walks more parent links when ordering; memoisation helps that case at
  least as much.
- Flutter widget-build timings in the test environment were several
  seconds for a few rows and did not reflect a device; they are not
  quoted as a result.  The numbers above are the model work the app does
  around a build.
