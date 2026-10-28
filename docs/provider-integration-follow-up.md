# Provider integration follow-up (2026-10-27)

This work follows the [screenshot-evidence research session](harness:session/a0510ccd-73dc-4805-b036-4aebe34536ac). It separates image delivery and tool contracts from an agent's observable verification behavior. No screenshot-enforcement or minimum-summary rules were added.

## Image capability defect and fix

`harness-responses--entry-model` discarded catalogue `input_modalities`. Provider normalization then supplied `("text")`; `harness-agent--vision-p` consequently returned false. Screenshot tool results lost their image data and acquired the notice that only the user could see them. Calling `read_file` was not sufficient to establish visual inspection.

The parser now copies a nonempty list of string modalities to `:input-modalities`. It does **not** infer capability from a familiar model name, provider-wide `:vision`, or reasoning levels. Explicit text-only metadata stays text-only. Missing, null, empty, false, and malformed metadata retain the existing conservative text default. The unlisted-model resolver is unchanged: unknown models do not gain image capability.

Field-name corroboration: OpenAI's [Codex model metadata source](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/openai_models.rs) describes `ModelInfo.input_modalities` as the input modalities accepted by the backend. This is public schema evidence, **not** a capture of this account's current `/v1/models` response. Its legacy image-capable default is deliberately not copied here. Without affirmative metadata, this fix does not assert support. A live account that omits the field still requires authoritative capability information before image delivery can be enabled.

### Regression coverage

`harness-provider-responses-catalogue-controls-image-delivery` exercises eight catalogue cases through:

1. JSON model-list response parsing;
2. actual provider registration, normalized cache, and `provider/model` lookup;
3. agent preparation of both a user attachment and a `read_file`-style screenshot tool result;
4. the Responses HTTP request builder and JSON serialization round-trip.

For the image case it asserts the exact inline PNG bytes in both `input_image` parts. For other cases it asserts text fallback and absence of any image data URL. Every case uses the same familiar `gpt-4o` name, so accidental name-based vision assumptions fail the test. HTTP/account behavior is mocked; these tests establish the client boundary, not remote model perception.

The existing Responses suite passes (39 tests). A separate fault-injection run restoring metadata loss makes the new regression fail with normalized `("text")` versus expected `("text" "image")`. Full verification and comparison evidence are linked in the task hand-in.

After loading the change, refresh the model catalogue (or restart the harness) before assessing an already-cached model. Inspect the normalized entry; missing upstream metadata is not fixed by refreshing.

## Optional-field boundary

See [the serialized-schema audit](provider-schema-audit.md) for source/wire fixtures, the documented Responses strict-mode default, parser evidence, and permission-guard regressions. Empty strings are not silently made into inherited values, and forbidden fields do not become acceptable because they are empty or null.

## Controlled comparison

See [the comparison report](provider-comparison.md) for the identical synthetic task, evidence fixtures, available routes, per-request identity/delivery records, and observed acceptance/rejection outcomes. Routed model-family trials must not be described as tests of the direct ChatGPT or Claude integrations. Current session labels and historical fallback labels are not per-request identity evidence.

In completed common-route scratch trials, GPT-4.1 Mini rejected the mismatch **2/2** times, Sonnet 5.5 **2/2**, and DeepSeek V4.1 Flash **1/1** (its repeat was billing-blocked). All three described the correct fixture in two completed controls each. DeepSeek also rejected and recaptured the unrelated fixture in one original trial; several other wrong-image trials stopped without corrective capture. This is not a model ranking. Astra never reached generation, and no direct ChatGPT/Anthropic comparison or live Responses strictness A/B was possible with the isolated credentials.

The experiments comprise **21 runs: 16 completed and 5 billing-blocked**, with **55 requests and 22 image-bearing requests**. The paired replication fixed initially cumulative response-identity recording; every successful replication request has its own exact model identifier and response ID. The parent independently checked both committed manifests, fixture hashes, request image references, prompts, schemas, counts, final states, and replication identities. The researcher's live ChatGPT session still received the text-only notice, so pixel inspection was attributed to the [image-capable fixture inspector](harness:session/f6d0492a-2105-4da3-b02f-367bfc5b8e6a/message/n-wdghogzat6), not falsely claimed there. At re-hand-in on 2026-10-28 the parent session ran on `deepseek` and inspected all three committed fixtures itself; see [the parent inspection note](evidence/provider-comparison/parent-inspection.md). No trial result changed.

These are controlled, fixture-backed status-change microtasks, not full UI implementation sessions. The custom loop bypasses the normal agent capability gate, whose separate local regression covers Responses. The static fixture and the very small, unequal completed samples constrain what can be concluded.

A failure to reject incorrect evidence **after confirmed image delivery** is an observable model/task failure in that trial. Failure before delivery is an integration or availability failure, not a visual-verification result. A successful trial does not establish reliability or a ranking; conclusions must retain the reported sample size and prompting limitations.

## Project verification

The full `scripts/test.sh` run covered **161 suites**. Its first run used this session's scratch directory as `TMPDIR`, which was a mistake: `harness-files-scratch-owner` correctly treats paths beneath `harness-UID/SESSION/` as session scratch, so project-list tests no longer saw ordinary projects. Longer paths also affected socket limits and literal/truncated UI-path assertions. This produced failures in 11 suites, not provider regressions.

After inspecting the complete logs, only those 11 suites were rerun with `env -u TMPDIR`, the project's normal temporary-directory setting. All passed (one intentionally skipped project case). No source changes were made to suppress the failures. Across the latest saved result of every suite: **5,376 tests, 5,348 expected results, 28 skips, zero unexpected results**. That first aggregate was a full run plus targeted environment-corrected reruns, not a claim that the initial full command exited successfully.

At re-hand-in on 2026-10-28 the caveat was removed: one complete `scripts/test.sh` execution with the normal temporary settings ran **161 files, 0 failed, 196 s wall**, again **5,376 tests, 5,348 expected, 28 skipped, zero unexpected**. The focused suites also re-ran clean on that date (Responses 39, schema boundary 6, agent images 23), and `scripts/lint.sh` exited 0 with the same pre-existing warnings.

The full run includes **39 Responses**, **6 new schema-boundary**, **66 settings**, and **23 agent-image** tests, all passing. `scripts/lint.sh` exited 0, with warnings in unchanged files only. Complete logs are retained in `/var/tmp/harness-1000/de1c364f-1267-4d52-aba0-6287edccaeba/`: `full-tests.log`, `full-test-logs/`, `environment-rerun.log`, `environment-rerun-logs/`, `lint.log`, and the separate `capability-defect-reproduction.log`. The hand-in links the command results.

The comparison runner is opt-in research code, not part of the production suite. Its offline loading/integrity check and its live experiment evidence are reported separately; a mocked provider test is never counted as a live model trial.
