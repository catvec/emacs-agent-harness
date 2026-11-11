# A live harness, every module enabled: before and after the fix

Run from a checkout of this branch (after) and of its base d7077c4 (before),
with the same probe: start the harness with every module enabled in a state
directory it is told to use, then read back what became of that state.

```
$ emacs -Q --batch -L . -L lisp -L lisp/modules -L lisp/ui \
    -l harness.el -l probe-accident.el

--- BEFORE (base d7077c4) ---
RESULT state-directory-after-start="/tmp/harness-test-state-VVSsdh/"
RESULT test-helpers-loaded=t
RESULT tmp-root="/tmp/harness-test-state-VVSsdh/session-tmp/"
RESULT store-in-repository=nil

--- AFTER (this branch) ---
RESULT state-directory-after-start="/tmp/evidence-state/"
RESULT test-helpers-loaded=nil
RESULT tmp-root=nil
RESULT store-in-repository=t
```

Before: the harness restated itself into a throwaway test directory
(harness-test-state-VVSsdh), the shared test helper was loaded into the
live harness, the session temporary root moved with it, and the task
module fell back to the global store (store-in-repository=nil, because
the helper sets it).  The state directory the harness was told to use
was left behind, unused: its sessions and task board were still there
and nothing looked at them any more.

After: the state directory that was chosen is the one the harness
keeps, the shared helper is never loaded, the session temporary root is
untouched, and the task module keeps its repository store.
