# OpenRouter: an unreadable catalogue

The reported failure:

```
OpenRouter routing paused: the endpoint catalogue could not be read:
Invalid error symbol: http-error
```

A transient failure of OpenRouter's endpoint catalogue -- a 503, a rate
limit, a connection reset -- was reported as a bug in the harness, and the
status and the provider's own message were lost.

## Cause

`harness-http-request-json` rejects with a tagged tuple, `(http-error
STATUS BODY)`, which is **not** a defined error type: it is a data list.
`harness-openrouter--reading-of` passed such a rejection on by signalling its
car, `(signal (car err) (cdr err))`, asking Emacs to signal `http-error`,
which no `define-error` declared.  Emacs raised `(error "Invalid error
symbol" http-error)` instead, and the real failure was gone.

## Run it

```
demo/openrouter-catalogue-failure/demo.sh
```

Offline: the failures are canned, no completion is sent, no policy is
installed and no harness is touched.  It prints each failure as it was
reported before the fix and as it is reported now.  `expected.txt` holds
the output.

## The regression test

`harness-provider-openrouter-a-refused-catalogue-names-the-status` asserts
the exact reported text.  `repro-before.log` is that test run against the
old behaviour: it fails with precisely the reported message.
