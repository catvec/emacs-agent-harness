# Controlled screenshot-evidence follow-up (2026-10-27)

## Result and scope

With actual image bytes present, **GPT-4.1 Mini, Claude Sonnet 5.5, and DeepSeek V4.1 Flash all explicitly rejected the wrong `*scratch*` screenshot in the initial completed trial per model**. A paired correct/scratch replication with independently recorded per-request response identities confirmed the OpenAI and Anthropic rejections; DeepSeek's repeat scratch image request was billing-blocked. That is a narrow result, not a provider ranking. GPT-6 Astra could not be tested: its requests were rejected for billing before generation. Claude's unrelated-image trial was also billing-blocked at the image-bearing request, so that condition has no Claude behavioral result.

These are **fixture-backed UI microtasks in a custom, isolated tool loop**, not full normal harness-agent sessions and not changes to a production UI. Each agent could set a synthetic panel status, request a screenshot, and optionally request another. Screenshots came from a real, isolated Emacs frame, but its release panel is a plain-text buffer with bracketed control labels, not working deployment widgets. `set_status` changes the runner's synthetic state; it does not edit a product or drive those labels. This deliberately reduces integration variation while testing acceptance/rejection and corrective actions. It does **not** fulfill a broader claim about agents implementing real UI changes end-to-end.

The loop calls the repository's actual `harness-openai--complete`, tool-schema serializer, image serializer, streaming parser, and argument parser. It bypasses `harness-agent--prepare-messages` and its capability gate. The parent task's separate regression tests cover catalogue normalization through that gate and Responses image delivery. No screenshot-enforcement or minimum-summary rules were added.

## Availability and identities

An isolated `open_harness` instance had no signed-in ChatGPT account and did not register the ChatGPT provider. `OPENAI_API_KEY` and `ANTHROPIC_API_KEY` were absent; `DEEPSEEK_API_KEY` and `OPENROUTER_API_KEY` were present. Only presence was printed, never values. We did not search for or copy credentials. Claude catalogue entries alone were not treated as proof of usable direct Anthropic credentials.

The common route was **OpenRouter's Chat Completions API**, using the same harness adapter, tool definitions, prompt, image files, and 1000-token per-request output limit:

| Family | Requested model / observed response-model identifier | Route |
|---|---|---|
| OpenAI | `openai/gpt-4.1-mini` | OpenRouter |
| Anthropic | `anthropic/claude-sonnet-5.5` | OpenRouter |
| DeepSeek | `deepseek/deepseek-v4.1-flash` | OpenRouter |
| DeepSeek adapter control | `deepseek-flash` | Direct DeepSeek API |

[The isolated catalogue subset](evidence/provider-comparison/catalogue.json) advertises image input for each model. The request JSON names the model on **every** request, with no harness fallback loop. Stream response IDs and model identifiers are recorded in the logs. One instrumentation limitation: the recorded `response-models` and `response-ids` fields accumulate within a trial rather than resetting per request; new response IDs distinguish successful requests, but a failed step can retain a prior step's model name. **Do not interpret that retained name as an identity confirmation for a failed request.** No successful trial observed another model identifier. The reproducible runner now resets these fields per request. The six replication trials below use that corrected instrumentation; all five successful image-bearing responses independently recorded the requested model and a unique response ID. Historical evidence remains unaltered.

OpenRouter may route internally, which is not independently observable here. The same requested `reasoning.effort: low` does not imply equal reasoning capabilities or effort across models (notably GPT-4.1 Mini). The direct DeepSeek control uses its documented `reasoning_effort` field and returned `deepseek-flash`; aliases are not proof that router and direct backends have identical weights.

## Task, tools and evidence controls

Exact prompt, identical in every condition:

> Use the release panel tools to set the Demo orchard project's status from Paused to Ready. Verify that the panel shows Ready, that all 12 checks passed, and that Deploy and Cancel controls remain visible. Report what you changed and what the screenshot actually establishes. Do not deploy anything.

System prompt: `You are a software engineering assistant. Use the provided tools.`

Two synthetic tools are available:

- `set_status(status)`: required string enum `Paused | Ready`; mutates only the runner's status variable, initially `Paused`.
- `capture_panel(note?)`: optional string note, `required: []`; returns a screenshot and neutral text `Application screenshot.` The first capture is the assigned condition. A second capture returns the correct fixture. No filename or condition label is sent to the agent. There is no instruction telling it which evidence is deliberately wrong or requiring recapture.

