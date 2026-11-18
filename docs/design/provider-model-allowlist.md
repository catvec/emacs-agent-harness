# A provider's own model allowlist

## The problem

`harness-allowed-models` is a harness-wide policy: a list of glob
patterns over model ids, set by an administrator (see
[policy](../policy.md)), which refuses a request at dispatch and filters
the catalogue every picker draws.  It answers "what may this harness
use at all", and it is the right answer to that question.

It is the wrong answer to "what should this endpoint offer".  OpenRouter
registers through `harness-openai-endpoints` and lists every one of its
several hundred models.  An operator who wants their OpenRouter endpoint
to offer three of them has, today, only the global list — which then
constrains Claude Code, Bedrock, the local server and every other
provider too.  The narrowing is a fact about one endpoint, and it
belongs in that endpoint's definition.

## What the change decides

A provider definition takes an optional `:allow-models`: a list of glob
patterns of model ids, the same ones `harness-allowed-models` takes.

- `*` stands for any run of characters and `?` for one.
- A pattern with a colon matches the whole `provider:model` id, so
  `openrouter:deepseek/*` is the DeepSeek models of OpenRouter.
- A pattern without a colon names providers, so `openrouter` is
  `openrouter:*`.
- Nil or absent offers every model the provider lists, exactly as
  before.  An empty list is the same as absent: it is not a way to say
  "nothing", because a setting that silently offers nothing is a
  misconfiguration, not a policy.
- A single string stands for a list of one, so a hand-written
  `:allow-models "openrouter:qwen*"` reads as intended.
- An entry that is not a non-blank string is dropped
  (`harness-provider--allow-patterns`, applied by
  `harness-define-provider`), so a stray nil in a hand-written list does
  not narrow the provider to nothing.

The two allowlists both apply and neither widens the other: a model must
pass `harness-allowed-models` **and** its provider's `:allow-models`.

## Where the filtering happens

In the core provider module, where a provider's models are settled —
`harness-provider--rebuild-cache`, which builds the catalogue, the model
index and the per-provider catalogue from the cached listings.  That is
the one place every surface reads:

| Surface | How it sees the narrowing |
| --- | --- |
| `provider/models` (every picker, the settings page, the Flutter client) | the catalogue is built from the narrowed set |
| `provider/model` | the model index holds only the offered models |
| `provider/tier-model`, `provider/tier-model-info` | tier selection and price ranking read the narrowed catalogue |
| `provider/cached-models` | the per-provider catalogue is narrowed |
| `provider/complete`, `provider/warm`, `provider/embed` | refused by `harness-provider-model-refusal` before the provider is asked |

Filtering in the core rather than in each provider is what makes the
narrowing reach all of them: a provider states it once, in its
definition, and no provider module has to know the key exists.  It also
means a provider that lists its models statically (`:models`) and one
that fetches them are narrowed the same way, because both go through the
same settle.

## The refusal

A request for a model the provider's own allowlist leaves out is refused
before the provider sees it, in the same place and the same shape as the
global refusal:

```
Model openrouter:qwen/qwen-4-72b is not allowed: openrouter's :allow-models allows only openrouter:deepseek/*
```

The global refusal is checked first, because it is the wider of the two:
a model both lists exclude is reported as the harness-wide policy's
doing, which is the one an administrator set.  The message names the
setting and its patterns, so the reader can find what to change.

## Edge cases

- **No patterns** — every model the provider lists, as before.
- **One pattern** — the models it matches.
- **Several** — the union.
- **An id-matched pattern** — `openrouter:deepseek/*` matches the whole
  id; a pattern without a colon matches the provider name.
- **A pattern that matches nothing** — the provider offers nothing.  The
  catalogue holds none of its models, a tier finds none, and the picker
  says `No available models` rather than appearing broken.  The log says
  once, per provider and pattern set, which patterns did it.
- **A static `:models` list** — narrowed the same way, because the
  filtering is after the listing, not inside it.
