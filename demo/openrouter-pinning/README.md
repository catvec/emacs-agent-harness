# Price-aware OpenRouter selection

`demo.sh` prints what the policy decides for
`deepseek/deepseek-v4.1-flash-1017`, and why, in six situations:

```sh
demo/openrouter-pinning/demo.sh
```

1. **Today, as published.** The live endpoint listing, read-only.
   DeepInfra's `deepinfra/fp8` is listed at its 51%-off promotional
   rate and is the cheaper of the two vetted endpoints, so it is pinned.
2. **The promo ended.** The same catalogue with DeepInfra at its list
   rate. Cohere is now cheaper, so a *new* session would pin Cohere.
   Nothing about a session already pinned changes: it pauses instead.
3. **Both above the owner price.** Every vetted endpoint is dearer than
   DeepSeek's own peak rate, so nothing is sent at all.
4. **A rate that varies by the window of the week.** The listing cannot
   be read as one price, so the decision blocks rather than quietly
   taking Cohere.
5. **A ceiling lowered under an existing pin.** The pin is fresh and
   still listed; what changed is the price the policy allows, so it
   stops with `over-owner-price` instead of sending at the old price.
6. **A refresh that lists nothing.** An empty catalogue is not "no
   refresh": it cannot be evidence the pinned endpoint still exists, so
   it stops with `catalogue-empty`.

Cases 5 and 6 are the two that used to dispatch anyway.

The script sends no completion, installs no policy and touches no
Harness: it calls the selector and the dispatch check directly.  It
reads OpenRouter's public endpoint listing once — no credential, no
charge — and `HARNESS_DEMO_OFFLINE=1` skips even that, showing cases 2
to 6 from a stock catalogue.

The privacy evidence in the demo is a labelled placeholder, not
evidence: the demo is about price, and a real policy needs Noah's own
dated, cited evidence for each endpoint (see
[docs/openrouter-pinning.md](../../docs/openrouter-pinning.md)).

What this does not show: a real request, real cache hits, or a real
provider switch.  Those need the paid smoke plan in
[docs/openrouter-pinning.md](../../docs/openrouter-pinning.md).
