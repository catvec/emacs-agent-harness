# Provider verification plan: ChatGPT plan and DeepSeek via OpenRouter

**Status: plan with an executed scaled-down Stage 2 — 2026-11-09.**
The 2026-11-09 review revision adds the content-free prefix and
serving-host diagnostic described in
[`docs/design/provider-diagnostics.md`](../design/provider-diagnostics.md);
no live stage was run for it and no verdict below changes.
This document proposes a staged, bounded verification. On 2026-11-09,
after the review asked for small smoke tests, the Stage 2 cache checks
were run with a temporary test-only pin: three provider-check jobs,
under $0.005, no ChatGPT request. No provider was enabled. The full
Stage 2/3/4 remain unrun. The branch now also carries the diagnostic
code (Stage 0, offline tests only); it is not deployed. The assessment behind
this plan is
[`docs/analysis/provider-readiness-2026-11-08.md`](../analysis/provider-readiness-2026-11-08.md);
its §4.8 has the smoke's numbers.

**2026-11-14 revision.** Two things changed in this document, neither a
verdict. First, the 2026-11-13 zero-cache calls (assessment §5.3c) are
recorded as an observation with an unknown cause, and the 149.4M uncached
tokens of that window are explicitly **not** attributed to prefix
breakage. Second, this task's ownership is stated: the immutable
provider-ready prefix freeze belongs to **`t-sp1j60ii`**, and the gates
and assertions below are what this task will use to verify its commit.
Nothing here implements it, and no route is enabled.

## What this plan decides

0. **Data sovereignty is checked only on the OpenRouter target.** For
   ChatGPT and any other non-OpenRouter provider, the live stage is
   **cache-only**; no training, retention or geography claim is made for
   them.
1. **No meaningful paid use before Stage 3.** The provider self-test and
   a single agent turn are evidence about the harness and the endpoint;
   they are not production readiness.
2. **The first money goes to the cheapest thing that can falsify the
   claim**, not to the biggest test: public catalogue/policy checks
   (Stage 1, $0), then the cache self-test (Stage 2, cents), then one
   agent session (Stage 3, cents). ChatGPT gets a separate, much smaller
   **cache-only** smoke (Stage 4) only if Noah approves it and a
   client-side output stop exists.
3. **Fail closed on routing, not on luck.** If any request is served by
   an endpoint other than the pinned one, or reports a non-US data
   region, the run stops and the route is disabled. It is not "retry and
   hope"; a cross-host retry is the failure the pin exists to prevent.
4. **A PASS on a check is not a policy verdict.** For OpenRouter, the
   cache check proves cache behaviour; it does not prove training or
   geography. For ChatGPT, only the cache is evaluated. The readiness
   gate is the evidence matrix in §6 of the assessment, not a green
   provider-check page.
5. **ChatGPT is the expensive, opaque target, not the cheap one.** Its
   verification is bounded in plan quota, not dollars, and is blocked
   until the output cap and keep-warm problems are fixed. It is
   cache-only: the cache probes are the only live checks run there.

The 2026-11-09 smoke was a **scaled-down Stage 2**: two cache sessions,
the `cache` and `cache-parallel` checks, a temporary test-only pin, and
three jobs (Particle twice, Morph once). It is recorded in §4.7 below
and in assessment §4.8. It is not a Stage 2 pass: no stress run, no
agent turn, no failure-path test, no ChatGPT run.

Alternatives rejected:

- **Global OpenRouter plus account-level privacy settings.** Not
  per-request, not visible in code, not auditable after the fact.
- **ZDR as a geography control.** ZDR is retention. It does not keep a
  request out of China.
- **The cheapest endpoint (Relace at $0.006).** Not US in-region, no
  declared HQ/datacenters, policy unreachable. Cheap is not qualifying.
- **OpenInference ($0.0175).** Not US in-region; privacy and terms
  contradict each other on training and storage.
- **Wafer ($0.038).** US in-region and ZDR-listed, but its provider
  policy is silent on training and retention, and it declares no
  datacenters.
- **ChatGPT API key instead of plan usage.** A different billing path
  and a different contract; out of scope. Do not use it to make the plan
  look measurable.

### Scope by target

| Target | Data sovereignty | Cache | Quota / accounting |
| --- | --- | --- | --- |
| OpenRouter / DeepSeek 1017 | **Yes**: exact pin, US in-region, ZDR, no-training evidence, generation audit | Yes | `usage.cost` + $1 budget |
| ChatGPT plan | **No** (out of scope per review) | **Yes**: cache checks only | Static context only; plan quota for the cache run |
| Any other provider | No | Yes | Not assessed |

## 1. Preconditions (gates, not steps)

Nothing below Stage 1 starts until all of these are true.

### 1.1 Code and configuration gates

