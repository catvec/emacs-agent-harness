# Skill file bounds taken in name order

## The defect

`harness-skills-scan-files` builds a skill's supporting-file list with a
walk that reads a directory with `directory-files` and applies its three
bounds -- `harness-skills-scan-max-files`, `-max-files-bytes` and
`-max-depth` -- as the names arrive.  `directory-files` returns readdir
order, which is not name order: on tmpfs it is very nearly creation
order, on ext4 it is a hash order.  So *which* files survive a bound is
a property of the filesystem that holds the skill and of the order its
files happened to be created in, not of the skill.

Two consequences, one small and one not:

- The repository's own suite fails on an ext4 `/tmp`.
  `harness-skills-scan-bounds-what-it-lists` makes `file-0.txt` ...
  `file-5.txt`, lowers `harness-skills-scan-max-files` to 3 and expects
  `("file-0.txt" "file-1.txt" "file-2.txt")`.  On ext4 it gets
  `("file-0.txt" "file-2.txt" "file-3.txt")` -- 12 of 12 runs on this
  machine.  The same suite, same tree, with `TMPDIR` on `/dev/shm` (a
  tmpfs), passes.  That is why it had been dismissed as load flakiness:
  it is not load, it is readdir order.
- The fingerprint is wrong when a bound bites.
  `harness-skills-scan--fingerprint` hashes the SKILL.md bytes, the
  relative names of the files *the bound returned* and each one's size.
  Its whole purpose, in the file's own commentary and in
  `docs/design/skills-as-computer-resources.md`, is that "two machines
  compare their copies without trusting a clock".  With the bound taken
  in readdir order, two machines holding the same skill -- same names,
  same sizes, same SKILL.md -- hash different lists and disagree.  A pin
  written on one machine then does not resolve on the other.  The
  default `harness-skills-scan-max-files` of 200 hides this for an
  ordinary skill, but a lowered bound hits it immediately, and a skill
  with more than 200 supporting files hits it at the default.

The function's docstring already promised the list "sorted", so the code
contradicted its own contract, not only its test.

## The decision

**Sort where the entries are read, once.**  A new private function,
`harness-skills-scan--dir-entries`, is the only place that reads a
directory in this library:

```elisp
(defun harness-skills-scan--dir-entries (dir)
  (sort (ignore-errors (directory-files dir t "\\`[^.]" t)) #'string<))