- **A model the narrowing left out, looked up by id** — `provider/model`
  still answers with a plist made for it (an alias, a model of a
  provider that is gone), as it does for any model no listing holds.
  The refusal is what stops it being used; the lookup is not a promise
  that it may be.

## Alternatives rejected

- **Filter in each provider module.**  Every provider would have to
  learn the key, and a provider that forgot it would silently offer
  everything.  The core already owns the catalogue; the narrowing
  belongs there.
- **Filter in the picker.**  The UI would have to know each provider's
  configuration, and the settings page, the provider check, the task
  board and the Flutter client draw the same catalogue.  The
  [model selection](../model-selection.md) page records the same
  reasoning for availability.
- **Reuse `harness-allowed-models` with a per-provider scope.**  That
  turns one policy into a tree of them, and the policy file is an
  administrator's, not an endpoint's.  A provider's definition is where
  a fact about that provider goes.
- **An empty list meaning "offer nothing".**  A typo would then look
  like a working configuration.  A pattern that matches nothing already
  says it, and says it in the log.

## Where the code is

- `lisp/modules/harness-provider.el`: the `allow-models` slot of
  `harness-provider`, the `:allow-models` keyword of
  `harness-define-provider`, `harness-provider--allow-patterns` (what
  the value is normalised to), `harness-provider--pattern-matches-p`,
  `harness-provider--offered-p`, `harness-provider--offered`,
  `harness-provider--note-empty-allowlist`, the filtering in
  `harness-provider--rebuild-cache`, and the second arm of
  `harness-provider-model-refusal`.
- `lisp/modules/harness-provider-openai.el`: the `:allow-models` key of
  an endpoint, in `harness-openai--endpoint-type`, the
  `harness-openai-endpoints` docstring and
  `harness-openai-register-endpoint`.
- `lisp/modules/harness-provider-openrouter.el`: a configured entry's
  `:allow-models` is passed through with the other legacy fields.
- Tests: `lisp/modules/harness-provider-test.el` (the filtering, the
  refusal, both allowlists, the surfaces),
  `lisp/modules/harness-provider-openai-test.el` (the endpoint key),
  `lisp/modules/harness-provider-openrouter-test.el` (the pass-through),
  `lisp/ui/harness-ui-model-picker-test.el` (the narrowed catalogue in
  the picker, and the empty one).
- Demo: `demo/allow-models/` registers four made-up providers and prints
  what a client sees -- the catalogue, a tier, a refusal, both allowlists
  together -- so it shows the surfaces reading one narrowed set rather
  than the filter function.  `demo/allow-models/render-evidence.py`
  rewrites `docs/evidence/allow-models/allow-models-demo.png` from the
  demo's own output.  It needs no network and no credential.

## UI copy

The only new user-visible text is in the settings page's endpoint
editor, and each piece is a noun or a noun phrase:

- `Allowed models` — the key's label;
- `Provider, model or pattern` — a pattern's label, the same words
  `harness-allowed-models` already shows, so the two entries read alike;
- the key's `:doc` — a setting description, the one place the copy rule
  allows prose.

A test asserts both labels exactly
(`harness-openai-allow-models-widget-is-copy-in-nouns`), including that
the pattern label equals the global option's.  The refusal message is a
server payload — data, not interface copy — and keeps the shape of the
global option's.

## The reader's own configuration

The routing example in `~/.config/doom/config.el` constrains the models
it will send to with `harness-allowed-models`, which applies to every
provider.  It can now state them on the OpenRouter endpoint with
`:allow-models` instead, leaving the global list free for what the whole
harness may use.  That file was not edited.

## Limits

- The narrowing is by model id, not by capability: it cannot say "the
  models that take images".
- It is read when a provider is defined, so changing it takes effect
  when the provider is registered again — which is what changing
  `harness-openai-endpoints` through customize does.
- A model the narrowing leaves out is still reachable by
  `provider/model` as a plist; only the refusal stops a request.
