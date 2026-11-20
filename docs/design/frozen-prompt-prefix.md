# Freezing the prompt prefix the provider actually reads

## The problem this settles

A provider's prompt cache is keyed on the **bytes of the request body**
it received.  The harness used to keep only a provider-neutral payload
(`harness-replay.el`: model, thinking, system, tools, messages) and to
re-render the suffix from it.  The body that went on the wire was
rebuilt from scratch by the adapter on every request
(`harness-openai--body`, `harness-responses--body`).

Those two facts do not meet.  Any change to adapter serialization -- a
reordered field, a new setting, a different image representation, a
`:strict :true` keyword encoding as the string `":true"` -- changed
the wire prefix while the neutral payload stayed byte-identical, and
nothing reported it.  The harness could not even tell whether *it* had
changed the prefix or the provider had evicted it, because it never
kept what it actually sent.

This document decides what the harness now guarantees, and -- as
importantly -- what it does not.

## What is frozen: the prompt, not the request

The final adapter body, but **only the fields that are the prompt the
model is given** -- `harness-replay-prompt-fields`: the model, the system
material (`system` or `instructions`), the tool schema, and every message
or Responses input item.  Those are the bytes a provider's prompt cache
reads.

Every other field is per-request **metadata**: `stream`, `stream_options`,
`include`, `store`, a token budget, a temperature.  It is encoded fresh on
every request, never compared with what an earlier request sent, and
never a reason to refuse one.

This distinction is the invariant, and it is exact:

- **A prompt field must be continued.**  Every byte of it that was sent
  before is sent again, in the same place; only an array may append.
- **A metadata field may change freely.**  Freezing the whole body would
  make a change of `max_tokens` look like a change of the prompt, which is
  neither what a cache sees nor what the harness should stop a turn for.

Each prompt field is kept as a **component**, encoded once by the
adapter's own encoder, and split following `harness-json-encode`'s rules
so a body that only grew is still recognisably the same body:

- a plist whose car is a keyword is an **object**, kept field by field;
- any other list or vector is an **array**, kept item by item;
- everything else is a **scalar**, kept as its exact bytes.

A piece is itself JSON -- a plist whose `:kind` is `"scalar"`, `"array"`
or `"object"` -- because a record written with `harness-json-encode` and
read back must round-trip.  Cons cells become two-element arrays and
symbols become strings, so Lisp-native structures would not survive.

**Objects must not grow; arrays may.**  A field added to or dropped from
an object changes that object's own bytes, which is exactly where a cache
prefix ends; only an array may append.  `harness-replay--piece-diff`
enforces this, and it is what makes "an appended message changes nothing
before it" a testable claim rather than a hope.

## The seam: splice, then send bytes

`harness-replay-seam` takes the body the adapter built and returns the
**text to send**: every component an earlier request already sent is
put back as the bytes that request sent, and only the request's new
material is encoded fresh.  The transport is given `:body TEXT` with an
explicit `Content-Type: application/json`, never `:json`, because
`:json` would re-encode and undo the whole exercise.

The previous revision of this work got that wrong: it passed the seam's
text to `harness-http-request` as `:json`, so the wire body was a JSON
*string literal* rather than the body object.  That is fixed here, and
`harness-provider-openai-test` -- which asserts on what the transport
received -- is the regression test for it.

## The boundary check fails closed

`replay/frozen-check` runs at the transport boundary, on the body about
to go out.  It returns nil when every byte that was sent before is
still there, unchanged and in place.  It returns a complaint -- naming
the first divergent component by path, never by content -- when
something changed with no recorded reset.  The adapter then **sends
nothing**: the openai adapter sets `:error-kind 'permanent` and finishes
with the complaint, and
`harness-replay-a-mutation-stops-before-the-transport` asserts the
transport was called zero times.

Failing closed is a deliberate cost.  A rebuild after the splice, or a
field changed on the way to the transport, stops the turn rather than
silently paying for a full uncached prompt.  An unexplained mutation is
a bug in the harness, and the harness says so instead of billing for
it.

## Resets are explicit and recorded

A frozen body stops applying for a reason, and every reason is recorded
with an incrementing `:generation` (`replay/frozen-reset`).  The reasons
in `harness-replay-frozen-reset-reasons`:

