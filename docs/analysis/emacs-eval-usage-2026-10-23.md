# What agents used `emacs_eval` for

`emacs_eval` ran model-written Lisp in the user's own Emacs.  It is gone (see
[docs/trust-model.md](../trust-model.md)).  Before it was removed, every stored
call of it was read, to answer two questions the removal depends on: what did
agents do with it, and which of that is a need the other tools do not meet?
Where the answer to the second is "yes, and it is safe to meet", a tool was
extended or a way was added; where it is "yes, and it is not safe", nothing was
offered; and the rest is covered.  Data read on 2026-10-24.

## Findings

- There are **817 distinct calls in 107 sessions** in the store.  The grep
  output that was read has 861 lines in 124 session files: forks keep copies
  of their parents' calls, so a call is counted once (by its call id) and a
  session together with its forks once.  340 calls (42%) are cut by the
  500-column window of the grep tool.  The 132 that show their time were made
  between 2026-10-08 and 2026-10-24, most on two days (40 on the 10th, 64 on
  the 17th).
- Most of it was **reading**: what a variable, feature or function is, what a
  buffer or a UI structure holds, what a file holds.  The state of the running
  Emacs was the subject of **190 calls (23%) that read a variable's value**
  (137 variables in all) and 31 more that only asked about variables.  Those
  calls are nearly all of the `introspection`, `harness internals` and
  `ui poking` categories (43, 23 and 37 sessions).  That need now has a
  tool: the `elisp` tool can start its child from a **copy of the user's
  Emacs** (see "The state that was read, and the copy now offered").
- **One repeated, legitimate need had no tool: searching a long live buffer.**
  The harness log buffer was named by 32 calls in 11 sessions, to take its last
  lines (15) or to filter its lines by a word (24); chat and view buffers by
  about as many more.  `emacs_buffer` read only a line range.  It now takes
  `contains` (lines that hold any of up to five strings) and `tail` (from the
  end), bounded and never as a pattern.  See "The gap, and the change".
- **Every `worktree/remove` call (12, in 11 sessions) removed a scratch worktree
  the agent had made under its own session temporary directory**, usually a
  checkout of the base commit to compare with.  That includes the call that
  began this work.  The goal was harmless; the route was not.  The fix is
  structural (see the `worktree/remove` paragraph below).
- What should **not** be offered, and was not: arbitrary Lisp in the user's
  Emacs (the whole tool); calling a harness method by name (126 calls named
  one); starting processes in the user's Emacs (74 calls: 32 ran `bash`
  outside the sandbox, 10 ran `ssh`); copying credential files into the jail
  (33 calls naming `k3s.yaml`, kubeconfigs, `~/.ssh`); redefining or advising
  code in the running Emacs (23 calls, 11 sessions); the merge queue's and the
  worktrees' privileged methods.
- **No new tool name** was added.  Two changes answer the evidence: the
  `emacs_buffer` search and tail, and the copy of the user's Emacs that the
  `elisp` tool takes as an input (`snapshot`, with `fresh` to renew it).  The
  copy is a read-only, offline child in the sandbox that computes over the
  user's values; the user's Emacs is only read.  The next candidate, a
  read-only `usage_summary`, was asked for by one session and is left as a
  note.

## Method

The transcripts are `~/.emacs.d/.local/cache/harness/sessions/*.nodes.jsonl`, one
JSON object per node.  The sandboxed shell cannot read that directory (and a
non-interactive session cannot be granted it), so the data was read with the
`grep` tool, which can, and classified by a script.

1. **The corpus.**  `grep`, path the sessions directory, glob `*.nodes.jsonl`,
   case sensitive, `max_results` 3000, pattern

       "kind":"tool-call","tool":"emacs_eval"

   861 lines in 124 session files.  Because the result is large the tool saved
   it under the harness's `outputs/` directory, which the sandbox shows
   read-only.  Each line is `PATH:LINE: JSON`; the code of a call comes early
   in the node, so a call's opening forms are almost always visible and a long
   call is cut.  **340 calls (42%) are cut**, at a median of 336 characters of
   visible code.
