# Skill file bounds taken in name order: evidence

## `readdir-order.txt` and `readdir-order.el`

![The same skill on ext4 and on tmpfs: before the fix the two filesystems
list different files and fingerprint differently, after it they
agree](readdir-order.png)

The same skill -- same names, same sizes, same SKILL.md -- made in the
same creation order on two filesystems: ext4 at `/tmp` and tmpfs at
`/dev/shm`.  It records each one's readdir order, then what the scanner
makes of it with the count bound at 3, before the fix and after it.

Before the fix the two filesystems disagree: ext4 lists `file-0.txt`
`file-2.txt` `file-3.txt` and tmpfs lists `file-1.txt` `file-3.txt`
`file-5.txt`, and their fingerprints differ.  After the fix both list
`file-0.txt` `file-1.txt` `file-2.txt` and fingerprint the same, so two
machines holding one skill agree.  That is the contract the fingerprint
exists for; see
[the design document](../../design/skill-file-bounds-in-name-order.md).

The `.txt` is the output of the `.el` beside it, which builds both
directories, scans them with this tree's walk and with the walk as it
was at `3cba0da`, and deletes them again.  Rerun it from the repository
root with

    emacs -Q --batch -L lisp -L lisp/modules -L lisp/ui -L test -L . \
      -l docs/evidence/skill-file-bounds/readdir-order.el

The only thing that moves between runs is the process id in the two
temporary directory names.

## `merge-queue-repro.txt` and `merge-queue-repro.svg`

Why this branch's merge into
`task/implement-price-aware-openrouter-session-e2mdkyz2` kept failing.
The `.txt` is the transcript and the `.svg` renders it.  Both come from
a throwaway clone of the repository at the real topology: the
repository root worktree has `main` out, and the review branch is
checked out in a worktree of its own.

It runs the merge queue's own git sequence twice, changing only the
commit it reads as the merge's parent:

- From the repository root, as `harness-merge--run-git-merge` reads it
  today (`parent-cwd`), the branch is merged against `main`'s older copy
  of the scanner: `merge-tree` reports a conflict in
  `lisp/harness-skills-scan.el`, and the commit it builds is parented on
  `main`, so `git merge --ff-only` in the review branch's checkout
  refuses with `fatal: Not possible to fast-forward, aborting.` and
  leaves the branch where it was.  That is the failure the queue
  reported, message for message.
- From the branch's own checkout (`cwd`), the merge is clean and
  fast-forwards it.  Both scanner regressions -- this branch's and the
  review branch's own -- are in the result, and its working tree is
  clean.

So the branch's work is not what kept the merge from landing.  The fix
is one line, carried by the unmerged branch
`fix/merge-branch-target-head` (`10d21b5`); see
[the design document](../../design/skill-file-bounds-in-name-order.md),
section "The merge into the review branch, and why it kept failing".