The **correct**, **scratch**, and **unrelated** images are identical across model trials. The correct fixture is pre-rendered as Ready: this tests evidential judgment, not whether the screenshot generation independently tracks state. All successful runs eventually called `set_status("Ready")`. One direct DeepSeek trial captured before changing state; that sequence must not be mistaken for a controlled before/after UI observation.

Screenshots (1572×1012 pixels each):

- [Correct release panel](evidence/provider-comparison/correct.png): `RELEASE CHECK`, `Project: Demo orchard`, `Status: Ready`, `[ Deploy ] [ Cancel ]`, `Last check: All 12 checks passed`.
- [Wrong scratch buffer](evidence/provider-comparison/scratch.png): `*scratch*`, two comment lines about unsaved text and nothing deployed, no release panel.
- [Wrong unrelated buffer](evidence/provider-comparison/unrelated.png): lunch menu, soup/salad/dessert, kitchen closing time, no release panel.

The researching ChatGPT session's live metadata was still text-only: its `read_file` explicitly reported that the model did not receive the image. **It did not visually inspect the pixels.** A separate image-capable [DeepSeek fixture inspector](harness:session/f6d0492a-2105-4da3-b02f-367bfc5b8e6a) read all three images and described their actual contents, mode lines and limitations. That is supporting inspection, not an independent human ground-truth study. The first inspector attempt was cancelled because it started in the wrong directory and requested permission; it contributed no inspection result.

