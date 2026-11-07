# The conversation's observed cache rate, in the chat header

## What the header shows

The chat header already says what the conversation used: its context,
the tokens of every call, what it cost. This adds the one figure that
was missing there: how much of the last completed request's prompt the
provider served from its prompt cache.

```
  Session name  100k/8.0k  cache · last 85%  1.2M tokens  $0.42  [menu]
```

The figure sits immediately after the context figure, which it is a
share of. It is information, not a setting, so it stays in the header
and never moves to the settings line.

| State | Text | Face | Why |
| --- | --- | --- | --- |
| Known | `cache · last 85%` | `harness-context-ok-face` at 80% and above, `-warning-face` at 50%, `-urgent-face` at 20%, `-critical-face` below | A provider-reported rate over a prompt above zero |
| Completed request, no usable rate | `cache · last —` | `harness-dim-face` | A hosted loop's turn total, no cache tokens reported, or no prompt tokens |
| No completed request | no segment | — | Nothing measured yet, as a session that wrote nothing has no output figure |

The tooltip names the window, the denominator and the raw counts, for
example:

```
Provider-reported cache read 85% · last completed request · 85.0k of
100k prompt tokens · 5.0k prompt tokens written to cache · model
deepseek-chat · 14:05
```

While a turn is in flight the figure remains the last completed
request's and the tooltip ends `· turn in progress`; it never presents
the running request's unknown usage as its own. The unknown tooltips
say which unknown it is: `Hosted provider turn totals · no
request-level cache rate`, `Last completed request without cache
tokens · cache rate unavailable`, or `Last completed request without
prompt tokens · cache rate unavailable`.

All of this is noun phrases and values, with `·` separators: no sentence
is added to a heading, label, tooltip or status line. The number, the
word `last` and the em dash are the non-colour cues; colour only
reinforces them.

## The measurement

For the session's latest completed provider request:

```
rate = cache-read tokens / prompt tokens
```

- **Numerator**: the request's provider-reported cache-read tokens
  (`:cache-read`). Not a write, not a warmth estimate.
- **Denominator**: the request's `:context`, the provider's own total
  prompt size with cached tokens included. This is the whole input the
  request sent, so the share is "of the prompt", not "of the uncached
  part".
- **Window**: that one request, not the turn, the session's lifetime,
  or the previous prompt. A later completed request replaces it.
- **Source**: `session/usage-add`, the one place a provider's usage
  record is accounted. The figure is therefore provider-reported
  telemetry that already drives the session's tokens, cost and context.

The denominator is provider-correct because `:context` is normalized by
each provider before the session sees it:

| Provider route | `:input` | `:cache-read` | `:context` |
| --- | --- | --- | --- |
| Claude Code / Copilot (hosted turn total) | uncached input, summed over the turn | cached tokens, summed over the turn | the last request's prompt |
| Bedrock Converse | uncached input | `cacheReadInputTokens` | input + read + write |
| OpenAI-compatible, plain | `prompt_tokens` (cached included) | `prompt_tokens_details.cached_tokens` | `prompt_tokens` |
| DeepSeek (and compatible) | misses | hits | hits + misses = `prompt_tokens` |
| Responses | `input_tokens` (cached already inside) | `input_tokens_details.cached_tokens` | `input_tokens` |

The Responses route is the trap: its `input_tokens` includes the cached
tokens, so computing `input + cache-read` would read a session as up to
twice as full as it is. Taking `:context` as the denominator counts the
cached part exactly once, whichever way the provider's input is
counted. This is the provider accounting that `harness-provider-claude`,
`-bedrock`, `-openai` and `-responses` already document, and the same
reason `session/usage-add`'s context replaces rather than accumulates.

## Unknown is not zero

The session keeps `:last-cache` as
`(:prompt N :cache-read N :cache-write N :model MODEL :at TIME)`, with
`:hosted` for a hosted loop's turn record. A reading is kept only when
it is a nonnegative number (`harness-token-count-p`): zero is a real
miss the provider reported, while `nil`, JSON `null` or a non-number is
unknown.

The states follow from that:

- **No completed request**: no `:last-cache`; no figure. A new session,
  a conversation just reset, and a first request in flight all land
  here. The header does not show `0%`.
- **A hosted loop's turn**: `:hosted` is set, so no request-level rate
  is derived. Its `:context` is the last request's prompt but its cache
  count sums every request of the turn; dividing them would be a
  fabricated figure.
- **No cache tokens**: the provider reported a prompt but no cache
  reading (missing, null or invalid). `cache · last —`, not `0%`. The
  providers now leave `:cache-read`/`:cache-write` off a usage event
  when they have no usable reading; a reader can tell by the key's
  absence, as `harness-provider-check` already did.
- **No prompt tokens**: `:prompt` is zero or invalid; there is no
  denominator, so no rate. `cache · last —`.
- **Zero rate**: a numeric `0` cache read over a positive prompt is a
  real observed miss and shows `0%` in the critical face.

The providers changed minimally for this: plain OpenAI,
Responses and Bedrock now omit a cache key when the field is missing,
null or not a token count, instead of coercing it to `0`. DeepSeek's
own sum (`prompt_tokens = hits + misses`) is used to recover the hits
only when the hit field itself is unusable and both the miss and total
are reported; no other endpoint gets that arithmetic. Claude Code and
Copilot keep their turn-aggregate events, which the session marks
`:hosted`; their per-request cache counts are not used to invent a
request-level denominator.

