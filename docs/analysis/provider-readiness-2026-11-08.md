# Provider readiness: ChatGPT plan and DeepSeek via OpenRouter

**Status: assessment plus bounded live smoke — 2026-11-09.** The
assessment was written 2026-11-08. On 2026-11-09, after the review
asked for small smoke tests, a scaled-down Stage 2 was run against
OpenRouter (§4.8): about 86 synthetic requests, under $0.005, and no
ChatGPT request. It changes no provider configuration and proposes no
merge. Its companion,
[`docs/design/provider-verification-plan-2026-11-08.md`](../design/provider-verification-plan-2026-11-08.md),
is the bounded verification plan.

Deployed baseline: `main` at `5022581` ("Fix inconsistent reply window
placement"), the same commit this worktree started from. External
sources were retrieved 2026-11-08 and rechecked 2026-11-09 UTC; prices,
endpoint lists and policies change, and every external claim below
carries its retrieval date.

The 2026-11-09 review revision adds one implementation on this task's
branch: content-free prompt-prefix and response/provider diagnostics
(§5.3b, [`docs/design/provider-diagnostics.md`](../design/provider-diagnostics.md)).
It changes no route, credential or privacy setting and spends nothing.
Everything else in this report is the assessment and the bounded smoke
as they stood; the GO/NO-GO verdicts are unchanged.

The **2026-11-14 revision** fixes the readiness and diagnostics defects
this task owns. It no longer reports a missing cache reading as zero,
no longer lets a cache-miss alarm imply a cause, no longer calls an
unwritten capability record a pass, announces the request bound the
job actually enforces, and keeps what each probe response said served
it. The immutable provider-ready prefix freeze is `t-sp1j60ii`'s to
implement; this task owns the verification gates that will consume it.

Those gates have now run twice against that branch. The first pass, on
its commit `dc18b8d`, found the freeze broken at the transport: replay
35/35, but the chat-completions adapter suite 10 of 56 unexpected,
because the frozen JSON text was handed to the transport as `:json`
and encoded a second time, and the Responses adapter's keep-guard then
recorded no frozen body at all. The second pass, on its new tip
`8df2fe1` (`ef092ed`, `18a79d6`, `8df2fe1`), finds **both defects
fixed**: replay 48/48, chat-completions 54 of 56 with 2 skipped by
design, Responses 54/54, and this task's own probes -- not that
branch's tests -- confirm the body goes out as bytes, that the
ChatGPT-plan adapter records the body it sent, and that a changed
prompt still sends nothing at all. Commands, output and the probes are
in
[`docs/evidence/provider-replay-branch-check-2026-11-14.txt`](../evidence/provider-replay-branch-check-2026-11-14.txt).

One thing that pass found is not a defect but a fact of merging: both
branches edit the same adapter regions, so bringing them together
conflicts in five files. It is recorded in the same evidence file and
is for the merge queue and the quota owner, not for this task to
resolve.

The short answer is the behaviour table below. Everything after it is
the assessment as it stood, kept as the appendix.

**Revision 3 (this one)** repairs one load-sensitive test the full run
failed, and records the full suite passing on this branch for the first
time: `scripts/test.sh` (full) at `c763735`, **239 files, 0 failed**.
No provider request was made, no route, credential or privacy setting
was read or changed, and the GO/NO-GO verdicts are unchanged.

## Behaviour report (2026-11-14 revision)

This is the practical answer.  Each row is one behaviour, the state of the
code that implements it, and the evidence for that state.  **Branch**
means implemented and tested on
`task/provider-readiness-assessment-and-jibzilj2` and not merged;
**merged** means it is in `main`; **deployed** means the harness the user
runs has it.  This revision deploys nothing.

| Behaviour | State | Evidence | Fix | Remaining blocker |
| --- | --- | --- | --- | --- |
| Content-free prompt-prefix checkpoints (HMAC chain, key lifecycle, per-session scope) | working (branch) | `harness-provider-diagnostics-test.el` 34/34: append vs identical, divergence at model/settings/system/tools/wire order/tool order, rotation, no-randomness disable, Unicode and boundaries, no prompt/tool/key leakage | `0223d0b`, extended in `9adc553` | Not merged, not deployed |
| Per-attempt response identity (response id, `gen-` generation, `x-request-id`, observed provider and served model) | working (branch) | `harness-provider-diagnostics-summary-is-content-free`: provider `Morph`, generation and request id kept, missing fields left unset | `9adc553` (public summary API) | A provider name is not a geography; no live request this revision |
| Public, content-free correlation API for other modules | working (branch) | `harness-provider-diagnostics-session-summary`, `-summary`, `-cold-cause`, `-miss-cause`; asserted in the same suite and consumed by `harness-cache` | `9adc553` | The quota owner consumes it; see the coordination note |
| Unknown telemetry rendered as zero | **fixed** (was broken) | `harness-provider-check-cache-detail-keeps-unknown-unknown`: no cache field now reads `repeats unknown/unknown cached`, not `0/0`; `...-shows-a-real-zero` keeps a reported zero at `0/2` | `9adc553` | Branch only |
| Cache-miss alarm that implies a cause | **fixed** (was ambiguous) | `harness-cache-health-names-the-cause-diagnostics-record`: no record gives `cause unknown`, a preserved prefix gives `warm`, a changed tool schema gives `tools-change` | `9adc553` | The cause is only as good as the diagnostics record |
| Capability record reported as a pass when it was not written | **fixed** (was misleading) | `harness-provider-check-evidence-that-cannot-be-kept-is-a-skip`: no state directory gives SKIP and `record not saved (no state directory)` | `9adc553` | Branch only |
| Announced request bound equals the enforced budget | **fixed** (was wrong) | `harness-provider-check-estimate-announces-the-enforced-budget`: a 10-request plan under a 4-request budget reports 4 enforced, 10 planned, `over-budget`, and a basis that says the request budget applied | `9adc553` | Branch only |
| Control isolation: warm control vs no control reading | **fixed** (was one skip for two cases) | `...-prompt-cache-verdict-classifies-runs` and `...-independent-cache-verdict-classifies-runs` assert `control prefix warm` and `no cold control · isolation unmeasured` separately | `9adc553` | Branch only |
| Observed serving provider recorded with the cache evidence | **fixed** (was absent) | `harness-provider-check-serving-counts-what-the-response-named`, `...-evidence-record-keeps-the-observed-provider`: only a response-supplied name counts, and the configured route is never substituted | `9adc553` | A name is not a region, a training policy or a stable cache shard |
| Immutable provider-ready prefix freeze, fail-closed transport mutation, image assets, recorded resets | **working on `t-sp1j60ii`'s branch (`8df2fe1`); not merged, not deployed** | Reverified here, twice. `dc18b8d`: replay 35/35 but chat-completions 10 of 56 unexpected. `8df2fe1`: replay **48/48**, chat-completions **54 of 56, 2 skipped by design, 0 unexpected**, Responses **54/54**; openrouter 84, chain 10, cache 22, agent 102, module-docs 11, all as expected. This task's own probes: the body goes out as `:body` bytes (not `:json`), the ChatGPT-plan adapter records the body it sent (`:generation 1`, 120 bytes), a changed prompt sends **nothing** and names `messages[0].content`, a changed `temperature` still sends, and no decision record carries prompt text or a digest ([evidence](../evidence/provider-replay-branch-check-2026-11-14.txt)) | `ac77340` fixes the two defects this task reported; `ef092ed` moves the invariant to the prompt | Merging it into this branch conflicts in 5 files (the adapters, `harness-cache` and its test, one module doc) -- for the merge queue, not resolved here. Live cache behaviour still unverified |
| US in-region OpenRouter routing | blocked (external) | 2026-11-09 observation: `us.openrouter.ai` answered 403 `Regional routing requires a Business or Enterprise plan` | no code fix attempted; none is possible | A Business/Enterprise plan and written subprocessor confirmation, which only the user can obtain |
| Live cache reuse on the configured OpenRouter route | unverified this revision | The 2026-11-09 Particle/Morph smoke is a **dated observation**, not current DeepInfra evidence; no live request was made in this revision | — | A separately authorised bounded smoke |
| ChatGPT plan cache behaviour | unverified | No ChatGPT request in this revision or the one before it | — | The same bounded cache-only smoke, if authorised |
| Prefix preservation in the client (`harness-replay`) | best-effort, not a freeze | `harness-replay.el` keeps a provider-neutral latest snapshot and falls back to a fresh render; §5.3c | `t-sp1j60ii` implements the freeze | Unchanged by this task |
| The 2026-11-13 zero-cache calls | observed, cause unknown | Five calls with two `cache_read=0` rows between 350k-430k neighbours; the final-wire requests were never archived (§5.3c) | diagnostics now fingerprint every attempt, so the next one is decidable | The past five cannot be explained from what was kept |

### Coordination with `t-sp1j60ii` (quota and prefix-storage owner)

- **Shared observability, not a second fingerprint system.** The quota
  task reuses `harness-provider-diagnostics`.  The API it consumes is
  `harness-provider-diagnostics-session-summary` (a content-free plist of
  `:prefix`, `:preserved`, `:expected-cold`, `:configured`, `:route`,
  `:host` and the `:response` reading) and
  `harness-provider-diagnostics-cold-cause`, which turns that into
  `warm`, a named client cause, or `unknown`.
- **Commit to consume:** `9adc553` on this branch, on top of `0223d0b`.
- **How this was communicated.** The coordination note is written here
  because the session-to-session message could not be sent from this run:
  the non-interactive session's approval never came back.  This section,
  on the branch the merge queue brings into `main`, is the durable copy
  the quota owner reads, and it names the API, the commit, the ownership
  boundary and the verification still owed.
- **Ownership boundary.** `t-sp1j60ii` exclusively owns the provider-ready
  frozen prefix, reset generations, image storage and transport mutation
  enforcement.  This task owns the diagnostics, the classification and the
  independent verification of that commit; it has not touched
  `harness-replay.el`, the adapters' body construction, or any storage.
- **State of that branch on 2026-11-14.** It carries the freeze through
  `dc18b8d` (the body frozen field by field, an unexplained change
  refused), `ac77340` (the frozen body sent as bytes, the Responses
  keep-guard fixed, the cache alert reworded), `ed4bc0d` (two sessions
  interleaved) and `ef092ed` (the prompt, not the request, is the
  invariant; content-free `replay/prefix` telemetry).  It touches
  `harness-replay.el`, both adapters and their tests; it does not touch
  the diagnostics module.  This task has not edited any of its files.

- **Independent verification of the new revision, done here.**  The tip
  `8df2fe1` (`ef092ed`, `18a79d6`, `8df2fe1`) was extracted with
  `git archive` to a fresh scratch tree and its suites run there;
  nothing was edited.  The three suites its hand-in named pass: replay
  **48/48**, chat-completions **54 of 56 with 2 skipped by design, 0
  unexpected**, Responses **54/54**.  The five others it named pass
  too: openrouter 84, chain 10, cache 22, agent 102, module-docs 11.
  Two small inaccuracies in its hand-in note, neither a failure: the
  OpenAI suite is called `56/56' when 2 of the 56 are skipped, and
  the cache suite is called 23/23 when it has 22 tests.
- **Both defects this task reported are fixed.**  Probed here with this
  task's own fake transport, not with that branch's tests: the body
  reaches the transport as `:body` bytes with an explicit
  `Content-Type`, and parses back to the body object; the ChatGPT-plan
  adapter records the body it sent (`:generation 1`, 120 bytes), where
  on `dc18b8d` it recorded nothing; a changed prompt still sends
  nothing and the step ends naming `messages[0].content`; a changed
  `temperature` is still sent, spliced rather than refused; and no
  `replay/prefix` record carries prompt text or a digest of it.  All
  11 probes pass.
- **What merging will cost.**  Both branches change the same adapter
  regions: `git merge-tree --write-tree HEAD 8df2fe1` conflicts in
  `harness-provider-openai.el` (5 hunks), `harness-provider-responses.el`
  (2), `harness-cache.el` (2), `harness-cache-test.el` (1) and
  `docs/modules/provider-openai.md` (1).  This task has not resolved
  them and does not intend to: whose version of the transport boundary
  wins is the quota owner's decision, made in the merge queue, not a
  verification task's.

### Verification of this revision

Offline only; no provider request, and no route, credential or
privacy setting read or changed.

| Check | Result |
| --- | --- |
| Focused suites, 2026-11-14 revision 2 | **pass**, 7 suites: `harness-provider-diagnostics` 34, `harness-provider-check` 57, `harness-cache` 22, `harness-ui-provider-check` 16, `harness-provider-openai` 50 of 52 (2 skipped), `harness-provider-responses` 56, `harness-replay` 19 |
| Independent verification of `t-sp1j60ii` at `8df2fe1` | **pass**, 8 suites in a scratch tree: replay 48, chat-completions 54 of 56 (2 skipped), Responses 54, openrouter 84, chain 10, cache 22, agent 102, module-docs 11; 11 probes of this task's own pass |
| `scripts/lint.sh`, revision 2 | **exit 0**; 11 pre-existing warnings, none in a file this branch changes |
| Focused suites | **pass**, 131/131: `harness-cache` 22, `harness-provider-check` 57, `harness-provider-diagnostics` 34, `harness-ui-provider-check` 16, `test/harness-docs` 2 |
| `scripts/lint.sh` | **exit 0**, no warning for a changed file |
| `scripts/module-docs.sh --check` | current, 151 pages |
| `demo/provider-diagnostics/demo.sh` | **exit 0**, four attempts, leak check clean; output kept in [`docs/evidence/provider-diagnostics/demo-run-2026-11-14.txt`](../evidence/provider-diagnostics/demo-run-2026-11-14.txt) |
| `scripts/test.sh` (full) at `352ba5e` | **FAILED**, exit 1: 204 files, 2 failed — the base commit's layout failure and one stop-ordering flake that passes 44/44 alone |
| `scripts/test.sh` (full), 2026-11-14 revision 2 | **FAILED**: all 204 suites were run, in four batches of 51 (the run exceeds one call's limit, so it is not one invocation). 3 suites failed: `test/harness-test-layout-test.el` (the branch predates `main`'s fix -- see below), `lisp/modules/harness-tools-shell-tramp-test.el` (times out at `main` too), and `lisp/ui/harness-ui-patch-review-test.el` (1 of 163, passes 163/163 when re-run alone -- a load flake) |
| `scripts/test.sh` (full) at `c763735` (revision 3) | **PASS**: 239 files, 0 failed, 536 s, clean tree — after repairing `...-retry-rechecks-a-stale-pin`, which bounded how long `session/create` may take (see below) |
| The repaired stale-pin test under load | **pass**: 3 consecutive suite runs clean, and 6 runs at once under `HARNESS_TEST_JOBS=6`; the same test still fails on 4 POSTs when the retry's re-read is suppressed, so the fix is a margin and not a weakening |

The full suite has now passed on this branch.  `scripts/test.sh` (full)
at `c763735` ran **239 files, 0 failed**, 536 s, on a clean tree
([stamp](../evidence/provider-diagnostics/full-run-2026-11-20-stamp.json),
[output](../evidence/provider-diagnostics/full-run-2026-11-20.out));
`scripts/test.sh --status` reports `PASS (full, 239 suites, 0 failed)`.
The runs below are the earlier ones, kept as they were recorded.

Earlier runs of this revision did not pass, and were not reported as
passing.  The last of them ran all 204 suites, in four batches because
the whole run is longer than one call may take, and three failed:

- `test/harness-test-layout-test.el` -- **this branch's merge base, not
  this branch.**  The test finds two suites in `test/` that its own
  list does not name: `harness-images-test.el` and
  `harness-ui-model-picker-test.el`.  Both are at the merge base
  `5022581`; `main` has since **deleted** them (`5020e5f`) and added
  one to the list, so the same test **passes on `main`** (3/3, run
  here) and fails on this branch only because the branch predates that
  commit.  This task changes nothing under `test/`.  The merge queue's
  merge into `main` takes `main`'s copy of both, which is why it is
  reported as a failure of this branch rather than papered over.
- `lisp/modules/harness-tools-shell-tramp-test.el` -- **fails on `main`
  too.**  Its first test passes and the second hangs; the suite is
  killed at the timeout, at 200s on `main` and at 300s here.  A TRAMP
  mock-method suite in this environment, not this branch's.
- `lisp/ui/harness-ui-patch-review-test.el` -- 1 of 163,
  `harness-ui-patch-review-reads-the-revisions-typed`, where a git
  process finished before its promise was read.  It passes **163/163
  when re-run alone**, so it is load-sensitive and not this branch's.

Every earlier full run of this revision is recorded in
[`docs/design/provider-verification-plan-2026-11-08.md`](../design/provider-verification-plan-2026-11-08.md)
§11, the failing ones included.  The failures have been the same two
environmental suites plus, twice, a stop-ordering flake.

The one failure the revision-3 full run had was neither: it was
`harness-provider-openrouter-transport-test`'s
`...-retry-rechecks-a-stale-pin`, and it is repaired at `3443405`.  That
test gives the pin a `:freshness` bound and stamps the pin's
`:catalogue-at` when the route is built, before `session/create`; the
gap between making the pin and dispatching is bounded by nothing the
test controls, so a loaded machine put the **first** request outside the
bound, the dispatch refused it as `over-max-price`, nothing was sent,
and the wait for "trying again in" timed out.  Delaying the dispatch
0.3 s reproduces it deterministically.  The routing code was right --
it failed closed, which is the behaviour the policy exists for -- and
what was wrong was a test bounding how long a session takes to be made.
Both bounds now keep a margin on the side they are not about
(`:freshness` 1.0 s, the retry waits 2.0 s), and the pin is restamped
immediately before the request so the age measured is the retry's wait.
The assertions are unchanged, and the test still catches the defect it
guards: suppressing the re-read makes it fail on 4 POSTs instead of 1.

### What this revision changed

Revision 1 (the code) is unchanged from the previous hand-in:

1. `lisp/modules/harness-provider-check.el`: unknown stays unknown in the
   cache evidence and its detail; the record keeps the observed serving
   provider; a record that was not written is a skip; the estimate
   announces the enforced budget; warm and absent controls are different
   skips.
2. `lisp/modules/harness-cache.el`: the cache-miss alarm names the cause
   the diagnostics recorded, or `unknown`.
3. `lisp/modules/harness-provider-diagnostics.el`: each attempt keeps its
   response reading and exposes the content-free summary API.
4. Tests: 12 new offline tests across the three suites plus one
   exact-copy UI test.  No request, no route change, no credential read.

Revision 2 changes no Emacs Lisp at all.  It adds the second
independent verification pass of `t-sp1j60ii`'s branch at `8df2fe1`,
records both defects fixed, records the five-file merge conflict that
bringing the two branches together will need, and records the full-suite
run honestly, including the failure that is the branch's own merge base.

Revision 3 (this one) repairs one test it did not write.  The full run
on this branch failed one suite, `harness-provider-openrouter-transport-test`:
`...-retry-rechecks-a-stale-pin` gave the pin a 0.2 s `:freshness` and
stamped its reading when the route was built, before `session/create`,
so the gap between making the pin and dispatching -- which nothing in
the test bounds -- put the *first* request outside the bound on a loaded
machine.  The dispatch then refused it as `over-max-price`, nothing was
sent, and the wait for the retry timed out; delaying the dispatch 0.3 s
reproduces it every time.  The routing code is right and fails closed
as it should: what was wrong was a test bounding how long a session
takes to be made.  The bounds now keep a margin on the side they are not
about (`:freshness` 1.0 s, the retry waits 2.0 s) and the pin is
restamped immediately before the request.  The assertions are unchanged
and the test still catches the defect it guards -- suppressing the
re-read makes it fail on 4 POSTs instead of 1.

`scripts/test.sh` (full) at `c763735`: **PASS**, 239 files, 0 failed,
536 s, clean tree
([stamp](../evidence/provider-diagnostics/full-run-2026-11-20-stamp.json),
[output](../evidence/provider-diagnostics/full-run-2026-11-20.out)).
The repaired suite also passed 3 consecutive suite runs and 6 runs at
once under `HARNESS_TEST_JOBS=6`, the load that produced the failure.

Everything below is the assessment as it stood, kept as the appendix it
now is.  Dates on its external claims are the dates they were retrieved.

### A regression on `main`, found while checking this branch's merge

Not this branch's, and not repaired here: reported so it is not lost.

When this branch was merged with `main` (`0f99217`) in a scratch tree to
check the merge, **7 suites failed there**, and they fail on `main`
alone too: `harness-access`, `harness-readonly`, `harness-tools-ssh`,
`harness-tools-jobs`, `harness-supervisor`, `harness-provider-claude`
and `harness-ui-access`.

The cause is `662ccac` ("Settle a session's system prompt and tool
schema once").  That change is right about the prompt cache: a session's
tool schema is settled at its first request and never rewritten, so a
tool appearing mid-session cannot invalidate the provider's cached
prefix.  But `tools/list` now returns the settled list **verbatim**,
before the `agent/tools` filters run, so a tool a session *loses* is no
longer taken off it.  `drop_access` sets the profile to `:network
:false` and tells the person "the web tools and ssh are gone from the
next request on", and they are not: the session keeps offering them.

The fix is small and is not applied here, because it belongs to the
change that made the regression: the settled names must still be put
through `agent/tools`, which narrows and never widens, so settling keeps
its guarantee (a tool the session settled without is still not added)
while giving access up still takes tools away.  A prototype of exactly
that made `harness-access`, `harness-tools-ssh`, `harness-ui-access`,
`harness-tools` and `harness-agent` pass in a scratch tree.

Four of the seven (`harness-readonly`, `harness-supervisor` ×2,
`harness-tools-jobs`, `harness-provider-claude`) are a second question
the same change raises and that is **not** a filter bug: they expect a
tool to *appear* after the session settled, which settling now forbids
by design -- `harness-readonly-offers-bash-only-where-the-sandbox-
confines-it` and `harness-supervisor-bash-is-offered-only-where-the-
sandbox-confines-it` flip `sandbox/confined-p` and expect `bash` to
come back, and the judged-hands-on test expects the writing tools to
return mid-session.  Whether settling should be re-decided when the
sandbox answer or the supervisor mode changes, or those tests should
assert the new rule, is a design decision for whoever owns `662ccac`,
not something to settle from this task.

---

## Appendix: the 2026-11-08 assessment

| Target | Verdict | One line |
| --- | --- | --- |
| **ChatGPT plan** (`chatgpt:*`) | **NO-GO** for meaningful cache-heavy plan use | The route has no numerical quota telemetry, no enforceable output cap, and records plan calls as zero cost; its cache behaviour is unverified. Data sovereignty is out of scope for ChatGPT per the 2026-11-08 review. A bounded cache smoke is the only defensible use, after §3.6. |
| **DeepSeek via OpenRouter, on the 2026-11-08 baseline configuration** | **NO-GO** for production routing | That baseline (`main` at `5022581`) carried no provider preferences, used the global `openrouter.ai` domain, defaulted to `allow_fallbacks: true` and `data_collection: allow`, and recorded no per-request host or region. It could not prove "no training" or "no China processing" for the request it actually sent. **This is the baseline as it stood, not a description of the current configuration**: the route, pin and privacy settings are set in the user's own configuration and were not read or changed by this task. |
| **DeepSeek via OpenRouter, on a pinned US in-region endpoint** | **Not verified — conditional candidate only** | US in-region routing is the only control that makes "not China" an enforced property of prompt/completion processing, but it needs a Business/Enterprise plan, an exact endpoint pin, and written confirmation for the provider's own subprocessors. |
| **OpenRouter live smoke, 2026-11-09** | **NO-GO — region gate and cache reliability fail** | `us.openrouter.ai` returns 403 "Regional routing requires a Business or Enterprise plan"; on the global route the exact pin works and reports `data_region: "global"`; cache hits are intermittent (Particle's second run 1/2 exact repeats; Morph 0/2 concurrent rounds). |
| **Cheapest endpoint fully verified under both constraints** | **None verified** | No endpoint clears the audit-standard bar in §2.4. The cheapest at list input price is Morph `morph/fp8`; the cheapest for a cache-heavy 4k-in/512-out step is Particle AI flex `particle-ai/us/flex`; both are provisional. |
| **Prefix / serving-host observability** | **Implemented on the task branch, not deployed** | Content-free, keyed checkpoints over the wire prefix plus response-supplied provider/model/cache/cost; §5.3b. It makes the next miss decidable; it does not make either provider ready. |
| **Client prefix preservation** | **Best-effort only** | `harness-replay` keeps a provider-neutral latest snapshot and silently falls back to a fresh render; it does not freeze the final wire body or fail closed. §5.3c. The immutable-freeze implementation belongs to `t-sp1j60ii`. |
| **2026-11-13 zero-cache calls** | **Observed, cause unknown** | Five `chatgpt:gpt-6.1-sol` calls, two with `cache_read=0` between 350k-430k neighbours; the final-wire requests were not archived, so client drift and provider-side eviction cannot be separated. §5.3c. |

The model is **`deepseek/deepseek-v4.1-flash-1017`**
(canonical slug `deepseek/deepseek-v4.1-flash-20261017`, created
2026-10-17 08:27 UTC), a 1,048,576-token context snapshot, not the
older `deepseek/deepseek-v4.1-flash` (2026-09-10). Prices below are per
million tokens: input / output / cache read. No cache-write price is
published for the shortlisted endpoints; the harness therefore bills a
write at the input price (`harness-openai--pricing`,
[`lisp/modules/harness-provider-openai.el:313-319`](../../lisp/modules/harness-provider-openai.el)).

## 1. What was assessed, and what "verified" means here

### 1.1 Scope

- The harness's ChatGPT provider: Sign in with ChatGPT (SIWC), the
  Responses API contract, plan quota telemetry, usage accounting,
  caching and keep-warm, fallback, retry and context safeguards.
- DeepSeek V4.1 Flash 1017 through OpenRouter: the current endpoint
  catalogue, US in-region eligibility, ZDR eligibility, provider data
  policies, strict host pinning, cache economics and host audit.
- The deployed code at `5022581`, the merged work it contains, and the
  task branches that are still unmerged (they are not evidence of
  deployed behaviour).

**Scope clarification (2026-11-08 review).** Data sovereignty —
training, retention, operator/subprocessor geography, "no China" — is
assessed **only for the OpenRouter target**. For ChatGPT and any other
non-OpenRouter provider, **only cache behaviour is in scope**. The
ChatGPT quota and accounting sections remain because they bound what a
cache run can cost; they are not a data-sovereignty verdict.

### 1.2 Evidence classes

Every claim in the evidence matrix (§6) is one of these:

| Class | Meaning | Readiness value |
| --- | --- | --- |
| **E0 advertised** | A provider page, API catalogue field or policy says it. | A lead, never proof of the request that was sent. |
| **E1 code** | The deployed harness code does it. | Proves harness behaviour, not provider behaviour. |
| **E2 synthetic** | A fake provider or a unit test asserts it. | Proves the code path; proves nothing about a real provider. |
| **E3 live** | A real request observed it, with a date and evidence. | Proves one observation; repeatability and scope still matter. |
| **E4 contract** | A written confirmation, DPA, addendum or provider-published policy covers it. | The only class that can bind a provider's data handling. |

"Verified" in this report means **E4 plus E3 for the specific
property**, not a green label on a task or a check. A provider-check
`PASS` is E1/E3 evidence about the response it saw, not a policy
verdict. This distinction is the reason the task says not to claim
readiness from hand-in labels alone.

### 1.3 Secrets

No credential, token, account identifier or API key value is printed
or written. The endpoint metadata below was fetched from OpenRouter's
public catalogue and policy pages. The live smoke used the
`OPENROUTER_API_KEY` already in the process environment; it was sent to
OpenRouter and never logged. No ChatGPT credential was read or used.

## 2. What the constraints actually mean

These constraints are the **OpenRouter target's**. They are not applied
to ChatGPT, whose only evaluated dimension is cache behaviour (§3).

### 2.1 "No training on user data"

Training is not one promise. It is at least four:

1. **OpenRouter itself** must not train on prompts or completions.
2. **The endpoint provider** must not train, fine-tune, evaluate or
   improve models on the prompt or completion.
3. **No support/debugging exception** may silently permit training.
4. **Safety retention** may keep flagged content for abuse review; that
   is retention, not training, but it must be disclosed and accepted.

`training: false` in OpenRouter's provider metadata is E0: OpenRouter's
own routing documentation calls the Data Policy tag "not a definitive
source of third party data policies"
([provider-selection, retrieved 2026-11-08](https://openrouter.ai/docs/guides/routing/provider-selection)).
A provider's own policy is E4 only where it is unambiguous, current and
not contradicted by another part of the same policy. OpenRouter's
account-wide "disable training" switch is not proof: it filters by the
same metadata, and `data_collection: "deny"` means only "use providers
which do not collect user data" — it does not distinguish "no
training" from "no retention".

### 2.2 "No China processing or hosting"

This is a property of **where the prompt and completion are processed**,
not of a company's headquarters or the model's origin. It must hold for:

1. the router's request handling;
2. the inference endpoint that actually serves the request;
3. every fallback the router might choose;
4. the provider's subprocessors and the router's own account/operational
   records, if the constraint is read to cover all data rather than only
   prompt content.

OpenRouter's global domain has no geographic constraint. Its US
in-region routing is the only published control that makes geography
operational: on `us.openrouter.ai`, candidate endpoints are filtered to
provider infrastructure OpenRouter has onboarded as US, and a request
with no eligible endpoint **fails closed** rather than falling back out
of region
([in-region routing, retrieved 2026-11-08](https://openrouter.ai/docs/guides/features/in-region-routing)).
That control still has a boundary: it covers prompts and completions in
requests served by shared provider endpoints, plus OpenRouter's request
handling; account data, billing records, security logs, abuse metadata
and other operational records may be stored or processed outside the
region. For `eu.openrouter.ai` the published table says the latter "may
be stored or processed in the US"; the same boundary is stated for
regional routing generally, and no China-free subprocessor list for
those records was found. If "no China" covers all data, no current
endpoint is verified.

### 2.3 "NON-DeepSeek hosting provider"

The model weights may be DeepSeek's; the **operator that processes the
request** must not be DeepSeek. That excludes DeepSeek first-party
(`headquarters: CN`, `training: true`, `retainsPrompts: true` in
OpenRouter's provider catalogue) and any China-hosted third party. It
does not exclude a US operator serving DeepSeek weights.

### 2.4 Derived requirements

| Id | Requirement | Evidence that would satisfy it |
| --- | --- | --- |
| R1 | The request is routed only to a named non-DeepSeek endpoint outside China. | Request-level `provider.only` exact slug + `allow_fallbacks: false`, plus the endpoint's declared datacenter region. |
| R2 | Prompt and completion processing is in the US, or contractually excluded from China. | `us.openrouter.ai` + US onboarding of that endpoint + the generation record's `data_region`, or a written DPA/confirmation covering subprocessors. |
| R3 | The provider does not train on prompts or completions, with no support exception. | Current provider policy or signed terms; OpenRouter's `training: false` alone is not enough. |
| R4 | Fallback cannot leave the allowed set. | `allow_fallbacks: false`; harness fallback list empty or itself pinned; fail-closed on 429/5xx rather than cross-host retry. |
| R5 | Each request's actual host and region are observable. | Generation id retained; `GET /api/v1/generation?id=` returns `provider_name`, `data_region`, `total_cost`. Today the harness discards the id. |
| R6 | The harness records what the provider actually billed. | `usage.cost` recorded; budgets use it; failed/retried streams accounted for or explicitly marked unknown. |

Storage — ZDR versus 30-day retention — is **not one of the two stated
constraints**, but it changes the answer. It is treated separately in
§4.3, and the plan asks Noah to choose in §8.

## 3. ChatGPT plan provider

### 3.1 What the harness implements

- **Auth:** dynamic client registration, PKCE, a stable
  `ext_agent_host_id`, an access token and a 30-day rotating refresh
  token. A token without `chatgpt.tokens.use.direct` is retained but
  cannot pay for inference; enabling plan usage repeats consent with
  `force_reconsent=true`
  ([`lisp/modules/harness-chatgpt-plan.el:470-511`](../../lisp/modules/harness-chatgpt-plan.el),
  [`877-925`](../../lisp/modules/harness-chatgpt-plan.el)).
- **Wire contract:** `POST https://api.openai.com/v1/responses`,
  `store: false`, `stream: true`, instructions rather than a system
  message, encrypted reasoning, `additional_tools`. Unsupported fields
  are not sent, including `max_output_tokens`
  ([`lisp/modules/harness-provider-responses.el:25-45`](../../lisp/modules/harness-provider-responses.el),
  [`986-1015`](../../lisp/modules/harness-provider-responses.el)).
- **Provider registration:** `chatgpt`, capabilities `(:vision t
  :thinking t :quota t :cache-ttl 1800)`, no `:cache-refresh`, no
  `:hosted-loop`
  ([`1723-1725`](../../lisp/modules/harness-provider-responses.el)).
- **Usage:** a completed response records `:cost 0.0` and `:billing
  subscription`; the list value is priced from the catalogue for
  display only
  ([`lisp/modules/harness-provider-responses.el:1290-1325`](../../lisp/modules/harness-provider-responses.el)).
- **Quota:** `provider/quota` returns `:billing subscription`, the
  account email and a note; **no numerical windows**. The official
  place to see usage is `https://chatgpt.com/settings/usage`. A Codex
  CLI login can supply an explicitly associated, read-only,
  **informational** reference, but it must never block inference
  ([`1561-1590`](../../lisp/modules/harness-provider-responses.el)).
- **Errors:** `subscription_sharing_usage_limit_exceeded` is a quota
  error, `subscription_sharing_usage_unavailable` is a 503 to retry
  later, `subscription_sharing_user_not_eligible` is an auth/eligibility
  error. OpenAI says it does not silently switch billing paths
  ([errors-and-recovery, retrieved 2026-11-08](https://developers.openai.com/siwc/token-sharing-open-source/errors-and-recovery)).

### 3.2 What OpenAI advertises

- SIWC plan usage is for **open-source and locally hosted apps**; paid
  or remotely hosted apps need a separate interest form. The harness is
  a local open-source app, so the preview applies, but it is a preview.
- The Responses route **does not accept `max_output_tokens`** (nor
  `background`, `conversation`, `metadata`, `prompt_cache_retention`,
  `temperature`, `top_p`, `truncation`, `user`, and others). This is in
  the current preview limitations
  ([retrieved 2026-11-08](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations)).
- There is **no numerical usage endpoint**. A usage-limit error can
  arrive after streaming has begun, as `response.failed`; the error
  itself does not tell you the reset time, and an app-specific limit
  can apply
  ([errors-and-recovery, retrieved 2026-11-08](https://developers.openai.com/siwc/token-sharing-open-source/errors-and-recovery)).
- **Data sovereignty for ChatGPT is out of scope** per the 2026-11-08
  review. No training, retention or geography verdict is made for it.
  OpenAI's API data page was checked and is not used as a readiness
  condition here; no SIWC-specific statement was needed for the
  cache-only assessment.

### 3.3 Accounting and safeguards

| Safeguard | Behaviour | Consequence |
| --- | --- | --- |
| Dollar budget | Plan calls record `cost 0.0`, `billing subscription`; `harness-usage--check` and hard budgets count cost. | A dollar budget cannot cap ChatGPT plan usage. `harness-usage` says a Pro/Max subscription has no cost report ([`lisp/modules/harness-usage.el:1289-1300`](../../lisp/modules/harness-usage.el)). |
| Quota windows | None are published or parsed; the quota check accepts zero windows as a pass ([`lisp/modules/harness-provider-check.el:2501-2530`](../../lisp/modules/harness-provider-check.el)). | No warning at 80% or 100%; the UI can only link to ChatGPT settings. |
| Output cap | `max_output_tokens` is dropped, logged once at debug ([`986-1015`](../../lisp/modules/harness-provider-responses.el)). | Provider-check's 512-token cap is not enforced on this route; a runaway answer can spend plan quota. Normal agent steps also send no output budget. |
| Keep-warm | The provider is not `:hosted-loop` and advertises `:cache-ttl 1800`; `harness-cache-warm` therefore treats it as an API provider and re-sends the conversation to refresh the cache, up to `max-refreshes`. With no catalogue prices, `compaction/resend-cost` is nil and the default is **12** refreshes ([`lisp/modules/harness-cache-warm.el:152`](../../lisp/modules/harness-cache-warm.el), [`254-280`](../../lisp/modules/harness-cache-warm.el)). | Up to twelve full-context refreshes per idle period, each covered by the plan and invisible to dollar budgets. A hit refreshes the cache, but it is still plan usage; this is a quota-burn path, not a free saving. |
| Retry | HTTP retries at most 3 times (`harness-http-max-retries`); a step retries at most 3 times per turn with exponential backoff. Quota errors go to fallback, not retry ([`lisp/modules/harness-retry.el:49-68`](../../lisp/modules/harness-retry.el)). | Bounded retries, but each retry of a long prompt is plan usage. |
| Fallback | `harness-fallback-models` defaults to nil ([`lisp/modules/harness-fallback.el:57-87`](../../lisp/modules/harness-fallback.el)). A quota error stops the turn unless a fallback is configured. | Safe by default; configuring a fallback moves the session off ChatGPT, which is the intended operational response. |
| Accounting boundary | Usage is emitted only when the stream carries a usage object; a failed or cancelled stream may carry none. | Provider billing can exceed recorded usage for failed, retried or cancelled requests. The harness records what it saw, not what OpenAI charged. |

### 3.4 Historical incidents and what has been fixed

- **The trigger for the cache-bomb work:** the user reported blowing
  through about 80% of a **$100 weekly ChatGPT quota** in one session,
  then reaching 100% (`t-2xh8jeni`). The "$100" is a plan UI figure; no
  code knows it, and there is no API-dollar equivalent.
- **Measured cold-cache waste:** of 73 historical ChatGPT forks, **73
  first requests read 0 cached tokens (5.8M tokens)**; of historical
  seeded DeepSeek workers, 25 of 48 first requests read 0 cached tokens
  on Flash and 16 of 23 on v4-pro
  ([`docs/architecture.md:10156-10176`](../architecture.md)).
- **Merged protections in the deployed baseline:** the shared-seed
  module is gone; supervisor forks are capped at
  `harness-supervisor-fork-limit` = 10,000 tokens and fail closed when
  the size is unknown or over the limit; a fresh step is the fallback;
  automatic model-written compaction is allowed only when the estimate
  says its own request is cached, and the estimate always says `:cached
  nil`, so automatic summaries become transcripts; the cold-cache
  default is `transcript` and the new-conversation limit is 100,000
  tokens
  ([`lisp/modules/harness-supervisor.el:363-380`](../../lisp/modules/harness-supervisor.el),
  [`lisp/modules/harness-compaction.el:205-248`](../../lisp/modules/harness-compaction.el),
  [`641-660`](../../lisp/modules/harness-compaction.el),
  [`lisp/modules/harness-cowboy.el:129-188`](../../lisp/modules/harness-cowboy.el),
  [`243-289`](../../lisp/modules/harness-cowboy.el)).
- **Operational follow-up:** `t-zi2s9b0o` ("Stop tasks using ChatGPT
  model") is in review with **no code diff**; it moved tasks off
  ChatGPT after the quota exhaustion. It is operational evidence, not a
  provider fix.

### 3.5 Current gaps

| Gap | Severity | Why it blocks readiness |
| --- | --- | --- |
| No numerical quota or reset time | High | Cannot know how much plan is left, cannot stop at a fraction, cannot verify a budget. |
| No enforceable output cap | High | A single runaway response can consume an unknown share of the plan; provider-check's 512-token cap is not enforced on this route. |
| Plan cost is zero in accounting | High | Dollar budgets and warnings do not apply; `usage/quota-rates` cannot compute a plan exchange rate without windows. |
| Keep-warm counts 12 full re-sends | High | Idle sessions can spend plan quota invisibly; this is on by default. |
| Quota check passes with zero windows | Medium | A `PASS` on the quota check overstates what is known. |
| Provider-check request cap is per model request, not per HTTP attempt | Medium | Retries can exceed the nominal 64-request bound. |

### 3.6 ChatGPT verdict and conditions

**NO-GO for meaningful cache-heavy plan use.** A bounded **cache-only**
smoke is the only defensible use, and only if all of these hold before
it starts:

1. Noah explicitly approves a plan-quota allowance (requests, expected
   output, stop on 429) and accepts that no numerical meter exists.
2. A client-side output stop exists (cancel after N output tokens or N
   seconds), because the wire cap cannot be sent.
3. Keep-warm is off for ChatGPT sessions, or capped to a number Noah
   approves; today it defaults to 12 full re-sends.
4. No task, automation, fallback list or supervisor route selects
   ChatGPT during the smoke.
5. The quota check is not read as "quota known": it passes with zero
   windows. Data sovereignty is not part of this verdict (review
   scope).

## 4. DeepSeek V4.1 Flash 1017 via OpenRouter

### 4.1 The model and the endpoint catalogue

At retrieval, `GET /api/v1/models/deepseek/deepseek-v4.1-flash-1017/endpoints`
returned **50 endpoints**. The table lists the ones relevant to the
decision (and the China-hosted ones the default request does not
exclude); prices are $/M input, output, cache read; `write` is not
published separately, so the harness assumes the input price.

| Endpoint slug | Provider | Input | Output | Cache read | US in-region | ZDR list | Provider metadata |
| --- | --- | ---: | ---: | ---: | --- | --- | --- |
| `relace/fp4` | Relace | 0.006 | 0.50 | 0.005 | no | yes | HQ/datacenters not declared; policy link 404 at retrieval |
| `open-inference/fp4` | OpenInference | 0.0175 | 0.70 | 0.004 | no | yes | HQ US; terms conflict with privacy (below) |
| **`morph/fp8`** | **Morph** | **0.022** | **0.40** | **0.004** | **yes** | **yes** | HQ US; datacenters US; no training; retention contradictory |
| `particle-ai/us/flex` | Particle AI | 0.025 | 0.25 | 0.0015 | yes (flex) | yes | HQ US; datacenters US; ZDR default; no training unless opt-in |
| `wafer/us` | Wafer | 0.038 | 0.50 | 0.01 | yes | yes | HQ US; datacenters not declared; terms silent on provider training; privacy page 404 |
| `particle-ai/us` | Particle AI | 0.05 | 0.50 | 0.003 | yes | yes | as above, standard tier |
| `wafer/mxfp4` | Wafer | 0.066 | 0.50 | 0.0065 | no | yes | as above, non-US-tagged variant |
| `alibaba` | Alibaba | 0.075 | 0.30 | 0.0075 | no | no | HQ SG; datacenters SG and **CN**; retains prompts |
| `inference-net/us` | InferenceNet | 0.08 | 0.55 | 0.008 | yes | yes | HQ US; datacenters not declared; policy not independently read |
| `baidu/fp8` | Baidu | 0.09772 | 0.39437 | 0.002094 | no | no | HQ CN; retains prompts |
| `deepinfra/fp8` | DeepInfra | 0.098 | 0.294 | 0.00294 | yes | yes | HQ US; datacenters not declared; metadata only |
| `streamlake/fp8` | StreamLake | 0.111 | 0.444 | 0.00222 | no | no | HQ CN; retains prompts |
| `deepseek` | DeepSeek | 0.15 | 0.60 | 0.003 | no | no | HQ CN; **training true**; retains prompts |
| `fireworks/us` | Fireworks | 0.45 | 1.80 | 0.009 | yes | yes | HQ US; datacenters not declared; metadata only |

`stepfun/fp8` ($0.135/$0.54/$0.0027) is also in the list; its
headquarters is not declared but it retains prompts. None of these
China-hosted or China-headquartered endpoints is excluded by a default
request.

**The cheapest endpoint overall is Relace at 0.006/0.50/0.005.** It is
not in OpenRouter's US in-region list, its provider entry declares
neither headquarters nor datacenters, and its published policy was not
reachable (the catalogue's privacy link returned 404 at retrieval).
Cheap is not qualifying. The same logic excludes OpenInference at
0.0175: it is not US in-region eligible, and its privacy policy says
zero retention/no training while its terms say "Training opt-out" and
"we process and store Customer Content". Two policies that contradict
each other are not E4.

### 4.2 Routing, fallbacks and geography

**Today's harness request.** `harness-openai--body` sends `model`,
`messages`, `stream`, `stream_options`, tools, `max_tokens`, `usage`
and a reasoning object on OpenRouter. It sends **no `provider`
object**, no `session_id`, no `prompt_cache_key` and no
`cache_control`
([`lisp/modules/harness-provider-openai.el:750-783`](../../lisp/modules/harness-provider-openai.el)).
The default endpoint is `https://openrouter.ai/api/v1`
([`132-135`](../../lisp/modules/harness-provider-openai.el)), the
global domain. With OpenRouter's defaults:

- `allow_fallbacks` is **true**;
- `data_collection` is **"allow"**;
- `zdr` is absent and has no effect;
- a request with no `only`/`order` uses default routing, which considers
  every eligible endpoint of the model, including DeepSeek first-party
  (`training: true`, headquarters CN), Baidu, StreamLake and Alibaba
  (declared datacenters SG and CN). Default routing is not a price sort:
  it weighs price and availability, and a fallback can land on any of
  them.

([provider-selection, retrieved 2026-11-08](https://openrouter.ai/docs/guides/routing/provider-selection))

So the deployed request can be served by an endpoint that is not the
one whose price the UI shows, and cannot prove either constraint. This
is not a hypothetical: the model-level price the catalogue gives
(`$0.006/$0.50/$0.005`) is the cheapest endpoint's price, not the price
of any endpoint a policy-conscious user would pin.

**What strict pinning requires.** These are request-level, not
account-level, because only request-level fields are visible in code
and auditable per request:

```json
{
  "model": "deepseek/deepseek-v4.1-flash-1017",
  "provider": {
    "only": ["morph/fp8"],
    "allow_fallbacks": false,
    "zdr": true,
    "data_collection": "deny"
  },
  "session_id": "<stable per-session id>"
}
```

- `only` with the exact endpoint slug pins the endpoint. A base slug
  (`morph`) matches all variants; the exact slug is `morph/fp8`.
- `allow_fallbacks: false` is what makes "fail closed" true; `order`
  alone still allows other providers when the named ones fail.
- `zdr: true` filters to ZDR endpoints; Safety Retention endpoints are
  also eligible unless the account's privacy setting is "ZDR only".
- `data_collection: "deny"` filters by OpenRouter's data-policy
  metadata, not by geography and not by a contract.
- `session_id` enables sticky routing from the first request; without
  it, sticky routing only starts after a cache hit is observed.

**Does the pin keep DeepSeek and China out?** The pin, not the model
id, is what does it. Every request names `deepseek/...` as the model in
either case; `only: ["morph/fp8"]` with `allow_fallbacks: false` is the
part that makes another endpoint — DeepSeek first-party, Alibaba, or
anything else — ineligible, and makes the request fail rather than
fall back. `only` without `allow_fallbacks: false` still lets
OpenRouter use a backup provider when the pinned one is unavailable;
`order` alone is only a preference. On the global domain, the 1017
endpoint list includes DeepSeek first-party, Baidu, StreamLake and
Alibaba (whose declared datacenters include CN), and nothing in a
default request excludes them. On `us.openrouter.ai`, the regional
filter excludes them by onboarding; the pin then names the one endpoint
that remains.

**US in-region routing.** Send requests to
`https://us.openrouter.ai/api/v1`, or enforce the region with a
guardrail whose `allowed_data_regions` is `["us"]`. A regional domain
filters candidates to endpoints OpenRouter has onboarded for US
infrastructure; if none is eligible, the request **fails** rather than
falling back out of region. The guarantee covers prompt and completion
processing, provider inference on shared provider endpoints, and
OpenRouter's request handling. It does **not** cover account data,
billing, security logs, abuse metadata or other operational records;
those are outside the boundary. It also rejects features whose
infrastructure is out of region (web search/fetch server tools, Batch,
some PDF engines). None of those is used by the harness's chat turn.

**What this means for the constraints.** If Noah means "prompt and
completion processing", US in-region + an exact pin + a provider whose
inference is US-onboarded is a real, fail-closed control. If Noah means
"all data, including router account records and provider
subprocessors", no endpoint is verified: OpenRouter does not publish a
China-free subprocessor list for those records, and the provider
policies below reserve non-US processing.

**The harness's own fallback is a second route.** Even with a pinned
endpoint, `harness-fallback-models` can move a session that runs out of
quota or money to another provider or model. For a constrained
verification, leave it nil, or make every entry itself a pinned
US-hosted endpoint. An unpinned fallback undoes the pin.

### 4.3 Training, retention and provider policies

| Provider | No training | Retention | Geography statement | Verdict |
| --- | --- | --- | --- | --- |
| **Morph** | Yes, every tier, no support/debug exception; flagged-prompt safety review is retained but not used for training (privacy and ToS, updated 2026-10-23) | **Contradictory:** the introduction says "we do not retain it", but the tier table says free/paid retain inputs and outputs up to 30 days; full ZDR is enterprise-only under a signed addendum | "Primary data processing occurs in the United States, with additional processing in select countries where our service providers operate" | No-training E4; geography not exclusive; retention ambiguous. Needs written confirmation. |
| **Particle AI** | Yes, no training/fine-tuning/improvement unless the customer separately opts in; ordinary use is not opt-in | Standard synchronous inference is ZDR by default; no raw prompts/outputs written to persistent storage; content-free operational metadata retained | "Services are initially intended for the United States"; use only in the US and locations Particle expressly supports; personal information may be processed and stored in the US | Strongest published policy, but "initially intended" is not an exclusive processing guarantee. |
| **Wafer** | Not stated for prompt data; its terms only forbid the *customer* from training a competing model, and grant a processing licence; its privacy page returned 404 at retrieval | Not stated | HQ US; datacenters not declared | Not verified. |
| **OpenInference** | Privacy says no training; terms say "Training opt-out" and "we process and store Customer Content" | Privacy says ZDR; terms conflict | Privacy says platform and subprocessors in the US | Contradictory; excluded. |
| **Relace** | Not verified; policy link 404 | Not verified | Not declared | Excluded. |
| **Alibaba** | Metadata says no training, but retains prompts | Retains prompts | HQ SG; datacenters SG and CN | Excluded for the China constraint. |

Sources: [Morph privacy](https://www.morphllm.com/privacy) and
[terms](https://www.morphllm.com/privacy/tos) (updated 2026-10-23,
retrieved 2026-11-08); [Particle privacy](https://particle.ai/privacy/)
and [terms](https://particle.ai/terms/) (retrieved 2026-11-08);
[Wafer terms](https://www.wafer.ai/terms) (retrieved 2026-11-08);
[OpenInference privacy](https://www.openinference.ai/privacy) and
[terms](https://www.openinference.ai/terms) (retrieved 2026-11-08);
[OpenRouter provider catalogue](https://openrouter.ai/api/frontend/v1/all-providers)
(retrieved 2026-11-08).

**The key contradiction.** OpenRouter lists Morph in its ZDR endpoint
list and marks `retainsPrompts: false`, while Morph's own current policy
says paid tiers are **not** ZDR and retain content for up to 30 days
(only an enterprise ZDR addendum is zero-retention). One of the two is
stale or scoped differently. This is exactly the "generic OpenRouter
privacy switch is not proof" case: `zdr: true` would route to Morph,
but Morph's published paid-tier policy says the content is retained.
Until Morph or OpenRouter confirms in writing which agreement applies
to OpenRouter-routed traffic, Morph's retention is **unknown**, not
zero.

**Storage decision.** If Noah requires ZDR, Morph fails the public
policy and Particle passes (standard synchronous inference is ZDR by
default). If Noah requires only "no training", both Morph and Particle
pass on training, and retention is a separate accepted risk. The plan
asks for this decision explicitly.

### 4.4 Cache economics and sticky routing

- All shortlisted endpoints advertise implicit caching
  (`supports_implicit_caching: true`). The 2026-11-09 smoke confirms
  that Particle and Morph do report `cached_tokens`, but not that every
  repeat hits; see §4.8.
- Cache reads are 18% of Morph's input price (0.004 / 0.022) and 6% of
  Particle flex's (0.0015 / 0.025). They are economically important in a
  long agent loop.
- No shortlisted endpoint publishes a separate cache-write price. The
  harness prices a write at the input price; a provider that charges
  more (Anthropic-style 1.25x) would make a cold first request more
  expensive than the estimate.
- OpenRouter's sticky routing keeps a conversation on the endpoint that
  served a cache hit, but it **only activates after a cache hit** unless
  the request carries `session_id`. Sticky sessions expire after 60
  minutes of inactivity. If the sticky endpoint becomes unavailable,
  OpenRouter falls back to the next provider, which loses the cache
  ([prompt caching, retrieved 2026-11-08](https://openrouter.ai/docs/guides/best-practices/prompt-caching)).
- The harness sends **no `session_id` and no `prompt_cache_key`**. Before
  the first hit, the router may send the first request to one endpoint
  and the next to another; the first request's cache write is then
  wasted. With an exact pin and `allow_fallbacks: false`, the host is
  stable, so this is not a problem for the pinned candidate; it is a
  problem for today's default routing and a plausible contributor to
  cache misses.
- The harness's displayed and estimated prices come from the
  **model-level** `/models` entry, which is the cheapest endpoint
  (Relace), not the pinned endpoint. Actual `usage.cost` from
  OpenRouter is recorded and drives budgets, so completed calls are
  costed correctly; estimates and provider-check bounds can understate
  a pinned Morph request's input by about 3.7x (0.006 vs 0.022), though
  the full-output estimate is only about 5% low because Morph's output
  price is lower. At the short outputs the cache probes actually use,
  the understatement is larger (roughly 2.7x for a cache-only run).

### 4.5 Host and region audit

OpenRouter's generation endpoint returns `provider_name`, `data_region`,
`total_cost`, `upstream_inference_cost`, `cache_discount` and
`upstream_id`
([generation API, retrieved 2026-11-08](https://openrouter.ai/docs/api/api-reference/generations/get-generation)).
The harness does not keep the response's generation id: the
OpenAI-compatible stream accumulator has no id slot, the body sends no
`session_id`, and no code calls `/api/v1/generation`. There is therefore
**no per-request evidence of which endpoint served a request or in
which region**. A
pinned request is a configuration claim; the generation record would be
the observation. The verification plan makes retaining it a gate.

The 2026-11-09 direct smoke called the generation endpoint and got
`provider_name` and `data_region` back (§4.8), so the API can provide
the audit row. Two operational details matter: the row can lag a
successful response (one immediate query returned 404 and a retry a few
seconds later returned the row), and its `tokens_prompt` is a
router-side count (3,516 where the response's `prompt_tokens` was
2,753); cache evidence should use the response's
`prompt_tokens_details.cached_tokens` or the row's
`native_tokens_cached`, not the router count.

### 4.6 Cheapest qualifying host: the answer

**No endpoint is fully verified under the strict reading of both
constraints.** The cheapest candidate depends on the workload, and the
two cheapest have different risks.

| Candidate | Input / output / cache read | 4,096 in + 512 out, uncached | 4,096 in + 512 out, 80% cached | 4,096 in + 24 out, 80% cached | Risk |
| --- | ---: | ---: | ---: | ---: | --- |
| **Morph `morph/fp8`** | **0.022 / 0.40 / 0.004** | **$0.000295** | $0.000236 | $0.0000407 | Cheapest input and standard tier; retention contradiction; non-US subprocessors |
| **Particle `particle-ai/us/flex`** | 0.025 / 0.25 / 0.0015 | $0.000230 | **$0.000153** | **$0.0000314** | Cheapest blended cost for normal output and cache-heavy loops; flex tier |
| Particle `particle-ai/us` | 0.05 / 0.50 / 0.003 | $0.000461 | $0.000307 | $0.0000628 | ZDR default, but more expensive |
| Wafer `wafer/us` | 0.038 / 0.50 / 0.01 | $0.000412 | $0.000320 | $0.0000759 | Terms silent on training/retention; privacy 404 |

Per request, not per million tokens; the arithmetic is input × price +
output × price, with the cache-read price on the cached share of the
input.

**The answer for the harness's usual step** — a few thousand input
tokens, a few hundred output tokens, a cache-heavy loop — is
**Particle AI flex `particle-ai/us/flex` at $0.025/$0.25/$0.0015**, if a
lower-priority flex service tier is acceptable. It is the cheapest
qualifying endpoint for that mix and its provider publishes the
strongest policy: ZDR by default for standard synchronous inference,
no training unless the customer opts in, and US processing.

**If flex is not acceptable**, the cheapest **standard** endpoint at
list input price is **Morph `morph/fp8` at $0.022/$0.40/$0.004**. It is
the lowest-priced endpoint that is simultaneously in the US in-region
list, in OpenRouter's ZDR list, marked no-training/no-retention with no
safety retention, and declared with US headquarters and US datacenters.
It is provisional because Morph's own paid-tier retention (30 days)
contradicts OpenRouter's ZDR classification, and Morph's policy permits
processing in "select countries" through service providers. It becomes
verified only with a written confirmation (or a DPA/addendum) that
OpenRouter-routed inference is US-only and no-training, and with
per-request `provider_name`/`data_region` evidence.

Particle's geography statement is "initially intended for the United
States", not an exclusive guarantee, so it also needs written
confirmation if the constraint covers all data. If Noah means "no
storage at all", Morph is out and Particle is the candidate. If Noah
means only "no training", both are candidates. In neither case is any
endpoint "verified" today.

### 4.7 DeepSeek via OpenRouter verdict

**NO-GO for production routing as configured.** The harness cannot
enforce R1, R2, R4 or R5 today. **GO for a bounded verification** only
after the controls in the plan land: an exact pin, US base URL,
`allow_fallbacks: false`, `zdr: true`, `data_collection: "deny"`,
`session_id`, generation-id retention and a pinned-price estimate.
Nothing in this assessment enables a route; the smoke spent no ChatGPT
plan quota.

The 2026-11-09 smoke (§4.8) confirms the verdict with live evidence:
the current account cannot use US in-region routing (403), and cache
reuse under a strict pin is intermittent on both shortlisted hosts.

### 4.8 Live smoke, 2026-11-09 (E3)

**Authorization and spend.** The 2026-11-09 review asked for small smoke
tests and warned about the ChatGPT plan quota. The smoke used only
OpenRouter: three provider-check jobs (57 requests), 25 direct cache
probes, and a few canary and policy requests — about 86 synthetic
requests. The provider-reported cost totals **$0.00476**; the canaries
and the one policy probe add under $0.00001. No ChatGPT request was
made: the `chatgpt-plan` module was not loaded in this harness
instance, so no plan quota was touched.

**Method.** Model `deepseek/deepseek-v4.1-flash-1017`; global base
`https://openrouter.ai/api/v1`; each request carried `provider.only`
with one full endpoint slug (`morph/fp8` or `particle-ai/us`),
`allow_fallbacks: false`, `zdr: true` and `data_collection: "deny"`.
The provider-check jobs ran the deployed check code with a **test-only
around-advice** on `harness-http-request` that added those fields; no
source file, endpoint or route was changed. The direct probes sent the
same body. All prompts were synthetic.

**Checks run.** The offline provider-check suite passed 49/49
(`lisp/modules/harness-provider-check-test.el`), including the
independent-prefix fake-provider cases. The two OpenRouter integration
tests in `lisp/modules/harness-provider-openai-test.el` passed 2/2
against `openai/gpt-4.1-nano` (text and tool round-trip). Those tests
exercise the harness's OpenRouter request path, but not the pinned
1017 model or its cache.

**Region gate: fail.** `POST https://us.openrouter.ai/api/v1/chat/completions`
with the same body returned 403:

> Regional routing requires a Business or Enterprise plan. Upgrade at
> https://openrouter.ai/settings/manage-plan, then send requests to
> eu.openrouter.ai or us.openrouter.ai.

The key is not on that plan. On the global domain,
`GET /api/v1/generation?id=...` reported `data_region: "global"` and
`provider_name: "Morph"` (or `"Particle AI"`). The exact pin fixes the
operator; it does not fix the region. **No request in this smoke was
US in-region.**

**Host audit and fail-closed pin.** The generation rows matched the
pinned operator and the response's `usage.cost`. A request with
`only: ["morph/nonexistent"]` and `allow_fallbacks: false` returned 404
("No allowed providers are available ...") and listed the eligible
providers; nothing fell back. That list includes `deepseek` and
`alibaba` on the global route, which is the set the pin excludes.

**A metadata filter is not a policy.** A request pinned to
`relace/fp4` with `zdr: true` and `data_collection: "deny"` returned
200 and was served by Relace — the provider whose policy link is 404
and which §4.3 excludes. The switches are OpenRouter's metadata
classification; they do not establish the provider's contract.

**Cache results.** Each row is one provider-check job with
`:cache-sessions 2`. "Baseline" is the serial repeat immediately after
the prime in each independent session; "rounds" are concurrent reuses
of those same prefixes, each in its own session. All rows had cache
telemetry, cold controls, no throttling, no errors and no identity
mismatches.

| Job | Exact-prefix check | Independent-prefix check | Cost |
| --- | --- | --- | ---: |
| Particle run 1 | **PASS** — repeats 2/2 cached, keep-warm 1/2, resume hit | **FAIL** — baseline 1/2, round 1 2/2, round 2 2/2, controls 0/2 | $0.00111 |
| Particle run 2 | **FAIL** — repeats 1/2 cached, keep-warm 1/2 | **FAIL** — baseline 2/2, round 1 2/2, round 2 1/2, controls 0/2 | $0.00123 |
| Morph run 1 | **FAIL** — repeats 1/2 cached, keep-warm 0/2 | **FAIL** — baseline 1/2, round 1 0/2, round 2 0/2, controls 0/2 | $0.00078 |

The independent-prefix check did not pass in any job, though for
different reasons. Particle run 1 met both concurrent rounds (2/2,
2/2) but missed one serial baseline repeat (1/2). Particle run 2 hit
both baselines (2/2) and round 1 (2/2), but round 2 was 1/2. Morph
missed both concurrent rounds (0/2, 0/2) after one baseline hit. The
concurrent-round part was met once (Particle run 1, two sessions; the
full four-session criterion was not run), but the provider-check's
complete independent-prefix check — baseline plus both rounds — was not
passed. Particle's exact repeats were 2/2 and then 1/2. A separate
direct probe, outside the provider-check, saw the same intermittency: Particle's immediate and 3-second repeats hit 2/2,
while a later concurrent pair hit 0/2; Morph's immediate repeats hit
0/2.

The provider-check rightly labels each miss **unverified, not
unsupported**: a single run can miss for timing or cache-propagation
reasons, and neither host is shown to lack a cache. But the result is
also not a pass. The correct reading is **cache reuse is real,
measurable and did not produce a clean independent-prefix pass**, and
the plan's rule that one run is unverified held in practice.

**What this does and does not establish.** It establishes the region
403, the exact pin on the global domain, the generation audit fields,
the presence of cache telemetry, and the observed cache counts. It does
not establish training, retention or subprocessor geography; it does
not establish any US in-region processing; it does not run the
4-session stress, an agent turn, the miss alarm, the cold-cache
fail-closed path or any ChatGPT check. Those remain in the plan.

## 5. Safeguards in the deployed harness

### 5.1 Request accounting

- Each provider emits a `usage` event; `harness-usage--on-session-usage`
  records input, output, cache-read, cache-write, cost, list-cost,
  billing and turn
  ([`lisp/modules/harness-usage.el:1750-1770`](../../lisp/modules/harness-usage.el)).
- OpenRouter returns `usage.cost` when the body asks for usage; that
  number is recorded as cost. If it is absent, the model-level price is
  used, which can understate a pinned input (above).
- ChatGPT returns `cost 0.0`/`subscription`; list cost is priced from
  the catalogue for display.
- **Boundary:** a stream that fails before its usage object is recorded
  has no usage row, and a retried step can have been billed for the
  discarded partial answer. Provider billing can exceed recorded usage
  for failures, cancellations and retries. The verification plan must
  compare provider-side spend with the harness's rows.

### 5.2 Context and cold-cache fail-closed

| Mechanism | Setting | Behaviour |
| --- | --- | --- |
| New-conversation gate | `harness-cowboy-new-conversation-limit` 100,000 | A forked/resumed session whose first message would send ≥100k uncached asks, or takes the default. |
| Cold-cache gate | `harness-cowboy-ask` t, default `transcript` | Asks; non-interactive or "never ask" writes a transcript, no model request. |
| Compaction warmth | `harness-compaction--estimate-summary` `:cached nil`; `harness-compaction-request-warm-p` | A model-written summary/brief is made only when its own request is cached; the estimate always says nil, so automatic compaction becomes a transcript. |
| Supervisor fork | `harness-supervisor-fork-limit` 10,000 | A fork step over the limit, or of unknown size, fails before a worker or request exists; a fresh step is the fallback. |
| Shared seeds | removed | No seed module; the architecture records 73/73 cold ChatGPT fork first requests and the DeepSeek seed misses. |

These are real protections, but they are **synthetic-verified** (unit
tests with provider spies), not live-verified against OpenRouter. The
live evidence in the repository is from DeepSeek direct and from the
historical incidents, not from an OpenRouter host.

### 5.3 Cache-miss alarm: what it proves and what it does not

- It alerts when a request reads less than
  `harness-cache-health-threshold` (0.99) of the **previous** prompt,
  for 2 consecutive requests, with at least 20,000 previous tokens, at
  most once per 300 seconds
  ([`lisp/modules/harness-cache.el:456-490`](../../lisp/modules/harness-cache.el),
  [`539-585`](../../lisp/modules/harness-cache.el)).
- **Real incident (E3):** `t-iizjs8ot` found two live "Prompt cache
  miss" hints (57.8k and 67.1k tokens re-sent) caused by a screenshot
  tool overwriting a file the model had already read: the transcript
  kept only the path, so the next request re-read new bytes in an old
  result. The fix keeps a content-addressed snapshot of tool-result
  images; merged as `163293d`, with a design note at
  [`docs/design/tool-result-image-snapshots.md`](../design/tool-result-image-snapshots.md).
- **Known false-positive mechanisms:**
  - block granularity: the threshold is 99% of the previous prompt, but
    providers cache in blocks (1,024 tokens on some routes); a 20k
    prompt can legitimately read ~95% and alert;
  - provider routing: without `session_id`, a request can move hosts
    before the first hit, or after a 60-minute sticky expiry; that is a
    real miss but not a harness bug;
  - growth: a request that adds a large tool result while the cache
    serves the prefix should read 1.0 by the definition, but a provider
    that rounds the boundary can read less.
- **Blind spot:** if the provider reports no `cached_tokens`, no ratio
  is emitted and the alarm cannot fire. The harness treats a missing
  cache field as unknown, not zero; provider-check reports "unverified"
  rather than "unsupported" in that case.
- An alert during the ChatGPT cleanup session (`d20d0017`) showed "89%
  cached · 14 calls · 1.08M tokens re-sent". That is an observation, not
  a root cause; it is the kind of alert the verification must classify
  (block rounding vs. routing vs. changed tool result) before treating
  it as a provider defect.

### 5.3b Prefix and serving-host diagnostics (implemented 2026-11-09)

The 2026-11-09 revision adds a content-free diagnostic that the 2026-11-08
assessment lacked: every OpenAI-compatible attempt (OpenRouter/DeepSeek)
and every ChatGPT Responses attempt now logs, before it is sent, a
keyed chain of checkpoints over the **final wire body** -- model,
settings, leading system messages, tool schema and each message in
request order -- and, when it ends, what the response itself said
answered it.

- **Source:** [`lisp/modules/harness-provider-diagnostics.el`](../../lisp/modules/harness-provider-diagnostics.el),
  called from [`harness-provider-openai.el:1101`](../../lisp/modules/harness-provider-openai.el)
  and [`harness-provider-responses.el:1509`](../../lisp/modules/harness-provider-responses.el).
  Design and reading instructions:
  [`docs/design/provider-diagnostics.md`](../design/provider-diagnostics.md).
- **What a preserved prefix proves:** `prefix=appended` with
  `preserved=N` says every checkpoint of the previous request is
  unchanged in the new chain. It **does not** prove the provider kept
  or served the cache. A `prefix=identical` request with
  `cache-read=0` is evidence *against* the provider serving that prefix
  from cache (or for a different host/shard); it is not proof of which.
- **Serving host:** `provider=` and `served-model=` are filled only when
  the response body supplies them (OpenRouter's `provider`,
  `openrouter_metadata.provider_name`, or the ChatGPT response object's
  `model`); missing reads `unknown`. The configured endpoint, dialect
  and host are logged separately as `configured=`, `route=`, `host=`.
  A provider name is still not geography, a training policy or a stable
  cache shard.
- **Cache and cost:** `cache-read=`, `cache-write=`, `output=`,
  `cost=` and `cost-source=` read the raw usage object; a missing field
  is `unknown`, never zero. `cost-source=provider` is provider-reported;
  `cost-source=plan` is a subscription's zero; no list-price estimate is
  substituted.
- **Cold markers:** `expected-cold=` labels `compaction`, `first`
  (restart or new), `model-change`, `settings-change`,
  `system-change`, `tools-change`, `prefix-diverged`, `idle` or `warm`
  as the session state and checkpoint comparison support. These are
  predictions, not evidence; the response line repeats the label and
  gives the provider's actual cache reading beside it.
- **Privacy:** HMAC-SHA256 under a 32-byte key from `/dev/urandom`
  (state file 0600, never logged, per-session subkey, rotation visible
  as a changed key id); no prompt, tool text, body, error text or key in
  a line; 2,000-character line cap, 16 checkpoints, 16 MiB hashing cap.
  If no secure key can be made, hashing is off and says so once. There
  is no unsalted fallback.
- **Generation lookup:** not performed. The response id is retained and
  `generation=` is filled only for OpenRouter's `gen-` ids; `data_region`
  remains unknown. This revision adds no network request.
- **History:** the 80k/zero alternation that motivated this is **not**
  classified by the change. §5.3's known causes remain candidates; the
  diagnostics make the next occurrence decidable from the log.

This closes the "generation-id retention absent" observability gate in
the plan, but **not** the host/region audit gate, the pin/fallback code
gates, or any policy gate. The readiness verdicts in the Short answer
are unchanged.
- **Seen running:** [`demo/provider-diagnostics/demo.sh`](../../demo/provider-diagnostics/demo.sh)
  sends four attempts through the real provider path with a faked HTTP
  layer and prints `first`, `identical`, `appended` and
  `diverged at=3:tools` with the leak check; one run's output is
  [`docs/evidence/provider-diagnostics/demo-run.txt`](../evidence/provider-diagnostics/demo-run.txt)
  and a picture in a live frame is
  [`demo-frame.png`](../evidence/provider-diagnostics/demo-frame.png).

### 5.3c The 2026-11-13 zero-cache calls, and what replay protects

This revision adds the verified evidence below and corrects an overclaim.
It changes no verdict.

**Verified observation (E3).** From `usage.db`, Android session
`3fd8ccb5-25d4-438d-bdb6-f3f20d7f5938`, model `chatgpt:gpt-6.1-sol`,
five consecutive calls on 2026-11-13:

| UTC time | input | cache-read | row |
| --- | ---: | ---: | --- |
| 08:10:43.818631 | 444,160 | **0** | 364337 |
| 08:11:20.419487 | 444,907 | 430,592 | — |
| 08:15:47.168310 | 455,112 | 428,672 | — |
| 08:18:02.655925 | 455,796 | **0** | 364440 |
| 08:19:55.192477 | 458,037 | 359,296 | — |

**What this proves and what it does not.** It proves that two calls in
the same session, minutes apart, read no cached tokens at all while
their neighbours read 350k-430k. It does **not** prove the cause. Three
very different explanations fit these five rows equally well:

1. the request prefix the harness sent changed (client drift);
2. the provider evicted, did not retain, or served from a different
   cache shard or host (provider-side);
3. the call was cold for a reason the harness has no field for.

The historical final-wire requests were **not archived**, and
`harness-replay.el` keeps only the latest snapshot per session
(`sessions/ID.request.jsonl`, overwritten by each
`replay/save-request`), so these five requests can no longer be
compared to each other. That is precisely why the diagnostics of 5.3b
log a content-free fingerprint **per attempt** instead of one mutable
snapshot: the next occurrence will be decidable, and these five are
not.

**Correction to the earlier framing.** The quota investigation of
the same window (`t-sp1j60ii`) reports 149,402,113 uncached input
tokens across the 01:00-03:20 EST burst, of which the ChatGPT-plan
route read 186,223,616 of 335,625,729 input tokens from cache (55.5%).
That 149.4M is **not** attributable to prefix breakage, and must not be
read as such. It is the sum of:

- genuinely fresh suffixes (every appended message, tool result and
  turn is uncached by construction);
- cold sessions and cold first requests (the 73/73 fork measurement in
  section 3.4 is the same effect);
- any provider-side eviction or shard move;
- any client-side prefix change.

The ledger has no field that separates those, and the requests are
gone. A tail append does not by itself invalidate the prefix before it:
the provider may still serve every earlier token from cache, which is
exactly what a partial `cache_read` below the new total looks like.
Reading 149.4M as "prefix breakage" would be an unsupported inference.

**What replay actually guarantees today (E1, code).** `harness-replay`
is **best-effort reuse, not immutable provider-ready request
protection**:

- It stores a **provider-neutral** payload - system prompt, tools and
  messages - and explicitly not the provider's own body
  ([`lisp/modules/harness-replay.el:27-36`](../../lisp/modules/harness-replay.el)).
  The provider's body is reconstructed afterwards by
  [`harness-responses--body`/`--input`](../../lisp/modules/harness-provider-responses.el),
  so any change in that reconstruction changes the wire prefix while
  the stored payload stays byte-identical.
- `replay/prefix` returns nil - silently falling back to a **fresh
  render** - on a model, thinking, system, tools, builtin-tools, node
  or digest mismatch ([`248-298`](../../lisp/modules/harness-replay.el)).
  The fallback is the correct behaviour for safety; it is not a
  guarantee that the prefix was preserved.
- `replay/save-request` **skips** any request whose messages contain
  image bytes (`:data` anywhere) and any request over 16 MiB, keeping
  only the latest snapshot
  ([`227-240`](../../lisp/modules/harness-replay.el),
  [`300-333`](../../lisp/modules/harness-replay.el)).
- Compaction drops the snapshot
  ([`384-392`](../../lisp/modules/harness-replay.el)).
- `harness-agent--replay-messages` returns the freshly rendered request
  when there is no prefix
  ([`1516-1532`](../../lisp/modules/harness-agent.el)), and
  `harness-agent--step` saves **before** the provider call, with
  recoverable errors ([`1594-1596`](../../lisp/modules/harness-agent.el)).
- The Responses route remembers reasoning and tool items in a table
  capped at 1,000 per session
  ([`harness-provider-responses.el:213`](../../lisp/modules/harness-provider-responses.el));
  a pruned response is rebuilt from blocks, which is a different
  prefix, and a message whose call ids are no longer remembered
  reconstructs differently. Old-image pruning can likewise rewrite
  history.

So the harness today reduces *some* client-side drift and can say
nothing at all about provider-side misses. It does not freeze the final
wire body, does not fail closed on an unexplained mutation, and has no
explicit cache generation.

**No new spend.** This revision made no provider request: the five
rows above are the quota task's verified ledger evidence, re-read
from `usage.db`, not a new run. No plan quota and no OpenRouter
credit was spent to produce it, and no bounded live test is
proposed until the prefix freeze of `t-sp1j60ii` lands and its
offline invariants are validated.

**Ownership.** The implementation that would close this - freeze the
final provider-ready components after rendering, reuse the exact
ordered content plus an append-only suffix, key by model/account/route
and an explicit cache generation, fail closed at the transport boundary
naming the first divergent component, require recorded resets
(compaction, model/system/tools change, redaction), handle images as
immutable content-addressed assets, and keep per-request content-free
fingerprints - belongs to **`t-sp1j60ii`** (the quota/cache
implementation owner). This task owns the assessment and the
verification gates that consume its commit and test artifacts. No
second storage mechanism is implemented here.

### 5.4 Retry, concurrency, quota and cost bounds

| Bound | Value | Source |
| --- | --- | --- |
| HTTP retries per request | 3 (`harness-http-max-retries`) | [`lisp/harness-http.el:61-68`](../../lisp/harness-http.el) |
| Step retries per turn | 3 (`harness-retry-max-attempts`); 1s doubling, 30s cap | [`lisp/modules/harness-retry.el:49-68`](../../lisp/modules/harness-retry.el) |
| Provider-check requests per job | 64; 512 output tokens per request; 3 checks at once; 12 requests at once; 900s total | [`lisp/modules/harness-provider-check.el:117-190`](../../lisp/modules/harness-provider-check.el) |
| Provider-check independent prefix sessions | 4 normal, 12 stress; each has its own prefix and session | [`lisp/modules/harness-provider-check.el:150-170`](../../lisp/modules/harness-provider-check.el) |
| Fallback | nil by default; quota/billing only; no fallback on a rate limit | [`lisp/modules/harness-fallback.el:57-87`](../../lisp/modules/harness-fallback.el), [`204-224`](../../lisp/modules/harness-fallback.el) |
| Keep-warm cap | computed from cache-read vs uncached cost, default 12 when unpriced | [`lisp/modules/harness-cache-warm.el:152`](../../lisp/modules/harness-cache-warm.el), [`254-280`](../../lisp/modules/harness-cache-warm.el) |
| Task concurrency | project slots, `harness-tasks-max-running` (nil = no limit) | [`lisp/modules/harness-tasks.el:378`](../../lisp/modules/harness-tasks.el) |

There is no per-provider global request-rate limiter; concurrency is
whatever the sessions and tasks run, bounded by the HTTP layer's
connection behaviour, retries and the provider-check job's own slots. A
12-session stress test is the only place the harness deliberately puts
12 requests in flight at once.

## 6. Evidence matrix

Legend: **E0** advertised, **E1** code, **E2** synthetic, **E3** live,
**E4** contract. "Verified?" means E4+E3 for the property, not a green
check.

| Claim | Code | Synthetic | Live | Deployed | Verified? |
| --- | --- | --- | --- | --- | --- |
| ChatGPT OAuth and `chatgpt.tokens.use.direct` gating | `harness-chatgpt-plan.el:470-511`, `877-925` | plan tests | none in this task | yes | E1/E2, no live |
| ChatGPT Responses contract, unsupported fields | `harness-provider-responses.el:25-45`, `986-1015` | responses tests | historical live turns | yes | E1/E2; preview E0 |
| ChatGPT numerical quota | `harness-provider-responses.el:1561-1590` | quota tests | none | yes | **No** — no endpoint |
| ChatGPT plan accounting cost 0 | `harness-provider-responses.el:1290-1325` | tests | historical | yes | E1; provider's plan meter is opaque |
| ChatGPT output cap | `harness-provider-responses.el:1008-1015` | test asserts dropped | none | yes | **No** — cap cannot be sent |
| ChatGPT keep-warm full re-sends | `harness-cache-warm.el:109`, `152`, `254-280` | cache-warm tests | none specific | yes | E1/E2; live effect unmeasured |
| ChatGPT data sovereignty | out of scope (2026-11-08 review) | none | none | n/a | **Not assessed** — only cache is in scope for non-OpenRouter providers |
| OpenRouter global default, fallbacks, data collection | `harness-provider-openai.el:750-783`, `132-135` | body tests | OpenRouter docs; 2026-11-09 direct probe | yes | E1/E0; no request-level proof |
| OpenRouter exact pin / ZDR / region | not implemented | none | 2026-11-09 direct probe with a test-only pin | no (proposal) | **No** — API pin works; harness has none |
| OpenRouter US in-region | not implemented | none | 2026-11-09 `us` request: 403 plan gate | no (proposal) | **No** — current account cannot use it |
| OpenRouter no-training per provider | not implemented | none | provider metadata; Relace served under ZDR/deny | no | E0; provider policies conflict; metadata not proof |
| OpenRouter host/region audit | `harness-provider-diagnostics.el` (observed provider/model only when supplied); no `/generation` lookup | diagnostics tests 2026-11-09 | 2026-11-09 generation row: `provider_name`, `data_region: global` | **not deployed** (branch only) | E1/E2; `data_region` still unknown |
| Prompt-prefix comparability | `harness-provider-diagnostics.el:395-580` (HMAC chain, checkpoints, append/divergence) | 30 diagnostics tests, incl. Unicode, tool order, wire order, concurrency | none live | **not deployed** (branch only) | E1/E2 |
| Cache reading is not a prefix claim | diagnostics response line (`cache-read` raw, `prefix=` separately) | no-leak and unknown-field tests | none | **not deployed** | E1/E2; the log does not label a cause |
| OpenRouter actual cost recorded | `harness-provider-openai.el:888-955` | usage tests | DeepSeek direct; OpenRouter 2026-11-09 | yes | E1/E2/E3 for completed calls |
| Cache-miss alarm | `harness-cache.el:456-490`, `539-585` | cache tests | `t-iizjs8ot` real incident | yes | E3 for one cause; heuristic |
| Independent-prefix self-test | `harness-provider-check.el:1569` | fake-provider tests | DeepSeek direct 4/4, 12/12, $0.0055; OpenRouter 2026-11-09 partial | yes | E3 DeepSeek direct; OpenRouter **not verified** |
| OpenRouter cache checks | `harness-provider-check.el:1152`, `1569` | fake-provider tests | 2026-11-09: Particle 2 runs, Morph 1 | yes | E3; intermittent, no strict PASS |
| Cold-cache fail-closed | `harness-compaction.el:641-660`, `1411`; `harness-cowboy.el:243-289` | provider spies | none | yes | E1/E2 |
| Supervisor fork fail-closed | `harness-supervisor.el:363`, `2086` | supervisor tests | historical measurement | yes | E1/E2/E3 |
| Fallback/retry | `harness-fallback.el:57-87`, `204-224`; `harness-retry.el:49-68` | fallback/retry tests | none for OpenRouter | yes | E1/E2 |
| Budgets | `harness-usage.el:1911` | usage tests | historical | yes | E1/E2; blind to plan cost |
| Provider-check quota check passes zero windows | `harness-provider-check.el:2501-2530` | check tests | none | yes | E1; overstates |

## 7. Prior tasks, pending work and what they prove

### 7.1 Prior tasks this assessment used

| Task | What it established | Evidence class | Deployment |
| --- | --- | --- | --- |
| `t-2xh8jeni` — context blowup / cache bomb | The 80%-of-$100 ChatGPT quota blowup; shared seeds removed; supervisor fork limit 10,000; cold compaction gated; 73/73 ChatGPT forks read 0 cached tokens (5.8M) | E3 (historical) + E1/E2 | merged (`0d02ee2`) |
| `t-ivw4aq22` — cache self-test | Independent **distinct** primed prefixes, each in its own session, reused concurrently; not a shared prefix. Live DeepSeek direct: 4/4 normal, 12/12 stress, controls 0, 59 requests, ~$0.0055 | E3 (DeepSeek direct) + E2 | merged (`67f5e02`, `9d099d4`) |
| `t-63x9wubf` — observed cache-hit rate | The conversation cache-rate UI reads observed hits; it is a display of provider telemetry, not proof of identity or policy | E1/E2 + some E3 | merged (`78697fd`) |
| `t-c9uk6s8z` — repeated compact prompt | The compaction menu prompt is shown once; a UI fix, not provider evidence | E1/E2 | merged (`f86bb0c`) |
| Quota history — `b7cb8d7`, `a9a83f3`, `57a4882`, `37f26ed`, `e214e0a`, `02f7754`/`5fdbc9e` | ChatGPT plan quota is reported as a subscription with a usage link; Codex CLI is optional/informational; no numerical windows | E1/E2, no E4 | merged |
| `t-iizjs8ot` — cache misses | A real cache-miss cause: a changed screenshot in an old tool result; content-addressed image snapshots; the alarm itself is a heuristic | E3 + E1/E2 | merged (`163293d`) |
| 2026-11-13 zero-cache calls | Two `cache_read=0` calls among five `chatgpt:gpt-6.1-sol` calls in one session, 444k-458k input each; cause unknown | E3 (usage.db rows 364337, 364440) | §5.3c; the final-wire requests were not archived |
| Client prefix preservation | `harness-replay` keeps a provider-neutral latest snapshot, skips images and >16 MiB, and silently falls back to a fresh render on any mismatch | E1 code | §5.3c; not an immutable provider-ready freeze |

**What these do not prove:** the historical independent-prefix result is
DeepSeek **direct**, not OpenRouter; the cache-rate UI reads whatever
the provider reports; the quota work reports the shape of a plan, not
its amount; and none of the tasks made a request-level US/China or
training determination. The 2026-11-09 smoke (§4.8) is the first
OpenRouter live test; it is a scaled-down Stage 2, not a pass.

### 7.2 Pending and unmerged work (not deployed)

| Task | State | What it changes | Effect on this assessment |
| --- | --- | --- | --- |
| **this task** — provider diagnostics | **on this branch, for review** | Content-free prefix and response diagnostics for OpenRouter/DeepSeek and ChatGPT; no route or accounting change | Not deployed; the log exists only after this branch merges. Its tests are offline; the live stages below still need their own runs. |
| `t-sp1j60ii` — overnight quota and cache | review (report), implementation pending | The 2026-11-13 quota report; owns the immutable provider-ready prefix freeze | This task's verification gates consume its commit and tests; nothing here implements it. |
| `t-z4cwev5l` — uncached reads and compaction menu | unmerged, needs input | Large compaction-menu/UI rewrite, "always compact" paths | Not deployed; do not cite its UI as current behaviour. |
| `t-ddgc6w58` — missing auto-compaction | unmerged, review | "Always compact" and UI/demo changes | Not deployed; no effect on the cold-summary gate. |
| `t-zi2s9b0o` — stop tasks using ChatGPT | review, no code diff | Operational model switch | Evidence of quota exhaustion; not a fix. |
| `t-y5x3r7g4` — test helper load fix | review | Fixes a broken update commit | Unrelated. |
| `t-8a7wk4e1` / quota queue work | merged | Quota waits, pause-all, cheap-model branches | In baseline; does not add numerical ChatGPT quota. |

A previous plan (session `16143dce`) proposed exposing OpenRouter key
credits through `GET /api/v1/key` behind a `:quota` capability. There is
no such code in `5022581`; `harness-openai--capabilities` for OpenRouter
has no `:quota`. Do not count credit telemetry as available.

## 8. Decisions only Noah can make

1. **"No China" scope:** prompt/completion processing only, or all
   account, billing, log and subprocessor data? The first can be met
   with US in-region plus a provider confirmation; the second is not
   verified for any endpoint today.
2. **Storage:** is ZDR required, or is 30-day retention acceptable? This
   decides Morph versus Particle.
3. **Flex tier:** is a lower-priority flex endpoint acceptable for a
   cheap cache-heavy loop, or is standard tier required?
4. **ChatGPT plan spend:** what request/output allowance, and is a
   client-side output stop acceptable before any smoke?
5. **Written confirmation:** will Noah ask OpenRouter/Morph/Particle for
   a DPA or written statement, or accept published policies as the
   standard?
6. **Model:** 1017 is a 2026-10-17 snapshot; is that the version to
   verify, or the older `deepseek-v4.1-flash` (2026-09-10)?
7. **US in-region plan:** upgrade OpenRouter to Business/Enterprise, or
   accept that the current account cannot satisfy the geography
   constraint? The 2026-11-09 smoke measured the 403; nothing else can
   make `us.openrouter.ai` work on this key.
8. **Cache reliability:** is intermittent reuse acceptable, or must the
   complete independent-prefix check pass? Particle met both concurrent
   rounds in run 1 but missed a baseline; no job passed the complete
   check.

## 9. Sources

### 9.1 Internal

| Path | Lines | What it supports |
| --- | --- | --- |
| `lisp/modules/harness-provider-openai.el` | 132-135 | Default OpenRouter base URL |
| | 214-224 | OpenRouter capabilities: no `:quota`, no cache TTL |
| | 313-319 | OpenRouter model pricing mapping, cache-write defaults to input |
| | 750-783 | Request body: no provider object, usage include, max tokens |
| | 888-955 | Usage event, cache fields, plan vs API billing |
| | 1047-1054 | HTTP retry and plan headers |
| | 1142-1160 | Plan status from quota |
| `lisp/modules/harness-provider-responses.el` | 25-45 | SIWC contract and unsupported fields |
| | 986-1015 | `max_output_tokens` dropped |
| | 1019-1042 | Quota/auth/rate-limit error kinds |
| | 1290-1325 | Usage event, cost 0, subscription |
| | 1561-1590 | Quota: subscription, no windows, usage URL |
| | 1723-1725 | Provider capabilities |
| `lisp/modules/harness-chatgpt-plan.el` | 470-511 | Account status, plan-usage scope |
| | 877-925 | Scope parsing and consent message |
| `lisp/modules/harness-cache-warm.el` | 14-84 | Keep-warm design and cost reasoning |
| | 109, 152 | Default on; 12 refreshes when unpriced |
| | 206-238 | What cannot be warmed |
| | 254-280 | Refresh cap formula |
| `lisp/modules/harness-compaction.el` | 205-248 | Default kind, warmth gate |
| | 641-660 | Summary estimate `:cached nil` |
| | 1411, 1442 | Request warm predicate, effective kind |
| `lisp/modules/harness-cowboy.el` | 129-188 | Default transcript, ask, new-conversation limit |
| | 243-289 | New-conversation and cold-cache predicates |
| `lisp/modules/harness-supervisor.el` | 363-380 | Fork limit 10,000 and fail-closed intent |
| | 2086-2095 | Past-limit predicate |
| `lisp/modules/harness-cache.el` | 456-490 | Threshold, min context, streak, cooldown |
| | 539-585 | Alert accounting |
| `lisp/modules/harness-provider-check.el` | 117-190 | Request/output/concurrency/time bounds |
| | 2501-2530 | Quota check accepts zero windows |
| | 2816-2937 | Per-check request counts |
| | 2962-3005 | Estimate: 4,096 input, 512 output, model prices |
| | 1569 | Independent-prefix experiment |
| `lisp/modules/harness-usage.el` | 1289-1300 | Subscription has no cost report |
| | 1750-1770 | Usage recording and budget check |
| | 1911 | Hard budget check |
| `lisp/modules/harness-fallback.el` | 57-87 | Default nil, retry-after |
| | 204-224 | Quota vs billing classification |
| | 537-560 | Candidate choice |
| `lisp/modules/harness-retry.el` | 49-68 | 3 attempts, backoff |
| `lisp/harness-http.el` | 61-68 | 3 HTTP retries |
| `docs/architecture.md` | 10156-10176 | Seeds removed; 73/73 ChatGPT forks cold; DeepSeek seed misses |
| `docs/design/provider-check-cache-evidence.md` | whole | Independent-prefix experiment design |
| `docs/design/tool-result-image-snapshots.md` | whole | Cache-miss root cause and fix |
| `docs/design/conversation-cache-rate.md` | whole | Observed cache rate UI |

### 9.2 External (retrieved 2026-11-08, rechecked 2026-11-09 UTC)

The 2026-11-09 observations in §4.8 are **E3 from this task's own
requests**, not external citations. The endpoint prices, slugs and
`supports_implicit_caching` flags above were re-fetched from the 1017
endpoints URL on 2026-11-09 and matched the 2026-11-08 values.

| Source | What it supports |
| --- | --- |
| [OpenRouter provider selection](https://openrouter.ai/docs/guides/routing/provider-selection) | Defaults `allow_fallbacks: true`, `data_collection: "allow"`; `only`, `order`, `zdr`; Data Policy tag is not definitive |
| [OpenRouter US in-region routing](https://openrouter.ai/docs/guides/features/in-region-routing) | Business/Enterprise; regional domain; fail-closed; what stays outside the region |
| [OpenRouter ZDR](https://openrouter.ai/docs/guides/features/zdr) | Per-request/account ZDR; Safety Retention eligibility; endpoint list URL |
| [OpenRouter prompt caching](https://openrouter.ai/docs/guides/best-practices/prompt-caching) | Implicit caching, sticky routing, `session_id`, 60-minute expiry, fallback loses cache |
| [OpenRouter generation API](https://openrouter.ai/docs/api/api-reference/generations/get-generation) | `provider_name`, `data_region`, `total_cost`, `upstream_inference_cost`, `cache_discount` |
| [OpenRouter provider catalogue](https://openrouter.ai/api/frontend/v1/all-providers) | HQ, datacenters, training/retention/safety metadata |
| [OpenRouter 1017 endpoints](https://openrouter.ai/api/v1/models/deepseek/deepseek-v4.1-flash-1017/endpoints) | Exact endpoint prices and slugs |
| [OpenRouter ZDR endpoint list](https://openrouter.ai/api/v1/endpoints/zdr) | ZDR-eligible endpoints |
| [OpenRouter US model list](https://openrouter.ai/api/v1/models?region=us) | US in-region eligibility and prices |
| [OpenRouter privacy](https://openrouter.ai/privacy) | No OpenRouter training; provider-side training possible; transfers |
| [OpenRouter terms](https://openrouter.ai/terms) | Provider training caveat; logging/retention |
| [OpenAI SIWC overview](https://developers.openai.com/siwc/token-sharing-open-source) | Open-source/local app scope; host id; preview |
| [OpenAI SIWC preview limitations](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations) | `max_output_tokens` unsupported; Responses requirements |
| [OpenAI SIWC errors](https://developers.openai.com/siwc/token-sharing-open-source/errors-and-recovery) | Quota codes; no reset time; no silent billing switch |
| [OpenAI API data](https://developers.openai.com/api/docs/guides/your-data) | Checked; not used as a ChatGPT readiness condition (data sovereignty out of scope) |
| [ChatGPT usage](https://chatgpt.com/settings/usage) | Official plan usage view |
| [Morph privacy](https://www.morphllm.com/privacy), [terms](https://www.morphllm.com/privacy/tos) | No training; 30-day paid retention; enterprise ZDR; transfers |
| [Particle privacy](https://particle.ai/privacy/), [terms](https://particle.ai/terms/) | ZDR default; no training unless opt-in; US processing |
| [Wafer terms](https://www.wafer.ai/terms) | Customer no-competing-training; processing licence; no provider no-training statement |
| [OpenInference privacy](https://www.openinference.ai/privacy), [terms](https://www.openinference.ai/terms) | ZDR/no training vs training opt-out contradiction |

**Blocked pages:** `help.openai.com` (Cloudflare challenge) and
Morph's HTML page (bot checkpoint) were retrieved through their
Markdown/reader equivalents where possible; Relace's policy link was
404. These are marked unverified above, not assumed.

## 10. What this document does not establish

- It does not establish that any endpoint **will** process a request in
  China; it establishes that the deployed request and the current
  account cannot prove it will not. The 2026-11-09 smoke adds a hard
  region gate: `us.openrouter.ai` returns 403 on this plan.
- It does not establish that OpenRouter's `zdr: true` is ineffective;
  it establishes that its classification conflicts with one provider's
  own current policy and needs confirmation.
- It does not establish a dollar cost for ChatGPT plan usage; no such
  mapping exists.
- It does not assess data sovereignty for ChatGPT. That dimension is
  explicitly out of scope for non-OpenRouter providers; only cache
  behaviour is assessed there.
- The live OpenRouter smoke (§4.8) is E3 for the specific requests made
  on 2026-11-09: the region 403, the pinned host identity, the
  `data_region: "global"` value and the cache counts. It is not a policy
  verdict and not a full Stage 2 run; one run of a cache check is
  unverified by the plan's own rule.
- It does not claim a ChatGPT live request was made. No ChatGPT account
  was used and no plan quota was spent.
- It does not change, enable or disable any provider.

