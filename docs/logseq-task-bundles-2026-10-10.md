# Logseq backlog bundles, 2026-10-10

The `LATER` items of the "Emacs Agent Harness" Logseq page were grouped
by feature area, de-duplicated, bundled and submitted to the task board
with **Refine**, so the tasks wait in the backlog until they are
started.  The page now groups the same items under these bundles;
every item carries its `harness-task::` id, and the page items are
`DOING` (submitted) or `DONE`.

97 items became 24 bundles.  Two items were left alone: the
"supervisor mode improvements" header (its children were already
submitted tasks, now `DONE`) and the item marked
`#A PENDING DON'T DO` (remote session / central server).

## High priority

| Bundle | Task | Items |
| --- | --- | --- |
| Auto mode: allow read-only gcloud/gsutil | `t-v0wxo4ci` | 1 |
| Harness update and version pages | `t-3sws5q5i` | 2 |
| Task board: lifecycle state machine and queue safety | `t-tsflue74` | 7 |
| Merge queue commits and worktree performance | `t-ga9nrevm` | 3 |
| Cowboy compaction correctness | `t-rnvfm2d6` | 3 |
| Budget, usage and cost accounting | `t-qvbm5ror` | 4 |
| Window management and fullscreen | `t-b9gsnh7n` | 4 |

## Medium priority

| Bundle | Task | Items |
| --- | --- | --- |
| End-to-end tests with a real ACP client | `t-u9ho6kqa` | 1 |
| Session list: dired mode, columns, filters | `t-uqdaprnq` | 7 |
| Review flow and hand-in polish | `t-kkxe4q09` | 5 |
| Session navigation and status visibility | `t-nziugtk6` | 6 |
| Compaction control: tool, interrupt, drop-oldest | `t-twxfkjw0` | 4 |
| Chat rendering fixes | `t-f9pborum` | 8 |
| Compose box: send-now, key routing, prompts, attachments | `t-jk08mh7u` | 7 |
| Harness-wide quick search | `t-ga0haw2q` | 3 |
| Module system refinements | `t-2mlyyofm` | 4 |
| BTW model tier and internal job limits | `t-tsw5lqxw` | 2 |
| Out-of-band plumbing: events, remote methods, ui-thread elisp | `t-mj3v5c3t` | 4 |
| macOS jail and Emacs socket placement | `t-dzcwinwy` | 2 |
| Compose-inline-response library extraction | `t-40d7xzfd` | 1 |

## Low priority

| Bundle | Task | Items |
| --- | --- | --- |
| Task board polish and slot view | `t-02k8cv0g` | 5 |
| Pet commentary behaviour | `t-h6p2r2jd` | 6 |
| Pet animation and placement | `t-7vvvgmqm` | 5 |
| Undo/redo for permanent decisions | `t-pfjocmd8` | 3 |

## Notes

- Duplicates merged into one bundle each: the two cowboy-compact asks
  (read all messages, keep first/last verbatim), the pet-comment
  lifecycle asks (fade, session-specific, overview recaps) and the
  undo/redo asks (cowboy compact plus permission answers).
- Bundles stay at a size one task can land; the broad asks (module/API
  audit, worktree performance, window management) are scoped in their
  write-ups rather than left open-ended.
- Each write-up names the running tasks that touch the same code
  (update nag, top-bar trim, vector search, task priority, message
  navigation, budget UI) so the executing agent coordinates instead of
  duplicating.
- The sibling Logseq sync task's 13 verified `DOING` bullets were
  flipped to `DONE` in the same page write.
