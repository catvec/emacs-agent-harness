# A malformed judge reply is no permission, and no dead end

## The failure

The auto-mode permission judge is a one-off model call whose reply the
harness reads as a verdict. The contract, in its system prompt and its
question, is one JSON object: `{"decision":"allow"|"deny","reason":"…"}`.

On 2026-11-10 the judge answered task `t-e2mdkyz2`'s call
(`permission request 1n6ylk`, a `git diff` inspection) with

```json
{"allow":"Read-only inspection of a local git diff; no destructive or exfiltrating action."}
```

a bare `allow` key where the decision belongs. The old reader
(`harness-perms--parse-verdict`) took the first `{…}` it found, looked
only at `"decision"`, found none, and returned "no verdict". Stage 30
handed the call on undecided, and the interactive session asked the user
— for a read-only `git diff`, because of punctuation.

Three separate weaknesses let that happen:

1. **The reader was narrow and silent.** One object, `"decision"` only,
   no notion of *why* a reply was not a verdict. A reply that said
   `allow` in a shape the prompt did not spell out was simply dropped.
2. **No second chance for a shape error.** The only retry was for
   `max-tokens`, and it asked the same question again at a larger
   budget: the model was never told what was wrong, so it could make the
   same mistake twice.
3. **Nothing asked the provider to constrain the shape.** The providers
   that accept a JSON schema were sent none, so the contract existed
   only in prose.

## What the change decides

### 1. A strict reader that says why

`harness-perms--read-verdict` walks the reply for balanced JSON objects
(braces inside strings do not count, nesting does) and reads each one:

- exactly one `"decision"`, whose value is the word `allow` or the word
  `deny` (case and surrounding space aside) — a verdict;
- `"decision":"ask"` — not a verdict, and **not** an error to correct:
  the decision to involve the user is the harness's, not the judge's;
- an object that talks about the decision without giving one plainly —
  a bare `"allow"`/`"deny"` key, a decision that is neither word, the
  key given twice — a *conflict*, which makes the reply no verdict;
- an object that says nothing of the decision — a note, `{}` — neither
  makes nor breaks a verdict, so a wrapping reply is still read.

The reply as a whole is a verdict only when it holds at least one
verdict, holds no conflict, and all its verdicts agree. Anything else is
no verdict, with a `:problem` phrase naming what was wrong: no JSON
object, no `"decision"`, the key `"allow"` where `"decision"` belongs, a
decision of `"maybe"`, two `"decision"` keys in one object, a verdict
beside another that disagrees, a verdict beside a conflict.

Two consequences matter for safety and for cost. Ambiguity is never
permission: one object saying `allow` and another saying `maybe` is no
verdict, not an allow. And the strictness does not backfire: an
ordinary JSON aside does not erase a plain verdict, so a model that
explains itself in extra objects does not cost a prompt.

The reply is quoted in the problem only where it is short; the strict
reading never coerces a value into a word. `harness-perms--parse-verdict`
remains as the boolean-shaped wrapper it was, so every existing caller
and test keeps its meaning.

Why so strict: the alternative readings are all unsafe in a permission
system. A bare `"allow"` key is ambiguous (is it the verdict, or a note
about what would be allowed?). A `"decision":"yes"` is a word the
contract does not have, so accepting it means accepting whatever else a
model invents. Two disagreeing objects have no verdict to take. Any of
those read as an allow would be *permission derived from a malformed
reply*, which is the one thing this path must never do.

### 2. One bounded correction

The judge is asked at most **twice**, as before. The second call now
also happens when the first replied in no shape the contract reads, not
only when it ran out of room, and its message is different: the call it
already saw, its own reply quoted as data under a heading that says so,
and the specific problem. The model corrects the form, not the
judgement; the prompt says which strings are legal.

What is **not** corrected: a failed request, a timeout, and
`"decision":"ask"`. A request that failed has no reply to correct, and
the call has waited long enough. An explicit `ask` is a decision, not a
mistake.

The two calls keep the first's session id, `:job-parent` (the session
asking) and prompts, and are recorded as "Permission judge" and
"Permission judge (retry)" under the same parent, so request identity
is unchanged. The chain settles once (`settled` in
`harness-perms--auto`), so a late `done` from a cancelled call, or from
a retry that never went out, neither answers a prompt nor starts work.

Exhausted retries are unchanged in policy: interactive sessions put the
call to the user, non-interactive ones deny it with
`harness-perms-no-verdict-hint`. Both outcomes are `ask` decisions that
the same later stages already handled; no new fallback branch exists.

### 3. A schema where the provider says it takes one

The verdict's JSON schema (`harness-perms--judge-verdict-schema`) rides
on the request as `:response-schema`. The OpenAI-compatible transport
converts it to `response_format: json_schema` **only where the route is
known to accept it**:

- a plain OpenAI-compatible endpoint is sent it (the caller named a
  schema, so it asks a server it knows);
- a dialect with a `:response-format` hook decides; OpenRouter's reads
  the pin, which records what the pinned endpoint listed in
  `supported_parameters`, and withholds the field unless that says
  `structured_outputs`;