| Reason | What changed |
| --- | --- |
| `compaction` | the conversation was replaced by a summary |
| `system` | the system prompt |
| `tools` | the tool schema |
| `model` | the model or its thinking settings |
| `route` | the endpoint or the account |
| `redaction` | a secret was taken out |
| `images-pruned` | pictures dropped from the history |
| `adapter-version` | another serialization version |
| `storage-failure` | the body could not be written |
| `too-large` | over `harness-replay-frozen-max-bytes` |
| `no-session` | a request that names no session |

A recorded reset **empties** the frozen body, so the boundary check has
nothing to refuse.  That is the whole mechanism: a change the harness
knows about is explained in advance, and a change it does not know about
is refused.  The two are never the same code path.

`session/updated` carries the changed settings, so
`harness-replay-reset-on-change` records `model`, `system`, `tools` or
`route` before the next request is built.

A session settling its prompt or its tool schema is one of those changes,
and the one that is not a setting: `session/set-system` and
`session/set-tool-schema` fix what every request starts with, so a session
that had already sent one and settles it now has a frozen body built from
a prompt this one replaces.  Both announce it on `session/updated`, which
is what records the reset -- otherwise the next request is refused as a
change nothing explained.  A session settling at its first request has
sent nothing, so there is no frozen body to stop applying and neither
announces anything.  Sessions that lived before prompts were settled at
all are the ones this repairs: their records say nil, and their next
request is the first after the settle.

## What may become the prefix: the conversation, not every request

Not every request that names a session is a step of that session's
conversation.  Three kinds are not, and all of them used to be spliced
into the frozen body and then kept as it, which left the conversation's
next step diverging from a body it never sent:

- **One-off calls.**  An auto-name, a permission judge and a recap carry the
  session's id but their own system prompt and their own message list.  Kept
  as the session's prefix, the next real step was refused at the boundary
  (`prompt component system changed with no recorded reset`).
- **A cache refresh.**  `harness-cache-warm` sends the conversation plus one
  short message the transcript does not hold, to read the cache.  Kept as the
  prefix, the next real step diverged at that message.
- **A compaction summary made from the prompt cache.**  A warm summary is
  the conversation's next request with the summarisation instruction
  appended (`harness-compaction--prefix-request`), so it reads the cache.
  The instruction is a user message of its own after the conversation's
  last, never a rewrite of that last message: the frozen bytes must stay
  byte for byte.  Kept as the prefix, the next real step would diverge at
  the instruction.

A cold summary -- another model, a hosted loop, a cache that lapsed -- is a
one-off call and says so with `:ephemeral`.  A warm one is a request of the
conversation that only reads, and says so with the flag of its own,
`:replay-read-only`: it splices, and it is never kept.  The two flags are
separate on purpose.  `:cache-refresh` already means a warmer to the
admission ranking, the demo provider and the Claude provider, and
`:ephemeral` says a call is not the conversation at all, which a warm
summary is.

| Request | Spliced? | Kept as the prefix? |
| --- | --- | --- |
| a step of the conversation | yes | yes |
| a cache refresh | yes -- this is what reads the cache | no |
| a warm compaction summary | yes -- this is what reads the cache | no |
| a one-off call, a cold summary | no | no |