| Gate | Current state | Needed for | Why |
| --- | --- | --- | --- |
| Request-level provider pin | Absent: `harness-openai--body` sends no `provider` object ([`lisp/modules/harness-provider-openai.el:750-783`](../../lisp/modules/harness-provider-openai.el)) | Stage 2 | Without it the run tests whichever endpoint OpenRouter picked, not the one under assessment. |
| US base URL or US guardrail | Absent: default is `https://openrouter.ai/api/v1` ([`132-135`](../../lisp/modules/harness-provider-openai.el)) | Stage 2, Stage 3 | Global routing has no geographic constraint. |
| `allow_fallbacks: false`, `zdr: true`, `data_collection: "deny"` | Absent | Stage 2, Stage 3 | Defaults are fallback-allowed, ZDR-off and data-collection-allowed. |
| `session_id` for sticky routing | Absent | Stage 2, Stage 3 | Without it sticky routing starts only after the first cache hit. |
| Generation-id retention and audit | **Partly implemented on the task branch** (not deployed): response id, `x-request-id` and response-supplied provider/model are logged by `harness-provider-diagnostics`; no `/generation` lookup, so `data_region` is still unknown ([design](../design/provider-diagnostics.md)) | Stage 2, Stage 3 | Needed to observe `provider_name` and `data_region` per request. The log now gives the id and provider when the response supplies them; the region still needs the lookup or the generation row. |
| Pinned-endpoint estimate | Absent: estimate uses the model-level `/models` price ([`lisp/modules/harness-provider-check.el:2962-3005`](../../lisp/modules/harness-provider-check.el)) | Stage 2 budget | The model price is Relace's, not the pinned host's. |
| ChatGPT client-side output stop | Absent: `max_output_tokens` is dropped ([`lisp/modules/harness-provider-responses.el:986-1015`](../../lisp/modules/harness-provider-responses.el)) | Stage 4 | The wire cap cannot be sent; a runaway answer has no bound. |
| ChatGPT keep-warm off or capped | On by default; 12 full re-sends when unpriced ([`lisp/modules/harness-cache-warm.el:152`](../../lisp/modules/harness-cache-warm.el), [`254-280`](../../lisp/modules/harness-cache-warm.el)) | Stage 4 | Idle sessions can spend plan quota invisibly. |
| Quota check no longer passes zero windows | Passes today ([`lisp/modules/harness-provider-check.el:2501-2530`](../../lisp/modules/harness-provider-check.el)) | Stage 4 | A PASS must not be read as "quota known". |
| `us.openrouter.ai` in the key-needed-host list | Absent: only `openrouter.ai` is listed ([`258-267`](../../lisp/modules/harness-provider-openai.el)) | Stage 2 | Otherwise a keyless regional endpoint can look configured. |
| **Immutable provider-ready prefix** | **Absent; `harness-replay` is best-effort** (provider-neutral latest snapshot, silent fresh-render fallback, images and >16 MiB skipped; assessment §5.3c) | Stage 2, Stage 3, Stage 4 | Without it a client-side prefix change cannot be ruled out when a cache read is 0, so a miss cannot be attributed. **`t-sp1j60ii` owns the implementation**; this plan consumes its commit and tests. |
| **Explicit cache generation and recorded resets** | Absent | Stage 2, Stage 3, Stage 4 | Compaction, model/system/tools change and redaction must be recorded resets, not silent re-renders, or a "miss" after one cannot be told from drift. |
| **Fail-closed prefix mutation at transport** | Absent: `harness-agent--replay-messages` returns a freshly rendered request when there is no prefix ([`1516-1532`](../../lisp/modules/harness-agent.el)) | Stage 2, Stage 3 | The mutation must stop before the request is sent, naming the first divergent component, rather than being sent and discovered afterwards. |
| **Content-free per-request prefix fingerprint** | **On this task's branch** (`harness-provider-diagnostics`, §5.3b) | Diagnosing any stage | Per-attempt, not one overwritten snapshot; it is what makes the next zero-cache call decidable. |

The code changes are small and local; none of them enables a route by
itself. The assessment does not implement them, and this plan does not
claim they exist.

### 1.1b Gates that wait on other tasks

Two tasks own work this plan depends on. Nothing here duplicates
either; the gates below name what to consume, and when.

| Owner | What it owns | What this plan consumes |
| --- | --- | --- |
| **`t-sp1j60ii`** | The immutable provider-ready prefix freeze: final-component freeze after rendering, append-only reuse, model/account/route plus explicit cache-generation key, fail-closed transport mutation, recorded resets, content-addressed images, per-request fingerprints | Its commit and test artifacts, checked against assertions 10-15 of §2. Its quota report is cited as E3 for the 2026-11-13 numbers (assessment §5.3c), with its offline invariants validated before any bounded live test is proposed. |
| **this task** (`t-jibzilj2`) | The assessment, the verification gates, the content-free per-attempt diagnostics (§5.3b), and the bounded Stage 2-4 runs | Its own branch's diagnostics, and the gate table above. |

Neither task enables a route. Neither task's hand-in label is evidence
of readiness.

### 1.2 Account and policy gates

