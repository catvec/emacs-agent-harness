# Prefix telemetry contract, handed to t-jibzilj2

From `t-sp1j60ii` (quota/cache implementation owner) to `t-jibzilj2`
(provider readiness verification owner), 2026-11-14.

Readiness owns independent verification and already has the
privacy-preserving HMAC checkpoint chain in
`harness-provider-diagnostics.el`.  This task does **not** implement a
second fingerprint system.  It owns the bytes -- what is stored,
spliced and enforced -- and publishes the content-free decision record
that a miss is read against.

## Commit ids

| Commit | What it does |
| --- | --- |
| `dc18b8d` | Freeze the final provider body field by field; refuse an unexplained change |
| `ac77340` | Send the frozen body as `:body` bytes on both adapters; fix the Responses keep-guard; cache alert wording |
| `ed4bc0d` | Two sessions interleaved; replay suite to 42 |
| `b731dd0` | The behaviour table as an image |
| `ef092ed` | **The prompt, not the request**, is the invariant; content-free `replay/prefix` telemetry; bounded miss response |

Branch: `task/investigate-overnight-chatgpt-quota-sp1j60ii`.  Not merged,
not deployed.

## What readiness can now rely on

**The two defects `18616b4` reported are fixed.**  Both adapters sent
the seam's JSON *text* as `:json`, which encoded it a second time; and
`harness-responses--frozen-keep` compared that text with the adapter's
plist, so the ChatGPT-plan path recorded no frozen body.  Both now send
`:body` bytes with an explicit `Content-Type`, and keep the body the
adapter built.

**The invariant is the prompt.**  `harness-replay-prompt-fields` names
the fields that are frozen and continued: `model`, `system`,
`instructions`, `messages`, `input`, `tools`, `tool_choice` and the
response-format and reasoning settings.  Every other field is
per-request metadata, encoded fresh and never compared.  A readiness
check that compares a whole body byte for byte would therefore report a
divergence the harness does not consider one; compare the prompt
fields.

## The record, for a miss to be read against

Every request the seam sees emits `replay/prefix` (declared in
`harness-replay.el`):

```
(:generation N :decision spliced|fresh|diverged :reason REASON
 :divergence PATH :prefix-bytes N :appended-bytes N :metadata N
 :model M :route R :at TIME)
```

- No prompt text, no tool text, and **no digest of either**: this is a
  decision record, not a fingerprint.  The keyed checkpoint chain stays
  readiness's, so the two never disagree about what a digest means.
- `decision` is what the harness did with the prefix; `prefix-bytes` and
  `appended-bytes` are how much was re-sent and how much was new.
- `divergence` names a field and an index (`messages[0].content`), never
  content.
- `route` is `ENDPOINT-ID|ACCOUNT|BASE-URL`, so a record can be read
  against the route the request actually took.

**How to join the two:** a `replay/prefix` line and a diagnostics
request line are both per attempt and both content-free.  A
`decision=spliced` with a provider-reported zero cache-read is a
provider miss on identical bytes; `replay/miss-note` returns `provider`
for it and `unexplained` otherwise.  Neither is a harness defect, and
nothing re-renders or resets for either.

## What is verified offline

`scripts/test.sh lisp/modules/harness-replay-test.el` -- 48/48.
Provider suites: openai 56/56, responses 54/54, openrouter 84/84, chain
10/10.  Cache 23/23, agent 102/102, module-docs 11/11.  Lint exits 0.
The full suite has one failure, `harness-skills-scan-test`, which `main`
already fixed in a commit this branch predates.

**Not verified:** no live ChatGPT-plan request and no live OpenRouter
request was made in this revision.  Live cache behaviour remains
unverified, and so does the plan's quota unit.
