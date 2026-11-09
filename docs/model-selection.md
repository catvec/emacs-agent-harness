# Choosing a model: availability, providers and families

The model selector offered one flat list of every model of every
provider, including providers that were not configured, with no way to
see which provider a model came from beyond a parenthetical, and the
complexity estimates missed the same models under a namespaced id.
This page records what the selector decides now, why, and what it
deliberately does not do.

## What was wrong

1. **Providers nobody configured offered models.** OpenRouter's
   `/models` answers without a credential, so a fresh harness listed
   all 400-odd OpenRouter models without an account that could run
   any of them. Copilot listed its CLI's built-in catalogue before
   sign-in, and Claude Code listed a catalogue while signed out or
   without its CLI installed. A `provider/models` answer is the
   catalogue every picker and settings page draws, so the fix belongs
   in the providers, not in the selector.
2. **No organization.** One list of 590 models, sorted by nothing the
   user could see, is hard to walk even with fuzzy search: the search
   matched prefixes only, so `g61sol` found nothing and `opus` needed
   the first characters of the name.
3. **6.1 models unrated.** `chatgpt:gpt-6.1-sol` was rated, but
   OpenRouter lists it as `openrouter:openai/gpt-6.1-sol`, which no
   rule matched. The same held for `anthropic/`-prefixed Claude ids.

## What the selector does now

### Availability comes from the harness

The UI draws the catalogue it is given, unchanged; it never guesses
whether a provider is usable. The providers decide:

- **OpenAI-compatible endpoints** (`harness-openai--configured-p`) list
  models only with a key, static `:models`, or custom `:headers`.
  `api.openai.com`, `openrouter.ai` and the official DeepSeek hosts
  need one of those however public their `/models` is. Local and other
  keyless endpoints keep working, and a refresh of an unconfigured
  endpoint clears the models it listed before.
- **Copilot** lists nothing without the CLI or a login, and a refresh
  asks `auth.getStatus` again, so `copilot logout` stops the catalogue.
  The built-in model list is a fallback only for a signed-in account.
- **Claude Code** lists nothing without a runnable CLI, and a refresh
  whose `initialize` answer names a signed-out account (or fails)
  clears the catalogue. A CLI too old to name an account keeps its
  catalogue, and a model lookup keeps the static metadata.
- **Bedrock, DeepSeek and the subscription ChatGPT provider** already
  listed what their configuration allows.

The default picker asks for a refresh when it opens
(`harness-ui-refresh-models` takes `REFRESH` as its third argument), so
removing a key or logging out is reflected the next time it opens
rather than at the next schedule.

### Browsing: providers, then families, then models

`harness-ui-read-model` is one browser shared by the normal picker and
the optional complexity picker:

- An empty answer at the root lists **providers**, each annotated with
  how many models it offers, and `All models`.
- Choosing a provider lists its **families** (`harness-ui-model-groups`
  by default): GPT by version, Claude by family, Gemini and DeepSeek by
  version, and any other model by its vendor word (`Llama`, `Qwen`,
  `Grok`). A catalogue can name its own categories through `:groups` or
  `:family`.
- A family of one model is **not** a level of its own: that model is
  offered with the models of the provider, so drilling through a
  folder of one is not a keystroke the user has to pay. Providers are
  always a level.
- `All models` lists the current level flat (all providers' models at
  the root, one provider's below it) in catalogue order, which is what
  keeps the complexity picker's low-to-high list.
- `Back` returns to the level above. Prompts say where the browser is:
  `Model provider: `, `Model · OpenRouter: `, `Model · OpenRouter /
  Claude Opus: `, `All models · OpenRouter: `.

`harness-ui-model-group-function` is a `defcustom` so a user can group
by something else, or set it to `nil` for flat provider lists.

### Search: every provider, ranked by how tight the match is

A typed query searches every model below the current level — every
model of every provider at the root — so the old cross-provider search
is still one keystroke away. Three rules make it usable:

- **Fields, not a concatenated string.** Every whitespace-separated
  term must match the model's own name, its qualified name, its
  provider or its estimate; a term that only matches across two of
  them is not a match. Without this, `opus` matched 303 of 590 models
  because `o`, `p`, `u` and `s` could be found in `OpenRouter…` and the
  model name together.
- **Subsequences, not prefixes.** `g61sol` finds `GPT-6.1 Sol`
  wherever it is listed, punctuation optional.
- **Tighter matches first.** A term that appears as typed comes before
  one that matches at a word start, which comes before a loose
  subsequence; ties keep catalogue order. `opus` leads with the Opus
  models and pushes a name that merely holds the letters to the end.

Completion goes through a **function table** that answers with what it
matched, and the browser binds the `basic` style for its category:
`flex` and `partial-completion` would filter the fuzzy matches again,
and a space is a word separator here, not a wildcard.

### The ranked picker keeps its order

The optional complexity plugin's picker opens on the flat list, headed
`Model · estimated work complexity, low to high: `, each row led by its
level, and `Back` from there offers the providers. Rows in either
picker read `Model (Provider)  [provider:id]`, with the estimate when
there is one, and the context window and price as the annotation.

### Complexity in a namespace

`harness-model-complexity` accepts an optional `openai/` namespace for
the explicit GPT entries and `anthropic/` for the Claude families, so
`openrouter:openai/gpt-6.1-sol` is rated as `chatgpt:gpt-6.1-sol` is.
No new versions or suffixes were invented: unknown ones stay Unrated.

## Alternatives

- **Filter the provider list in the UI** — rejected: the UI would have
  to know each provider's credential rules, and settings pages, the
  provider check and the task board draw the same catalogue.
- **Keep the flat list and annotate it by provider** — rejected: 590
  rows with a provider on each is still one list; the user asked to
  start from providers.
- **Only fuzzy-search, no drill-down** — rejected: search cannot answer
  "what does this provider have at all".
- **A folder per family, even a family of one** — rejected: it costs a
  keystroke and hides the model's name until the last level.
- **Score every match with a cost model and sort by it** — rejected as
  more machinery than needed: three tiers (literal, word start, loose)
  separate the real matches from the accidental ones.
- **Hide the ranked list behind `All models`** — rejected: the
  complexity picker's whole point is the low-to-high view.

## Where the code is

- `lisp/ui/harness-ui.el`: `harness-ui-choose-model`, `harness-ui-read-model`,
  `harness-ui-model-groups`, `harness-ui-model-group-function`,
  `harness-ui-model-display-label`, the catalogues a `defcustom` user
  can change, and the `harness-model` completion category.
- `lisp/ui/harness-ui-model-complexity.el`: the ranked picker's prompt
  and its fallback to the normal picker.
- `lisp/modules/harness-provider-openai.el`, `-copilot.el`,
  `-claude.el`: the availability rules.
- `lisp/modules/harness-model-complexity.el`: namespace matching.
- Tests: `lisp/ui/harness-ui-model-picker-test.el` (browsing, search,
  labels, copy), `test/harness-ui-model-complexity-test.el` (ranked
  order and navigation), the provider suites (availability), and the
  existing UI suites whose model stubs now choose by id.

## Limits

- A model the catalogue does not list is not offered, even if it would
  work: availability is the catalogue's answer, not the picker's.
- Family inference is about finding a model. It never claims
  capability, and a name no rule knows stays directly under its
  provider.
- An older Claude Code CLI that names no account cannot report that it
  is signed out; its catalogue is shown, as before.
- A Copilot or Claude refresh notices a logout when it runs, at the
  next picker opening or catalogue refresh, not the instant it
  happens.