| Gate | Needed for | Evidence |
| --- | --- | --- |
| OpenRouter account on **Business or Enterprise** | Stage 2, Stage 3 | Dashboard plan; US in-region routing is not available otherwise ([in-region routing](https://openrouter.ai/docs/guides/features/in-region-routing)). |
| Guardrail `allowed_data_regions = ["us"]` on the key/workspace | Stage 2, Stage 3 | Guardrail editor or API; requests through `openrouter.ai` then get 403 before inference. |
| OpenRouter credit balance and a hard budget | Stage 2, Stage 3 | Dashboard balance; `harness-usage` project budget §4. |
| Written confirmation or DPA covering the chosen provider's training, retention and subprocessor geography | The "verified" claim | Morph/Particle/OpenRouter response; resolve Morph's 30-day-vs-ZDR contradiction. |
| Noah's decision on "no China" scope and ZDR | The verdict | §8 of the assessment. |
| No other session/task/automation using the same OpenRouter key during the run | Clean measurement | Task board and session list; stop or park them. |

If any gate is missing, do not start the stage it gates. "We will check
it after the run" is not a gate.

## 2. Stage 0 — offline and fake-provider checks ($0)

**Purpose:** prove the harness paths and the new controls without a
provider.

Run the suites that cover the changed code, then the repository's full
check before hand-in of the follow-up task:

```sh
scripts/test.sh \
  lisp/modules/harness-provider-diagnostics-test.el \
  lisp/modules/harness-provider-openai-test.el \
  lisp/modules/harness-provider-responses-test.el \
  lisp/modules/harness-provider-check-test.el \
  lisp/modules/harness-cache-test.el \
  lisp/modules/harness-cache-warm-test.el \
  lisp/modules/harness-compaction-test.el \
  lisp/modules/harness-cowboy-test.el \
  lisp/modules/harness-supervisor-test.el \
  lisp/modules/harness-fallback-test.el \
  lisp/modules/harness-retry-test.el \
  lisp/modules/harness-usage-test.el
scripts/lint.sh
scripts/module-docs.sh --check
```

If `scripts/test.sh` with several files is not accepted, run the files
one by one with the same list; the repository's
[`CLAUDE.md`](../../CLAUDE.md) allows focused suites while working.

Assertions that must exist before Stage 2 (add tests with the code, not
after):

1. **Body pin.** An OpenRouter endpoint configured for a pinned host
   sends `provider.only` with the exact slug, `allow_fallbacks: false`,
   `zdr: true`, `data_collection: "deny"` and a stable `session_id`.
   A non-OpenRouter endpoint sends none of them.
2. **No secret in logs.** The body, usage and audit records never
   contain the authorization header or the key.
3. **Base URL.** The pinned endpoint uses `https://us.openrouter.ai/api/v1`
   and is recognised as OpenRouter; a keyless regional endpoint is not
   offered as configured.
4. **Host audit.** The stream keeps the response id; the completion
   resolves the generation record and stores `provider_name`,
   `data_region`, `total_cost` and `cache_discount` in a record the UI
   and the test can read. A fake generation answer with `provider_name`
   not the pin, or `data_region` not `us`, fails the run.
5. **Pinned estimate.** `provider/check-estimate` prices the pinned
   endpoint, not the model minimum; the estimate is within one cent of
   the hand calculation in §4.
6. **ChatGPT output cap.** A provider that drops `max_output_tokens`
   makes the output-cap finding `fail` or `unverified`, not `pass`; the
   quota check with zero windows is `unverified`/`skip`, not `pass`.
7. **ChatGPT keep-warm.** A ChatGPT session is not kept warm by
   default, or is capped to a number the test names; the state says why.
8. **Cache-miss alarm classification.** A synthetic 1% shortfall at a
   1,024-token block boundary is either ignored or labelled
   "block rounding", not "cache miss"; a 30% shortfall still alerts.
   This is the policy decision from §5.3 of the assessment; the test
   pins the chosen policy.
9. **Fail-closed.** A pinned request that gets a 429/5xx surfaces as a
   failure, not a fallback to another endpoint; the harness fallback
   list is empty or itself pinned.

#### Assertions the prefix freeze must pass (t-sp1j60ii's, verified here)

10. **Final payload equality under append** (`t-sp1j60ii`'s
    adapter): the byte-for-byte provider body of step N+1 starts with the
    body of step N and adds only the suffix. Asserted at the adapter, not
    at the provider-neutral payload, so a change in
    `harness-responses--body`/`--input` is caught too.
11. **Equality survives restart and reuse.** The same assertion after a
    process restart, after reasoning/tool-output replay, and after a
    pruning of the remembered responses table; a pruned entry must be a
    recorded reset, not a silently different reconstruction.
12. **Images and large snapshots.** A request carrying image bytes, and
    one over 16 MiB, keep a stable provider representation rather than
    disabling reuse; retention of old images does not rewrite history.
13. **Mutation stops before transport.** An unexplained prefix mutation
    fails closed at the transport boundary, naming the first divergent
    component, and no request is sent; a storage failure, a retry and two
    concurrent independent sessions each keep their own attribution.
14. **Recorded resets.** Compaction, a model/system/tools change and a
    redaction each produce an explicit reset record; a redaction still
    removes what it must and retains no secret.
15. **No universal-hit promise.** An unchanged prefix is *not* asserted
    to hit: eviction, retention and routing can still miss. The test
    asserts the harness's bounded miss response (a logged, classified
    miss), not a hit.
Items 10-15 are `t-sp1j60ii`'s to implement and this task's to
verify. They are listed here so the gates exist before its commit
lands; none of them is implemented in this branch. Run them against
its commit and its test artifacts; do not reimplement them here.

## 3. Stage 1 — public catalogue and policy checks ($0, no inference)

**Purpose:** freeze the facts the report cites, so Stage 2 is compared
with a dated snapshot rather than memory.

Run in the session's temporary directory, not the worktree; keep only a
small `sources.txt` with URLs, retrieval times, HTTP status and SHA-256
of the JSON, not the megabyte dumps.

```sh
cd "$TMPDIR"
date -u +%FT%TZ
curl -fsS 'https://openrouter.ai/api/v1/models/deepseek/deepseek-v4.1-flash-1017/endpoints' -o ep-1017.json
curl -fsS 'https://openrouter.ai/api/v1/models?region=us' -o us-models.json
curl -fsS 'https://openrouter.ai/api/v1/endpoints/zdr' -o zdr.json
curl -fsS 'https://openrouter.ai/api/frontend/v1/all-providers' -o providers.json
sha256sum ep-1017.json us-models.json zdr.json providers.json
```

Assertions:

- `deepseek/deepseek-v4.1-flash-1017` is present, with the canonical
  slug `deepseek/deepseek-v4.1-flash-20261017` and the endpoint count
  recorded (50 at the 2026-11-08 retrieval).
- The China-hosted or China-headquartered endpoints in the same list
  (DeepSeek first-party, Baidu, StreamLake, Alibaba, StepFun) are
  recorded with their prices and data-policy flags, to show what a
  default request would not exclude.
- `morph/fp8` is present at $0.022/$0.40/$0.004 (or record the new
  price), in the US list and in the ZDR list; `morph` declares HQ US,
  datacenters `["US"]`, training false, retainsPrompts false,
  safetyRetention false.
- `particle-ai/us` and `particle-ai/us/flex` are present, in both
  lists, with the prices in the assessment.
- The cheaper `relace/fp4` and `open-inference/fp4` are **not** in the
  US list; `alibaba` is not in the US list and declares CN datacenters.
- The exact model version and prices match the report; if any differ,
  update the report before spending.

Then re-read the provider policies and record their Last Updated dates:
Morph privacy/terms, Particle privacy/terms, Wafer terms, OpenInference
privacy/terms. The specific questions are:

1. Does the provider train on prompts/completions, including
   support/debug? (Yes/No/Exception)
2. Is retention ZDR, fixed-period, or unspecified? Which tier?
3. Is prompt processing restricted to the US, or only "primary" /
   "initially intended"? What about subprocessors?
4. Does a safety/flagged-content path retain content, and for how long?

A contradiction is a finding, not a footnote. Morph's "we do not retain
it" versus its 30-day paid tiers is the current example; do not resolve
it by choosing the sentence you prefer.

**Stop condition:** the live catalogue no longer contains a US in-region
candidate with a no-training policy. In that case, say "none verified"
again and stop; do not fall back to a cheaper global endpoint.

## 4. Stage 2 — OpenRouter cache self-test (paid, cents)

**Purpose:** the first live evidence that the pinned endpoint actually
serves the model, caches an exact prefix, reuses independent prefixes
under concurrency, and stays on the pinned host/region.

### 4.1 Target

- Model: `deepseek/deepseek-v4.1-flash-1017`.
- Endpoint: choose **one** before the run. `morph/fp8` is the cheapest
  at list input price and the cheapest standard tier; `particle-ai/us/flex`
  is the cheapest for a cache-heavy 4k-in/512-out step but is a
  lower-priority flex tier. `particle-ai/us` is the standard-tier
  ZDR-default alternative. Do not run two endpoints and compare in the
  same job; that doubles the cost and muddies the host audit.
- Base URL: `https://us.openrouter.ai/api/v1`.
- Provider preferences: `only: ["<the chosen slug>"]`,
  `allow_fallbacks: false`, `zdr: true`,
  `data_collection: "deny"`.
- `session_id`: one stable id per provider-check session, derived from
  the session id (not a secret).
- Fallback list: nil. No task, supervisor, seed or shared prefix.

### 4.2 Request and token bounds

Provider-check's own bounds are the first line of defence:

| Bound | Value | Source |
| --- | --- | --- |
| Requests per job | 64 | `harness-provider-check-max-requests` |
| Output tokens per request | 512 | `harness-provider-check-max-output-tokens` |
| Checks at once | 3 | `harness-provider-check-concurrency` |
| Requests at once | 12 | `harness-provider-check-max-concurrency` |
| Whole job | 900 s | `harness-provider-check-total-timeout` |
| Cache sessions | 4 normal, 12 stress | `harness-provider-check-cache-sessions`, `cache-stress-sessions` |
| Per-request timeout | 90 s | `harness-provider-check-timeout` |

The HTTP layer can retry a failed request up to 3 times
(`harness-http-max-retries`), and the request count does not include
those attempts. Budget the worst case as **4× the nominal requests**.
The step retry module is not used by provider-check's synthetic probes,
but a 429/5xx can still be retried at the HTTP layer; the pin makes a
cross-host fallback a failure, not a retry.

### 4.3 Estimate before starting

Use the method, not the page's model-level price:

```elisp
(provider/check-estimate
 "openrouter-us:deepseek/deepseek-v4.1-flash-1017"
 "provider"
 '(:checks ("catalogue" "cache" "cache-parallel" "cache-evidence")
   :cache-sessions 4))
```

Record the answer. The hand check at the retrieval prices:

| Run | Requests | Input (4,096 each) | Output cap (512 each) | Morph | Particle flex |
| --- | ---: | ---: | ---: | ---: | ---: |
| Normal cache checks | 27 | 110,592 | 13,824 | $0.00796 | $0.00622 |
| Stress cache checks | 59 | 241,664 | 30,208 | $0.01740 | $0.01359 |
| Both, plus 4× retry worst case | 86 | 352,256 | 44,032 | **$0.101** | **$0.079** |

The stress plan includes the 9 exact-prefix probes
(`2 + 4×12 + 9 = 59`). Run the normal plan first; run the stress plan
only if the normal plan passes.

### 4.4 Run

1. Start the normal cache plan with `provider/check-start`, suite
   `"provider"`, the same `:checks` and `:cache-sessions 4`. Watch
   `provider-check/result`; do not start a second job.
2. While it runs, watch the first result's generation audit: the
   provider must be Morph (or the chosen Particle endpoint) and
   `data_region` must be `us`. If the first request is not on the pin,
   **cancel the job** and stop.
3. On completion, record: request count, token counts, cache-read
   counts, errors, retries, wall time, recorded cost, generation-audit
   rows, and the exact provider-check result records.
4. If the normal plan passes, run the stress plan (`:cache-stress t`,
   `:cache-sessions 12`). It runs the cache checks only; do not add the
   model suite.
5. Take screenshots of the provider-check result page, the cache-rate
   header of the run session, and the usage row. They are part of the
   evidence, not decoration.

### 4.5 Acceptance criteria

- **Exact prefix:** prime, immediate repeat, refreshed repeat and
  persistence repeat show positive cache reads on the same endpoint;
  the cold control reads 0; no identity mismatch.
- **Independent prefixes:** every primed prefix reads its own cache in
  both concurrent rounds (4/4 normal, 12/12 stress); fresh controls read
  0; no prefix/session mixing; no partial result counted as a hit.
- **Host:** every audited generation says the pinned provider and
  `us`; no 429/5xx-triggered fallback; no unexpected model.
- **Cost:** the recorded `usage.cost` sum is within 20% of the
  generation `total_cost` sum and within the §4.3 bound; no unexplained
  cache-write charge.
- **Deliverable:** evidence record schema 2, with per-phase cache
  reads/inputs/outputs and start times, saved in the task's evidence
  directory (not the worktree's source tree).

A single run is **unverified**, not a pass, by provider-check's own
rule. If the first run is ambiguous (one prefix misses while controls
stay cold), rerun once; do not average a miss into a pass.

**An identical prefix is not a promised hit.** These criteria test
whether *this route* serves a prefix the harness proved it re-sent
unchanged. They cannot promise universal reuse: eviction, a retention
window, a cache-shard move or a routing change can still miss on a
byte-identical prefix. The correct response to such a miss is the
bounded one this plan already has -- log it with the per-request
fingerprint (§5b.1), classify it, and stop rather than retry into
cost. A pass means "the route served it in this run", never "the cache
cannot miss".

### 4.6 Stop conditions

- Any request served by a provider other than the pin, or `data_region`
  not `us` → cancel, disable the route, report.
- Any fallback after a 429/5xx → stop; the pin failed closed and the
  run did not test what it claimed.
- Cache reads 0 on all primed prefixes while controls are 0 → stop;
  this is a routing/cache failure, not a harness bug to work around.
- Cost > $0.25 or a projected run > $1.00 → stop.
- A 4,096-token estimate is wrong by more than 2× for the cache probes
  → stop and fix the estimate; do not spend through it.
- Any credential, prompt or generation record written to a log or
  transcript with a secret → stop and redact.

### 4.7 What the 2026-11-09 smoke already showed

The scaled-down run used the deployed check code with a temporary
around-advice that added `provider.only`, `allow_fallbacks: false`,
`zdr: true` and `data_collection: "deny"`. Results (full table in
assessment §4.8):

| Job | Exact-prefix | Independent-prefix | Cost |
| --- | --- | --- | ---: |
| Particle run 1 | PASS (2/2 repeats) | FAIL (baseline 1/2; rounds 2/2, 2/2) | $0.00111 |
| Particle run 2 | FAIL (1/2 repeats) | FAIL (baseline 2/2; rounds 2/2, 1/2) | $0.00123 |
| Morph run 1 | FAIL (1/2 repeats) | FAIL (baseline 1/2; rounds 0/2, 0/2) | $0.00078 |

Two results change the plan's expectations:

1. **The US region gate is not just a code gap.** The current key gets
   `403 Regional routing requires a Business or Enterprise plan` from
   `us.openrouter.ai`. No Stage 2 or Stage 3 run can satisfy the
   geography requirement until the account is upgraded.
2. **Cache reuse is intermittent even under an exact pin.** No job
   passed the complete independent-prefix check. Particle run 1 met
   both concurrent rounds (2/2, 2/2) but missed one serial baseline
   repeat; Particle run 2 passed both baselines and round 1, then
   missed one prefix in round 2; Morph missed both rounds. The
   provider-check labels the misses unverified, not unsupported; that
   is the right reading, but it is not a pass. The strict Stage 2 needs
   more than one clean run before it can be called a PASS.

   This is a **provider-side** observation: the probe sent its own
   synthetic prefix and did not depend on `harness-replay`. It is
   therefore not evidence of client drift, and it does not explain the
   2026-11-13 zero-cache calls (assessment §5.3c), which had no archived
   request to compare. The two questions are separate and need separate
   evidence: this plan's Stage 2 measures the route; the per-request
   fingerprints measure the client.

The full Stage 2 remains unrun: no 4-session normal run, no stress run,
no host/region audit inside the harness, no screenshots.

## 5. Stage 3 — one agent session on the pinned endpoint (paid, cents)

**Purpose:** prove the real turn — not only the synthetic probes — keeps
the pin, uses the cache across steps, records honest usage, and fails
closed.

### 5.1 Shape

- One session, one project, model
  `openrouter-us:deepseek/deepseek-v4.1-flash-1017`, fallback nil,
  keep-warm left at its default but observed.
- No task, no supervisor, no seed, no shared prefix, no images unless
  the image path is the thing under test.
- Two turns, at most four steps each, context at most 64,000 tokens,
  output at most 1,000 tokens per step (enforced by the prompt and by
  stopping if it grows).
- Turn 1: a deterministic small task that calls one tool (read a short
  file) and answers. Turn 2: a follow-up that reuses the same context
  and should read the cache.

### 5.2 Bounds and worst case

| Item | Bound | Morph worst case |
| --- | ---: | ---: |
| Turns | 2 | — |
| Steps per turn | 4 | — |
| Input per request | 64,000 tokens | 8 × 64k × $0.022/M = $0.01126 |
| Output per step | 1,000 tokens | 8 × 1k × $0.40/M = $0.0032 |
| Retries | 3 HTTP attempts | ×4 = **$0.058** |
| Cache writes | billed at input, no extra published | included |
| Budget cap | $0.25 for the stage | — |

A 64k context is deliberately far below the 1,048,576 window; the point
is the turn and the cache, not the model's maximum. Do not "see if it
handles 1M" in this plan.

### 5.3 Acceptance criteria

- Every request's generation audit says the pinned provider and `us`.
- Turn 1 sends an uncached (or cache-write) request; turn 2's first
  request reads a positive cache prefix. If not, classify before
  concluding: same host? same prefix? block rounding? Did the turn add
  a tool result before the cache read?
- Usage rows: input + cache-read + output are nonnegative; cost is the
  provider's `usage.cost`, not the model-level estimate; the sum is
  within 20% of the generation `total_cost`.
- No fallback, no unexpected provider, no retry storm (≤3), no 429.
- The UI shows the cache rate and the cost; screenshots are captured.
- The session is stopped and its route disabled after the run.

### 5.4 Stop conditions

Same as Stage 2, plus: if turn 2 reads 0 on the same host and prefix,
stop and classify; do not keep sending turns to "warm it up". If the
turn grows past 64k, stop; if output passes 1,000 tokens in a step,
stop; if the cost row is missing, stop.

## 5b. Stage 3b — failure paths (mostly $0)

**Purpose:** the happy path is not the readiness question. Check the
failures the assessment found, without inducing a provider incident and
without spending quota.

### 5b.1 Miss alarm

- **Unit (E2):** a synthetic 1% shortfall at a block boundary follows
  the policy chosen in §5.3 of the assessment (ignored or labelled
  "block rounding"); a 30% shortfall alerts after the streak and
  cooldown; a session with no `cached_tokens` cannot alert. Assert the
  exact hint text, e.g. "Prompt cache miss · 91% cached · 2 calls ·
  57.8k tokens re-sent".
- **Diagnostic evidence (E1/E2, $0):** `harness-provider-diagnostics`
  logs, per attempt, `prefix=appended|identical|diverged|first`,
  `preserved=N`, `at=INDEX:TAG`, `expected-cold=` and the raw
  `cache-read=`. Its 31 offline tests cover append, early system/tool/
  model/settings changes, tool and wire order, Unicode boundaries,
  concurrency and no prompt/key leakage. This is the evidence that
  separates a changed prefix from a serving-host change; it is not a
  live result.
- **Live (E3, $0 unless a miss happens):** Stage 2's mismatch control
  must report a miss, not a hit; Stage 3's turn 2 must report a hit.
  If a live "Prompt cache miss" appears, read the two diagnostic lines
  for the previous and current attempt before calling it a bug:
  `prefix=diverged` names the changed boundary; `prefix=appended` or
  `identical` with `cache-read=0` points at routing/cache shard, and
  `provider=`/`served-model=` say what the response reported. Record
  the generation id, the provider/region (the region still needs the
  generation row), the previous prompt size and the ratio. Do not "fix"
  a block-rounding alert by lowering the threshold without Noah's
  decision.
- **The 2026-11-13 evidence (E3, already observed).** Five
  `chatgpt:gpt-6.1-sol` calls in session
  `3fd8ccb5-25d4-438d-bdb6-f3f20d7f5938` on 2026-11-13 read
  444,160 / 444,907 / 455,112 / 455,796 / 458,037 input tokens with
  cache reads 0 / 430,592 / 428,672 / 0 / 359,296 (assessment §5.3c).
  This is the exact pattern the diagnostics exist for, and it cannot
  be classified retrospectively: the final-wire requests were not
  archived. Use it as the shape a future alert must be read against --
  two lines per attempt, previous and current -- and not as proof of
  a cause.
- **Client and provider are separate questions.** A `diverged`
  fingerprint is a client finding; an `identical` or `appended`
  fingerprint with `cache-read=0` is a provider-side observation. The
  first is fixed by the prefix freeze (`t-sp1j60ii`); the second by
  route choice, retention policy or accepting the miss. Neither
  explains the other, and a live miss must be labelled before it is
  acted on.

### 5b.2 Cold-cache fail-closed

- **Unit (E2):** with a provider spy, a cold summary/brief through
  direct compaction, the question answer, a saved "always", the compact
  panel, handoff, the compact tool or the queue makes **zero** provider
  requests and writes a transcript instead. A fork over
  `harness-supervisor-fork-limit`, or of unknown size, fails with zero
  provider requests.
- **Live (E3, $0):** open a session whose cache has lapsed (or a small
  fork with a large inherited transcript), trigger the cold-cache
  question, choose the default transcript, and confirm no request was
  sent (session usage row unchanged, provider-check's request count
  unchanged, generation log empty). Do this without sending a message
  to a paid model.

### 5b.3 Unexpected provider, host or fallback

- Stage 2 and Stage 3 already audit every generation. The diagnostic
  response line records `configured=`, `route=`, `host=` separately from
  `provider=`/`served-model=`, so a fake answer naming another provider
  is visible rather than folded into the configured route; a missing
  provider is `unknown`, not a guess.
- Add the negative test: a fake generation answer with `provider_name` =
  another provider or `data_region` = `global` must make the run fail,
  not silently record a different host. A 429/5xx on the pinned endpoint
  must surface as an error; if the harness fallback list is non-nil, the
  run is not a valid pin test. The diagnostic `error-kind=`,
  `status=`, `retry-after=` and `http-retries=` fields are what the run
  reads to tell a retry from a fallback.

### 5b.4 Quota exhaustion and retries

- **Unit (E2):** a fake provider returns `subscription_sharing_usage_limit_exceeded`
  (429), `subscription_sharing_usage_unavailable` (503), a 402/credit
  error and a transport reset. Assert: quota moves to fallback or stops;
  a 503 is retried with bounded backoff; a 402 is billing, not a retry
  loop; a reset is retried at most 3 times; no retry overrides the pin.
- **Live:** do not deliberately exhaust the plan or the OpenRouter
  credit. If a 429 or 402 occurs, stop and record it; do not loop.

### 5b.5 Accurate UI evidence

- Screenshots (E3) of: the provider-check estimate before the run, the
  result page after it, the cache-rate header of the run session, the
  usage row with cost, and the cold-cache question showing the
  transcript default. The copy must match the rendered strings; a
  sentence-style label is a UI-copy defect under
  [`docs/ui-guide.md`](../../docs/ui-guide.md).
- Compare the UI cost with the generation `total_cost`; a difference
  over 20% or $0.01 is a finding.

### 5b.6 What is deliberately not tested

- A 1M-token context, a 12-session *agent* run (only the cache stress),
  a supervisor plan, a shared seed, a cross-provider fallback, and a
  deliberate ChatGPT plan exhaustion. Those are exactly the paths that
  caused the historical incidents; testing them by spending is not a
  bounded verification.

## 6. Stage 4 — ChatGPT cache smoke (plan quota, separate approval)

**Purpose:** per the 2026-11-08 review, non-OpenRouter providers are
evaluated on **cache behaviour only**. This stage asks whether ChatGPT's
plan route serves an exact prefix and whether independent sessions reuse
their own primed prefixes under concurrency. It does not test training,
retention, geography, quota telemetry or tools. Data sovereignty is out
of scope for ChatGPT; the static quota/accounting context is in the
assessment, not a live check here.

This stage is **skipped by default**. It starts only after Noah
approves the plan-quota allowance and a client-side output stop exists.

**Not run on 2026-11-09.** The `chatgpt-plan` module was not loaded in
the harness instance used for the smoke and no ChatGPT account was
used, so no plan quota was spent. This stage remains unexecuted; it is
not a pass.

### 6.1 Caps

| Bound | Value | Notes |
| --- | ---: | --- |
| Checks | `catalogue`, `cache`, `cache-parallel`, `cache-evidence` | The cache checks only; no completion, quota, tool or model suite. |
| Sessions | 4 | `cache-parallel` normal; no 12-session stress on plan quota. |
| Requests | 27 | 9 exact-prefix probes + 18 independent-prefix probes (2 + 4×4). |
| Input per request | 4,096 tokens (estimate) | The synthetic prefix is a few kilobytes. |
| Expected output | 24 tokens | The cache probes ask for 24. |
| Hard stop | 30 s or 512 output tokens, whichever first | Client-side; the wire cap cannot be sent. |
| Concurrency | 4 | The four independent sessions; no other ChatGPT session. |
| Keep-warm | Off | Otherwise up to 12 full re-sends per idle period. |
| 429 | Stop immediately | Do not loop; link to `https://chatgpt.com/settings/usage`; wait for the plan window. |
| Plan allowance | 27 requests, 4k input, 24 expected output | No dollar budget can enforce this. |

If the stop holds, the stage is about **111k input tokens and at most
14k output tokens** (27 × 4k in, 27 × 24 expected, 27 × 512 worst). If
the stop fails, the output is unbounded; that is why the stop is a
precondition. The plan's weekly quota is token-weighted in a way the
harness cannot see, so the only honest assumption is "unknown"; the
request allowance is the cap.

### 6.2 Run

Use the cache plan only:

```elisp
(provider/check-estimate
 "chatgpt:<the model the account lists>"
 "provider"
 '(:checks ("catalogue" "cache" "cache-parallel" "cache-evidence")
   :cache-sessions 4))
```

Then `provider/check-start` with the same suite and options. Do not add
`completion`, `usage`, `quota`, `cancellation`, `tool-transport`,
`image-input`, `fork` or the model suite. One job at a time; no task,
fallback or automation selects ChatGPT during the run.

### 6.3 Acceptance criteria

- **Exact prefix:** prime, immediate repeat and refreshed repeat show
  positive cache reads; the cold control reads 0; no identity mismatch.
- **Independent prefixes:** every one of the four primed prefixes reads
  its own cache in both rounds; fresh controls read 0; no mixing.
- If the route reports no `cached_tokens`, the result is **unverified**,
  not a pass; say so and stop.
- A 429 stops the run; no retry loop, no silent billing switch.
- The final plan usage reading (from the ChatGPT settings page, manually
  recorded) is within the 27-request allowance.
- No task, fallback or automation selects ChatGPT during or after the
  run.

### 6.4 Stop conditions

Any 429, any plan usage jump beyond the allowance, any output that
passes the client-side stop, any missing usage event, any unexpected
model, or cache reads 0 on all primed prefixes while controls are 0 →
stop, sign out of plan usage if needed, and report. ChatGPT's cache
behaviour remains unverified; no data-sovereignty claim is made either
way.

## 7. Budget

### 7.1 Money

| Item | Expected | Worst case (4× retries) | Cap |
| --- | ---: | ---: | ---: |
| Stage 2 normal (27 requests) | $0.008 | $0.032 | — |
| Stage 2 stress (59 requests) | $0.017 | $0.070 | — |
| Stage 3 session (2 turns, 8 requests) | $0.014 | $0.058 | — |
| **DeepSeek verification total** | **< $0.04** | **< $0.16** | **$1.00 hard budget** |
| OpenRouter Business/Enterprise plan | unknown | unknown | Noah's approval |
| ChatGPT plan quota | unknown | unknown | Noah's request allowance |

Stage 4 is not in the dollar table: it is **27 ChatGPT plan requests**,
4k input each, 24 output expected, 512 worst, with a 30-second stop and
keep-warm off. Its cost is plan quota, not dollars, and the plan's
weekly meter is unknown. The allowance is 27 requests; a 429 stops the
run.

The **2026-11-09 smoke spent $0.00476** in observed OpenRouter
`usage.cost` (three provider-check jobs, 25 direct cache probes and a
few canaries; about 86 synthetic requests). It spent **$0** of ChatGPT
plan quota. That is within the $1.00 cap and leaves the Stage 2/3
budget unchanged. The two integration tests in the same session are not
included in the $0.00476; their model is `openai/gpt-4.1-nano` and
their token counts are small.

Set a **project hard budget of $1.00** for the verification project and
a warning at 50% (`harness-usage-warn-fraction` applies to the budget).
The budget is a stop, not an invitation: if the estimate before a stage
exceeds the remaining budget, do not start it. The OpenRouter plan fee
is separate and not counted in the $1.00.

### 7.2 Quota

- OpenRouter: the account's credit balance must cover the $1.00 cap;
  a 402/insufficient-credit error stops the run.
- ChatGPT: no numerical quota; the allowance is **27 cache-check
  requests**, checked against the manual usage reading. A 429 stops the
  run.

## 8. Readiness blockers

These are the things that must be true before **meaningful** use, not
before the bounded verification:

1. **OpenRouter controls in code:** exact pin, US base/guardrail,
   `allow_fallbacks: false`, `zdr: true`, `data_collection: "deny"`,
   `session_id`, pinned-endpoint estimate, and a generation/region audit
   (the diagnostic now keeps the id and response-supplied provider; it
   does not fetch `data_region`).
2. **Account:** Business/Enterprise plan and a US region guardrail.
3. **Written confirmation/DPA:** training, retention, subprocessor
   geography for the chosen provider; resolve Morph's
   ZDR-vs-30-day contradiction; decide ZDR vs retention.
4. **ChatGPT:** client-side output stop, keep-warm off/capped, no
   tasks/fallbacks on it, and a 27-request cache-only plan allowance.
   Data sovereignty is not a ChatGPT blocker; it is out of scope.
5. **Cache-miss policy:** classify block rounding vs. routing vs.
   changed tool result; the alarm must not be read as a provider defect
   without host/prefix evidence. The diagnostic lines provide the
   prefix evidence; they do not classify the historical 80k/zero
   alternation, and they do not prove a serving host's geography.
6. **Accounting:** failed/retried/cancelled streams must be recorded as
   unknown or estimated, and reconciled with provider-side spend; the
   harness currently records only what the stream reported.
7. **Evidence:** a live OpenRouter run on the pinned host, with
   generation-audit rows, screenshots and a cost reconciliation. No
   hand-in label or green check substitutes.
8. **US in-region eligibility:** the 2026-11-09 smoke measured a 403
   from `us.openrouter.ai`; the account needs Business/Enterprise. Until
   then the geography requirement is not satisfiable, whatever the
   provider policy says.
9. **Cache reliability:** the smoke did not produce a clean
   independent-prefix pass on either host. A clean, repeated result — or
   Noah's acceptance of intermittent reuse — is needed before a
   production route. This is a **provider-side** observation from the
   pinned Particle/Morph probes; it is not evidence of client drift, and
   the two must be measured separately (the diagnostics of §5.3b do
   that).
10. **Client prefix preservation (`t-sp1j60ii`):** the immutable
    provider-ready freeze, explicit cache generation, recorded resets
    and fail-closed transport boundary (gates of §1.1, assertions 10-15
    of §2). Until it lands, a zero cache read cannot be attributed: the
    harness may have re-rendered the prefix itself. No amount of
    provider-side probing substitutes for it.
11. **Evidence freshness:** the 2026-11-09 pricing, region and policy
    conclusions are dated observations, not current facts. Re-fetch the
    catalogue and policy pages at Stage 1 of any run rather than citing
    this document's numbers.

## 9. What Noah must approve

- The scope of "no China": prompt/completion processing only, or all
  account/operational/subprocessor data.
- ZDR versus 30-day retention, and whether flex tier is acceptable.
- The pinned endpoint: Morph `morph/fp8` (cheapest list input and
  standard tier) or Particle AI (ZDR default; flex cheapest for a
  cache-heavy step, standard if flex is not acceptable).
- The $1.00 hard budget and the expected <$0.16 spend, plus the
  OpenRouter Business/Enterprise plan fee.
- Whether to request a written confirmation/DPA from OpenRouter and the
  provider, and which one.
- The ChatGPT **cache-only** plan allowance: 27 requests, 4k input,
  24 output expected, stop on 429, keep-warm off, and a client-side
  output stop.
- The model version: 1017 (2026-10-17) or the older
  `deepseek-v4.1-flash` (2026-09-10).
- The OpenRouter **Business/Enterprise** plan fee, or a decision to
  drop the US in-region requirement. The current key cannot use
  `us.openrouter.ai`.
- Whether intermittent cache reuse is acceptable, or every primed
  prefix must hit in both concurrent rounds before production.

## 10. Rollback and disable

Because this plan is verification only, the rollback is the removal of
a configuration and, if the follow-up task added code, the revert of
that commit. No production route is enabled by the assessment.

| Target | Disable |
| --- | --- |
| OpenRouter pinned endpoint | Remove the endpoint entry from `harness-openai-endpoints` (or set it inactive), remove `OPENROUTER_API_KEY` from the environment/auth-source, cancel any running provider-check (`harness-provider-check-cancel`), set `harness-fallback-models` nil, and stop sessions on the model. If a route was already live, switch the default model off it before removing the key. |
| OpenRouter account guardrail | Remove `allowed_data_regions = ["us"]` only after the endpoint is off; leaving it on is harmless and keeps a stray request out. |
| Hard budget | Keep the $1.00 budget until the verification project is closed; remove it only after the final cost reconciliation. |
| ChatGPT | Sign out of plan usage or remove the account (`M-x harness-chatgpt-plan-sign-out`), set the default model and all tasks off `chatgpt:*`, set fallback nil, cancel running turns. |
| Evidence | Keep the provider-check records, screenshots and `sources.txt`; delete any raw request/response dump that could contain prompts or credentials. |

## 11. Verification of this plan

This document is not the verification. Its own check is:

1. The focused suites in Stage 0 pass on the follow-up task's branch.
2. `scripts/test.sh` (full) passes before that task hands in.
3. `scripts/lint.sh` exits 0, and `scripts/module-docs.sh --check` is
   current if a module doc changed.
4. The live stage records its evidence; a run that was not made is
   labelled "not run", not "pass". The 2026-11-09 smoke is recorded as
   partial: Stage 2 cache checks only, no stress, no agent session, no
   ChatGPT.
5. The final report's GO/NO-GO is read from the evidence matrix, not
   from the number of green checks.
6. The smoke's numbers are in assessment §4.8. They are E3 for the
   specific observations, not a Stage 2 PASS; no job passed the complete
   independent-prefix check.
7. The diagnostics revision's own full run fails one suite,
   `test/harness-test-layout-test.el`, on this branch's base commit:
   `test/harness-images-test.el` and
   `test/harness-ui-model-picker-test.el` sit in `test/` without being
   named in the layout's list of repository suites. That is the base's
   failure, not the change's -- the branch touches nothing in `test/`,
   and `main` already moved those two suites beside their modules.

   A trial merge with `main` clears it. Its final run, at two jobs, ran
   210 files with one failure:
   `harness-ui-patch-review-tool-open-reveals-a-closed-thread-by-prefix`,
   which fails identically on a clean `main` checkout (209 files, one
   failure, the same test). At four jobs on a machine under heavy load
   the merged trial also dropped one other suite per run -- `acp`,
   `ui-chat`, `provider-check`, `tasks`, a different one each time --
   and each passed on its own rerun, so those are the load's flakes, not
   the change's. The diagnostics, provider, usage and layout suites pass
   in every run.
8. The 2026-11-14 documentation revision's full run was 204 files, 3
   failed: two load flakes that passed on rerun and the same
   base-commit layout failure as item 7.
9. The 2026-11-14 **implementation** revision (the one that fixes the
   unknown-vs-zero, alarm, record, budget and identity defects)
   changed `harness-cache`, `harness-provider-check`,
   `harness-provider-diagnostics` and their suites, and the UI
   check page's copy test. Its focused suites pass: cache 22/22,
   provider-check 57/57, diagnostics 34/34, UI provider-check 16/16,
   docs 2/2. `scripts/lint.sh` exits 0 with no warning for a changed
   file, and `scripts/module-docs.sh --check` is current at 151
   pages.

   Its full run, on the committed tree at `36451d5` and four jobs:
   204 files, **1 failed** -- `test/harness-test-layout-test.el`, the
   same base-commit failure as item 7. At `5022581`,
   `test/harness-images-test.el` and
   `test/harness-ui-model-picker-test.el` exist in `test/` and are not
   named in its list of repository suites, and this branch changes
   no file under `test/`. **Full suite FAILED**, exit 1; it is not
   reported as a pass.

   The final full run, on the tree at `023137f`, failed two: that same
   layout suite and `harness-codex-quota-protocol-failures-are-
   sanitized`, which expected an `error` status and got `missing` under
   load and passed when its suite was rerun alone (7/7).  This branch
   changes no file in `harness-codex-quota.el` or its suite.  Three
   full runs of this revision are reported: the first lost `merge`
   and the layout suite, the second lost only the layout suite, and
   this one lost `codex-quota` and the layout suite.  Each load-
   sensitive suite passed on its own rerun.  The layout failure is
   the only one present in all three and at the base.  The final
   run still failed, and it is reported as failed.

10. A fourth full run, on the clean committed tree at
    `352ba5e` and four jobs: 204 files, **2 failed**, exit 1.
    One is the base-commit layout failure again.  The other
    is `harness-tools-agent-stop-outstanding-stops-only-
    the-sessions-own-sub-agents`, which expected
    `Sub-agents first, second stopped` and got
    `Sub-agents second, first stopped` -- the order two
    stopped sub-agents are named in, which this branch does
    not touch; it passed 44/44 when its suite was rerun
    alone (exit 0).  Every full run of this revision has
    failed, and every one of them is reported as failed.

11. The quota/prefix branch's commit `dc18b8d` was checked here on
    2026-11-14, from a `git archive` copy of that branch in a
    scratch tree, without editing it. Its own replay suite passes,
    **35/35**. The chat-completions adapter suite that Stage 0 of
    this plan names, `harness-provider-openai-test.el`, **fails:
    10 of 56 unexpected**, and the same suite passes at that
    branch's merge base `cb5621e` (54/54, 2 skipped) and on `main`
    (56/56, 2 skipped). `harness-replay-seam` returns JSON text and
    both adapters pass it to `harness-http-request` as `:json`,
    which encodes it a second time, so the wire body is a JSON
    string literal rather than the body object. In the Responses
    adapter the same mismatch makes its keep-guard false, so no
    frozen body is recorded for a ChatGPT-plan session at all. The
    branch's own tests assert that pre-encoded string, which is why
    they pass.
    Stage 0 assertions 10-20 are therefore **not verified**; the
    fix belongs to that task. Commands and output:
    [`docs/evidence/provider-replay-branch-check-2026-11-14.txt`](../evidence/provider-replay-branch-check-2026-11-14.txt).

12. A fifth full run, on the clean committed tree at `2e533f4`
    and four jobs: 204 files, **1 failed**, exit 1 -- only the
    base-commit layout failure. The stop-ordering flake of item 10
    did not recur. This is the closest any run of the revision came
    to passing, and it still failed; it is reported as failed, not
    as a pass with a caveat.