2. **Copies of a call are counted once.**  A forked session keeps its parent's
   nodes, so the same call appears in both files.  The classifier dedupes by
   the node's `call-id`, and counts a session with its forks as one.  This is
   the difference between the 861 lines and the 817 calls; a raw grep count of
   any pattern over this store over-counts by the same share.
3. **The classifier**, [`scripts/analysis/emacs_eval_usage.py`](../../scripts/analysis/emacs_eval_usage.py),
   reads that file.  It gives each call one *primary category* (the first rule
   that matches, so the table adds up) and the *features* it shows (a call may
   show several), tallies the `harness-call` methods by name, the buffers and
   the variables the call reads and how, and counts distinct sessions.  It
   sanitizes everything it prints; `--self-test` checks its parser and rules
   on a fixture (a fork's copy included); `--distinct` prints lines against
   distinct calls for a file, so the size of the copy effect can be measured.
4. **The counts are lower bounds.**  The whole-text exact counts of the first
   version of this report came from the grep tool's own match count over the
   complete nodes; 42% of the calls are cut in the saved text, so the script
   sees the start of those calls only.  Every count here is the script's, over
   the visible text, deduped.  Where a call is cut its category is still
   decided by its first form, which is what decides a category; the features
   it would show later are lost.
5. **Nothing printed can be a secret.**  The script sees only the text of calls,
   never the contents of the files they touched, shortens paths to `~/`, and
   replaces ids, hosts, addresses, key prefixes and long tokens.  This document
   names credential *files* and counts them; it quotes none of their contents.

**What this does not measure.**  The result of a call (it ran, failed, was
refused, or the Emacs was busy), the order of calls in a session, or the reasons
the model had.  "Legitimate" below is the author's judgement of the stated goal,
not a count.

## The numbers

817 calls in 107 sessions; 340 of them (42%) are cut by the window.  Models,
where the window shows one (323 calls): deepseek 187, claude 136.

| primary category | what | calls | share | sessions |
|---|---|---:|---:|---:|
| credentials | names a credential file | 33 | 4% | 8 |
| process | starts, drives or inspects a process | 74 | 9% | 11 |
| analysis recipe | gathers session data for the usage analysis | 5 | 1% | 1 |
| harness-call | calls a harness method | 126 | 15% | 38 |
| file mutation | writes, copies, renames or deletes files | 30 | 4% | 12 |
| ui poking | reads or sets display and UI state | 144 | 18% | 37 |
| buffers | reads or edits buffers | 74 | 9% | 26 |
| introspection | asks what a symbol, feature or variable is | 88 | 11% | 43 |
| harness internals | reads other harness-* variables and functions | 58 | 7% | 23 |
| file reads | reads files and directories | 134 | 16% | 16 |
| other | none of the above | 51 | 6% | 13 |

| feature (a call may show several) | calls | share | sessions |
|---|---:|---:|---:|
| credential file named | 33 | 4% | 8 |
| changes the running Emacs | 23 | 3% | 11 |
| usage-analysis recipe | 5 | 1% | 1 |
| secret-ish word | 1 | 0% | 1 |
| starts, drives or inspects a process | 76 | 9% | 12 |
| harness-call | 126 | 15% | 38 |
| mutates files | 45 | 6% | 18 |
| UI / display internals | 158 | 19% | 37 |
| buffer reads and edits | 143 | 18% | 30 |
| symbol / environment introspection | 145 | 18% | 63 |
| mentions harness-* symbols besides harness-call | 387 | 47% | 80 |
| reads files | 237 | 29% | 37 |

## What each kind of call was for, and what covers it now

**Introspection (88 primary; 145 show a feature; 63 sessions).**
Mostly "is the harness loaded, and what is in it": `featurep`/`fboundp`/`boundp`
of a `harness-*` symbol, the environment (`getenv`, `system-type`),
`symbol-value`, documentation, where a function is defined.  The symbols asked
about were mostly the UI's, then the providers', the supervisor's and the
tasks', and `harness-directory` with the state directory.  *Covered by*
`emacs_describe` (value, documentation, where defined, advice, watchers of any
symbol), `emacs_find_definition`, `session_info`, and now by the copy of the
user's Emacs for the values themselves.

**UI poking (144 primary; 37 sessions).**  Most mention `harness-ui-*` or
`harness-chat-*` symbols, then windows and frames, faces, fonts and images,
overlays and text properties; some took a screenshot of a frame.
This is development of the harness's own UI.  *Covered by* the dev loop: the
`open_harness` tool starts a separate Emacs from a checkout and
`scripts/dev.sh eval`, `keys` and `shot` drive it (docs/dev-loop.md).  That
instance is not the user's, and starting it is an `exec` call decided by the
permission mode like `bash`.  A single variable of the user's own Emacs is
`emacs_describe`, or in the copy.  A screenshot of the user's live frame is not
offered: it shows the user's screen.

**Buffers (74 primary; 26 sessions).**  Reading the harness log (32 calls, 11
sessions), a session's chat buffer (20 calls, 5 sessions), the session list (11
calls, 3 sessions) and a few views and terminals; 24 of the 32 log calls
filtered its lines by a word, 15 took its tail, 27 did either, and 4 dumped it
to a file to search it in the sandbox.  *Covered by* `emacs_buffers`,
`emacs_buffer`, `emacs_messages`, `emacs_insert`, and the copy of the user's
Emacs when the code is a computation over the text; the search and the tail
are the gap below.

