# The provider diagnostics lines, run by the provider itself

Four completions through the real OpenAI-compatible path
(`harness-openai--complete`) with the HTTP layer replaced for the
duration. Nothing leaves the process; the endpoint's key is a literal
test string. Every line below is written by the code the harness runs,
not by the demo.

```sh
demo/provider-diagnostics/demo.sh
```

The demo prints the four request/response line pairs and then a leak
check. In one run:

```text
key file: /tmp/provider-diagnostics-demo-8A2o7g/provider-diagnostics.key (mode 600), key=53f4d43d, lines=8

provider-diagnostics: request attempt=pd-b-loqqrq-1 session=demo ... v=1 chunks=5 bytes=609 prefix=first preserved=0 at=- expected-cold=first prev=- cps=0:model@35:...,1:settings@243:...,2:system/0@319:...,3:tools@527:...,4:message/1@609:... final=4@609:...

provider-diagnostics: request attempt=pd-b-loqqrq-2 ... prefix=identical preserved=5 at=4:message/1 expected-cold=warm prev=pd-b-loqqrq-1 ...

provider-diagnostics: request attempt=pd-b-loqqrq-3 ... chunks=7 bytes=687 prefix=appended preserved=5 at=4:message/1 expected-cold=warm prev=pd-b-loqqrq-2 ... final=6@687:...

provider-diagnostics: request attempt=pd-b-loqqrq-4 ... prefix=diverged preserved=3 at=3:tools expected-cold=tools-change prev=pd-b-loqqrq-3 ...

leak check: no prompt marker, tool description, key or API key in any line
```

The four states are the four things a caller most needs to tell apart:

| Attempt | Request | `prefix=` | Why |
| --- | --- | --- | --- |
| 1 | a first message | `first` | nothing earlier in the process to compare with |
| 2 | the same request | `identical` | all five checkpoints match |
| 3 | one appended user message | `appended` | the previous final checkpoint is a checkpoint in the new request |
| 4 | a changed tool description | `diverged`, `at=3:tools` | the tool-schema segment differs; the earlier ones still match |

Attempt 4 also shows the expected-cold label the divergence implies:
`expected-cold=tools-change`. The cached prefix the provider would keep
is not the one this request sends.

The response lines carry what the synthetic response reported:
`response-id`, `generation`, `request-id`, `provider=Morph`,
`served-model`, `prompt`, `cache-read`, `output`, `cost` with
`cost-source=provider`, `currency=USD`, and the `cache-write=unknown`
the response did not supply. `key=` is the key's id, eight hex digits;
the key itself is never printed.

Reading the lines is described in
[`docs/design/provider-diagnostics.md`](../../docs/design/provider-diagnostics.md).
The same run's whole output is kept in
[`docs/evidence/provider-diagnostics/demo-run.txt`](../../docs/evidence/provider-diagnostics/demo-run.txt),
and a picture of the lines in an Emacs frame in
[`docs/evidence/provider-diagnostics/demo-frame.png`](../../docs/evidence/provider-diagnostics/demo-frame.png).

## In a running Emacs

`provider-diagnostics-demo-present` runs the same four attempts and
shows the lines in `*provider-diagnostics demo*`, which is what the
picture shows. It needs no network either.

## What the demo does not show

The provider's real cache behaviour. The HTTP layer is fake, so
`cache-read=1024` is a number the fixture chose; the demo proves the
harness reports what a response supplies and keeps it separate from the
configured route, not that any real host answered. Nothing here is a
readiness result for either target.
