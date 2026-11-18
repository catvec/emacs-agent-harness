# Provider diagnostics: content-free prompt prefixes and observed serving

**Status: implemented on `task/provider-readiness-assessment-and-jibzilj2`,
2026-11-09, extended 2026-11-14, for review; not merged and not
deployed.** No paid request
was made for this revision and no live route, credential or privacy
setting was changed.

## The question this answers

A warm task alternated around 80k cached input tokens and zero within
seconds, with no idle period and no compaction hint. Two very different
things produce that reading:

1. the request prefix changed -- an appended message re-rendered, a
   tool schema, a system prompt, the model or a cache-affecting setting;
2. the request was fine, but OpenRouter routed it to another serving
   provider, another cache shard, or a provider whose cache did not
   hold.

The harness log recorded neither the prefix nor the serving host. The
turn could describe the symptom and nothing about its cause. This
change adds the missing evidence; it does not decide which cause any
past incident had, and the readiness report keeps saying so.

## What is logged

Two lines per completion attempt, at `info` by default:

- **Request**, before the request is sent, from the same final body
  that goes on the wire: the model, a canonical settings record, the
  leading system messages, the tool schema and every message in order,
  reduced to a versioned chain of HMAC-SHA256 checkpoints with
  cumulative byte lengths.
- **Response**, once when the attempt ends: the HTTP status, the
  response id and any request id the headers supplied, the observed
  provider and model only if the response named them, the raw usage
  readings, provider-reported cost and its source/currency, the
  expected-cold label, and the outcome (ok/error/cancelled) with the
  failure kind, retry-after and HTTP retry count.

A line is bounded to `harness-provider-diagnostics-max-line-chars`
(2,000) and the existing harness log keeps at most 5,000 lines / 4 MiB.
A request body over `harness-provider-diagnostics-max-bytes` (16 MiB) is
not hashed; the line says `prefix=skipped-large`.

Example, from the offline test fixture (synthetic prompt text, one
real key id from a throwaway state directory):

```
provider-diagnostics: request attempt=pd-b-…-2 session=demo boot=b-… model=openrouter:deepseek/deepseek-v4.1-flash-1017 configured=… route=openrouter host=openrouter.ai key=… scope=… v=1 chunks=7 bytes=433 prefix=appended preserved=5 at=4:message/1 expected-cold=warm prev=pd-b-…-1 cps=0:model@46:…,1:settings@182:…,2:system/0@218:…,3:tools@323:…,4:message/1@357:…,6:message/3@433:… final=6@433:…
provider-diagnostics: response attempt=pd-b-…-1 session=demo … status=200 response-id=gen-demo generation=gen-demo request-id=req-demo provider=Morph served-model=deepseek/… outcome=ok stop=end-turn error-kind=unknown … prompt=100 input=60 cache-read=40 cache-write=unknown output=5 context=100 cost=0.00042 cost-source=provider currency=USD billing=unknown expected-cold=first prefix=first
```

`provider=` is what the response itself reported. It is never inferred
from the configured endpoint, and `provider_name` is not read as a
geography, a training policy or a cache-shard identity.

## The serialization and why the prefix is comparable

A whole-request digest changes on every appended turn, so it cannot show
a preserved prefix. The module hashes a **chain of segments**:

```
version "hpd1"
state0 = HMAC(subkey, "harness-provider-diagnostics/1\0init")
stateN = HMAC(subkey, "chunk\0" TAG "\0" LEN "\0" hex(stateN-1) BYTES)
```

- `BYTES` is the exact JSON encoding of the body value (`model`,
  the settings list, one message, the tools array, or a Responses input
  item). The settings list includes the top-level key order and every
  non-message field, JSON-encoded, so a reordered field or a changed
  `max_tokens`/`reasoning`/`stream_options` is a visible change.
- TAG and LEN make the boundaries unambiguous: `("ab","c")` and
  `("a","bc")` do not hash alike, and a moved boundary is visible even
  when the concatenated text is the same. Unicode is encoded as UTF-8
  bytes by `harness-json-encode`; a test covers `é`/`𝄞` and the
  boundary split.