**`harness-call` (126 primary; 126 show the feature; 38 sessions).**  By method
in the next section.

**Harness internals (58 primary; 23 sessions).**  Counting loaded sessions,
listing the slots of the session structure, finding the state and temporary
directories.  *Covered by* `emacs_describe`, `session_info` (it names the
session's temporary directory), `session_list`, and the copy.

**File reads (134 primary; 16 sessions).**  `/proc/mounts`, directory listings of
`/tmp/harness-UID` and `/var/tmp`, files of the user's tree.  Agents were
discovering what the sandbox shows and where session temporary directories
are, from the one place that saw everything.  *Covered by* `read_file`,
`list_dir`, `glob`, `grep`, and `bash` or `elisp` in the sandbox; that these
see less than the user's Emacs did is the point of the sandbox.

**File mutation (30 primary; 45 calls show a mutating form, in 18 sessions).**  41
of them name the session's own temporary directory: exporting a buffer's text, a
screenshot or the harness's data there (13 copy into it).  Only 4 touch anything
else, one appending a host to the user's `~/.ssh/config`.  *Covered by*
`write_file`, `edit_file` and `bash` inside the jail.  Writing the user's own
files outside it is a decision for the user (`request_directory_access`).

**Credentials (33 primary; 8 sessions).**  File names counted: `k3s.yaml` (34
mentions), kubeconfigs (20), `~/.ssh` (10), a docker config (1), `~/.kube` (1).
Typically the agent copied a cluster's kubeconfig from the user's project into
its temporary directory to run `kubectl` from the sandbox, or read
`~/.ssh/config`.  The goal (use the cluster) is legitimate; the route (reading
credentials with the user's authority, outside the sandbox) is the problem.
*Not offered.*  The path that exists is explicit: the user grants the directory
(`request_directory_access`) or the network (`request_escalation`).  The copy
of the user's Emacs leaves credentials out by name (below).

**Processes (74 primary; 11 sessions).**  Programs run, by calls (sessions):
`bash` 32 (2), `ssh` 10 (1), `emacsclient` 5 (1), `spectacle` 4 (1), `firefox` 3
(1), `kubectl` 2 (2), `scrot` 2 (1), and one each of `adb`, `tailscale`, `git`,
`emacs`, `logseq`, `find`; 11 calls only inspected or deleted processes already
running.  These are commands that needed what the sandbox withholds (the
network, a device, a display, a credential), run from the one place that had it
all.  *Not offered.*  `bash` runs in the sandbox; `ssh` is the tool for other
hosts; what a command needs beyond the session's directories is asked for with
`request_escalation`.

**Changes to the running Emacs (23 calls, 11 sessions).**  14 defined or
redefined code, 7 set a harness variable, 3 added advice, 2 loaded code, 2 added a
hook, 2 started or cancelled a timer.  Hot-patching the UI under test, the
most dangerous use and the one the tool was removed for.  *Not offered.*  The dev
loop does it in a separate instance; the copy of the user's Emacs can be changed
freely and the changes stay there.

**Other (51 primary; 13 sessions).**  Profiling the live Emacs for UI-thread
stalls (the profiler, timers, GC counters), editing review comments through an
internal operation list, and finding out how the package was installed.  A
diagnosis of one problem (docs/analysis/ui-thread-blocking-2026-10-22.md).
*Not offered:* one investigation; `emacs_trace` records the calls of a function,
which is part of such a diagnosis.

## The state that was read, and the copy now offered

Of the 817 calls, 190 (23%) read the value of a variable, and 31 more only asked
about variables (whether one is bound, what it is).  137 variables were read in
all.  The table is by primary category of the call; a call may read several
variables, so a row is calls, not values.

| category of the call | calls | read a variable's value | only asked about variables |
|---|---:|---:|---:|
| credentials | 33 | 0 | 0 |
| process | 74 | 2 | 0 |
| analysis recipe | 5 | 0 | 0 |
| harness-call | 126 | 3 | 0 |
| file mutation | 30 | 1 | 0 |
| ui poking | 144 | 79 | 9 |
| buffers | 74 | 4 | 1 |
| introspection | 88 | 43 | 21 |
| harness internals | 58 | 30 | 0 |
| file reads | 134 | 3 | 0 |
| other | 51 | 25 | 0 |
| all | 817 | 190 | 31 |

The variables read most often were the harness's own state and the UI's data:
`harness-state-directory` (17 calls, 11 sessions), `harness-directory` (11, 8),
`harness-ui-patch-review--reviews` (9, 3), `harness-ui-sessions--project` (7, 2),
`load-path` (6, 6), `harness-supervisor` (5, 4), `harness-ui--sessions` (5, 4),
`features` (5, 5), `custom-file` (5, 3), `harness-model` and `harness-thinking`
(4 each), `harness-tasks-max-running` (4, 2).  The profiler's and the GC's
variables (`gcs-done` and `gc-elapsed` 16 calls each, `profiler-cpu-log` 7,
`gc-cons-threshold` 6) are one investigation of a stalled UI thread
(docs/analysis/ui-thread-blocking-2026-10-22.md).

What a call did with the value (it may do several): counted the elements (16),
took one by position (3), looked up a key (23), visited or filtered the elements
(29), printed or cut the text (1), asked what it is (50), called a harness
function with it (3), or merely bound it and passed it on (108).  Four calls
read a symbol's property (`get` 7, `symbol-plist` 1); the properties named were
`standard-value`, `customized-value` and `safe-local-variable`.  In other
words: the need was not a tool that answers a question about one variable
(`emacs_describe` does that), it was **a value to compute over**, often
several, sometimes a buffer's text beside it.

### The copy

The user asked for a compromise: allow read-only, memory-only operations in an
Emacs Lisp VM, run in the sandbox and initialized with the variable values the
user's Emacs has.  That is now the `snapshot` input of the `elisp` tool
(`fresh` renews the copy instead of using the session's).  With it:

- The harness asks the user's Emacs for the copy through the endpoint's
  `snapshot` request, in slices: each request works for about 25 ms and 256 KB
  and answers `{chunk, next, done}`, so the user's one thread is not held.  The
  harness spends at most 8 s on it; a copy that is not whole by then is used as
  it is and the result says so.  A copy is kept for the session for 60 s.
- The copy holds: the global value of every bound variable, as plain data; and
  every live buffer that is not hidden -- its name, major mode, file,
  `default-directory`, point, modified flag, size, buffer-local values
  (bounded) and its text -- plus `emacs-version`, `system-type`,
  `system-configuration`, the loaded `features` as data, and the time.
- Values that are not data (a buffer, marker, window, frame, process, overlay,
  subr, byte-code function, char-table, obarray) become
  `#s(harness-user-object KIND "DESCRIPTION")`; text properties are dropped.
  A value over 64 KB becomes `#s(harness-user-truncated "NAME" SIZE)`; a
  buffer's text is cut at 1 MB, at most 300 buffers are copied, and the whole
  copy is at most 16 MB.  A manifest, the last form the child reads, says what
  was left out, cut or masked.
- The child sets each value in itself before the code runs, except a fixed list
  the child needs to work (`load-path`, `exec-path`, `process-environment`,
  `features`, the printer, the reader, the debugger, every hook and every
  variable that holds a function: loading a copy runs nothing of the user's,
  and that must stay true afterwards).  The user's value of each of those is
  still in the copy: `(harness-user-value 'load-path)` returns it, and
  `(harness-snapshot-info)` says what the copy held and what the child did with
  it.  So `(length (harness-user-value 'harness-ui--sessions))` is a call the
  old tool was used for, and the child's own `load-path` is not replaced by the
  user's.
- The code changes the copy and nothing else.  Such a child runs with the
  sandbox's `:read-only t :network nil`, whatever the session otherwise has, and
  is refused (`harness-sandbox-unavailable`) where no sandbox can give that.  It
  cannot reach the user's Emacs; nothing in it evaluates anything there.
- Credentials are left out **by name**, because the copy goes to a model.
  `harness-snapshot-withheld-regexp` names the patterns of a credential variable
  (password, token, secret, api-key, the auth-source caches, `plstore`, `epa-*`,
  the provider keys of the harness...); a matching variable is not copied, and
  the manifest lists its *name* only.  A value after a key that looks like a
  credential inside an alist, plist, hash table or struct is masked
  `<withheld>`; `process-environment` is copied entry by entry with such an
  entry's value withheld.  `harness-snapshot-withheld-buffers-regexp` does the
  same for a buffer named for, or visiting, `.authinfo`, `.netrc`, `*.gpg`,
  `.pgpass`, `id_rsa`, a password store...; the buffer's name goes in the
  manifest, not its text.  Both are user options, and the withheld list is the
  user's to extend.

Tests: `test/harness-snapshot-test.el` (the slice cursor, the readable
placeholders, the truncation, sorted names, hiding, the manifest, the time
budget, a buffer's locals and text, and the credentials: a variable, a nested
key, a buffer-local value and a buffer) and `test/harness-elisp-snapshot-test.el`
(what the child sets, what it keeps, `harness-user-value`, a partial copy, the
failure to fetch, and the profile: a snapshot child reads and writes nothing
outside its call's directory and reaches no network, under real bubblewrap).
Making the withheld regexp empty, or letting the child take the user's
`load-path`, fails a test.

### What it does not cover

The copy is data, not the user's Emacs: a function is an opaque placeholder, so
the code cannot call one of the user's functions; hooks never run, no mode
hooks and no after-load functions; a process, window, marker, timer or overlay
is only a description.  It is "read only" against *writes*, not against the
model reading what the copy holds: the copy goes to the provider of the model
that asked for it, and a name is not a proof that a value is not a secret.  What
it does not answer is everything that changes or drives the running Emacs
(23 calls), every `harness-call` (126), every process (74), every credential
file (33) and a screenshot of the user's screen.

## `harness-call`: which methods, and what covers them

Every method named in the visible text, the calls that named it and the sessions
of those calls.  A call may name two methods (the merge rows), so a column adds
up to more than 126.

| method | calls | sessions | covered by |
|---|---:|---:|---|
| `session/list` | 33 | 9 | `session_list` (id, status, kind, name, model, directory, cost, what it waits on) |
| `task/list` | 16 | 5 | `task_list` |
| `worktree/remove` | 12 | 11 | structural, below |
| `session/nodes` | 9 | 4 | `session_read`, `session_history`, `session_search` |
| `session/get` | 8 | 7 | `session_info`, `session_read` |
| `merge/queue` | 7 | 4 | `task_list` (the merge status of a task), `task_control` (merge) |
| `merge/status` | 6 | 3 | `task_list` |
| `task/get` | 6 | 3 | `task_list` |
| `patch-review/get` | 5 | 1 | `review_threads` |
| `acp/remote-status` | 5 | 3 | **not offered**: the state of the phone app's connection, the user's to look at |
| `merge/view` | 5 | 2 | `task_list` |
| `merge/enqueue` | 5 | 5 | **not offered**: the merge queue is the harness's, driven by `hand_in` and the user |
| `task/slots` | 5 | 1 | `task_list` for the queue and what each waits on; not the slot holders; see below |
| `usage/summary` | 3 | 1 | none; see below |
| `merge/pending` | 3 | 3 | `task_list` |
| `merge/cancel` | 3 | 3 | **not offered** |
| `task/settings` | 2 | 2 | **not offered**: the task board's defaults; `session_settings` shows a session's model and budget |
| `task/by-session` | 2 | 1 | `task_list` |
| `insights/projects` | 2 | 1 | none; see below |
| `supervisor/get` | 1 | 1 | `session_read` (the plan), `session_info` |
| `session/select` | 1 | 1 | `session_list` |
| `session/node` | 1 | 1 | `session_read` |
| `harness/api` | 1 | 1 | **not offered**: asked what the server's vocabulary is |
| `store/load` | 1 | 1 | **not offered**: the state directory's files are the harness's |
| `fallback/status` | 1 | 1 | `session_info`, `session_list` |
| `harness/version` | 1 | 1 | `session_info` |
| `acp/status` | 1 | 1 | **not offered** |
| `priority/get` | 1 | 1 | `session_list` (a task's priority) |
| `agent/running` | 1 | 1 | `session_list` |
| `config/get` | 1 | 1 | **not offered**: the whole configuration; `session_settings` shows what a session runs with |
| `config/set` | 1 | 1 | **not offered**: it raised the task limit, the user's setting |
| `agent/outstanding` | 1 | 1 | `session_list` (what a session waits on) |
| `sandbox/wrap` | 1 | 1 | **not offered**: asked what arguments the sandbox builds, to debug it |

33 methods in all.  Methods named in three sessions or more were:
`worktree/remove` (11), `session/list` (9), `session/get` (7), `merge/enqueue`
(5), `task/list` (5), `session/nodes` (4), `merge/queue` (4), `merge/status`
(3), `task/get` (3), `acp/remote-status` (3), `merge/pending` (3) and
`merge/cancel` (3).  Every one of those that an agent should be able to do has a
typed tool.

**`worktree/remove`.**  All 12 calls removed a worktree that lay under
`/tmp/harness-UID/<session>/` (10 name the path, 2 pass it in a variable): a
scratch checkout the agent made with `git worktree add` to compare its work with a
clean tree.  The sequence in the session that began this work is representative:
`git worktree add --detach $T/base HEAD`, a test run in it, then several attempts
to remove it with `git worktree remove` (refused: in the sandbox git cannot see the
other worktrees and would take them for deleted, so a guard read the command text
and refused), a try at moving it and `git worktree repair`, and then
`harness-call 'worktree/remove` through `emacs_eval`, which the refusal's own text
had named as the way.  The cleanup was a fair goal, and no other worktree was
touched; what was wrong is that the same call took any path.  The fix is
structural and is plan step 4: the sandbox mounts the registry of worktrees it
does not show read-only, so `git worktree prune` and `remove` cannot touch them,
and a worktree the session made inside its own directories can be removed with
`git worktree remove` in the sandbox, which is all that was ever needed.  No tool
was added for it.

**`task/slots`, `config/set`.**  One session debugged why its tasks did not
start: `config/set` raised `harness-tasks-max-running` to 3, and then
`task/slots` was read for the limit, the suspended flag and the holders.
`task_list` says the queue is suspended and what each waiting task waits on, but
not the slot holders.  It is the UI's own data (lisp/ui/harness-ui-slots.el) and
one session; nothing was added.

**`usage/summary`, `insights/projects`.**  One session (3 calls) asked for usage
grouped by session, with the session and task lists beside it, to compare what
the harness's modes cost: the recipe now in
`scripts/analysis/extract_usage_data.py`, whose raw data are made with tools
that can see the state directory; another asked for the project list.  A
read-only `usage_summary` (group by session, project or model; since, until)
is the shape a tool would take if this is asked for again; one session does not
make a repeated need.

## The gap, and the change

Of the needs above, one was repeated (11 sessions, 32 calls for the log alone),
legitimate (finding what the harness reported, in the user's own log, to
diagnose it), unmet, and safe to meet: **finding lines in, and reading the end
of, a long live buffer.**  `emacs_buffer` read a line range; the log of a busy
harness is long, so without Lisp it could not be searched at all.

`emacs_buffer` now takes two more arguments (and no new tool exists):

- `contains`: a string or up to five strings.  Only the lines holding any of them
  come back, each with its line number, and the answer says how many lines matched
  and how many it shows.
- `tail`: count from the end, the last `limit` lines or, with `contains`, the
  last `limit` matching lines.  `limit` defaults to 100 for either.

It reads nothing a read of the buffer did not (the buffer is readable in ranges
already), so it stays among the tools that need no approval.  What keeps it safe
on the one thread of the user's Emacs:

- The strings are matched **literally, ignoring case, never as a pattern**: a
  pattern can be written to backtrack for minutes, and Lisp cannot be interrupted
  in the middle of a search.  A search is `search-forward`, linear in the text.
- It looks through **at most the last 16 MiB** of the buffer and says from which
  line it looked.
- A line is cut at 500 characters, the answer stops at the character budget a read
  has, and says so.
- The strings must be short (200 characters), one line each, at most five.  An
  empty, multi-line, too long or too many strings is refused with the reason.
- The tool schema changed and its name, label, kind and folding did not, so the
  Flutter app's fixture is untouched.

Tests: `harness-emacs-endpoint-a-buffer-is-searched-and-read-from-its-end` (tail,
the lines found and their numbers, case, several strings, limit with and without
tail, nothing found, literal not pattern, narrowed buffers, a long line, the
character budget, refusals), `harness-emacs-endpoint-a-search-looks-through-a-bounded-end-of-the-buffer`
(the scan cap and the line numbers beyond it) and
`harness-tools-emacs-buffer-search-and-tail` (what the model reads).  Making the
matching case-sensitive fails the first.

## Not offered, on purpose

| use | why not | what exists |
|---|---|---|
| Lisp in the user's Emacs | arbitrary code in the user's editor, outside every jail | the copy, in a read-only offline child |
| credentials, kubeconfigs, `~/.ssh` | reading them is reading the user's keys with the user's authority, and the model's provider sees what a tool reads | the user grants a directory or the network; the copy withholds them by name |
| starting processes in the user's Emacs | it is `bash` without the sandbox | `bash` (sandboxed), `ssh` |
| redefining code, advice, hooks, timers in the running Emacs | arbitrary code in the user's editor | the dev loop's separate instance; the copy |
| calling a harness method by name | every method is privileged in some way | the typed `session_*`, `task_*`, `review_*` tools |
| changing the harness's configuration (`config/set`) | it is the user's setting | the user changes it; `session_settings` for a session's run |
| a screenshot of the user's frame | it shows the user's screen | `scripts/dev.sh shot` of a dev instance |
| profiling the live Emacs | one investigation | `emacs_trace` |

## Reproducing

1. Run the grep call of "Method", step 1, and note the path it reports ("The full
   output was saved to ...").
2. `python3 -I scripts/analysis/emacs_eval_usage.py PATH --distinct` prints the
   lines and the distinct calls of that file.
3. `python3 -I scripts/analysis/emacs_eval_usage.py PATH --methods --buffers
   --variables --extras` prints the tables above; `--examples CATEGORY:N` and
   `--method-examples METHOD:N` print sanitized first lines of calls; `--json`
   prints the numbers.

The store keeps growing and `emacs_eval` calls stop, so the counts of a later
run differ; the run of 2026-10-24, which this document reports, found 861 lines
and 817 distinct calls in 124 session files.