```

Every walk in the file now takes its entries from it -- the bounded
supporting-file walk (`harness-skills-scan-files`), the plugin cache walk
through `harness-skills-scan--subdirs`, and the skill walk in
`harness-skills-scan-root`.  Sorting at the one place the entries are
read, rather than after the bound, is what makes the list a function of
the names: the count bound, the byte bound and the depth cut all see the
same sequence on every filesystem.

**A depth cut no longer abandons the listing.**  In the old walk a
directory met below `harness-skills-scan-max-depth` set the one
`truncated` flag, and the `while` loop's `(and stack (not truncated))`
then ended the whole walk.  In readdir order that was arbitrary but
rarely visible; in name order a directory that sorts early (`b-notes/`)
would end the listing before a single top-level file was reached, which
would be a worse bug than the one being fixed.  The depth bound is a
bound on *where a file is*, not on how far the walk has got, so it now
marks the listing truncated and leaves out that directory only.  The
count and byte bounds keep the old behaviour: they are budgets, and once
one is spent the walk stops.

**The plugin walk and the skill walk sort too.**  `-subdirs` promised a
sorted result and did not sort; it and `harness-skills-scan-root` now
take their entries from the same helper, so the newest-version-first
plugin order has a defined tie-break and the skill bound cuts by name.

## Alternatives considered

- **Sort only the returned list.**  That is what the code already did
  (`(sort out #'string<)`), and it is exactly the bug: the bound had
  already cut a readdir-ordered list, so sorting afterwards only sorts
  the wrong files.  It made the failing assertion read as a puzzle.
- **Sort after collecting every name, then apply the bounds.**  Correct,
  and equivalent to what the walk now does for the count and byte
  bounds, since it descends depth-first in name order and stops when a
  budget is spent.  A separate collect-then-bound pass would read the
  whole tree before applying a budget it could have applied on the way,
  and would need its own depth handling.  Sorting per directory while
  descending keeps one walk.
- **Change the test to accept whatever the filesystem returns.**  The
  task forbids it, and it is wrong: the assertion is the contract the
  fingerprint depends on.
- **Sort by a stable key other than the name**, such as size or mtime.
  No: the fingerprint hashes names and sizes, and the documented promise
  is a name-sorted list.  mtime would reintroduce the clock the
  fingerprint exists to avoid.

## Shape of the change

- `lisp/harness-skills-scan.el`: `harness-skills-scan--dir-entries`, the
  one place a directory is read; `harness-skills-scan-files` rewritten as
  a recursive `cl-labels` walk in name order, with the depth cut
  per-directory and the count and byte budgets stopping the walk; the
  commentary and the docstring say the order the code now keeps;
  `harness-skills-scan--subdirs` and `harness-skills-scan-root` take
  their entries from the helper.
- `lisp/harness-skills-scan-test.el`:
  `harness-skills-scan-bounds-in-name-order-whatever-readdir-says`, a
  regression that stubs `directory-files` to return each directory
  reversed, as a filesystem whose readdir order is not name order does,
  and asserts the bounded list, the byte bound, the depth cut and the
  fingerprint, plus a second copy of the skill made in a different order
  that must agree with the first.  It holds on any host filesystem; it
  fails against the unpatched scanner.  A small helper,
  `harness-skills-scan-test--with-readdir-order`, does the stubbing.
  `harness-skills-scan-bounds-what-it-lists` is untouched.
- `docs/design/skill-file-bounds-in-name-order.md`: this document.

## Verification

Run on a clean tree at this branch's tip -- the commit `scripts/test.sh
--status` names.  The scanner and its suite are as they were at
`e229d64`; every commit after it changes this document, the evidence
beside it, or the parent branch's work merged in (`540dc13`, `6ca10db`,
`239ec92`, `main`'s `9544288`), which the full run covers as it covers
everything else.

- The focused suite under `TMPDIR` on ext4 and on tmpfs: 13 of 13 pass
  under both.
- The four bound tests against the pre-fix scanner, swapped in from
  `3cba0da`: all four fail, and `bounds-what-it-lists` reports exactly
  the list in the report, expected `("file-0.txt" "file-1.txt"
  "file-2.txt")` and got `("file-0.txt" "file-2.txt" "file-3.txt")`.
  The same four pass with the fix in place.
- The full suite on ext4: 233 files, and the two failures the earlier
  run reported are gone (see below) -- the TRAMP suite repaired, the
  server suite's kill-hooks test green.  `scripts/test.sh --status`
  reports `PASS (full, 233 suites, 0 failed)` for this commit.
- `scripts/lint.sh`: exit 0, no errors.  Its only warnings are
  pre-existing ones in files this change does not touch
  (`harness-ui-tasks.el`, `harness-ui-workspace.el`).

The full run is load-sensitive on this machine, which runs many task
suites at once, and each attempt tends to fail a different unrelated
suite.  The attempts before the green one reported, in turn,
`harness-server-test`, `harness-tools-shell-tramp-test`,
`harness-ui-pet-test` and, at earlier commits,
`harness-agent-blocked-subagent-test`, `harness-sandbox-openshell-test`,
`harness-commit-msg-test` and `harness-ui-patch-review-test`.  Every one
of those passes alone, and none names the scanner.  The green run above
is the one quoted; the TRAMP suite, which failed by hanging rather than
by load, is repaired in this branch (see below).

## Two failures a full run reported, and what became of them

Neither was this change's, and both are recorded here because the
repository's gate is that a full run passes, including failures that
also happen on `main`.

**The TRAMP suite's hang -- repaired here.**
`lisp/modules/harness-tools-shell-tramp-test.el`
(`harness-tramp-tools-run-on-remote-cwd`) hung: its first test passed
in about a second and the second never returned, so the file was killed
at its timeout and no full run could pass.  `harness-files-project-root`
(`lisp/harness-files.el`) called `project-current` on a TRAMP path with
no remote guard, which starts a vc probe on the host that blocks once a
connection another caller opened is still there.

It was measured on a clean scratch worktree at `main` with this
branch's commits entirely absent: the suite hangs at the same test in
the same way, so `main` could not pass it either.  The repair is the
one already made on `task/provider-readiness-assessment-and-jibzilj2`
(`34cbf91`), taken here because the gate asks for every failure to be
repaired: a remote directory is its own root, as the functions around
it already return it.  Its regression leaves a connection open the way
the earlier test does, then asks for the root -- it hangs on the old
code and returns the directory on the new.  The file now runs in 2s
instead of timing out at 900s, 3 tests passing.

**The server suite's kill-hooks test -- load, not code.**
`lisp/harness-server-test.el`
(`harness-server-stop-runs-kill-hooks-on-the-main-thread`) failed once
in a full run at load 21, and passes 29/29 alone at `main` in 317s.  It
is timing-sensitive under load and no change was made for it.

## The correction in `shared-retry-ownership.md`

`docs/design/shared-retry-ownership.md` recorded this failure in
"Failures seen while verifying" as load- or environment-sensitive, and
said "the test lists the home directory's skills and the count moves
with what else is installed".  Both were wrong: the test builds its own
temporary root, and what moved was the readdir order.

That document arrived on `main` with the review branch's squash merge
(`833a5dc`), so the correction could be made in place rather than only
noted for a reviewer: the passage now keeps what was observed and says
under it why both explanations were wrong, what the real cause was, and
that its "216 suites with none failed" run holds only where readdir
returns creation order.

## Noticed, and left alone

`harness-computer-endpoint-resources` in
`lisp/harness-computer-endpoint.el` has the same shape: it walks a
root with `directory-files` and keeps the first 200 directories it
finds (`(< (length out) 200)`), so which repositories it advertises
depends on readdir order too.  That is a resource listing, not the
skill scanner or its fingerprint, and this change is scoped to the
scanner and its tests, so it is recorded here rather than changed.  It
does not affect the skill listing or a skill's fingerprint.

## The integration: what the queue could not do, and what was done by hand

The task's branch was made from
`task/implement-price-aware-openrouter-session-e2mdkyz2`, the review
branch for price-aware OpenRouter session pinning.  The merge queue
tried to land this work there nine times and failed every time.  There
were two causes, and only the second one was still live at the end.

**First, a conflict, resolved.**  Both sides had independently fixed
this same scanner defect: the review branch in `8fe4358`/`1b2d3f6` (a
sort inline in the `dolist`), this branch in `e229d64` (the
`--dir-entries` helper and a recursive walk).  Merge commit `1e8c002`
resolved it by keeping this branch's structure and the review branch's
wording; both sides' regressions sit side by side in the suite.

**Second, no target left to merge into.**  The review branch's work was
then verified and squash-merged into `main` as `833a5dc` ("Implement
price-aware OpenRouter session pinning", listing all five of the
branch's commits), and the branch itself was deleted.  The queue kept
resolving its target to a ref that no longer exists, so no git sequence
it could run would have succeeded: the
`fatal: Not possible to fast-forward, aborting.` reports name a checkout
under `.worktrees/task-implement-price-aware-openrouter-session-e2mdkyz2`
that is gone.

That is why this change does not merge into that branch, and why the
branch is not recreated to receive it: its content is on `main`, and a
resurrected ref would be a second, divergent copy of work already
merged.

**What was done instead.**  `main` (`9544288`) was merged into this
branch, and `main` is now an ancestor of its tip.  The integration into
`main` is therefore a fast-forward whichever side the queue reads the
commit to merge onto from, and the earlier queue defect cannot bite:

- the target is `main`, checked out in the repository root, so the
  queue's `parent-cwd` and its `cwd` are the same directory;
- this branch's tip contains `main`, so `merge-tree` is clean and the
  commit it builds is a descendant of `main`.

The merge-queue defect described in earlier revisions of this section
is real and still present -- `harness-merge--run-git-merge` reads the
commit to merge onto from `parent-cwd` while reading the branch tip
from `cwd` -- and the one-line fix is still the unmerged branch
`fix/merge-branch-target-head` (`10d21b5`).  It is not in `main`, and it
is not carried here: it is a defect in the queue, not in the scanner,
and it needs its own review.  It is recorded because it is what the
nine refusals above were blamed on while the real cause was the missing
target.

## Other sessions worked this defect too, and `main` carries three partial fixes

This defect was found by more than one session, and `main` now holds
three separate fixes for it, each landed under a commit whose subject
names something else:

| commit | subject | what it did to the scanner |
| --- | --- | --- |
| `6ca10db` | Add Historical Token Mix and Spend Views | "Select bounded skill files in deterministic directory order" |
| `8fe4358` | Fix flaky UI timestamp tests | "Walk a skill's files by name, so a bound cuts the same subset" |
| `1b2d3f6` | Enable container workflows in Harness sandboxes | "Sort a skill directory before its listing is bounded" |

`6ca10db` added `harness-skills-scan-bounds-ignore-directory-enumeration-order`
to the suite; `8fe4358` and `1b2d3f6` then rewrote the same `dolist` to
sort its entries.  None of the three commit subjects names the scanner,
and none of the three was a task about it: each session met the failure
in a full run, diagnosed it as readdir order, and repaired it in
passing.  Session `a6e7bc34` ("Fix flaky UI timestamp tests") records
that path in its own summary -- it set out to fix two timestamp tests
and found this defect while verifying.  The other two arrived by squash
merge, so their originating session is not recoverable from the log; the
scanner hunk is listed under their `Changes:` trailers instead.

Their fixes are correct as far as they go, and `main`'s bounded listing
now passes.  They are not this change, and they leave three things
undone, which is why this branch is still worth merging rather than
being dropped as a duplicate:

1. **The depth cut still abandons the walk.**  On `main`, a directory
   met below `harness-skills-scan-max-depth` sets `truncated` and the
   `while` ends, so every file not yet reached is lost, not just the
   directory that was too deep.  A skill with `a/inner/x.txt`,
   `a/y.txt` and `b/z.txt` at depth 1 lists only `b/z.txt` on `main` and
   `a/y.txt` and `b/z.txt` here.  With entries now in name order this
   is worse than before, because `a` is always met first.
2. **The directory reads are not in one place.**  `main` sorts inline
   in the `dolist` of `harness-skills-scan-files`, but
   `harness-skills-scan--subdirs` (the plugin cache walk) still calls
   `directory-files` with NOSORT and no sort, and
   `harness-skills-scan-root` sorts at its own call site.  This change
   reads every directory through `harness-skills-scan--dir-entries`, so
   a walk added later cannot forget.
3. **The regression is weaker.**  `main`'s
   `harness-skills-scan-bounds-ignore-directory-enumeration-order`
   stubs `directory-files` to return one fixed order for every
   directory, so it never exercises a subdirectory and never compares
   two copies of one skill.  This branch's
   `harness-skills-scan-bounds-in-name-order-whatever-readdir-says`
   reverses every listing, covers the count bound, the byte bound, the
   depth cut and the fingerprint, and asserts that a second copy made in
   another order fingerprints the same.

Measured against `main` (`d8140cb`) with this branch's test file
swapped in: 12 of 13 pass and
`harness-skills-scan-bounds-in-name-order-whatever-readdir-says` fails,
so the regression is not satisfied by `main`'s three fixes.

## Tasks filed for what this change leaves out

Two defects of the same shape were found while verifying and are not
this change's to fix; each has a task of its own so the finding is not
lost with this branch:

- **`harness-computer-endpoint--resources`**
  (`lisp/harness-computer-endpoint.el`) keeps the first 200
  repositories a depth-first walk meets, over NOSORT `directory-files`,
  so which repositories a computer advertises depends on readdir order
  and on where the cap happens to fall.  Filed as task `t-4f2jy09m`.
- **`harness-merge--run-git-merge`** (`lisp/modules/harness-merge.el`)
  reads the commit to merge onto from `parent-cwd` while reading the
  branch tip from `cwd`, which is why a target branch checked out in a
  worktree could not be merged.  The one-line fix already exists on
  `fix/merge-branch-target-head` (`10d21b5`) and never landed.  Filed as
  task `t-bmjcvbt4`, to bring that commit in with its regression.