- The diagnostic order is **model, settings, leading system messages,
  tool schema, remaining messages in request order**. This is a
  reviewed model of a cache prefix, not the provider's internal cache
  key. A provider may include fields the harness cannot see or
  serialize them differently.
- Checkpoints are selected from the structural boundaries (model,
  settings, every leading system message, tools, the final chunk), the
  previous attempt's final chunk when it fits, and a geometric spread
  through the messages. At most 16 by default; always sorted and always
  including the final chunk.
- The comparison names exactly what it can prove: `identical` (same
  final chunk and index), `appended` (the previous final checkpoint is
  unchanged in the new chain and the new request is longer),
  `diverged` (a common checkpoint differs; `at=INDEX:TAG` is the first
  one) or `shorter`. If there is no common checkpoint, `unknown`, never
  a guess. `preserved=N` counts the common checkpoints that matched.

`expected-cold=` is the request line's prediction, not evidence:
`compaction` when the session's usage says the cache was reset,
`first` when this process has no earlier attempt for the session,
`model-change`/`settings-change`/`system-change`/`tools-change` from
the first differing boundary, `prefix-shorter`, `idle` when the
session's stamp and reported TTL say the lifetime passed, else `warm`.
The response line repeats it, and reports the provider's own
`cache-read=` in the same line.

## Privacy

- **Keyed, not plain hashes.** HMAC-SHA256 under a 32-byte key from
  `/dev/urandom`; the key is never logged. A key that cannot be made
  from `/dev/urandom` disables hashing with one warning. There is no
  `random` fallback and no unsalted hash, because a guessable prompt
  behind a plain digest is a dictionary attack.
- **Key file.** `provider-diagnostics.key` in `harness-state-directory`,
  mode 0600, written atomically. It survives a restart so checkpoints
  stay comparable; the log names it by `key=` (first 8 hex of an HMAC of
  a constant) and `boot=`. `harness-provider-diagnostics-rotate-key`
  deletes it and starts a new scope; older lines are then not
  comparable and say so by their different key id. An existing but
  invalid key file disables hashing rather than silently replacing it.
