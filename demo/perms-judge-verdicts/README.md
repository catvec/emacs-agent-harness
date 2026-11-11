# The permission judge's verdict shape

Shows what the permission judge's reply is read as, what a reply with no
verdict costs, and where the verdict's JSON schema goes on the wire.

```
demo/perms-judge-verdicts/demo.sh
```

Four parts:

1. **The reader.** The field's reply,
   `{"allow":"Read-only inspection of a local git diff; no destructive or
   exfiltrating action."}`, and nine others, read strictly: which are a
   verdict, which are no verdict, and why.  A bare `allow` key, a
   `"decision"` that is no word of the contract, the key twice, two
   objects that disagree, and explanation text are all no verdict.
2. **The correction.** The observed reply, then the corrected one, run
   through the real `harness-perms--auto` stage with a scripted provider.
   It prints both judge messages in full and the decision the chain
   settled on: two calls, and the call allowed on the second.
3. **Exhaustion.** Two malformed replies in a row.  With the user away
   nothing may be asked, so the call is denied.  With the user present it
   becomes one prompt and nothing runs; the demo answers it (a denial) so
   the chain settles.
4. **The schema gate.** A plain OpenAI-compatible endpoint is sent the
   schema; an OpenRouter pin is sent it only when the endpoint's catalogue
   entry listed `structured_outputs`.  The reader never depends on it.

It is offline.  It sends no model request, sets no permission rule,
installs no module and runs no tool: the provider is a scripted stub, the
tool is a page of text, and every path it prints is a placeholder.  See
[the design document](../../docs/design/permission-judge-verdict-shape.md)
for why the reply is read this way.