`harness-replay-keeps-prefix-p` is the predicate (`harness-replay-read-only-p`
is the summary's flag), `replay/prefix` telemetry still records every request
the seam sees, and the tests are
`harness-replay-a-one-off-call-is-not-the-conversations-prefix`,
`harness-replay-a-cache-refresh-reads-without-becoming-the-prefix`,
`harness-replay-a-read-only-request-reads-without-becoming-the-prefix`,
`harness-compaction-a-cold-summary-is-not-the-conversation`,
`harness-compaction-a-warm-summary-reads-the-frozen-prefix-but-never-replaces-it`,
`harness-compaction-a-warm-summary-is-still-refused-a-changed-prefix` and
`harness-replay-the-module-defines-its-handlers-and-inits-once`.

Those faults were latent rather than billed: no `sessions/ID.frozen.json`
exists in the production state directory, so no session has yet run the
freezing path this branch adds.  They are fixed here so that the first one
that does cannot be charged for them.

The compaction ones were found after the freezing path was in place, and
are the same fault in a third shape: a summary that is not the
conversation's next step was kept as its prefix.  The warm summary had a
second one of its own -- it appended a duplicate `:messages` key to the
request plist, so the instruction it built was never the one sent, and it
edited the conversation's last user message, which is frozen bytes.

## Pictures are content-addressed, not vetoed

The earlier rule was "a request holding image bytes is never replayed",
because image bytes could change under the conversation.
`harness-images.el` already solves that: it content-addresses
tool-result pictures by SHA-1 into `sessions/ID.images/HASH.EXT`.  The
bytes a result sends are therefore the bytes the tool returned, and a
file changed underneath cannot change the prefix.  The blanket veto is
removed.

What remains is the case where history is genuinely pruned:
`harness-agent--cap-images` now emits `agent/images-pruned`, and
`harness-replay--on-images-pruned` records a reset for it.  Pruning is a
recorded change, not silent drift.

## Restart, size and a store that fails

- **Restart.**  The frozen body lives in `sessions/ID.frozen.json` and
  is read back through `harness-replay--thaw`, which keeps an empty
  array a vector and an empty object `:empty`.  A body written again
  from a nil would have `null` where the request had `[]`, which is not
  the request the provider cached.
- **Size.**  Over `harness-replay-frozen-max-bytes` (32 MiB) nothing is
  kept and a `too-large` reset is recorded.  A body of tens of megabytes
  costs more to write with every step than the miss it saves.
- **Storage failure.**  A write that fails is logged and leaves the
  session with *no* frozen body rather than a wrong one; the next
  request is built fresh and records `storage-failure`.  A wrong body is
  worse than none.

## The telemetry a future miss is read against

Every request the seam sees emits one `replay/prefix` line, and nothing
in it is a prompt's text or a digest of one:

    (:generation N :decision spliced|fresh|diverged :reason REASON
     :divergence PATH :prefix-bytes N :appended-bytes N :metadata N
     :model M :route R :at TIME)

`decision` says what the harness did with the prefix; `prefix-bytes` and
`appended-bytes` say how much was re-sent and how much was new; `reason`
says why a fresh body was built.  `divergence` names a field and an
index, never content.  That is enough to answer, later, whether a zero-
cache call followed an identical prefix -- without keeping the prompt.

A miss is then read against it: `replay/miss-note` returns `provider`
when the last request spliced an unchanged prefix, and `unexplained`
when it did not.  **Nothing is done about either.**  The harness does not
re-render, reset or retry on a provider miss, because that would turn a
provider miss into client drift as well.

## What this does not promise

Identical bytes do not promise a cache hit.  Eviction, retention, shard
placement and routing are the provider's, and this module neither
observes nor controls them.  **The harness guarantees only what it
sends.**  The distinction between client drift and provider eviction is
preserved everywhere: a `prefix=appended` diagnostic line says the
harness re-sent a preserved prefix, and a miss that follows it is the
provider's, not the harness's.

That is why the quota report attributes none of the 149.4M uncached
tokens to broken prefixes: the ledger counts a miss and never its cause.

## Relationship to the diagnostics module

`harness-provider-diagnostics.el` (owned by `t-jibzilj2`, not yet on
`main`) keeps a keyed HMAC checkpoint chain over the same final wire
body, with the vocabulary `prefix=appended|diverged` and
`at=INDEX:TAG`.  This module reuses that design's *target* -- the final
body, not the neutral payload -- rather than inventing a second
fingerprint scheme.  The two are complementary and must not be
duplicated:

- **this module** owns the bytes: what is stored, spliced and enforced;
- **that module** owns the observation: what was sent, to which
  provider, and what the provider answered.

Neither is a substitute for the other.  When the diagnostics module
lands, the frozen body is what its `prefix=appended` claim can be
checked against.

- **Keep the neutral payload and re-render the suffix.**  What the code
  did.  It cannot detect adapter drift, which is the failure being fixed.
- **A whole-body digest.**  It changes on every appended turn, so it can
  say "different" but never "the same prefix plus a suffix".
- **Normalize the body before hashing.**  Normalizing away wire-order
  differences would hide exactly the class of bug this exists to catch.
- **Refuse nothing; only log.**  Logging a mutation after it was paid
  for is the status quo the review rejected.
