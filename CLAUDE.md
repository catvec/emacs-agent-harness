# CLAUDE.md

## Finishing work

- Work on this repo runs as emacs-agent-harness tasks, each in its own git
  worktree and branch. A task is done only once its branch is merged into
  `main`, and the harness's merge queue does that merge after the work is
  handed in (and verified, when review is on).
- When the work is done, commit everything on the task branch and finish
  with `hand_in`. Do not merge, rebase onto or push `main` yourself: the
  harness's merge queue merges the branch, and it comes back to you if the
  merge needs anything.
- A sub-agent in its own worktree (`spawn_agent` with `worktree=true`) is
  merged back into its parent session's working directory by the same
  merge queue.
