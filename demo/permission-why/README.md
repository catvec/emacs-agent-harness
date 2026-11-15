## Why a permission prompt is asked

Shows the line every permission prompt carries: what it says, the face
it wears, and the tooltip over it, drawn by the panel's own code.

```
demo/permission-why/demo.sh
```

Three parts:

1. **Every code.** The twelve reasons a prompt can carry, each drawn as
   the Emacs panel draws it: the `Why · <label>` line, the detail under
   it, the face of each, and the tooltip.
2. **The one safety judgment.** `judge-deny` beside a judge that gave no
   verdict and an ordinary ask mode, so the line that is a judgment on
   the call is told apart from the ones that are none.
3. **Where the reason comes from.** `harness-perms--why-of` on the
   decisions the chain really makes, the request a harness that sends no
   reason draws, and the cut on a long detail.

It is offline.  It sends no model request, asks no provider, sets no
permission rule, installs no module and runs no tool: it calls the
reason builder, the panel's insert function and the detail's masking,
and every path it prints is a placeholder.  See
[the design document](../../docs/design/permission-prompt-reasons.md)
for why a prompt says why it is asked.