- a dialect with no hook, and a session not yet pinned, send nothing.

And the judge names a schema only when `provider/capabilities` says
`:structured-outputs` for its model. Guessing would be worse than not
trying: a body field an endpoint refuses fails the very call the schema
was meant to make reliable, which costs more than a correction retry.

The reader does not trust the schema. Not every provider enforces one it
accepts, so the strict read is the real contract and the schema is a
hint that reduces the retry rate.

### 4. No duplicate work

The judge never runs the tool. The tool runs once, in `tools/execute`,
only if the chain allows it — a verdict, a user's answer, or an allow
rule. Two judge calls therefore cannot double-execute anything; the only
invisible risk would be two prompts for one call, which the single
`settled` flag rules out.

## Alternatives considered

- **Read a bare `"allow"` key as allow.** Fixes the incident in one
  line. Rejected: it is permission from a malformed reply, and it would
  make an invented `{"danger": false}` or `{"decision": "yes"}` equally
  arguable.
- **Correct by re-sending the same request verbatim.** Cheaper to
  write, but the model has no new information and the incident's cause
  (the model's idea of the shape) is unchanged. Telling it what could
  not be read is the smallest prompt that can actually work.
- **Correct until it parses (N retries).** Unbounded cost and latency
  in the permission path, for a call that must always finish. Two is the
  same bound the `max-tokens` path already had.
- **Force `response_format` everywhere.** Some endpoints reject the
  field; a 400 would turn a formatting problem into a failed judge call.
  Hence the capability gate and the strict read as fallback.
- **Retry on timeout.** The timeout already means "no verdict in time";
  a second call doubles the wait for a call that must answer now.
- **Make `ask` a third verdict.** The judge's job is to weigh harm, not
  to decide who should decide. Keeping `ask` out preserves that.

## The shape of the change

- `lisp/modules/harness-perms.el`:
  - `harness-perms--json-object-end`, `--json-objects`, `--judge-word`,
    `--verdict-reason`, `--verdict-word`, `--read-verdict` (new);
  - `harness-perms--parse-verdict` (now a wrapper over the reader);
  - `harness-perms--judge-correction-chars`,
    `--judge-correction-text`, `--judge-structured-output-p`
    (new); `--judge-verdict-schema` (new const);
  - `harness-perms--judge-request` (schema and name, when supported);
  - `harness-perms--auto` (correction decision, one settle, `ask` not
    corrected);
  - `harness-perms--no-verdict-message` (says the problem in the log).
- `lisp/harness-prompts.el`: `perms-judge-correction` registered, so
  every text the judge sees is auditable and overridable.
- `lisp/modules/harness-provider-openai.el`:
  `harness-openai--response-format` (new), the body writes it, and a
  model whose listing names `structured_outputs` gets the capability.
- `lisp/modules/harness-provider-openrouter.el`: the pin records the
  endpoint's `supported_parameters`; the dialect hook
  `harness-openrouter--response-format` reads it.
- `lisp/harness-prompts.el` registry plus `docs/prompts.md`,
  `docs/architecture.md` and the regenerated `docs/modules/perms.md`.

## What the tests hold

In `lisp/modules/harness-perms-test.el`:

| Test | What it pins down |
|---|---|
| `verdict-reader-accepts-the-contract` | allow, deny, case, wrap, non-string reason |
| `verdict-reader-refuses-everything-but-a-verdict` | bare keys, wrong words, duplicates, disagreeing objects, prose, blank |
| `observed-malformed-reply-is-corrected-once` | the field's exact reply, two calls, same identity, the correction's text |
| `a-corrected-allow-runs-the-call-once` | one execution, two calls |
| `a-malformed-reply-never-allows-a-call` | four malformed shapes never allow |
| `a-corrected-reply-that-is-still-malformed-is-no-verdict` | exhaustion: deny away, prompt interactive |
| `a-request-that-failed-is-not-corrected` | failure and timeout, one call, cancelled once |
| `a-malformed-reply-asks-the-user-not-the-judge-twice` | late reply after a timeout decides nothing |
| `judge-correction-keeps-the-call-alone` | `:ephemeral`, no thinking, prompts named |
| `a-provider-that-takes-no-schema-gets-none` | schema only with the capability |

In the provider suites: `response-schema-only-when-asked` (plain
endpoint, dialect without a hook),
`schema-only-where-the-endpoint-takes-one`, and
`schema-withheld-from-an-endpoint-that-lists-none` (the pin, and the
catalogues' `supported_parameters`).

## What you can watch

`demo/perms-judge-verdicts/demo.sh` prints the same decisions this
document argues for, offline: the reader on the field's reply and nine
others, the two judge messages of a correction and the decision they
settle, both fallbacks on two malformed replies in a row, and the schema
gate at a plain endpoint and at an OpenRouter pin either way.  It sends
no model request, installs no module and runs no tool, and every path it
prints is a placeholder; its provider is a scripted stub.