## Thresholds and colour

The bands are chosen on the displayed, rounded percentage:

| Shown rate | Face | Reading |
| --- | --- | --- |
| 80–100% | `harness-context-ok-face` | The cached prefix carried almost the whole prompt; the ordinary case for a conversation that goes on |
| 50–79% | `harness-context-warning-face` | Partial reuse: the prompt changed early, or part of the prefix was gone |
| 20–49% | `harness-context-urgent-face` | Most of the prompt was new |
| 0–19% | `harness-context-critical-face` | A near miss or a first request; the cache served little |

The faces are the context indicator's own, so the header keeps one
visual language. They are mapped the other way round because the
quantities point opposite ways: a high context figure is pressure, a
high cache rate is health. A high cache rate is therefore calm, never
red; a low one is warm, never described as pressure. The label's
`cache · last` wording and the tooltip's counts are the accessible,
non-colour cues. The percentage is rounded before the band is chosen,
so a figure reading `80%` never wears the warning colour.

A low rate is **not** a diagnosis. It is compatible with a first request,
a model switch, a compaction, a redaction reset, a prompt that changed
early, an expired cache, or a provider that simply did not cache. The
header says what was measured and nothing about why. The cold-cache
panel (`ui-cache`) and the cache health watcher (`cache`) keep their
separate expiry/warmth jobs.

## Where it is kept and how it stays fresh

`session/usage-add` calls `harness-session--usage-with-last-cache` for
every record that has a `:context`, before the totals are stored and
announced. The value is persisted with the session's usage, so a
restart keeps the last completed request's reading. A `:cache-reset`
record (a compaction or a reverted compaction) removes it, and
`session/reset-provider` removes it with the provider conversation a
redaction drops: the conversation that follows has made no request.
A record without a `:context` (a cache refresh, a cost-only record)
leaves it.

The header calls `harness-ui-format-cache-rate` on the session record
of its own buffer at every draw. There is no global or buffer cache of
the rate, so:

- repeated `session/usage-add` records replace the figure;
- switching the window to another chat reads that buffer's session,
  never the previous buffer's rate;
- switching the session's model leaves the historical rate visible and
  the tooltip names the model it was measured on; the next request
  replaces it;
- a running turn shows the last completed request, with the
  `turn in progress` note in the tooltip.

`harness-ui-format-cache-rate` is lazy in the header, as the context and
token figures are: the tooltip is made on hover from the newest session
record, not on every redisplay.

## Alternatives considered

- **Turn-level cache rate** (`cache-read` over the sum of the turn's
  prompts): available for hosted loops, but not request-level, and the
  acceptance asks for the request window. It would also mix two windows
  behind one label.
- **The `cache/reuse` event's ratio**: it compares the request's cache
  read with the *previous* prompt, is emitted only when there was a
  cache to reuse and the model did not switch, and is a cache-health
  signal consumed by another module. Reusing it would show a different
  denominator and silently have no value after a compaction or model
  switch.
- **Totals ratio** (`usage :cache-read` over `usage :input`): mixes
  every request the session ever made, is not request-level, and
  double-counts or undercounts depending on how the provider's input is
  normalized.
- **Expiry/TTL inference**: explicitly out; the cache's lifetime says
  when a cache may lapse, not what the provider reported for a request.
- **A new fetch or usage-row request per header draw**: an extra request
  for data the session already receives, and a window that could lag the
  session record. The existing usage accounting is the source.

## Limits

- Hosted loops (Claude Code, Copilot) report turn totals, so their
  request-level rate is unknown by design. A future change could carry
  each request's counts from those providers; this one does not guess.
- A remote harness older than this change sends no `:last-cache`, so the
  figure is absent, not zero. The UI needs no new method or capability
  negotiation for that.
- A provider with no cache telemetry shows `cache · last —` once its
  request completes, rather than a false 0%. Providers whose cache is
  entirely automatic and unreported stay unknown.
- The figure is the conversation's request rate, not a billing statement
  and not a cache-health alert. The raw counts are in the tooltip; the
  usage views keep their own totals.

## Verification

Tests use fixtures and the demo provider, never a real model request:

- `harness-session-test.el`: exclusive and inclusive input providers, the
  no-double-count denominator, DeepSeek's split, reported zero, missing
  and null and invalid readings, zero prompt, repeated records, a
  contextless record, cache reset, provider reset, hosted turn marking,
  and persistence.
- `harness-provider-{openai,responses,bedrock}-test.el`: numeric-only
  cache readings, nil/null/junk omission, reported zero, DeepSeek's
  miss-and-total arithmetic, and the route's unchanged context.
- `harness-ui-test.el`: exact labels `cache · last 85%` and
  `cache · last —`, no figure with no completed request, each unknown
  tooltip, the face at every threshold boundary and at the rounded
  boundary, the clamped above-prompt case, and the in-flight note.
- `harness-ui-chat-test.el`: the figure updating through repeated
  requests, zero prompt, cache reset, present/absent across widths
  without a bare percentage, and two sessions keeping their own rates.

The rendered header is checked in a live harness at wide and narrow
widths and at a larger text scale, with a demo session; the screenshots
are evidence for the hand-in. The final full suite and lint run cover
the changed files, and the module pages are regenerated from the new
docstrings.
