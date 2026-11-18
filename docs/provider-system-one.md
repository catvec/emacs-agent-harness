# System One providers

Design note, November 2026.  This is how the harness asks a *System One*
model for a decision: it is given a `state` -- the content to judge, once
-- and named, typed questions about it, and it answers each one with a
typed value instead of prose.  The module is
[lisp/modules/harness-provider-system-one.el](../lisp/modules/harness-provider-system-one.el)
and its page is [provider-system-one](modules/provider-system-one.md).

It is a **capability of the provider interface**, not a second interface
beside it.  `harness-define-provider` takes `:system-one` as it takes
`:embed`, `provider/system-one-p` says which models have it, and
`provider/system-one` asks for a decision, as `provider/embed` asks for a
vector.  A provider is registered once and declares what it can do; the
day a model both predicts tokens and answers System One questions, it
declares both, and nothing here forbids it.

## What this is not

The harness already has one interface for asking a model for something
in words: `provider/complete`, through which every one-off call it makes
on its own goes -- the permission judge, the auto-mode judge, naming a
session, a recap, a task's summary, a search.  Those calls are
completions by design, they already share that one API, and they want
nothing from this module.

A completion model cannot answer a noul at all.  Asked for the
probability that a statement is true, it writes a sentence; asked for one
option and the probability of every option, it writes a paragraph about
the options.  That is not a limitation this module works around, it is
why the capability exists: a System One model is a different kind of
model, and the harness can now address it directly instead of wrapping it
in a prompt and parsing prose back out.  So there is no completion
adapter here, and no "decision provider" a chat model can impersonate.
The two capabilities are declared separately because they are separate.

## The contract: a state and typed questions

**One request, one state, many questions.**  A request names the
`state` -- text, a JSON object or an array -- and a set of questions
keyed by names the caller chose.  The state is sent once however many
questions are asked, because a System One model evaluates every question
against it in one pass.  Asking several questions is the intended shape,
not a workaround: adding a question to a request barely changes its
latency.

**Every question has a type, and the type decides the answer.**  The
contract knows the four the API defines:

| Type | Asks | Answers with |
| --- | --- | --- |
| `noul` | Is this true? | `noul`: the probability that it is, from 0 to 1 |
| `choice` | Which of these options? | `choice`, `probabilities` for every option, `confidence` |
| `score` | Which level of this scale? | `score`, `legend`, `probabilities` for every level, `confidence` |
| `box` | Where is this in the image? | `box` (`top`, `bottom`, `left`, `right`), `confidence` |

A `choice` carries the options it chooses between and what each means; a
`score` carries its ordered levels.  A `noul` needs neither.  A `box`
needs the model to read images, which is a declared capability.

**The answer is checked against the question that asked it.**  A result
carries one answer per question, keyed by the same name, and no answer to
a question nobody asked.  Each answer must be the type its question asked
for: a choice is one of the criteria's options, a score lies on the
levels, a score's `legend` names exactly those levels, every probability
is a number from 0 to 1 and names something the question offered, and a
box's edges are fractions of the image with `top` above `bottom` and
`left` left of `right`.  A malformed answer is refused before a caller
reads it, so no consumer has to re-decide what malformed means.

**Capabilities are declared, and gated.**  The capability's own keys are
`:noul`, `:choice`, `:score`, `:box`, `:images`, `:long-context`,
`:confidence`, `:calibrated`, `:abstain`, `:stream`, `:audio`,
`:embeddings`, `:carried-state` and `:schema`, and they sit in a model's
`:capabilities` beside `:vision` and `:thinking`: one model declares all
of what it can do in one place.  A question of a type the model does not
answer is refused before the provider is called, with the reason; so is a
request that asks for an image, a larger context, carried-over state, a
response schema or partial results on a model that does not declare them.
This is the difference between an optional feature and a silently
degraded one: a local model that cannot read images is not a worse model,
it is a model that says so.  Jev, for instance, has no streaming and
takes no audio, and the contract makes that a fact a caller can read
rather than a failure it discovers.

