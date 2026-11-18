# A sub-agent's worktree starts from its parent's HEAD

## The problem

`spawn_agent` with `worktree=true` made the child's worktree with

```elisp
(harness-call 'worktree/create (or (plist-get parent :project) (plist-get parent :cwd))
              :branch (concat "harness/" (harness-tools-agent--short-id child-id)))
```

Two things are decided there, and both were decided by the wrong
directory.

**The base.** `worktree/create` runs `git worktree add -b BRANCH PATH`
in the root it is given, and its `:base` defaults to `"HEAD"`.  The
root was the session's `:project`, so `HEAD` was whatever the main
checkout had out.  A task's session is not like that: it is made in
the project and then moved into the task's worktree
(`harness-tasks--continue-session` → `session/update ... :cwd`), which
changes its `:cwd` and leaves its `:project` the main checkout.  This
session's own record says so:

```
"project": "/home/noah/documents/ai/emacs-agent-harness/",
"cwd":     ".../.worktrees/task-fix-subagent-worktree-branching-from-maicsat1/"
```

So a sub-agent of a task branched off `main`'s tip, without any of the
commits the task had made.  That is the reported bug: a child of a
session that has done work started as if the work had never happened.
It is also why a child that needed its parent's changes could not be
used at all, which is the opposite of why `worktree=true` exists: the
point of a child worktree is to change files *in parallel with* the
parent's work, not to start from before it.

**The root.**  Even when the base happened to be right -- a session
whose `:project` really is its own worktree, as a session made
directly in one is -- the worktree was made under that directory, at
`<parent-worktree>/.worktrees/harness-xxxx`.  A worktree nested in
another worktree is a directory that disappears with its parent, is
never seen by the project's own worktree list, and is not where any
other worktree of the repository lives.

## What it does now

- `worktree/head` (new method, `harness-worktree.el`): a promise of
  the commit `HEAD` names at a path, `git rev-parse --verify
  HEAD^{commit}` where the path is.  For a linked worktree that is the
  worktree's own branch tip, not the main checkout's.  It rejects
  where there is no repository, or no commit yet.

- `harness-tools-agent--worktree-base`: a promise of that commit for
  the parent session's `:cwd`, or nil when the directory is remote, is
  no directory, has no `worktree/head` to ask, or names no commit.
  nil leaves `worktree/create` at its default, which is the old
  behaviour for a directory that has nothing to start from.

- `harness-tools-agent--worktree-root`: the main checkout the parent's
  directory belongs to (`harness-files-main-root`), so the child's
  worktree lands in the project's `.worktrees` beside the parent's.  A
  working directory that is no checkout of its own -- a session started
  beside its repository, as the access suite has one -- falls back to
  the session's `:project`, the repository it was filed under, so the
  child's worktree is still the project's; only a session with neither
  gets its worktree where the child would have worked.

- `spawn_agent` resolves the base first, then creates the worktree
  with `:base` when it has one.  The commit is kept with the call:
  the result's text says `from 1234abcd` and its `:meta` carries
  `:worktree-base`, so the parent can tell what the child started from
  without running git.

## What it does not do

**Uncommitted work is not carried over.**  A git worktree is a
checkout of a commit; there is no way to hand a child a parent's dirty
index without copying files behind git's back.  The Planning section
now says so -- "work you have not committed is not in it, so commit
before spawning a child that needs it" -- which is the honest contract
and one an agent can act on.  The alternative, copying the working
tree over the new checkout, would produce a worktree whose `git
status` is not the child's work and whose diff would merge the
parent's uncommitted changes twice.

**The merge target is unchanged.**  The child's branch merges into the
session that queued it (`merge/enqueue`), which for a sub-agent of a
task is the task's session, working in the task's worktree.  That was
already right; it is only the starting point that was wrong.

**No automatic merge.**  A child's branch is still merged by the
session or the user through the merge queue, not when the child ends:
a stopped child's worktree is not merged as finished work
(`harness-tools-agent-stop-outstanding-does-not-merge-a-worktree-sub-agent`).

## The shape of the change

| File | Change |
| --- | --- |
| `lisp/modules/harness-worktree.el` | `worktree/head` |
| `lisp/modules/harness-tools-agent.el` | `--worktree-root`, `--worktree-base`, the spawn's worktree step, the result's `from`/`:worktree-base`, the commentary and the Planning section |
| `lisp/modules/harness-tools-agent-test.el` | the two regression tests below |
| `lisp/modules/harness-worktree-test.el` | `worktree/head` on a worktree, the main checkout and a directory below either |
| `docs/modules/tools-agent.md`, `docs/modules/worktree.md` | regenerated by `scripts/module-docs.sh` |

The two regression tests fail on the old code and pass on the new:

- `harness-tools-agent-spawn-worktree-starts-from-its-parents-head`
  builds the production shape: a session made in the main checkout,
  moved into a task's worktree whose branch has a commit the main
  checkout does not have.  It asserts the child's worktree is in the
  project's `.worktrees` (not inside the task's), that its `HEAD` is
  the task's commit, and that the task's commit is its merge base --
  then that a session in the main checkout still gets a child at the
  main checkout's `HEAD`.
- `harness-tools-agent-spawn-worktree-base-tells-what-it-started-from`
  asserts the call's `:worktree-base` and its `from ...` text, and
  that a child without a worktree carries no base.
- `harness-tools-agent-spawn-worktree-root-follows-the-session` pins
  the root rule: a session beside its repository, filed under it, still
  gets the child's worktree in the repository's `.worktrees` -- the
  case `harness-access-spawn-agent-in-a-worktree-lets-its-parent-read-it`
  failed on when the root was the session's own directory alone.

## Why not the alternatives

- **Base on the parent's branch name** (`worktree/branch` and `:base
  BRANCH`): a branch name is ambiguous across worktrees of one
  repository only in that it is a ref, which is fine, but a session
  can be detached, and a branch can be rebased or checked out
  elsewhere between the two calls.  The commit `HEAD` names is exactly
  the parent's state at the moment of the spawn.
- **Create the child's worktree in the parent's directory** and let
  `HEAD` resolve there: this is the nesting problem, and it also means
  a parent that is not itself in a worktree gets a child worktree
  under the main checkout's `.worktrees` -- which is what the root
  helper already does without the nesting.
- **Copy the parent's uncommitted changes**: see above.