- **Per-session scope.** The subkey is HMAC(master, session id),
  derived per request rather than cached, so two sessions that send the
  same text do not produce the same digests.  Within a session, restarts
  keep the scope; a session id reused later compares against its earlier
  request because the key persists.  The only per-session state kept is
  the bounded last-request table (`--max-last', 128).
- **Nothing raw.** No message text, tool name/description/schema,
  request body, error text, credential or token is logged. The tests
  put marker strings in system, user and tool content and in a tool
  name and assert that none of them, nor the key, appears in any line.
  Error lines carry only the classified kind and status; the provider's
  error text stays in the existing error path.
- **Bounded.** One request line and one response line per attempt;
  2,000-character cap; 16 checkpoints; 16 MiB hashing cap. The harness
  log's own retention bounds the rest.

## Correlation without overwriting

Every attempt gets a process-unique id (`pd-BOOT-N`). The attempt is
held by the stream, so a retry, a cancellation, or two concurrent
streams cannot overwrite another attempt's response. The response is
logged at the stream's one `finish`, so it is once. Diagnostics never
emit a usage event, never call `session/usage-add`, and never send a
request: existing accounting is untouched and cannot be double
counted. A second response call for the same attempt is a no-op.

- `http-retries=` comes from the HTTP handle and distinguishes an HTTP
  layer retry from a new step attempt.
- `error-kind=` is the provider's classification (`transport`,
  `rate-limit`, `billing`, `auth`, ...), not its message.
- A cancelled stream records `outcome=cancelled` and no usage reading.

## Usage and cost

The module reads the **raw usage object** (and the usage event only for
the DeepSeek-corrected `:input` and the plan billing) rather than
inferring:

| Field | Source | Missing means |
| --- | --- | --- |
| `prompt=` | `prompt_tokens` or `input_tokens` | unknown |
| `input=` | DeepSeek `prompt_cache_miss_tokens`, else the usage event's input, else prompt minus hits when both are numbers | unknown |
| `cache-read=` | `prompt_cache_hit_tokens` or `prompt_tokens_details/input_tokens_details.cached_tokens` | unknown, not 0 |
| `cache-write=` | `cache_write_tokens` in the details | unknown, not 0 |
| `output=` | `completion_tokens` or `output_tokens` | unknown |
| `context=` | prompt tokens | unknown |
| `cost=` | raw `usage.cost` (provider-reported) or the event's plan cost | unknown; no estimate |
| `cost-source=` | `provider`, `plan` or `unknown` | unknown |
| `currency=` | `USD` only when the provider reports a USD cost | unknown |

The distinction matters: the existing OpenAI usage event turns a hit
reading into `:cache-write 0`, which is an accounting convention, not a
provider statement. Diagnostics keeps `cache-write=unknown` unless the
provider actually reported a write. A provider cost is never replaced
by the harness's list-price estimate, and an absent cost is not zero.

## Reading it from another module

The log is for a person; other modules read the same attempt
through a content-free API rather than parsing lines.

- `harness-provider-diagnostics-session-summary SESSION` returns
  `(:attempt :at :prefix :preserved :expected-cold :configured
  :route :host :response)` for the session's last attempt, or nil
  when there is no record (unknown, never zero).
- `harness-provider-diagnostics-summary ATTEMPT` is the same for an
  attempt in hand.
- `harness-provider-diagnostics-cold-cause SUMMARY` returns the
  request line's `expected-cold` when it names a client cause
  (`first`, `compaction`, `model-change`, `settings-change`,
  `system-change`, `tools-change`, `prefix-diverged`,
  `prefix-shorter`, `idle`), `warm` when the prefix was preserved
  and no client cause was recorded, or `unknown`.  A label the
  module does not know is `unknown`, not passed through.
- `harness-provider-diagnostics-miss-cause SESSION` is that for a
  session, and is what `harness-cache`'s miss alarm says.

The `:response` plist holds the observed provider and served
model, the ids, the raw cache and cost readings with their source
and currency, and the outcome.  Missing readings are absent, not
zero.  Nothing raw is in any of it, so a caller may keep it.

The provider check consumes this to record what served its cache
probes: `harness-provider-check--serving` counts the names the
responses supplied and keeps the configured route out of them.

## What it cannot establish

- It does not prove the provider's cache key, its internal sharding, or
  that a matching checkpoint was actually cached. A matching prefix
  with `cache-read=0` is evidence *against* the provider serving that
  prefix from its cache (or for a different host/shard), not proof of
  either cause.
- It does not prove a serving provider's geography, training policy,
  retention or subprocessor. `provider=Morph` is a name; the
  assessment's sovereignty verdict stays "none verified".
- It does not perform OpenRouter's `/generation` lookup. The response id
  is retained, and `generation=` is filled only when the id has
  OpenRouter's `gen-` shape; `data_region` is not fetched. That keeps
  this revision free of a second network request per call. A bounded,
  opt-in lookup with one attempt and no polling is possible follow-up
  work, not something this revision does.
- It does not cover the Claude Code CLI provider, which keeps the
  conversation itself and reports its own `cache-stamp`; it covers the
  OpenAI chat-completions body and the Responses body (`instructions`,
  `input`, `tools`), which is what OpenRouter/DeepSeek and ChatGPT use.
  The ChatGPT provider's `response` object supplies the id and model;
  the plan's `store: false` means its cache behaviour is OpenAI's to
  keep or drop, and the log can only show the reading it reports.
- It does not log a prompt or a tool schema, so it cannot say *what*
  changed, only which boundary diverged. That is deliberate.

## Alternatives considered

- **Plain SHA-256 of the body or of each message.** Simple, but a
  guessable prompt becomes testable from the log; rejected for the
  keyed HMAC.
- **One digest per request.** Changes on every append and cannot show a
  preserved prefix; rejected for the checkpoint chain.
- **Log every message checkpoint.** Unbounded line size on a long
  conversation; rejected for the structural + geometric selection.
- **A global key shared by all sessions.** Lets two sessions' identical
  prefixes compare, which is a cross-session correlation the user did
  not ask for; rejected for the per-session subkey.
- **Inferring the provider from the configured route.** Would make the
  log look complete while being wrong; rejected. Unknown stays unknown.
- **A `/generation` lookup on every call.** A second request per
  completion, rate-limit exposure and a new failure path; left as a
  bounded opt-in future step.
- **Logging at `debug` only.** The user asked for the prefix in the
  log; `info` keeps it visible, and the size cap keeps it readable.
- **Adding a new log file.** The harness log already has retention,
  secret filtering and the page people read; a second file would drift.

## Shape of the change

- `lisp/modules/harness-provider-diagnostics.el` (new, module
  `provider-diagnostics`): key lifecycle, canonical chunks, HMAC chain,
  checkpoint selection, comparison, expected-cold, privacy-bounded log
  lines, raw usage reading, request/response entry points.
- `lisp/modules/harness-provider-openai.el`: build the body once,
  start the attempt before send, capture response id/model/provider and
  `x-request-id`, close the attempt at the single stream finish.
- `lisp/modules/harness-provider-responses.el`: the same for the
  Responses body and its `response` object; a refused-effort retry
  closes the first attempt before starting the second.
- `lisp/modules/harness-provider-diagnostics-test.el` (new, 31 tests):
  key stability/rotation/mode, no-randomness and invalid-key disable,
  append/identical/divergence at system, tools, model, settings, wire
  order and tool order, scope separation, deterministic checkpoints
  within a scope, Unicode and boundary ambiguity, byte (not character)
  lengths, shorter prefix, unknown response fields, provider vs plan
  cost, cancellation, concurrency, line bounds, large-body skip,
  malformed metadata, no prompt/tool/secret/key leakage, and
  fake-provider integration for both providers.
- `lisp/modules/harness-provider-openai-test.el`: unchanged assertions
  (the diagnostics integration is tested from the diagnostics suite).
- `lisp/modules/harness-provider-responses-test.el`: two diagnostics
  tests for the Responses provider -- response id/model/request-id, raw
  cache and plan cost, one usage event, and no prompt/tool/token in the
  lines.
- `docs/modules/provider-diagnostics.md`, `provider-openai.md` and
  `provider-responses.md`: regenerated with `scripts/module-docs.sh`.

## Verification

- `scripts/test.sh lisp/modules/harness-provider-diagnostics-test.el`
  → 31/31.
- The two provider suites, the provider-check suite and the usage suite
  pass. The full suite on this branch's base fails one suite,
  `test/harness-test-layout-test.el`, over two suites that sit in `test/`
  without being named in its list; the base commit has the same failure,
  the branch touches nothing in `test/`, and `main` already moved those
  two beside their modules. A trial merge with `main` clears it: 210
  files, one failure,
  `harness-ui-patch-review-tool-open-reveals-a-closed-thread-by-prefix`,
  which fails the same way on a clean `main`. Plan §11.7 has the detail.
- `scripts/lint.sh` exits 0 with no warning for the changed files.
- `scripts/module-docs.sh --check` is current.
- The readiness report and verification plan now point at these logs
  for the miss-alarm and unexpected-host stages; neither claims a live
  result.
- `demo/provider-diagnostics/demo.sh` runs the four states through the
  real provider path with a faked HTTP layer and prints the lines, with
  a leak check; `provider-diagnostics-demo-present` shows the same lines
  in a live frame. One run's output is
  [`docs/evidence/provider-diagnostics/demo-run.txt`](../evidence/provider-diagnostics/demo-run.txt).