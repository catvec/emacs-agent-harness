# Provider diagnostics, seen running

Four attempts through the real OpenAI-compatible completion path, with
the HTTP layer faked and nothing sent anywhere:

```sh
demo/provider-diagnostics/demo.sh
```

```
key file: /tmp/provider-diagnostics-demo-…/provider-diagnostics.key (mode 600), key=…, lines=8
…
```

| Attempt | What changed | Line says |
| --- | --- | --- |
| 1 | nothing yet | `prefix=first`, `expected-cold=first`, `prev=-` |
| 2 | nothing | `prefix=identical`, `preserved=5`, `prev=pd-…-1` |
| 3 | one user message appended | `prefix=appended`, `preserved=5` |
| 4 | the tool description changed | `prefix=diverged`, `at=3:tools`, `expected-cold=tools-change` |

Attempt 3 is the case the whole change exists for: the checkpoints at
`model`, `settings`, `system/0`, `tools` and `message/1` are unchanged,
and only the new message's checkpoint is new, so the previous prefix
was preserved even though the whole-request digest changed.

Attempt 4 shows the other direction: the same conversation, one changed
tool description, and the first differing checkpoint is the tool schema
-- not a message. `preserved=3` counts the checkpoints that still
matched (model, settings, system).

The response lines carry only what the response reported:
`response-id=gen-demo-1`, `provider=Morph`, `served-model=…`,
`cache-read=1024`, `cost=0.0004 cost-source=provider currency=USD`. The
fixture reports no cache write, so `cache-write=unknown`, not `0`.

## What the run does not show

The fake response always reports the same `cache-read`, so the demo does
not show a real cache miss or a real serving host. It shows that the
harness records the prefix and the reported serving facts in one place,
content-free, which is what makes a real miss decidable later.

The key file line names its path and mode; the key itself is never
printed, only its short id. The last line is the leak check.

## The output

[`demo-run.txt`](demo-run.txt) is one run's output, kept so the fields
can be read without running it. [`demo-frame.png`](demo-frame.png) is
the same four attempts shown in a live Emacs frame by
`provider-diagnostics-demo-present`, with the lines where a person can
read them.

The lines are wrapped to the frame in that picture, so a long field's
value can run onto the next line; the saved output has each line whole.
