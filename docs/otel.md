# OpenTelemetry export

`otel` exports what sessions do -- their turns, their model requests and
their tool calls -- to an OpenTelemetry collector you run, over OTLP/HTTP
with JSON bodies.  It is optional and off by default, and it is small: one
module ([lisp/modules/harness-otel.el](../lisp/modules/harness-otel.el)),
its tests beside it, and one lifecycle event added to the agent loop.  No
daemon, no observability UI, no full SDK.

This page is the design and the setup.  It says which conventions were
adopted and at which revision, what is emitted and what is deliberately
not, how tokens are counted across providers, what privacy and reliability
it promises, and what an upgrade would change.  The module page generated
from the source is [docs/modules/otel.md](modules/otel.md).

## Setup

Two settings, and both are needed.  Nothing is collected or sent until
both say so, so loading the harness -- or running its tests -- sends
nothing anywhere.

```elisp
(harness-enable-modules :features otel)  ; load it; it is off by default
(setq harness-otel-enabled t
      harness-otel-endpoint "http://localhost:4318")
```

`harness-otel-endpoint` is the collector's base URL; the OTLP/HTTP signal
paths are appended to it, `/v1/traces` and `/v1/metrics`.  A URL that
already ends in one of them is used as it stands for that signal, so a
gateway with its own paths takes the full address.  Only `http` and
`https` are used, and only when `curl` is present: the exporter posts over
the harness's own `harness-http`, which runs curl.

| Setting | Default | What it does |
| --- | --- | --- |
| `harness-otel-enabled` | `nil` | The master switch.  Nil collects nothing, whatever the endpoint says. |
| `harness-otel-endpoint` | `nil` | The collector's base URL.  Nil sends nothing, whatever the switch says. |
| `harness-otel-headers` | `nil` | Headers every request carries, an alist of `(NAME . VALUE)` -- for a collector behind an authenticating proxy.  Never logged. |
| `harness-otel-service-name` | `"emacs-agent-harness"` | The resource's `service.name`. |
| `harness-otel-export-interval` | `15` | Seconds between exports. |
| `harness-otel-max-queue` | `1024` | Most spans and metric records held while unsent.  The oldest are dropped past it, and counted. |
| `harness-otel-timeout` | `10` | Seconds one request may take. |

Headers come from `harness-otel-headers` when it is set, else from the
specification's `OTEL_EXPORTER_OTLP_HEADERS` environment variable
(`name=value,name=value`).  `harness-otel-enabled`, not the environment,
is the switch: an environment variable alone turns nothing on.

### Trying it against a collector of your own

`demo/otel-export/` has a tiny OTLP/HTTP JSON collector to try the export
against, with no collector to install: `collector.py` prints the spans and
metric points each request carried and answers 200 as a collector does,
and `run.el` runs one real turn of the scripted demo provider with the
module on.  In two shells, from the repository root:

```bash
python3 demo/otel-export/collector.py 4318 --verbose
```

```bash
emacs -Q --batch -L lisp -L lisp/modules -L lisp/ui -L . \
  -l harness -l demo/otel-export/run.el "tools"
```

`HARNESS_OTEL_DEMO_PORT` moves both to another port.  The turn's three tool
calls and its closing summary arrive as eight spans in one trace -- the
agent's at the root, each request and each tool under it -- and six metric
records: four durations and the input and output counters.  Nothing but the
model is scripted: the session, the agent loop, the tools and the exporter
are the harness's own.  `collector.py` is a demo stand-in, not a collector:
it keeps nothing and forwards nothing.

`(harness-call 'otel/status)` returns what the exporter is doing: the
settings, whether anything is collected now, how many items are queued,
dropped, sent and failed since the module started, how many requests are
on the wire, and how many spans are open.  `(harness-call 'otel/flush)`
sends what the queue holds now.  Shutting the module down, or the harness,
stops collecting and sends what is queued once; after that it sends
nothing.

### The agent event it needed

