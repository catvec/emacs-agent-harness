# Evidence: no per-turn scribe

The runs behind the hand-in, kept whole so they can be read rather than
described.

| File | What it is |
|---|---|
| `workspace-graph-notes.png` | A live dev harness's `*Workspace Graph*` over a temp graph: `Logseq · ready`, 2 nodes. The countertop decision was written twice through the ACP path and the page holds it **once**; the fabricator's quote is the second. Both carry `id`, `workspace`, `workspace-id` and `learned-at`, and no background pass wrote either. |
| `notes-demo.txt` | `scripts/notes-demo.sh`: three turns of one workspace. Two settle nothing and leave the page empty; the third writes one note. Every turn reports `requests after it ended: 0` — nothing reads a finished turn. |
| `routing-demo.txt` | `scripts/routing-demo.sh`: the router's scores and choices, unchanged by this work. Topic routing decides a thread and writes no note. |
| `lint.txt` | `scripts/lint.sh` on the same commit: exit 0, only the repository's pre-existing docstring-width warnings. |

The full suite is `scripts/test.sh` with no arguments: 203 files, 0
failed.  It is quoted as the tool call of the run at the tip of this
branch rather than stored here, because each run's log names the commit
it covered and the commit cannot hold its own run.

The three tests that replace the scribe cases are in
`lisp/modules/harness-workspace-test.el`:
`harness-workspace-a-turn-asks-no-second-model`,
`harness-workspace-a-note-is-written-once` and
`harness-workspace-a-note-holds-no-secret`.
