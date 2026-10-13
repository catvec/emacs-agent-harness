<!-- compare_supervisor_modes: placeholder without results -->

# Supervisor mode vs single-session tasks: usage analysis (2026-10-12)

> **No results in this file yet.** It holds the method only. The analysis needs the harness's usage database, session records and task store, which the session that wrote the scripts could not read, so no number has been computed and none is quoted. Run the two commands under [Reproduce](#reproduce) on the machine that holds the harness state directory; `compare_supervisor_modes.py` then rewrites this file with the results.

**Question.** Has supervisor mode made tasks slower and more expensive than the old one-session-per-task way?

## Method

### Data

The inputs are the CSVs written by `scripts/analysis/extract_usage_data.py`, which opens the harness state directory read-only: `usage_rows.csv` (one row per model call, from `usage.db`), `sessions.csv` (one row per session record, with compaction counts taken from its transcript), `tasks.csv` (the task board) and, when present, `plan_steps.csv` and `manifest.json`. The extraction copies only ids, flags, enum values, timestamps, numbers and project directory paths (it counts a transcript's nodes by kind and copies none of their text); this script reads those CSVs and uses none of the paths. No task title, prompt, plan text or transcript text is in the inputs, and no id or path is in this file.

Every timestamp in the CSVs is Unix epoch seconds. All times are held as timezone-aware UTC instants and compared as such; the cutoffs below are given with their offset and converted to UTC first.

### Cutoffs

| Event | Commit | Local time | UTC |
| :--- | :--- | :--- | :--- |
| Supervisor mode introduced | `73f987b` | 2026-10-08T15:24:17-04:00 | 2026-10-08T19:24:17Z |
| Plan mode introduced | `b0a013d` | 2026-10-11T21:48:45-04:00 | 2026-10-12T01:48:45Z |
| Supervisor cache/cost fix landed | `0803841` (landing `7be8ce2`) | 2026-10-11T23:55:53-04:00 | 2026-10-12T03:55:53Z |

Before the fix a supervisor's workers defaulted to inheriting (forking) the whole supervisor conversation, the cache blow-up already known about. Plan mode (a strong model plans read-only, a medium model works) is a different mechanism from supervisor mode's plan and sub-agents.

### Classification

Each task is put in the first group whose rule it meets:

1. **Plan mode** (set aside): the task's `plan` flag is set.
2. **Session record missing** (set aside): the task's top-level session has no record in `sessions.csv`, so its supervisor flag, creation time and sub-agents cannot be verified and its totals cannot be called complete.
3. **Group B, single-session (the old way)**: the top-level session was created before 2026-10-08T15:24:17-04:00 (supervisor mode did not exist), or its supervisor flag is off or absent.
4. **Excluded, old buggy supervisor mode**: the supervisor flag is on and the top-level session was created before 2026-10-11T23:55:53-04:00. Kept out of A and B and summarised on its own.
5. **Group A, fixed supervisor mode**: the supervisor flag is on and the top-level session was created at or after 2026-10-11T23:55:53-04:00 (the instant itself counts as after).

The supervisor flag is the *resolved* one: `ext.supervisor` of the task's top-level session record (`true` is on; `false` or no value is off). If the record carries no value, the task's own `supervisor` setting is used when it has one. The creation time is the session record's `created` (the task's `created` if the record has none).

Only tasks whose persisted state is `done` enter the comparison. Tasks in any other state (pending, refining, active, review, merging) are counted as still in flight and left out for that reason alone. A task with no sub-agents is a valid data point and is kept.

### Which sessions belong to a task

The *top-level session* is the task's own session. A *sub-agent* is a session of kind `subagent` or `fork` whose `parent_id` chain leads back to the top-level session, directly or through other sessions (a worker's own sub-agent counts). Sessions of kind `btw` and `internal` are not sub-agents; their usage is reported separately under the secondary checks and is not in a task's totals. Seed sessions (a `subagent` that only holds a shared context for fork workers) and merge-queue conflict resolvers are `subagent`s too and are counted as such; sessions named by a plan step, and seeds, are also counted on their own so the effect can be read.

### Measures

- **Tokens**: input, output, cache-read and cache-write tokens summed over the usage rows of the top-level session and its sub-agents; *total tokens* is the sum of the four kinds. The harness prices each kind at its own rate, so the four counts are disjoint and a token is not counted twice.
- **Billed cost**: the sum of `cost`, what was actually billed. It is 0 for calls paid under a subscription plan, so it depends on how each call was paid for as well as on how much was used.
- **List cost**: the sum of `list_cost`, the same usage at API list prices. A row with no `list_cost` counts at its `cost`, as the harness itself does (`harness-usage-list-cost`). It does not depend on billing mode, so it is the like-for-like dollar measure. A model the harness has no price for is recorded at $0; those rows are counted under the data-quality notes.
- **Billing breakdown**: row counts by `billing` value (`api`, `subscription`, `extra-usage`; rows written before that column existed have none).
- **Task duration**: `finished` minus `created` from the task record (wall clock; it includes time waiting for a slot and any rework after a send-back). `finished` minus `started` is reported as a secondary figure.
- **Session duration**: a session record's `updated` minus `created`. **Usage span**: the time from its first to its last usage row.
- **Compactions**: the compaction nodes a session's own transcript holds (nodes a fork copied from its parent are not counted). A session whose transcript was not scanned is left out of those figures.
- **Statistics**: mean, median, sample standard deviation (n-1; not defined for one value), minimum, maximum and sum, from Python's `statistics` module. Ratios divide A's figure by B's. No significance test is run. A figure that could not be computed for a task (a missing timestamp, say) leaves that task out of that figure only, and the figure shows its own n when it differs from the group's.

### What this cannot separate

Tasks were not assigned to the modes at random, and the groups differ in period, so the figures describe the two groups as they happened. They do not separate the effect of the mode from the kind of task it was used on, the model in use, how the calls were paid for, or what else changed in the harness over the weeks covered. The instant a fix reached the running harness is not recorded in the data; the commit time is used. The flag is the one the session record holds when it was read, which a judge or the user may have changed after the session started.

## Reproduce

```
python3 scripts/analysis/extract_usage_data.py        # reads the harness state directory (read-only)
python3 scripts/analysis/compare_supervisor_modes.py  # classifies, computes, rewrites this file
```

Both scripts take their directories as flags (`--help`); `compare_supervisor_modes.py --self-test` checks the arithmetic on a small synthetic world with known answers.