The harness already announces `agent/turn-started`, `agent/turn-ended`,
`agent/step-started`, `tools/started` and `tools/finished`.  Those cover a
turn and a tool call exactly, but a model request only begins: nothing
said when a step ended, so its duration, its tokens and its outcome had no
signal.  The agent loop now emits one more event, `agent/step-ended`
\(SESSION-ID INFO), **once per logical step however many attempts it
took**, with `:model`, `:reason`, `:attempt`, `:step`, `:duration`,
`:cancelled`, `:error-kind`, and the step's own `:input`, `:output`,
`:cache-read`, `:cache-write` and `:cache-read-known` when the provider
reported them.  That event is the whole core change: it is the only line
the module needed from outside itself.  Its counts are the step's, added
up over its attempts and never a session total; its `:error-kind` is a
class, never the provider's error text.

## The conventions adopted, and where they come from

These are the **GenAI semantic conventions** of the OpenTelemetry project,
which moved to their own repository,
[open-telemetry/semantic-conventions-genai](https://github.com/open-telemetry/semantic-conventions-genai).
They are **Development**: they change without notice, and no tag or
release exists to pin one.  So this module pins a commit.

- **Adopted:** commit
  [`e6658f14c9d9ea0760825f029cb82e7673f48fab`](https://github.com/open-telemetry/semantic-conventions-genai/tree/e6658f14c9d9ea0760825f029cb82e7673f48fab)
  \(2026-11-06, the head of `main`: "Remove trailing commas from the MCP
  JSON-RPC examples (#692)").  `GET /repos/open-telemetry/semantic-conventions-genai/tags`
  returns `[]`: there is nothing else to pin.
- **Verified against,** at that commit: `docs/gen-ai/client-inference.md`,
  `docs/gen-ai/gen-ai-agent-spans.md`, `docs/gen-ai/execute-tool.md`,
  `docs/gen-ai/gen-ai-token-metrics.md`, and the registry attributes the
  four of them cite (`docs/registry/attributes/gen-ai.md`).
- **Error recording** follows
  [semantic-conventions v1.45.0, `docs/general/recording-errors.md`](https://github.com/open-telemetry/semantic-conventions/blob/v1.45.0/docs/general/recording-errors.md),
  which the GenAI pages point to for span status: a failed span's status is
  `Error` (OTLP code `2`) and carries a low-cardinality `error.type`.  A
  successful span's status is left unset.

### Spans

| Signal | Type | Kind | Name | Attributes |
| --- | --- | --- | --- | --- |
| A turn | `gen_ai.invoke_agent` | `INTERNAL` (`1`) | `{gen_ai.operation.name} {gen_ai.agent.name}` -- `invoke_agent emacs-agent-harness` | `gen_ai.operation.name` `invoke_agent`; `gen_ai.agent.name`; `gen_ai.provider.name`; `gen_ai.request.model` |
| A model request | `gen_ai.client.inference` | `CLIENT` (`3`) | `{gen_ai.operation.name} {gen_ai.request.model}` -- `chat claude-sonnet-4-5` | `gen_ai.operation.name` `chat`; `gen_ai.provider.name`; `gen_ai.request.model`; `gen_ai.request.stream` |
| A tool call | `gen_ai.execute_tool` | `INTERNAL` (`1`) | `execute_tool {gen_ai.tool.name}` | `gen_ai.operation.name` `execute_tool`; `gen_ai.tool.name`; `gen_ai.tool.call.id` |

`gen_ai.operation.name` is `chat`: every provider of the harness makes a
chat completion, hosted loops and API calls alike.  A model request's span
name is set from the requested model as the convention has it; a request
opened before its session's model was read is renamed when the step ends,
so the name is always the convention's.

The agent span is also where the harness's own attributes go:
`gen_ai.conversation.id` and `harness.session.id` (the session's id),
`harness.session.kind`, and `harness.session.parent_id` when a sub-agent's
turn hangs under the turn that started it.  The turn's own account is
`harness.turn.stop_reason`, `harness.turn.requests` and `harness.cancelled`
-- the last set for a cancellation, which is not an error.

A request and a tool span carry `harness.session.id` too, so a span found
on its own says which session it belongs to without walking up the tree,
and a request made outside any turn -- the harness's own small calls --
is not left unattributed.  No metric carries it: a metric's dimensions
must not grow with use.

The convention's own slot, `gen_ai.conversation.id`, is written on the
agent span and nowhere else.  The conventions mark it **Conditionally
Required** on a client inference span "if and only if the instrumented
library has one readily available", and the harness has one -- but the
rule this module was asked to keep is that session ids go only on the
spans that need them, and a request already sits in its turn's trace.  So
the conversation is named once per turn, where a backend starts from, and
repeating it on every request of a long session would widen what a
collector keeps of a user's work without adding a correlation that the
trace and `harness.session.id` do not already give.

Parentage is the convention's: a turn's agent span is the trace's root (or,
for a sub-agent whose parent is running, a child of the parent's turn span,
in the parent's trace -- one logical operation, one trace); each model
request and each tool call hangs directly under the turn's span.  A request
made outside a turn -- the harness's own small calls have none -- opens a
trace of its own rather than dangling under no parent.

### Metrics

| Metric | Instrument | Unit | Buckets / labels |
| --- | --- | --- | --- |
| `gen_ai.client.inference.duration` | Histogram | `s` | The convention's explicit boundaries: 0.01 0.02 0.04 0.08 0.16 0.32 0.64 1.28 2.56 5.12 10.24 20.48 40.96 81.92 |
| `gen_ai.client.inference.usage.input_tokens` | Counter | `{token}` | `gen_ai.token.modality` = `unknown` |
| `gen_ai.client.inference.usage.output_tokens` | Counter | `{token}` | `gen_ai.token.modality` = `unknown` |

Every metric carries only what the convention names, and only
low-cardinality values: `gen_ai.operation.name`, `gen_ai.provider.name` and
`gen_ai.request.model`.  No session id, no turn, no task id: a metric's
dimensions must not grow with use.  A failed operation's metric carries
`error.type`; a successful one does not.  The duration metric's value is
the span's duration, as the convention asks when both are reported.

Metrics are sent as **DELTA** (`aggregationTemporality` `1`): one data
point per queued record, carrying what happened since the export before.
`gen_ai.token.modality` is `unknown`, because the harness does not split a
prompt's tokens by modality; the convention requires the attribute and
says to use `unknown` when the modality cannot be told.

### What is deliberately not emitted

The older spellings are **not** used, and this is a decision, not an
omission:

- `gen_ai.client.operation.duration` -- superseded by
  `gen_ai.client.inference.duration`.
- `gen_ai.client.token.usage` -- superseded by the two
  `gen_ai.client.inference.usage.*` counters.
- `gen_ai.token.type` -- superseded by `gen_ai.token.modality`.
- `gen_ai.system` -- superseded by `gen_ai.provider.name`.

A backend that still wants the v1.x names would be served by a deliberately
pinned older revision of the conventions; this module does not offer one,
because emitting both spellings would count the same operation twice.  Also
left out, though the conventions define them, are the time-to-first-chunk
and time-per-output-chunk metrics, the `gen_ai.client.inference.operation.*`
token histograms, the inference events, and every content attribute: the
task asked for duration and tokens, and a small surface.

### Content: never, in this version

The conventions mark prompt and response content **Opt-In**:
`gen_ai.input.messages`, `gen_ai.output.messages`,
`gen_ai.system_instructions`, `gen_ai.tool.definitions`,
`gen_ai.tool.call.arguments` and `gen_ai.tool.call.result`.  This module
writes **none of them**, and has no switch to turn them on.  A span says
what the operation was and how it ended; it never says what was said.

## Provider names and model names

`gen_ai.provider.name` takes the registry's well-known value where one
applies, and a dot-namespaced name of the harness's own where none does:

| Harness provider | `gen_ai.provider.name` | In the registry |
| --- | --- | --- |
| `claude` | `anthropic` | yes |
| `chatgpt`, `openai` | `openai` | yes |
| `deepseek` | `deepseek` | yes |
| `bedrock` | `aws.bedrock` | yes |
| `copilot` | `github.copilot` | no -- custom value |
| `demo` | `harness.demo` | no -- custom value |
| `gremlin` | `harness.gremlin` | no -- custom value |
| anything else | `harness.PROVIDER` | no -- custom value |

`gen_ai.request.model` is the vendor's model name, the part after the
colon of the harness's `provider:name` id: `claude:claude-sonnet-4-5`
becomes `claude-sonnet-4-5`, the vendor being in `gen_ai.provider.name`.
`gen_ai.response.model` is not emitted: the harness does not record what a
provider said it served, and guessing it would be worse than leaving it
out.

`telemetry.sdk.name` is `emacs-agent-harness`, not `opentelemetry`: the
registry reserves that value for OpenTelemetry SDKs, and this exporter is
not one.  `telemetry.sdk.language` is `elisp`, for which the registry has
no value -- a custom one is allowed.  The instrumentation scope is
`harness-otel`.

## Tokens across providers

Providers disagree about what "input tokens" means.  The convention counts
**cache-inclusive** input: a prompt's tokens including those the provider
served from its cache.  The harness's usage events carry the reading the
provider gave and, where the provider reports caching, the split:

- `:context` is the whole prompt for every provider -- cached tokens
  included -- so it is the input count when it is there.
- Otherwise the split counts are added back together:
  `:input` + `:cache-read` + `:cache-write`.  Bedrock, for example, reports
  an input count that leaves cached tokens out.
- A cache reading the provider did not give stays **absent**, never zero:
  `:cache-read` is present only when the provider reported a token count,
  and `:cache-read-known` says that it did.  Absent reads as unknown;
  zero would read as "nothing was cached", which is a different claim.
- A step whose provider said nothing about its tokens records **no**
  counter.  The conventions' counters are sums of known, strictly positive
  contributions, so an unavailable reading is left out rather than
  recorded as a zero that would drag a sum down.

Each contribution is one step's, and each step's counts are added up over
its attempts and recorded once: a retry does not count its tokens twice,
and a session's cumulative usage is never re-reported.  The cache readings
are also on the inference span, as
`gen_ai.usage.cache_read.input_tokens` and
`gen_ai.usage.cache_write.input_tokens`, beside
`gen_ai.usage.input_tokens` and `gen_ai.usage.output_tokens`, so a span
shows the split the metric's sum cannot.

### Failure, cancellation and retries

- A step that fails for good ends its span with status `Error` and
  `error.type`; a step that fails and is retried stays one span, and is
  reported once its fate is known -- so a transient failure that a retry
  fixes is a successful request, not two operations and not an error.
- `harness.step.attempt` on the span says how many attempts it took, which
  is how a retry is visible without being counted as another request.
- A cancelled step and a cancelled turn are **not** errors: their spans end
  without an error status, and say `harness.cancelled` `true` instead.  A
  call a turn left running when it ended -- a cancellation, say -- has no
  end event of its own, and is closed with the turn as cancelled, so no
  span is kept for ever.
- `error.type` is a class, never a message: a provider's kind is mapped to
  `rate-limit`, `quota`, `billing`, `auth`, `transport`, `process`,
  `timeout`, `error`, `denied` or `tool-error`, and anything else becomes
  `error`.  A provider's error text can hold a whole prompt, and never
  leaves the process.

## Privacy

Nothing a model or a tool says is exported.  Not a prompt, not an answer,
not a tool's arguments or its output, not a file path, not a credential,
not an account identity, and not an arbitrary exception's text.  The
module reads the events' structure -- an id, a name, a count, a reason, a
class -- and its attribute writer (`harness-otel--text`) refuses to
stringify anything it does not recognise, so no error object's text can
reach a collector through a slot meant to describe one.

`harness.turn.stop_reason` is the provider's stop reason (`end-turn`,
`tool-use`, `cancelled`, `error`), a small set of the harness's own words.
`gen_ai.agent.name` is the constant `emacs-agent-harness`, never a
session's name, which is the user's words.  A tool's name is the
registered tool's name, not the command it ran.

The tests hold this down: one asserts that no queued item's serialised
attributes contain a prompt, an answer, a tool's argument or its output, a
path or a secret; another asserts that no Opt-In content attribute key is
ever written.

## Reliability

The exporter is not on the agent's path.  Handlers only build a span or a
record and queue it; a timer sends the queue.  So a collector that is
slow, unreachable or wrong never makes a turn wait and never raises into
one:

- **Bounded queue.**  `harness-otel-max-queue` items at most (1024 by
  default, and never fewer than 16).  Past it the oldest are dropped and
  counted, so a harness left running with no collector in reach sets no
  more memory aside than this.
- **Asynchronous.**  The timer runs `harness-otel--export-now`, which
  catches its own errors.  A request's callback counts success or failure;
  neither raises.
- **No retry.**  `:retry 0`: a repeated POST would send the same spans
  twice and OTLP has no deduplication.  A failed request's items are gone,
  as they would be in any exporter whose queue is bounded; the next export
  carries on with what comes after.
- **Logged once.**  An endpoint that cannot be used, or a request that
  fails, is logged once with `harness-log`; the counters say how often it
  happened after that.  A collector's trouble must not fill the log.
- **Predictable shutdown.**  Shutting the module down unsubscribes, stops
  the timer, sends what is queued once and marks itself stopped: a handler
  still held by an event afterwards collects nothing.  The final request is
  made, not waited for -- stopping the harness never hangs on a collector
  that does not answer.  Reloading the module keeps a running exporter's
  queue and counters: what it collected is still owed.

The tests cover each: a collector that fails does not stop a turn or raise;
a full queue drops and counts; a shutdown sends once and then collects
nothing; a flush sends each item once.

## How Claude Code and Codex do it, as examples

Two published agent telemetries are worth reading beside these conventions.
Neither is a standard, and this module copies neither's namespace.

**Claude Code** (`claude_code.*`) exports OpenTelemetry metrics and events,
and optionally traces: `claude_code.interaction` is the turn's span,
`claude_code.llm_request` a model request under it,
`claude_code.tool.execution` and `claude_code.tool.blocked_on_user` under
the request, with subagent requests and tool spans under the Agent tool's
span.  Its metrics count sessions, tokens, cost and lines of code
(`claude_code.session.count`, `claude_code.token.usage`,
`claude_code.cost.usage`, `claude_code.lines_of_code.count`), and each span
carries a `span.type` attribute matching its name.  Content is behind
separate switches and off by default: `OTEL_LOG_USER_PROMPTS`,
`OTEL_LOG_TOOL_DETAILS`, `OTEL_LOG_TOOL_CONTENT`, `OTEL_LOG_RAW_API_BODIES`,
and a `CLAUDE_CODE_OTEL_CONTENT_MAX_LENGTH` bound on how much of it a body
may hold.  The design this module takes from it: **the hierarchy** -- turn,
request, tool -- and **content behind its own gate**.  What it does not
take: the `claude_code.` namespace, `span.type`, or its metrics, whose
dimensions (`session.id`, and tool and agent names under the content gate)
are wider than the GenAI conventions allow on a metric.

**Codex** (`codex.*`) exports structured log events and, independently, a
metrics pipeline: `codex.api_request`, `codex.sse_event`,
`codex.user_prompt`, `codex.tool_decision`, `codex.tool_result` and the
like, with counters and duration histograms (`codex.tool.call.duration_ms`,
per HTTP status and outcome), and default metadata tags on every metric
(`auth_mode`, `originator`, `session_source`, `model`, `app.version`).
Exporters are configured in `[otel]`, disabled by default, with log export,
trace export and metric export chosen separately, prompts redacted unless
`log_user_prompt` is set, and batches flushed on shutdown.  The design this
module takes from it: **independent, opt-in export, asynchronous batching,
flush on shutdown**.  What it does not take: the `codex.` namespace, its
log-event model, or its default metric tags -- `auth_mode` and
`originator` are account identity, which this module never exports, and
`session_source` and `app.version` are the kind of dimension the GenAI
conventions keep off a metric.

## The OTLP wire format

OTLP/HTTP with JSON bodies: `POST <endpoint>/v1/traces` and
`POST <endpoint>/v1/metrics`, `Content-Type: application/json`, the
`resourceSpans`/`resourceMetrics` envelope.  The shape:

- Trace and span ids are 32 and 16 lowercase hex digits, never all zeros.
- Timestamps are nanoseconds since the epoch, as **strings**, because a
  64-bit integer in OTLP JSON is a string: a JSON number is a double and
  would lose the last digits.  Emacs's time is exact to the nanosecond, so
  the value is exact.
- An attribute is a one-key object: `{"stringValue": ...}`, `{"intValue":
  "42"}` (a string), `{"doubleValue": ...}` or `{"boolValue": true}`.  An
  attribute whose value is not known is absent, which is not the same as
  empty.
- A span's `kind` is `3` for `CLIENT` and `1` for `INTERNAL`; its
  `parentSpanId` is `""` for a root; its `status` is `{"code": 0}` unless
  something set it.
- Every record of a metric instrument is one data point of its own: a
  counter's `asInt` is its value, and a histogram's `count` is 1 with its
  value in the one bucket it falls in, its `min` and `max` both that value.

No Lisp OpenTelemetry library was used: none was found that speaks OTLP
without a full SDK and its own daemon or process model, and the harness
already posts JSON over `harness-http`.  So the exporter is the body
builders and one POST per signal -- a few hundred lines rather than a
dependency.

## What an upgrade would change

These conventions are Development, and the repository publishes no tags.
Moving to a newer revision means reading, at the new commit: whether the
span types, the metric names and the explicit bucket boundaries still say
what this module assumes; whether `gen_ai.token.modality` is still
required and still takes `unknown`; whether the well-known provider values
this module maps to have moved; and whether the Opt-In content attributes
have changed name or requirement level.  Then: update the constants at the
top of the module, the table in this page, and the tests' assertions about
names and buckets.  Nothing else depends on the revision, because the
module builds its own bodies.

The one thing an upgrade would not change is the privacy default: content
stays unexported until someone decides otherwise on purpose, and a
convention's change to an attribute's requirement level is not a reason to
start exporting prompts.

## Tests

`lisp/modules/harness-otel-test.el` holds 36 ERT tests over a fake
`harness-http-request`, so nothing leaves the process: the request the
module would make is encoded and inspected.  They cover the disabled
behaviour (`harness-otel-is-off-by-default-and-not-loaded-unasked`,
`...-loads-off-and-sends-nothing`, `...-enabled-with-no-endpoint-sends-nothing`),
the OTLP envelopes and identifiers (`...-traces-body-is-an-otlp-envelope`,
`...-metrics-body-is-an-otlp-envelope`, `...-span-ids-are-w3c-trace-context`,
`...-nanoseconds-are-exact-and-strings`, `...-endpoint-paths-are-otlp`),
parentage and lifecycle (`...-a-turn-is-one-trace-with-coherent-parentage`,
`...-a-tool-call-is-one-span`, `...-a-cancelled-turn-closes-what-it-left-open`,
`...-a-sub-agent-hangs-under-its-parents-turn`,
`...-the-session-is-named-on-the-spans-that-need-it`), token accounting
\(`...-a-step-counts-its-own-cache-inclusive-input`,
`...-input-counts-a-cache-inclusive-provider-once`,
`...-tokens-are-not-session-totals`, `...-unavailable-usage-is-no-zero`,
`...-a-zero-cache-reading-stays-absent`,
`...-a-zero-token-count-records-no-counter`, `...-a-retry-is-one-operation`),
redaction (`...-never-exports-what-was-said-or-done`,
`...-no-content-attributes-are-ever-written`, `...-error-types-are-bounded`,
`...-metric-labels-are-bounded`), and exporter failure
\(`...-a-failing-collector-is-isolated`, `...-an-export-does-not-retry`,
`...-the-queue-is-bounded`, `...-shutdown-is-predictable`,
`...-flush-sends-each-item-once`).