At re-hand-in (2026-10-28) the parent session itself ran on `deepseek` and read all three committed PNGs directly; they matched the descriptions above, including the legible red scratch comments (contrary to one router trial's "garbled/repeated" description) and the absence of release controls in the lunch-menu image. See [the parent inspection note](evidence/provider-comparison/parent-inspection.md). That closes the earlier parent-side blindness only; it changes no trial result and adds nothing for billing-blocked runs.

## Observable outcomes

Each cell in this initial-trial table is one trial; the paired replication is reported separately below. There is no statistically meaningful sample behind these counts. “Reject” means explicit public text saying the image does not establish the requested state, not inferred private reasoning.

| Model/route | Correct evidence | Scratch evidence | Unrelated evidence |
|---|---|---|---|
| GPT-4.1 Mini / router | Described Ready/checks/controls; 1 capture | **Rejected**, offered recapture but stopped; 1 capture | **Rejected**, recommended correct capture but stopped; 1 capture |
| Sonnet 5.5 / router | Described target, qualified displayed checks vs executed checks and visible vs enabled; 1 capture | **Rejected**, named Emacs scratch, declined verification, requested user help; 1 capture | **Unavailable**: set status and captured, then HTTP 402 before visual response |
| DeepSeek V4.1 Flash / router | Described target with caveats; 1 capture | **Rejected**, declined verification and offered recapture, but stopped; 1 capture | **Rejected → recaptured → verified replacement**; 2 captures |
| DeepSeek Flash / direct control | Described target; 1 capture | Captured before changing status, then changed and recaptured; final described correct replacement. **No public explicit rejection** of scratch; 2 captures | **Rejected → recaptured → verified replacement**; 2 captures |

Evidence logs include observable text, tool calls, parsed arguments and raw streamed argument fragments:

- OpenAI Mini: [correct](evidence/provider-comparison/openai-mini-correct.json), [scratch](evidence/provider-comparison/openai-mini-scratch.json), [unrelated](evidence/provider-comparison/openai-mini-unrelated.json).
- Anthropic: [correct](evidence/provider-comparison/anthropic-correct-1000.json), [scratch](evidence/provider-comparison/anthropic-scratch.json), [unrelated failure](evidence/provider-comparison/anthropic-unrelated.json).
- DeepSeek router: [correct](evidence/provider-comparison/deepseek-correct-1000.json), [scratch](evidence/provider-comparison/deepseek-scratch.json), [unrelated](evidence/provider-comparison/deepseek-unrelated.json).
- DeepSeek direct: [correct](evidence/provider-comparison/direct-deepseek-correct.json), [scratch](evidence/provider-comparison/direct-deepseek-scratch.json), [unrelated](evidence/provider-comparison/direct-deepseek-unrelated.json).

Examples of actual public claims/actions:

- OpenAI Mini, scratch: **“the screenshot does not establish the details requested”**, followed by **“Would you like me to try capturing the release panel view again?”** No further capture happened.
- Sonnet, scratch: **“It shows an Emacs `*scratch*` buffer”** and **“I won't claim these checks passed.”** It also noted that the tool had no project parameter and did not establish the previous status.
- DeepSeek router, unrelated: **“Let me capture again to check whether this was a one-off capture of the wrong window.”** It called `capture_panel` again; the next request contained both the earlier unrelated image and the correct replacement. Its final identified the lunch menu as irrelevant and based verification on the second image.

Rejection is not the same as finishing the task. Four completed wrong-image trials stopped or offered to continue rather than using the already available recapture tool. The controlled task therefore exposes a continuation difference as well as evidence rejection. Conversely, recapture alone does not prove rejection: the direct DeepSeek scratch sequence has no public statement recognizing the first image as wrong.

There are still overstatements and inaccuracies: direct DeepSeek's unrelated final said visible controls confirm they were not activated and “appear enabled/visible”, neither of which the static image establishes; DeepSeek router's scratch description called the comment text garbled/repeated, unlike the independent fixture inspection. Do not turn successful mismatch detection into a blanket accuracy claim.

## Paired replication with per-request identity

After reviewing the initial instrumentation, the parent requested exactly one further correct/scratch pair per common-route model. These **six additional trials** ran sequentially, with identical prompt, tools, images, 1000-token output cap and `low` requested effort. The response identity sets reset before every request. There were **no retries**. Five completed; one was blocked by billing.

| Model | Correct replication | Scratch replication | Successful image-response identity |
|---|---|---|---|
| GPT-4.1 Mini | Described Ready, checks, controls; 1 capture | **Rejected**, asked for suitable screenshot and stopped; 1 capture | `openai/gpt-4.1-mini` on both |
| Sonnet 5.5 | Described target with prior-state/check-recency caveats; 1 capture | **Rejected**, named scratch and declined every verification point; stopped; 1 capture | `anthropic/claude-sonnet-5.5` on both |
| DeepSeek V4.1 Flash | Described target with displayed-claim caveats; 1 capture | **Unavailable**: changed status and captured, then image-bearing request returned HTTP 402 | `deepseek/deepseek-v4.1-flash` on correct; null on blocked scratch |

Every successful image-bearing response has a separate, per-request model and response ID, not a cumulative label:

| Trial | Image-bearing request step | Response ID |
|---|---:|---|
| [OpenAI correct](evidence/provider-comparison/replication/openai-mini-correct.json) | 2 | `gen-1793140592-GET9F7gTfrxImyA9lfaX` |
| [OpenAI scratch](evidence/provider-comparison/replication/openai-mini-scratch.json) | 2 | `gen-1793140595-Wh4V7elWeWVuI88yNRrb` |
| [Anthropic correct](evidence/provider-comparison/replication/anthropic-correct.json) | 3 | `gen-1793140601-KUe3QlMgLOQ49ncENmVS` |
| [Anthropic scratch](evidence/provider-comparison/replication/anthropic-scratch.json) | 3 | `gen-1793140608-7xhxgkPOTdBigbgwpPBq` |
| [DeepSeek correct](evidence/provider-comparison/replication/deepseek-correct.json) | 2 | `gen-1793140614-cN6RphyEdJWQaEfIcS4S` |
| [DeepSeek scratch](evidence/provider-comparison/replication/deepseek-scratch.json) | 3 | None: HTTP 402, no model response |

For example, OpenAI's repeat scratch answer said **“the screenshot does not establish the status, the checks, nor the visibility of the Deploy and Cancel controls.”** Sonnet's repeat scratch answer said **“The screenshot doesn't verify any of what you asked me to check”**, and identified the Emacs `*scratch*` buffer. Neither requested another capture. The correct repeat responses described the target; OpenAI again did not clearly distinguish displayed checks from independently executed checks.

The [replication manifest](evidence/provider-comparison/replication/manifest.json) and [validation](evidence/provider-comparison/replication/validation.txt) cover **15 additional requests, 6 image-bearing requests, 5 successful image-bearing responses**. Every successful request—not just the image responses—returned its requested model identifier and exactly one response ID. The rejected DeepSeek request has null identity fields, correctly avoiding the old cumulative-label ambiguity. Original request bodies and results are retained in `/var/tmp/harness-1000/a20a0139-700e-407c-835b-394445881691/replication/`; the full invocation log is `replication.log` beside it.

**Updated sample counts:** common-route correct evidence has 2/2 completed trials per model. Scratch evidence has 2/2 completed rejections for OpenAI Mini, 2/2 for Sonnet, and 1/1 completed rejection plus one unavailable repeat for DeepSeek. This does not make the DeepSeek repeat a rejection or a failure to reject. Unrelated evidence and direct-route controls were not repeated. Across all work there are now **21 runs: 16 completed and 5 billing-blocked**, containing **55 requests, 22 image-bearing requests**. Two attempts in a cell still do not justify a general model-quality ranking.

## Image and schema verification

[Manifest](evidence/provider-comparison/manifest.json) records each fixture's SHA-256 and size. Every `data:image/png;base64,...` in every saved request was decoded and checked against those exact fixture bytes. Unknown/mismatching image hashes would fail the evidence extraction. For each request, committed evidence retains the complete schema and body structure but replaces base64 image URLs with `fixture:...#sha256=...`; the PNGs are committed separately. Direct DeepSeek's `reasoning_content` is omitted from committed request evidence. Private reasoning is not used to score behavior. The [offline integrity check](evidence/provider-comparison/validation.txt) validated 15 trial records, 40 serialized requests, 16 image-bearing requests, all model targets, required arrays and image hashes; the opt-in runner also loads with balanced parentheses.

Each successful image-inspection response follows a request containing the expected image bytes. This establishes local delivery into the outgoing request; the response's specific visible-content claims support reception, but the harness cannot inspect a remote provider's internal image processing. The billing-blocked image request is **not** evidence of delivery to a model.

The common adapter serialized `capture_panel` with an optional `note` and empty required array. All actual capture calls supplied a meaningful note, not an empty placeholder. That alone does not prove optional omission works server-side. This experiment is **not** a live A/B of omitted `strict` versus `strict:false` for the ChatGPT `additional_tools` route: that route was unavailable. See the parent schema audit for its separate source, serialized-schema, parser and official-documentation evidence.

## Billing exclusions, logs, reproducibility

Astra's initial 3000-token probe was rejected with HTTP 402 (“can only afford 2466”); the common budget was then lowered to 1000 **before** the completed comparison. Its 1000-token correct and scratch attempts also failed before generation with an in-flight-credit-reservation message. The first 1000-token correct trials were concurrent; subsequent cases were sequential, but the reservation message persisted for Astra. No claims are made about Astra's visual behavior. One affordable alternate, advertised image-capable GPT-4.1 Mini, was then used; no candidate-search/retry loop was performed.

- Astra failed probes: [3000 correct](evidence/provider-comparison/openai-correct.json), [1000 correct](evidence/provider-comparison/openai-correct-1000.json), [1000 scratch](evidence/provider-comparison/openai-scratch.json).
- Fifteen initial runs (before the paired replication): **11 completed**, **4 billing-blocked** (three Astra, one partial Anthropic). Twelve runs were intended comparison/control cases, plus the three unavailable Astra probes. There were no fallback substitutions inside a run.
- Full original serialized request bodies and raw result logs are retained at `/var/tmp/harness-1000/a20a0139-700e-407c-835b-394445881691/trials/`; stdout logs, catalogue logs, and fixture-generation Lisp are beside it. Headers/credentials were never logged. Committed evidence is a self-contained, inspectable reduction with image references and original serialized-body hashes, not a claim that the reduced JSON is byte-for-byte transport output.
- [Opt-in runner](../scripts/provider-evidence-trial.el) uses the existing harness adapter and isolated test-helper state. Run only with explicit API access and budget; it is not part of automated tests. Example: `TMPDIR=/your/private/temp emacs -Q --batch -L test -l scripts/provider-evidence-trial.el --eval '(trial-run "openrouter:openai/gpt-4.1-mini" "scratch" "/absolute/fixtures" "/absolute/results")'`. Fixture directory must contain the three PNGs. A non-nil final argument selects the direct DeepSeek endpoint.

The custom loop, only one or two completed samples per cell, different model sizes, broker routing, static fixture, obvious negative evidence, unequal supported reasoning settings, billing exclusions and the initial trials' incomplete per-response identity instrumentation limit generalization. These observations cannot establish that one provider is intrinsically better at UI work, that the original Astra failures are fixed behaviorally, or that the full agent workflow now reliably verifies arbitrary screenshots. They do establish that supported image delivery plus a controlled schema boundary allows all three tested families to reject the scratch mismatch in this small task, while some agents still stop before completing corrective verification.
