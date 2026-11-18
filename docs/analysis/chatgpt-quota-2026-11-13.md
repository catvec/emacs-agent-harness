# Overnight ChatGPT-plan quota consumption, 2026-11-12/13

Investigation of the ChatGPT subscription quota the harness consumed
overnight. All numbers come from the harness's own usage ledger
(`usage.db`) and session records (`sessions/`), read read-only through the
harness's ACP socket and its session JSONL logs. Nothing is inferred from a
provider's billing page, and no quota unit is converted into another: see
[Data gaps and confidence](#data-gaps-and-confidence).

## What was fixed, behaviour by behaviour

Every row is this branch (`task/investigate-overnight-chatgpt-quota-sp1j60ii`),
not merged code and not deployed behaviour.  `main` does not contain it
yet, and nothing has run in production: the merge queue brings it in
after hand-in.  A behaviour with no test is marked unverified, not
working, and a partial success says which part.

| Behaviour | State | Evidence | Fix | Blocker |
| --- | --- | --- | --- | --- |
| Final adapter body is frozen, field by field, and the sent bytes are the kept bytes | **working (branch)** | `harness-replay-the-frozen-body-is-what-was-sent`, `harness-replay-the-sent-body-is-the-kept-one`; replay suite 51/51 | `harness-replay.el` (pieces, splice, text), `harness-provider-openai.el` (`--frozen-body`), `harness-provider-responses.el` (`--frozen-body`) | — |
| The invariant is the **prompt**, not the whole request body | **working (branch)** | `harness-replay-a-metadata-field-is-not-a-prompt-change` (a budget added: spliced, sent, not refused) and `-a-prompt-field-changed-is-still-refused` (a changed message: refused). `harness-replay-prompt-fields` names what is frozen | `harness-replay--prompt-only`, `--metadata-fields`, `--with-metadata` | — |
| Content-free prefix telemetry per request | **working (branch)** | `harness-replay-a-decision-says-what-it-did-with-the-prefix` asserts `decision`, `prefix-bytes`, `appended-bytes`, and that no message text or digest appears; `replay/prefix` is a declared event | `harness-replay--telemetry`, `harness-declare-event 'replay/prefix` | — |
| A provider miss on identical bytes is bounded, not acted on | **working (branch)** | `harness-replay-a-miss-on-identical-bytes-is-the-providers` (returns `provider`, generation and bytes unchanged, next request still splices) and `-a-miss-with-no-identical-prefix-is-unexplained` | `replay/miss-note`, `harness-replay--on-reuse` | no live provider miss was observed this revision |
| An appended message changes nothing before it | **working (branch)** | `harness-replay-an-appended-message-changes-nothing-before-it` asserts the second body equals a fresh encode of the two-message body | same | — |
| Unexplained mutation fails closed, with **no HTTP send** | **working (branch)** | `harness-replay-a-mutation-stops-before-the-transport`: `(= 0 (length harness-replay-test--requests))`, complaint names `messages[0].content` and never the text | `harness-openai--complete` sets `:error-kind 'permanent`; `harness-responses--start` refuses the same way | — |
| Recorded reset explains a change | **working (branch)** | `harness-replay-a-recorded-reset-explains-the-change`, `-a-compaction-records-its-reset`, `-a-session-setting-records-its-own-reset`, `-a-pruned-picture-records-its-reset` | `replay/frozen-reset`, `harness-replay-reset-on-change`, `harness-replay--on-images-pruned` | — |
| Compaction / system / tools / model / route / redaction resets are explicit | **working (branch)** | the four tests above plus `harness-replay-a-redaction-drops-the-frozen-body` | `harness-replay-frozen-reset-reasons`, `harness-replay-reset-changes` | — |
| Reasoning and tool items replay byte for byte | **working (branch)** | `harness-replay-reasoning-and-tool-items-go-back-as-they-came`; Responses suite 54/54 including `...-body-replays-remembered-reasoning` | item-wise array pieces keep each item's bytes | — |
| Pictures are kept, not vetoed; pruning is a recorded reset | **working (branch)** | `harness-replay-a-picture-is-kept-as-the-tool-returned-it` (replaces the old "not kept" test), `-a-pruned-picture-records-its-reset` | `replay/save-request` no longer refuses image bytes; `harness-agent--cap-images` emits `agent/images-pruned` | — |
| Restart keeps the frozen body | **working (branch)** | `harness-replay-a-frozen-body-survives-a-restart` | file-backed `replay/frozen-record`, `harness-replay--thaw` keeps `[]` and `{}` apart | — |
| Large payload is not kept, and says so | **working (branch)** | `harness-replay-a-large-body-is-not-kept` (`:reset` is `too-large`, `:bytes` 0) | `harness-replay-frozen-max-bytes` | — |
| A store that cannot write keeps nothing rather than a wrong body | **working (branch)** | `harness-replay-a-store-that-cannot-write-keeps-nothing` | `harness-replay--frozen-write` returns nil, caller records `storage-failure` | — |
| Retry sends the same bytes | **working (branch)** | `harness-replay-a-body-sent-twice-is-sent-the-same-bytes` (two sends, one body, idempotent keep) | the frozen body is a pure function of the kept record | — |
| Two sessions never share a frozen body | **working (branch)** | `harness-replay-two-sessions-do-not-share-a-frozen-body` | keyed by session id | — |
| Concurrency: two sessions interleaved | **working (branch)** | `harness-replay-two-sessions-interleaved-keep-their-own-bytes`: two conversations' requests interleave, each continues from its own body, and a reset of one leaves the other's bytes alone | keyed by session id | — |
| Redaction drops the frozen body and counts it | **working (branch)** | `harness-replay-a-redaction-cleans-what-the-provider-was-sent` (`:payload-count` includes it) | `replay/redact` binds the frozen file | — |
| A one-off call is not the conversation's prefix | **fixed (branch)** | `harness-replay-a-one-off-call-is-not-the-conversations-prefix`: an auto-name or judge for a session that has a frozen body is neither spliced into it nor kept as it, and the conversation's next step still splices. Before the fix it was **refused before the transport** | `harness-replay-conversation-p`, `harness-replay-seam`, `harness-replay-seam-keep` | latent: no production session runs the freezing path yet (no `*.frozen.json` in the state directory) |
| A cache refresh reads the cache without becoming the prefix | **fixed (branch)** | `harness-replay-a-cache-refresh-reads-without-becoming-the-prefix`: the refresh still splices (that is what reads the cache) and is not kept, so the next real step is not refused or re-rendered | `harness-replay-keeps-prefix-p` | latent, as above |
| Loading the module defines its handlers; init only subscribes | **fixed (branch)** | `harness-replay-the-module-defines-its-handlers-and-inits-once`; the two `declare-function` forms a lint fix inserted into `harness-replay--init` had nested both handlers inside it and left init without a docstring | `harness-replay--init` | — |
| ChatGPT-plan (Responses) route freezes and checks | **working (branch)** | Responses suite 54/54, including the `:body`-sent assertions the fake now reads back | `harness-responses--start` sends `:body` bytes with `Content-Type` | no live ChatGPT request was made; see below |
| The wire body is the body object, not a JSON string literal | **fixed (branch)** | this was the bug `t-jibzilj2` independently reported at `18616b4`; `harness-provider-openai-test` 56/56 asserts what the transport received | adapters pass `:body`, never `:json` | — |
| The Responses keep-guard records a body | **fixed (branch)** | same report: the guard compared the transport's text with the adapter's plist and kept nothing. It now rebuilds the plist and compares like with like | `harness-responses--frozen-keep` | — |
| Cache alert does not call a good read a miss | **fixed (branch)** | `harness-cache-health-does-not-call-a-good-read-a-miss` asserts the exact rendered line and that `"miss"` appears in neither the hint nor the notification title; cache suite 23/23 | `harness-cache--alert` wording, `Cache reuse low` | the 0.99 threshold itself is unchanged (see appendix) |
| A runtime's count is only believed for the state it counted | **fixed (branch)** | `harness-sandbox-session-an-answer-older-than-the-change-is-dropped` and `-answers-out-of-order-leave-the-newest`; both **fail on the previous code** and pass with this. sandbox suite 25/25, ten consecutive runs clean | `harness-sandbox-session--ask`, `--counted`, `--bump-epoch`, and the `P` frame's epoch in the supervisor | — |
| A runtime holding a background process is not torn down as idle | **fixed (branch)** | same tests: a `status` asked while a command runs is answered `0` (that run owns its processes), and that zero arriving after the run ended used to start the idle clock and destroy the runtime with the process still in it. `harness-sandbox-session-a-server-it-holds-outlives-an-empty-run-and-a-count` covers the live path | as above; a dropped answer leaves the count unanswered, which the poll already waits on, so ownership stays fail-closed | the live test was seen to fail once under parallel load before the fix and passes 10/10 after |
| Full suite green | **229 of 229 pass on the merged tree, 0 failures** | every suite's own log, exit 0 each, run in bounded batches because this environment ends long background jobs; the one suite not run is `harness-tools-shell-tramp-test`, which **hangs identically on a clean export of `main`** (passes test 1, never returns from test 2) | the merge `8eb1fe5` | not a single `scripts/test.sh` pass, so `--status` says `UNVERIFIED`; the TRAMP hang is the documented `project-current` block and not this task's to fix |
| Live ChatGPT-plan cache behaviour | **unverified** | no live ChatGPT request was made in this revision, by instruction | — | a separately authorised bounded smoke |
| Live OpenRouter DeepSeek cache behaviour | **unverified this revision** | the 2026-11-09 Particle/Morph observations are **dated**, and are not DeepInfra or ChatGPT evidence today | — | a separately authorised bounded smoke |

### What the frozen body does not claim

Identical bytes are not a cache hit.  Eviction, retention, shard
placement and routing are the provider's; the harness guarantees only
what it sends.  See [the design](../design/frozen-prompt-prefix.md).

### The merge the queue handed back

The branch was 30 commits behind `main`, and the merge queue started the
merge into it and stopped at six conflicts:
`lisp/harness-skills-scan.el` and its test, and
`lisp/modules/harness-provider-openai.el`, `harness-provider-openai-test.el`,
`harness-provider-responses.el` and `harness-sandbox-session.el`.  The
queue handing the branch back is exactly the case `CLAUDE.md` describes,
so the conflicts were resolved on the branch and committed as the merge
`8eb1fe5` (parents `829ac42` and `main`'s `1574160`), keeping both sides:

- **`harness-skills-scan`** — `main`'s sorted walk supersedes this
  branch's earlier, weaker attempt, so `main`'s file is taken whole; both
  tests stay (`-the-bound-keeps-the-first-names-in-order` from `main`,
  `-bounds-ignore-directory-enumeration-order` from this branch).
- **`harness-sandbox-session`** — `main`'s instance-scoped `environs_of`
  ownership beside this branch's epoch-numbered count: `status_all` scans
  `environs_of`, skips a run still in flight, and echoes the question's
  epoch.  Both mechanisms are in the merged file.
- **`harness-provider-openai`, `harness-provider-responses`** — both
  sides' changes, this branch's frozen body and `main`'s provider work.

The merged tree byte-compiles, lints clean in these files, and passes all
229 suites (see below).  Nothing was pushed, and `main` itself is not
touched: the queue does that.

### Route this revision used

`openrouter:deepseek/deepseek-v4.1-flash-1017`, endpoint `deepinfra/fp8`.
No ChatGPT-plan request, no direct DeepSeek, no fallback, no route or
pin change, no merge and no deployment.  The pin and the configured
model are untouched by this diff: it changes what is sent, not where.


# Appendix: the investigation of 2026-11-12/13

Everything below is the historical ledger evidence, kept exactly as it was
established.  It is the *why*; the behaviour table above is the *what was
done*.

## Verdict

The overnight spend was **one real workload plus one structural
inefficiency**, not a runaway loop:

1. **The workload was real.** Two task sessions and their sixteen
   sub-agents did about six hours of genuine engineering: voice
   turn-completion work in `emacs-agent-harness`, and a native Android
   client for `brapmony`. Every ledger row belongs to one of them; nothing
   is orphaned or unexplained.
2. **The inefficiency is re-sending whole conversations.** 335.6M input
   tokens were sent for 982k tokens of output, a 342:1 ratio. The prompt
   cache absorbed 55.5%. The remaining 149.4M tokens were re-sent at full
   price because the cache kept breaking.
3. **The plan was spent by design, then exhausted.** It stopped answering
   at **2026-11-13 03:20:00 EST** with
   `subscription_sharing_usage_limit_exceeded`. DeepSeek had already run
   out of money **27 hours earlier**, so no fallback was left and every
   affected session stopped.

The most actionable finding is not about the plan: **DeepSeek's balance
ran out at 2026-11-12 00:00 EST and nothing surfaced it**, which removed
the only fallback and put the whole night's work on the ChatGPT plan.

## Window

Noah is UTC-05. The overnight window is not midnight-to-midnight; the
ledger's hour buckets say exactly where it starts and stops.

| Bound | Local (EST) | Epoch |
| --- | --- | --- |
| Lookback start (preceding 24 h plus the night) | 2026-11-11 00:00 | 1794373200 |
| First plan call of the night | 2026-11-13 01:00 | 1794546000 |
| Last plan call of the night | 2026-11-13 03:19 | 1794558000 |
| Plan quota exhausted | 2026-11-13 03:20 | 1794558000 |
| Report cut-off | 2026-11-13 10:00 | 1794582000 |

Hourly **subscription** usage over the whole lookback (all plan models):

```
hour (local)          input      output   cache-read   calls
2026-11-13 01:00  135,797,968    566,628   51,752,320   2,244
2026-11-13 02:00  165,568,775    352,878  109,272,192   1,654
2026-11-13 03:00   34,258,986     62,875   25,199,104     276
```

Nothing was billed to the plan in the preceding 24 hours. The only other
subscription entries in the lookback are six `claude:haiku` calls, all
carrying zero tokens, all on 11-12 between 08:00 and 00:59. So **all
335.6M plan tokens fall inside a three-hour burst**, and the night's
boundaries are 01:00 and 03:19 EST, not midnight and dawn.

## Per-session table

Subscription-billed usage, 2026-11-13 01:00-03:20 EST, sessions with more
than one call. `cache%` is `cache-read / input`, because the cached tokens
are a *part* of `input` on this route (see
[Accounting defects](#accounting-defects)).

| Session | Kind | Input | Output | Cache-read | cache% | Calls | Work |
| --- | --- | ---: | ---: | ---: | ---: | ---: | --- |
| `3fd8ccb5` | main | 69,897,519 | 114,954 | 45,917,952 | 65.7% | 201 | brapmony: native Android app with parity |
| `4cd1a447` | main | 48,090,448 | 77,758 | 31,575,936 | 65.7% | 212 | harness: voice-mode speech-end detection |
| `e376af0d` | subagent | 44,921,528 | 75,064 | 27,289,600 | 60.7% | 294 | Flutter voice turn guard |
| `3d8a3405` | subagent | 34,633,019 | 76,780 | 21,763,712 | 62.8% | 229 | Emacs voice turn guard |
| `f85f312c` | subagent | 21,739,833 | 77,832 | 8,693,376 | 40.0% | 145 | brapmony: native parity and platform audit |
| `898fa49f` | subagent | 17,594,795 | 65,343 | 10,401,280 | 59.1% | 191 | brapmony: emulator visual verification |
| `f957ca8f` | subagent | 17,091,526 | 56,321 | 8,123,520 | 47.5% | 106 | brapmony: native social and notifications |
| `45d91762` | subagent | 14,735,363 | 56,013 | 6,819,840 | 46.3% | 105 | brapmony: native account and server controls |
| `cd1f9635` | subagent | 13,293,745 | 34,115 | 6,797,312 | 51.1% | 104 | Voice sidecar continuation metadata |
| `0102e78f` | subagent | 12,155,253 | 43,077 | 6,039,424 | 49.7% | 98 | Flutter speech backend safety |
| `49dccd65` | subagent | 9,532,941 | 35,930 | 4,169,472 | 43.7% | 81 | Flutter unsent speech surfaces |
| `692530e5` | subagent | 9,322,991 | 52,500 | 3,770,368 | 40.4% | 69 | Native server-management implementation |
| `7771c891` | subagent | 4,662,921 | 35,083 | 1,398,400 | 30.0% | 52 | Notification slice |
| `bd5a8527` | subagent | 4,342,943 | 34,778 | 633,216 | 14.6% | 48 | Audit checklist source crosscheck |
| `cd037112` | subagent | 3,787,336 | 17,133 | 937,344 | 24.8% | 35 | Server contract audit |
| `ef0b4e8a` | subagent | 3,287,059 | 14,376 | 950,784 | 28.9% | 32 | Review Emacs turn guard |
| `686d26c9` | subagent | 2,229,322 | 22,671 | 447,488 | 20.1% | 37 | Notification repository tests |
| `7e5b5395` | subagent | 1,348,375 | 7,648 | 494,592 | 36.7% | 19 | Pending speech UI review |
| **Task sessions (2)** | | **117,987,967** | **192,712** | **77,493,888** | **65.7%** | **413** | |
| **Sub-agents (16)** | | **214,678,950** | **704,664** | **108,729,728** | **50.6%** | **1,645** | |
| **Internal helpers (2,118)** | | **2,958,812** | **85,005** | **0** | **0%** | **2,118** | |
| **Total** | | **335,625,729** | **982,381** | **186,223,616** | **55.5%** | **4,176** | |

Reading the table:

- **The two task sessions read 65.7% of their prompt from cache; the
  sub-agents read 50.6%.** That gap is the finding. A task session starts
  from a compacted summary and re-reads the same files, so its prefix is
  stable. A sub-agent is spawned cold with a large self-contained prompt
  and then runs its own short, fast-moving turn, so less of its prefix is
  ever cached.
- **The worst cache ratios are in read-only reviewer sub-agents:**
  `bd5a8527` at 14.6%, `686d26c9` at 20.1%, `cd037112` at 24.8%, `ef0b4e8a`
  at 28.9%.  A reviewer reads widely and edits little, which is a workload
  shape that re-sends a lot for little output.  That is the observation;
  why any individual request missed is not in the ledger.
- **The 2,118 internal helper calls are half the call count and 0.9% of the
  tokens.** They are the permission judge, auto-naming, recaps and todo
  sync. Negligible for quota, relevant only to per-call overhead.

The per-session table above is by *ledger* model, not by the session
record's `model` field: the two disagree once a session has been moved by
the fallback (see [Data gaps](#data-gaps-and-confidence)).

## What the tokens bought

The work is substantial and is visible in the sessions:

- **Voice turn completion (8 sessions, 117.2M tokens).** `4cd1a447`
  (parent) plus `3d8a3405`, `e376af0d`, `cd1f9635`, `49dccd65`,
  `0102e78f`, `7e5b5395` and `ef0b4e8a`. One feature split into an Emacs
  turn guard, a Flutter turn guard, sidecar continuation metadata,
  unsent-speech UI and two read-only reviews. The parent's plan records the
  copy inventory (`Unsent speech`, `Finishing thought`, `Waiting for
  continuation`, `Possible cut-off`, `Submission`) and each child's commit.
- **Native Android client (11 sessions, 216.6M tokens).** `3fd8ccb5`
  (parent) plus `45d91762`, `f85f312c`, `f957ca8f`, `692530e5`,
  `7771c891`, `686d26c9`, `cd037112`, `bd5a8527` and `898fa49f`. A
  Compose app with parity to the Tauri client, a Robolectric render harness
  and an on-emulator journey test against a local server.

Both are the kind of work Noah runs overnight deliberately. The cost is not
wasted effort; it is the token price of ten agents working in parallel on
two large features for six hours.

## What the ledger actually shows about zero-cache calls

Five consecutive calls of the Android task session
`3fd8ccb5-25d4-438d-bdb6-f3f20d7f5938` on `chatgpt:gpt-6.1-sol`, read
from `usage.db` by row id.  These are **observed facts**, quoted exactly:

| UTC | input | cache-read | row |
| --- | ---: | ---: | --- |
| 2026-11-13 08:10:43.818631 | 444,160 | **0** | 364337 |
| 2026-11-13 08:11:20.419487 | 444,907 | 430,592 | — |
| 2026-11-13 08:15:47.168310 | 455,112 | 428,672 | — |
| 2026-11-13 08:18:02.655925 | 455,796 | **0** | 364440 |
| 2026-11-13 08:19:55.192477 | 458,037 | 359,296 | — |

What this shows: calls with a large prompt and **zero** cached tokens
sit between calls of the same session that read 359k-431k from cache.
A zero-cache call of 444k-456k input is real and is a full-price call.

**What it does not show is why.**  Three explanations fit the same
five rows and this data cannot separate them:

1. **Provider eviction or shard change.**  The prompt was sent
   identically and the provider had nothing cached for it.  Nothing
   the harness did would appear in the ledger either way.
2. **A changed prefix.**  Something earlier in the prompt differed from
   the previous call, so the cache could not match from that point.
3. **A cold or fresh prompt.**  A session's first call, or one after a
   compaction or a model move, has nothing to reuse and is not a miss
   in any meaningful sense.

**Historical final-wire requests were not archived**, and the
per-session snapshot `replay/save-request' keeps is overwritten by the
next request.  So the bytes of those five requests are gone.  That is
the gap this revision's telemetry closes for the future: a
`replay/prefix` line per request records the generation, the decision,
the prefix and appended lengths and the route, so the same question
can be answered next time without keeping a prompt.

**No share of the 149.4M is attributed to any of the three.**  The
figure is a subtraction (`input - cache-read`); its cause is not in
the data.  A tail appended to a prompt does not by itself invalidate
the prefix before it -- that is exactly what the frozen body is for --
so "appending a message" is not offered as a cause either.

## The 342:1 ratio, and where it goes

```
input      335,625,729   (100.0%)
cache-read 186,223,616   ( 55.5%)   served from cache
miss       149,402,113   ( 44.5%)   re-sent at full price
output         982,381   (  0.29%)
```

A cache read is cheap but not free; a miss is expensive.  The ledger
records **that** 149.4M tokens were re-sent at full price.  It does not
record **why** any one request missed, and this report attributes none of
them -- see [What the ledger actually shows](#what-the-ledger-actually-shows-about-zero-cache-calls).
The four mechanisms below are observed in the transcripts and each can
produce a miss; **none is measured as a share of the 149.4M**, and no
per-mechanism total appears.  A miss after a byte-identical prefix and one
after a changed prefix are indistinguishable in this data.

### 1. Compaction restarts the prefix

When a session compacts, the conversation becomes a summary and every
later request re-sends the new prefix uncached. `e376af0d` compacted at
02:26:19 EST (`Compaction · queue · interruption · summary`) and again at
02:29:28 (`Compaction · ~234k tokens · summary`). `4cd1a447` compacted into
a transcript at 01:21:57 EST and was then re-fed it:

```
read_file .harness/transcripts/4cd1a447-20261113T012157.md offset=285 limit=95
read_file .harness/transcripts/4cd1a447-20261113T012157.md offset=1   limit=155
```

Reading a 376-line transcript back into context is the compaction paying
for itself a second time.

### 2. Sub-agent fan-out multiplies the fixed prefix

Sixteen sub-agents each carried a full system prompt, project
instructions, memory and tool schemas, and re-sent their own copy on every
call (1,645 calls). The total is 214.7M input tokens for 704k output.

### 3. Cache health calls a healthy cache a miss

`harness-cache-health-threshold` is **0.99**: a request that read 98% of
its previous prompt counts as a *miss*, and after
`harness-cache-health-streak` (2) of them produces the hint
`Prompt cache miss · 98% cached · 6 calls · 366k tokens re-sent`.
Overnight this fired 15 times in `e376af0d` and 14 times in `4cd1a447`;
11 of the 29 were at 90% cached or better. The word "miss" is wrong for a working
cache, so the one signal a user would act on is misleading. See
[Accounting defects](#accounting-defects).

### 4. Provider-side overload and eviction

Two `server_is_overloaded` errors (01:38:24 in `4cd1a447`, 01:28:30 in
`e376af0d`) forced retries. A retry can land on a different machine with a
cold cache, which is the case `harness-cache-health-streak` exists to
tolerate. The ledger cannot separate "the cache lapsed" from "the cache
never existed", so these are counted as misses and the split is unknown.

## Error timeline and fallback transitions

The failure classes are distinct and must not be conflated. In order:

| Local (EST) | Epoch | Class | Session | What it means |
| --- | --- | --- | --- | --- |
| 2026-11-12 00:00:47 | 1794459647 | DeepSeek balance | `0f7afeb4` naming | `HTTP 402: Insufficient Balance` |
| 2026-11-12 00:00:48 | 1794459648 | Fallback exhausted | `0f7afeb4` | `Nothing left to carry on with: DeepSeek is out of money.` |
| 2026-11-13 01:28:30 | 1794551310 | Provider overload | `e376af0d` | `server_is_overloaded` (retryable) |
| 2026-11-13 01:38:24 | 1794551904 | Provider overload | `4cd1a447` | `server_is_overloaded` (retryable) |
| 2026-11-13 02:21:00 | 1794554460 | Empty key | `3fd8ccb5` | `invalid_api_key: Incorrect API key provided: ''` |
| 2026-11-13 03:19:55 | 1794557995 | Fallback move | `898fa49f` | moved to `chatgpt:gpt-6.1-sol` |
| 2026-11-13 03:19:56 | 1794557996 | DeepSeek balance | `898fa49f` | `HTTP 402: Insufficient Balance` |
| 2026-11-13 03:20:00 | 1794558000 | **Plan quota** | `4cd1a447` | `subscription_sharing_usage_limit_exceeded` |
| 2026-11-13 03:20:01 | 1794558001 | Fallback exhausted | `4cd1a447` | queued until a provider works again |
| 2026-11-13 03:20:02 | 1794558002 | Empty key | `e376af0d` | `invalid_api_key: Incorrect API key provided: ''` |

After that, `3fd8ccb5` retried hourly (04:19:59, 05:20:01, 06:20:03,
07:20:05, 08:20:07 EST), each time hitting the DeepSeek 402 first and then
stopping. No plan call was billed after 03:20: the 03:00 hour's 276 calls
all precede the limit.

### Distinguishing the three classes

- **`subscription_sharing_usage_limit_exceeded`** is the plan's own quota,
  reported by OpenAI as HTTP 429. The harness reads it as `quota` and marks
  the ChatGPT plan out. This is what actually ran out overnight.
- **`HTTP 402: Insufficient Balance`** is DeepSeek's prepaid wallet, read
  as `billing`. It is unrelated to any ChatGPT quota, and it fired **27
  hours before** the plan's own limit.
- **`invalid_api_key: Incorrect API key provided: ''`** is a configuration
  fault, not a quota: an empty string was sent as the OpenAI API key. It
  appears twice (`3fd8ccb5` 02:21:00, `e376af0d` 03:20:02), both times
  after the plan route stopped answering. It is a second-order symptom of
  the fallback trying a keyless route, not a cause of the spend.

`fallback.json` records only one session moving **into** a ChatGPT-plan
model during the night (`898fa49f` at 03:19:55). The plan spend was
therefore not caused by a fallback flood: both task sessions and their
sub-agents were *already* on `chatgpt:gpt-6.1-sol` when the night began.


## Baseline comparison

The same three-hour slot on the two preceding nights, by model, as
`usage/summary --group-by model` returns it.

Slot 01:00-03:20 EST on each night, so the three are alike in shape.

| Night | Model | Input | Cache-read | cache% | Calls |
| --- | --- | ---: | ---: | ---: | ---: |
| 11-13 | chatgpt:gpt-6.1-sol | 333,865,327 | 186,990,208 | 56.0% | 2,063 |
| 11-13 | openrouter:deepseek-v4.1-flash-1017 | 191,658,731 | 185,713,280 | 96.9% | 2,579 |
| 11-13 | openrouter:deepseek-v4.1-flash | 38,711,530 | 37,812,608 | 97.7% | 216 |
| 11-12 | openrouter:deepseek-v4.1-flash-1017 | 74,676,135 | 72,800,900 | 97.5% | 1,101 |
| 11-12 | openrouter:deepseek-v4.1-flash | 6,777,217 | 6,502,912 | 96.0% | 80 |
| 11-11 | openrouter:deepseek-v4.1-flash-1017 | 115,918,878 | 113,730,159 | 98.1% | 1,499 |

This is the sharpest comparison in the investigation. **On the same
harness, in the same clock slot, the OpenRouter DeepSeek route read
96-98% of its prompt from cache while the ChatGPT-plan route read
56%.** The workloads are comparable in call count: 1,101 and 1,499 on
the earlier nights against 2,063 plan calls, and 2,579 DeepSeek calls
in the very same slot on the night itself. The harness is not
systematically bad at caching; something about the plan route is.

Two candidate explanations, which this data does not separate:

1. **Provider granularity.** OpenAI's automatic prompt cache may use a
   coarser block size or a shorter life than DeepSeek's, so a fast-moving
   conversation misses more often. The harness cannot fix that.
2. **Workload shape.** The plan route carried the two big *task* sessions
   and their sub-agents (large, long, parallel), while the DeepSeek route in
   those hours carried sessions whose prompts repeat exactly. The harness
   could change that by routing.

Telling them apart needs an experiment the ledger cannot supply: the same
task on both routes, comparing `cache-read / input` per call. See
[Recommendations](#recommendations).

## Accounting defects

Two defects found while reading the ledger. Both are read-only findings;
nothing was changed.

### A. Cache health called a healthy cache a miss (fixed)

`harness-cache-health-threshold` is 0.99 (`lisp/modules/harness-cache.el`).
Any request that reads less than 99% of its previous prompt incremented the
miss streak, and the alert text hardcoded the word "miss":

```elisp
(format "Prompt cache miss · %d%% cached · %s"
        (round (* 100 (or ratio 0))) summary)
```

So `Prompt cache miss · 98% cached · 6 calls · 366k tokens re-sent` was
emitted for a cache that is working. Overnight that produced 29 alerts
across the two task sessions, 11 of them at 90% cached or better. A reader
of the transcript would conclude the cache was broken.

**Fixed on this branch.**  The alert now states what was measured --
`Cache reuse low · 98% cached · 6 calls · 366k tokens re-sent` -- and the
notification title is `Cache reuse low`, so no wording calls a working
cache broken.
`harness-cache-health-does-not-call-a-good-read-a-miss` asserts that exact
rendered line, and that the word "miss" appears in neither the hint nor
the title.  The threshold itself is **not** changed: 0.99 is still what
counts as a healthy read, and whether it should drop to 0.5-0.8 is a
judgement about this data, not a defect, so it stays a recommendation.
### B. `input` carries the cached tokens, so the obvious ratio is wrong

For the ChatGPT-plan route the cached tokens are **inside** `input`
(`harness-provider-responses.el` says so explicitly, to avoid compacting
at half the window). The correct hit ratio is therefore
`cache-read / input`. Computing `cache-read / (input + cache-read)`, which
a reader who assumes the fields are disjoint would do — and which the
DeepSeek route's separate `prompt_cache_hit_tokens` and
`prompt_cache_miss_tokens` encourage — reports 35.7% for a route that is
at 55.5%. Any comparison against a provider reporting the two separately
is wrong by that amount.

## Data gaps and confidence

### High confidence

- Every token figure, call count and timestamp in the tables comes from the
  harness's own `usage` table, read through `usage/summary`, `usage/totals`
  and `usage/series`, and is reproducible with
  `scripts/analysis/chatgpt-quota-query.py`.
- The error timeline quotes the sessions' own `hint` nodes verbatim, each
  with its node `ts`.
- The window bounds are the ledger's hour buckets, not an assumption about
  when Noah went to bed.

### Unknown, and how far to trust what is known

- **Quota units are unknown.** The plan reports a percentage of a rolling
  weekly window (the usage dashboard showed `This week, all models 0%` at
  09:51 EST, after the limit had been hit). The harness stores tokens and no
  plan-specific unit, and OpenAI does not publish how a token maps to
  subscription usage. **No conversion is attempted anywhere in this
  report.** "335.6M tokens consumed the plan's limit" is the whole claim;
  "X% of the weekly quota" is not knowable from this data.
- **Reasoning tokens are not recorded.** The Responses route reports
  `output_tokens` only, and `reasoning.effort` was `max` (`thinking: max`
  on every session). Reasoning tokens are billed as output by OpenAI but
  are invisible in `usage.db`, so 982k output is a **lower bound** on what
  the plan counted as output.
- **Internal helper sessions are unidentifiable in detail.** 2,118 of the
  4,176 calls are `internal` sessions: the permission judge, auto-naming,
  recaps and todo sync. Their records are pruned to the newest 100
  (`harness-session--internal-keep`), so which job each was is gone. What
  survives is the ledger: 2.96M input tokens, 0.88% of the plan total.
- **Cache misses cannot be split by cause.** The ledger records a miss but
  not whether the prefix changed (harness), the provider evicted (OpenAI),
  or a retry landed cold (transport). The 149.4M miss tokens are certain;
  the attribution between those three is not.
- **Retries are not separately counted.** A retried request is another
  call. The two `server_is_overloaded` errors are known; a silent transport
  retry is invisible.
- **A session record's `model` is not its ledger model.** Once the fallback
  moves a session, `sessions/<id>.json` shows the *current* model while the
  ledger keeps per-call rows under the model that actually ran. `898fa49f`
  reads as `deepseek:deepseek-flash` in its record, yet all 191 of its
  overnight calls are ledger rows under `chatgpt:gpt-6.1-sol`. **Attribute
  by ledger, never by the record's `model`.** Every table above does.

### The route this investigation used

This session ran on `openrouter:deepseek/deepseek-v4.1-flash-1017` through
OpenRouter (endpoint `deepinfra/fp8`, canonical slug
`deepseek/deepseek-v4.1-flash-20261017`, `billing: api`), verified from its
own session record before any analysis began. It never used the ChatGPT plan
and never fell back to direct DeepSeek.

## Recommendations

Ordered by what the evidence supports, strongest first.

### 1. Surface an out-of-money fallback at once

DeepSeek's balance ran out at 00:00 on 11-12 and nothing said so until the
plan ran out 27 hours later. A balance state in the usage dashboard, shown
when the fallback stops working rather than only when a turn fails, would
have let Noah top up before the night depended on one provider. This is the
change with the largest effect on this incident.

### 2. Fix the cache-health threshold and its wording

0.99 is not a health threshold; it is "a perfect cache". Put it where a
miss actually costs something (this data suggests 0.5-0.8), and stop
calling a 98%-cached request a miss. Small and local: a threshold change
plus an exact-copy regression test in `lisp/modules/harness-cache.el`.

### 3. Make the compaction restart cheaper

`4cd1a447` compacted to a transcript and then read that transcript back in
two `read_file` calls. Either carry forward a compact, cacheable prefix
instead of a file the model must re-read, or let a compacted session resume
from the summary alone and search the transcript lazily. Today it pays for
the conversation twice.

### 4. Keep read-only reviewers off the plan model

The four worst cache ratios (`bd5a8527` 14.6%, `686d26c9` 20.1%,
`cd037112` 24.8%, `ef0b4e8a` 28.9%) are all read-only audit sub-agents.
They read widely, invalidate their own prefix and produce little output.
Routing read-only review to the cheaper API model cuts plan usage without
touching the work.

### 5. Give plan-priced calls a budget-visible cost

The harness has session and project budgets, but a plan call records
`cost = 0`, so no budget can see it. Pricing plan calls at API rates for
budget purposes only — the dashboard already computes `list-cost` — would
let a budget stop a session before it exhausts a shared subscription.

### 6. Measure the plan route's cache behaviour

The 56%-against-97% gap is the largest lever in this report, and the data
does not yet say whether it is OpenAI's cache or the workload shape. Run
one comparable task on both routes and compare `cache-read / input` per
call. That answers it in one experiment, and decides whether
recommendation 4 should reach beyond read-only reviewers.

## Reproducing this

Both scripts are read-only. `chatgpt-quota-query.py` needs the harness's
ACP socket address and token. `chatgpt-quota-events.sh` needs a path to the
session logs; where bash cannot reach them, the harness's own `grep` tool
can, and the queries in that script are the ones to run there.

```sh
# The window, in epoch seconds (2026-11-13 01:00-03:20 EST).
T0=1794546000; T1=1794560400

# Per-session plan usage, biggest first (the table above).
scripts/analysis/chatgpt-quota-query.py --address 127.0.0.1:45203 \
    summary --group-by session --billing subscription --since $T0 --until $T1

# The whole-window totals (335,625,729 / 982,381 / 186,223,616 / 4,176).
scripts/analysis/chatgpt-quota-query.py --address 127.0.0.1:45203 \
    totals --billing subscription --since $T0 --until $T1

# The hourly shape that fixes the window bounds.
scripts/analysis/chatgpt-quota-query.py --address 127.0.0.1:45203 \
    series --bucket hour --billing subscription \
    --since 1794373200 --until 1794582000

# The per-model split, for the baseline comparison.
scripts/analysis/chatgpt-quota-query.py --address 127.0.0.1:45203 \
    summary --group-by model --since 1794459600 --until 1794474000

# The error timeline and the cache alerts.
scripts/analysis/chatgpt-quota-events.sh ~/.emacs.d/.local/cache/harness/sessions
```

Derived numbers, each one subtraction or division of ledger figures:

- miss tokens: `input - cache-read = 335,625,729 - 186,223,616 = 149,402,113`
- cache share: `cache-read / input = 186,223,616 / 335,625,729 = 55.5%`
- output share: `output / input = 982,381 / 335,625,729 = 0.29%`
- task-session cache share: `77,493,888 / 117,987,967 = 65.7%`
- sub-agent cache share: `108,729,728 / 214,678,950 = 50.6%`

## Checks run

`scripts/lint.sh` exits 0 (only the repository's existing byte-compile
warnings). `scripts/test.sh` is **not green**: 218 suites, 1 failed,
exit 1.

```
failed: lisp/harness-skills-scan-test.el
  FAILED harness-skills-scan-bounds-what-it-lists
  (equal '("file-0.txt" "file-1.txt" "file-2.txt")
         '("file-0.txt" "file-2.txt" "file-3.txt"))
```

This is a **pre-existing** failure, not one this change introduced. It is
reproducible on its own (`scripts/test.sh lisp/harness-skills-scan-test.el`
fails the same way), this branch touches no Emacs Lisp at all (its diff is
the three files under `docs/analysis/` and `scripts/analysis/`), and
`lisp/harness-skills-scan.el` was last changed by an earlier commit. The
test is correct and the implementation is wrong: the file listing at
`lisp/harness-skills-scan.el:401` truncates in filesystem order and only
sorts afterwards, so which three of six files survive the bound depends on
directory order.

## Checks run

### This revision's focused suites

| Suite | Result | Covers |
| --- | --- | --- |
| `lisp/modules/harness-replay-test.el` | 51/51 pass | freeze, append, refusal, resets, images, restart, size, storage, retry, redaction, one-off calls, cache refreshes |
| `lisp/modules/harness-provider-openai-test.el` | 56/56 pass | the body the transport receives; `:strict` encodes as JSON `true` |
| `lisp/modules/harness-provider-responses-test.el` | 54/54 pass | the Responses body, sent as `:body` bytes |
| `lisp/modules/harness-provider-openrouter-test.el` | 84/84 pass | the pin is untouched; the body read back from the wire |
| `lisp/modules/harness-provider-openrouter-chain-test.el` | 10/10 pass | the policy-off path is the old provider |
| `lisp/modules/harness-tools-agent-test.el` | 44/44 pass | two `spawn_agent` calls in one step |
| `lisp/modules/harness-cache-test.el` | 23/23 pass | the alert's exact rendered copy |
| `lisp/modules/harness-agent-test.el` | 102/102 pass | `agent/images-pruned` is emitted and declared |
| `lisp/modules/harness-agent-images-test.el` | 28/28 pass | pictures are content-addressed |
| `lisp/harness-module-docs-test.el` | 11/11 pass | every event a module emits is declared |

### Full suite

**On the merged tree: 229 of 229 suites pass, exit 0 each.**  This is not a
single `scripts/test.sh` pass: the environment ends long background jobs,
so the suite was run in bounded batches instead and every suite's own log
kept.  It is reported as it happened, not as a green stamp.

The merge of `main` (`1574160`) into this branch (`829ac42`) was resolved
keeping both sides — `main`'s sorted skill walk and its test beside this
branch's, `main`'s instance-scoped supervisor ownership beside this
branch's epoch-numbered count, and both providers' changes.  The merged
tree byte-compiles and every suite passes; the counts grew with `main`'s
own additions (sandbox 26, skills-scan 12, provider-openai 57 plus 2
skipped, provider-responses 55, tasks 273, ui-chat 283).

| Batch | Suites | Failures |
| --- | --- | --- |
| full run (cut by job teardown at 138) | 138 | 0 |
| bounded batches 1–4 | 29 + 30 + 27 + 4 | 0 |
| `harness-ui-chat` (283 tests) | 1 | 0 |
| `harness-tools-jobs`, `harness-tools-sessions` | 2 | 0 |
| `harness-server` (29 tests, slow) + `harness-tasks` | 2 | 0 |
| **distinct suites passing** | **229 of 229** | **0** |

The one suite not run is `lisp/modules/harness-tools-shell-tramp-test.el`.
It passes `harness-tramp-command-end-spares-the-current-buffer` and never
returns from the second test: run alone it outlives a 400 s outer bound
under a 120 s per-suite timeout.  **The same hang reproduces on a clean
export of `main` at `7461153`**, where it also passes test 1 and stops.
This branch touches no TRAMP, file or project file
(`git diff --name-only <merge-base>..HEAD` names none), so it is neither
this branch's code nor its regression.  It is the documented
remote-directory hang: `harness-files-project-root` calling
`project-current` on a TRAMP path starts a `vc` probe on the host that
blocks once a connection is open.

`scripts/test.sh --status` says `UNVERIFIED`, and that is correct: it
wants one uninterrupted full run for the current clean commit, and this
was not one.  The 214 suites above are the evidence, not a stamp.

**The previous revision's completed run** was 218 files, 1 failed:
`lisp/harness-skills-scan-test.el::harness-skills-scan-bounds-what-it-lists`.

That one is **not this branch's**, and it is not "impossible" either.
`main` already carries the fix (`384cbf1`/`c78d4ee`: sort the directory
walk *before* applying the bounds, plus
`harness-skills-scan-bounds-ignore-directory-enumeration-order`).  This
branch was cut before that commit, so it still has the unordered walk.
The same suite on a clean export of `main` passes 10/10; here it failed
the same way on every run, three runs out of three.  The merge queue
brings `main` in, which resolves it.

A previous revision of this report called this failure "pre-existing"
while its diff was documentation-only.  That was true then and is not
the claim now: this branch *does* touch Emacs Lisp, so the check had to
be run and read, and it was.

`scripts/lint.sh` exits 0 (only the repository's existing byte-compile
warnings), including for the files this branch touches.
`scripts/module-docs.sh --check` passes for the page this change touches
(`docs/modules/sandbox-session.md`).  The check as a whole exits 1 on the
merged tree, naming eight pages — `provider-openrouter.md`, `README.md`,
`sandbox.md`, `session.md`, `tasks.md`, `ui.md`, `ui-workspace-speech.md`
and `workspace-speech.md` — and **none of them is this branch's**: the
same eight are named by the same check on a clean export of `main` at
`1574160`, so the drift arrived with the merge and was already there.

## A note on the figures

The usage ledger is **live**: a session still running appends a row as it
calls the model. Every figure here is a snapshot taken at 2026-11-13
10:40 EST, and a query re-run later can differ in the last decimal. The
snapshot is internally consistent: the per-session table's rows sum to
the total (`117,987,967 + 214,678,950 + 2,958,812 = 335,625,729`), and
the plan-model total is that less the internal helpers
(`335,625,729 - 2,958,812 = 332,666,917`). A later run of the same
queries returned 333,865,327 for that last figure, 0.4% higher, because
one session had made a few more calls in between.
