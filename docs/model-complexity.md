# Model complexity guide

Enable the optional plugin:

```elisp
(harness-enable-modules :features model-complexity)
```

This loads `model-complexity` in the harness process and
`ui-model-complexity` in Emacs. It works with a remote harness too;
enable the feature on that harness as well.

Open **Model complexity** with `C-c h =` (or `M-x
harness-model-complexity`). The guide lists only the models your configured
providers make available and your model policy allows, from low to high
estimated work complexity. Each model keeps its actual name, provider and
ID. `g` refreshes the catalogue, `w` copies the ID at point, and `q` goes
back. Opening the guide does not select a model or make an inference request.

With the plugin enabled, the normal session/task model selector (`C-c h
m`, and the model buttons) opens on that same low-to-high list: each row
leads with its estimated level, then the real model name, its provider
and its ID.  It is the shared model browser, so `Back` goes to the
providers and their families, `All models` back to this flat list, and a
typed query searches every model of every provider.  Choosing one still
uses the normal model handoff checks; cancelling changes nothing.  If a
connected harness cannot provide rankings, the selector falls back to
the normal catalogue.

## Plain task levels

| Low to high | Intended work | Default guide examples |
|---|---|---|
| Simple tasks | Small, well-specified edits, formatting and summaries | Haiku |
| Routine tasks | Everyday implementation, tests and straightforward debugging | Sonnet; GPT-5.6 Luna |
| Complex tasks | Multi-file changes, difficult debugging and design decisions | Opus; GPT-6 Sol; GPT-6.1 Sol |
| Very complex tasks | Large, ambiguous problems with interacting constraints | Fable; GPT-6 Astra |
| Unrated | No matching guide rule; suitability is unknown | New or unrecognized models |

**These are editable estimates, not official capability ratings or benchmark
results.** The catalogue does not supply a verified measure of task
complexity. A model at a level is not guaranteed to solve every task in
that category, and models within a level are not ranked against each
other. Ties sort by full model ID for a stable display.

The guide does **not** infer capability from price, context-window size,
maximum output, thinking settings, or the provider's routing tiers. It does
not change routing, provider tiers, model IDs, thinking settings, defaults
or existing sessions. Older or future GPT versions and unfamiliar suffixes
are left Unrated instead of assumed to match the current named models.
The Anthropic guide recognizes the Haiku, Sonnet, Opus and Fable families
through Claude Code, Copilot and Bedrock. Aliases follow the model they
resolve to while retaining their own names and IDs in the display.

## Change a ranking

Set `harness-model-complexity-rules` in the **harness process**. With the
settings UI enabled, it is available among the advanced settings on `C-c h
S` (`M-x harness-settings`); search for `model-complexity-rules`. This is
also how to edit a remote harness's rules.

Each entry is `(REGEXP . LEVEL)`, matched against the full `provider:model`
ID. The levels are `simple`, `routine`, `complex` and `very-complex`; nil
explicitly marks a model Unrated. User rules are checked in order, before
the built-in guide. The first match wins. A rule can match either an
alias's own ID or its resolved model ID.

For example, in the harness configuration:

```elisp
(setq harness-model-complexity-rules
      '(("\\`chatgpt:gpt-5\\.6-luna\\'" . complex)
        ("\\`local:my-model\\'" . routine)
        ("\\`chatgpt:gpt-6-astra\\'" . nil)))
```

This moves Luna to Complex tasks for your workload, rates a local model,
and explicitly leaves Astra Unrated. All other models keep their guide
rules. Refresh the guide after editing. A user override is marked
`[user estimate]` in the guide; hovering over a model shows whether its
rank came from the default guide, a user rule, or no matching rule.

## Programmatic access

```elisp
(harness-call 'model-complexity/list)    ; promise of ranked model plists
(harness-call 'model-complexity/list t)  ; refresh providers first
```

Over ACP, call `_harness/model-complexity/list` with no parameters or
`(:refresh t)`. Each row preserves the catalogue fields and adds
`:complexity-level`, `:complexity-label`, `:complexity-rank`,
`:complexity-description` and `:complexity-basis`. Unrated rows have nil
level and rank. The provider catalogue itself is not modified.
