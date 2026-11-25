# Session soak evidence

The task diagnostics are a read-only snapshot of 16 retained task error records
and matching diagnostic hints, taken November 24, 2026. Fifteen are in the recent
window; the October 3 merge record illustrates a stale error surviving success. They contain IDs, error
text and times, not full conversations or credentials. A retained error is
historical evidence, not a statement that a task is currently running or broken.

`cache-divergence-repro.el` loads the checked-out core/store/session/replay and
keeps one ordinary request. Three subsequent requests change only reasoning
high to max. Before the repair all three are refused; at the current source
none are. Run from a checkout with:

```sh
TMPDIR=/var/tmp emacs -Q --batch -L lisp -L lisp/modules -L lisp/ui -L test -L . \
  -l /absolute/path/to/cache-divergence-repro.el
```

Exit 1 means all three requests were refused, 0 means unaffected, and 125 means
that revision could not be exercised. A revision predating the frozen transport
seam is unaffected by this particular refusal. The retained bisect identifies
`ac3fb53` on the investigated history; its parent has no frozen transport seam.
The exact `dc18b8d` development branch is not an ancestor of `ac3fb53`; do not
confuse a side branch implementation commit with its introduction in this line.

The full `session-soak` target also detects the original error with the replay
module from `a122507^`: action bytes `04 00` change the advertised effort ladder
after a successful first turn, and turn 2 errors at `reasoning.effort`. This
comparison substitutes that historical module into the current isolated test
fixture; it is not a full historical-tree run. The current module passes the
same action sequence. To reproduce the module substitution, export
`git show a122507^:lisp/modules/harness-replay.el` to a temporary file, wrap
`harness-test-load-module` so that only `replay` loads that file and starts its
module, then run `(harness-fuzz-session--check (unibyte-string 4 0))`.

The development AFL++ campaign used seed 20261124, a 60-second mutation budget,
stock Emacs and dumb mode. Its 21 inputs are whole multi-turn sessions; no
findings means no oracle violations, not coverage saturation. Seed probing and
AFL dry runs add time outside the mutation budget. The report retains input,
execution and environment metadata. Debug-only returned summary fields were
trimmed afterward and a wire-effort assertion added; final verification runs
the committed target through the ordinary full suite, including its AFL smoke
campaign. Replay any input by requiring `harness-fuzz` and calling
`harness-fuzz-session--check` on its bytes in a fresh batch Emacs.

The dropped-provider-pin check also fails with only the OpenRouter module from
`8b19e31^` substituted: no completion reaches the transport. The same current
regression passes against the current module (`repin-before.log` and
`repin-after.log`). This is a module comparison with current offline fixtures,
not a bisect of the routing module's original introduction.

A separate final-source `session-turns` campaign uses seed 20261125 and the same
60-second mutation budget. Its `ordinary-afl-*` artifacts exercise ordinary turns
without deliberate cache mutations, including the final UTF-8 response fixture.
The four seeds include the two tool-catalog sweeps. No threading is added to the
harness; each scenario's asynchronous callbacks run on Emacs's event loop.