**A confidence is not a calibration.**  A confidence is the model's own
number about how peaked its answer was.  It may only be read as a
probability of being right when the model declares `:calibrated` *and*
the artifact it names records how the calibration was fitted -- a
`:method` that is not `none`, and a `:source` saying where that is
documented.  Both halves are needed: a declaration is a provider's claim
about itself, and the artifact is what a training run (or, for a hosted
model, the vendor's published method) wrote down.  Nothing in this module
reads a threshold: the caller owns its policy, and the interface only
reports what the model said.  A consumer's threshold and a model's
confidence therefore never get confused for one another in code.

**An abstention is explicit.**  A model that will not answer says so
once, with a reason, and answers nothing.  It is one or the other, never
both.  A consumer's conservative fallback stays in the consumer: the
interface reports that there is no decision, and what the consumer does
about that is its own policy.

**A decision is asynchronous, cancellable and bounded.**  The interface
returns a handle before the provider answers.  The request's `:deadline`
(or `harness-provider-system-one-timeout`) bounds it; a decision past it
is cancelled and rejects.  `harness-provider-system-one-cancel` cancels
one, and cancelling twice changes nothing.  Every call has an id and a
settled flag: an answer, a failure or a partial result that arrives after
the call was cancelled, timed out or answered is dropped, and a provider
that answers twice settles once.

**One artifact, two sides.**
`harness-provider-system-one-artifact-problems` validates the metadata a
model ships: the schema version, the artifact and model versions, the
questions the model answers, the dataset and its provenance and splits,
the evaluation and its calibration, and what the model needs at run
time.  `harness-provider-system-one-artifact-agrees-p` checks that the
request in front of a model is the shape its artifact was made for: the
same questions, of the same type, with the same options and the same
number of levels.  A model asked something it was not made for answers
confidently and wrongly, so the disagreement is refused rather than sent.
A training run and an inference call therefore read one shape instead of
each keeping a copy that looks alike.  The fixture in
`test/fixtures/system-one/` is that agreement made concrete: the
artifact names the three questions, and the cases are the data.

## The providers that ship

**The System One API adapter**
(`harness-provider-system-one-register-jev`) speaks the published
contract over HTTP: `POST {base}/v1/systemone` with `model`, `state` and
`questions` (and `assets` when images are sent), answered with
`answers`, `model` and `usage`.  The API key goes in the `Authorization`
header, read from `harness-provider-system-one-jev-api-key-env`
(`TYPESAFE_API_KEY`), then auth-source.  The two danger-zone headers the
API defines -- images and long context -- are sent only when the request
asks for what needs them.  The `model` field of the answer is kept as the
API sent it, because it names the version an alias resolved to: a caller
that logged `jev-latest` can still tell which model decided.  The base
URL is a setting, so a reseller or gateway that serves the same contract
is the same adapter with another `:base-url`, and the transport is a
parameter, so the wire format is tested against a stub with no network.
`harness-provider-system-one-jev-refresh-models` reads `GET /v1/models`
on request, which is what an account may actually send.

**The fixture adapter**
(`harness-provider-system-one-register-fixture`) answers from a directory
of deterministic cases with no model call at all, which is what the tests
and the demo use.

No new transport, no new job queue, no new lifecycle: a decision is one
HTTP call for a hosted model, and a provider that keeps anything
registers it through the same `harness-define-provider` as every other.

## What it does not own

This module is the contract, not the models and not the consumers.  The
tool-call safety classifier owns its questions, data, objective and
training; the thread router owns its questions, its thresholds and its
end-user behaviour; the audio backchannel owns its pipeline, its causal
streaming and its silence-or-speak output.  Each of them registers a
provider or consumes this contract.  Their fallbacks stay theirs,
because a fallback is a product decision and this is a contract.

Nothing here trains a model, uploads anything, or decides on a caller's
behalf.  The only provider that ships data is the fixture, and its data
is synthetic and in the repository.  No model prediction authorizes a
tool, weakens an access policy or changes a thread's identity: those
remain `permission/decide`'s and the session's, whatever a model says.

## Alternatives

- **A second interface beside the provider interface.**  It is what this
  change first was, and it was wrong twice over: it duplicated a registry,
  a catalogue, a lifecycle and a model-selection rule that
  `harness-provider.el` already has, and it justified itself by treating
  the harness's own completions (the permission judge, naming, recaps) as
  things needing a new interface, which they are not.  One interface, one
  more capability.
- **A completion adapter that asks a chat model for JSON.**  It makes a
  chat model impersonate a System One model: the answers are slower,
  costlier, and carry a probability the model invented rather than one
  its training produced.  It also encodes "a chat model is what a
  decision model is" into the design, which is the opposite of the fact.
- **A kind of provider rather than a capability.**  Then a model that
  completes and answers System One questions could not be one provider,
  and the interface would forbid something the hardware does not.
- **A single-label classifier contract** (`labels` in, `label` out).  It
  cannot say "which of these options, and how sure", "how far along this
  scale", or "is this true, as a probability".  Those are the shapes
  System One models actually answer.
- **Making every capability mandatory.**  Then a model that cannot read
  images cannot register, and a consumer that wants images cannot tell
  which of its models can.  Declaring and gating keeps both sides honest.
- **Trusting a model's confidence as a probability.**  A confidence from
  an uncalibrated model is a number, not a probability.  Requiring the
  declaration and the artifact's calibration record keeps a consumer from
  reading it as one by accident.
- **A dataset registry or a model loader here.**  Both belong to whoever
  trains the model.  This module reads an artifact and asks a provider;
  it stores no dataset and loads no weights.

## The shape of the change

- `lisp/modules/harness-provider.el`: `harness-define-provider` takes
  `:system-one`, kept with the other hooks beside the provider record;
  `provider/system-one-p` and `provider/system-one` are the interface,
  the latter the funnel every request passes, which refuses a model the
  policy does not allow and a request the model's contract does not
  allow before the provider is called.
- `lisp/modules/harness-provider-system-one.el`: the question types and
  the capability gate, the request and per-answer validators, the
  artifact validator and the agreement check, the deadline,
  cancellation and settled-once guard, the answer readers, the fixture
  provider and the System One API adapter.
- `lisp/modules/harness-provider-system-one-test.el`: the capability on
  the interface (including one model that both completes and answers
  System One questions), the request gate per question type, the result
  gate per answer type, abstention, the calibration rule, cancellation,
  the deadline, a late answer, a provider that fails or answers with no
  promise, the artifact, the fixture provider, and the API's exact wire
  request and answer against a stub transport.
- `test/fixtures/system-one/`: `artifact.json` and `cases.jsonl`, the
  deterministic fixture both sides read.
- `scripts/system-one-demo.el`, `scripts/system-one-demo.sh`: three
  models answering one request, the API's wire request printed, and the
  refusals, the artifact and a cancellation.
- this page, the module page and `docs/architecture.md`.
