# Private model and prompt attribution for commits (2026-10-29)

**Question.** Can the harness record which model wrote each commit, and which
prompt produced it, without publishing that information to the code remotes,
and sync it privately across the user's own devices?

**Short answer.** Yes. Keep git-ai as the line-level attribution engine, but
do not let its notes live in the code repository. Run git-ai in a private
profile -- telemetry off, prompts local, no login -- and point its HTTP notes
backend at a small private notes service. Then add an optional harness module,
`commit-attribution`, which feeds git-ai checkpoints from the harness's own
tools, keeps the prompt side of the attribution in an encrypted private
vault, and reports/blames from both private stores. The code remote receives
neither notes nor prompts, and every device sees the same attribution through
the two private stores.

**Recommendation.** Build the module in four phases: (1) a private-profile
doctor and the private notes service, (2) the checkpoint adapter and a report
command, (3) the encrypted prompt vault and sync, (4) the task-report/blame
UI. The fallback for a user who does not want to run a service -- git notes
pushed only to a private remote -- works, but needs a small upstream git-ai
setting (`notes_sync`) to be safe; a `pre-push` hook alone cannot stop
git-ai's own note push, because git-ai pushes notes with `--no-verify`.

![Private commit attribution: the harness sends agent-v1 checkpoints to
git-ai, git-ai writes authorship logs to a private notes service, the harness
writes redacted prompts to an encrypted vault, and the code remote receives
neither.](../media/private-commit-attribution.png)

## What "private" has to mean

The design is measured against six goals:

- **G1 -- exact line attribution.** For each commit, which lines came from
  which agent session and model, explicitly reported by the agent rather than
  guessed.
- **G2 -- prompt attribution.** For each AI-written line, or at least each
  session/turn, the prompt that produced it, without storing the prompt in
  the commit or in a public place.
- **G3 -- cross-device sync.** A commit made on the laptop is attributed on
  the desktop; prompts written on one device are readable on the other.
- **G4 -- no publication.** Nothing about model, session, prompt or
  attribution appears in a public code remote, a public CI log, or a fork of
  the code.
- **G5 -- optional and reversible.** Off by default, turned on per project,
  removable without rewriting history, and no change to how commits are made.
- **G6 -- survives Git.** Rebase, squash, cherry-pick, amend and merge keep
  the attribution attached to the surviving lines.

Non-goals, at least for the first version: team dashboards, a public badge,
an account with a hosted service, uploading source code, or protecting the
data from the local root user. "Private" here means *not published*, not
"end-to-end encrypted against the device".

The parties and what they may see:

| Party | Sees | Must not see |
|---|---|---|
| Public code host / forks | commits, code, commit messages | notes, model names, prompts |
| Public CI | checkout and build output | notes, prompts |
| Private notes service | commit SHAs, file paths, line ranges, agent/model/session ids | prompts, source code |
| Private vault host | ciphertext only | prompt text |
| Other devices | the user's own notes and prompts | nothing else |
| Model provider | prompts and code it is sent, as today | -- |

## What git-ai already gives

git-ai (OSS, source read at upstream commit `8a6184a`, version 1.7.6) already
does most of the hard part:

- Agents call `git ai checkpoint` after editing. On commit, git-ai writes an
  authorship log to the Git note ref `refs/notes/ai`, mapping each file and
  line range to a session id and its `agent_id` (`tool`, `id`, `model`).
- It understands rebase, squash, merge, cherry-pick, stash/pop, amend and
  reset, and moves or merges the notes with the lines.
- It has a generic `agent-v1` preset for agents it does not ship a preset
  for. Its JSON events carry `repo_working_dir`, `agent_name`, `model`,
  `conversation_id`, and either `edited_filepaths` (an AI edit) or
  `command`/`tool_use_id` (a shell pre/post event). That is exactly the
  interface the harness needs.
- It is local-first: the CLI works offline and does not need a login.
- Its notes format is an open standard; the note content is readable without
  git-ai.

The two parts that are not private by default are the ones that matter:

1. **Notes follow `git push`.** When git-ai observes a push, it also pushes
   `refs/notes/ai` to the same remote (`apply_push_side_effect` in
   `src/daemon.rs`, `push_authorship_notes` in `src/git/sync_authorship.rs`).
   The push is made with `--no-verify`, so a repository's `pre-push` hook
   never sees it. There is no `notes_sync = off` setting in 1.7.6. So with the
   default `git_notes` backend, a `git push origin main` to a public GitHub
   repository also publishes the model/line attribution.
2. **Prompts can leave the machine.** `prompt_storage` has three values:
   `default` (uploaded through the CAS API), `notes` (stored in git notes
   after redaction), and `local` (only in local SQLite, never shared). The
   default is `default`. `telemetry_oss` is enabled unless it is set to
   `off`. A private setup must set both explicitly.

git-ai 1.7.6 also has an **HTTP notes backend** (`notes_backend.kind =
"http"`). With it, notes are stored in a local SQLite queue and uploaded to a
notes server; `apply_push_side_effect` skips the Git note push entirely. That
is the clean private mode: no `refs/notes/ai` exists in the repository, so
there is nothing for a push, a mirror, or a fork to publish. The upstream
repository even includes a reference implementation of the wire contract
(`src/notes/reference_server.rs`, `git ai notes serve`) with two endpoints:

```text
POST /worker/notes/upload          {"entries":[{"commit_sha","content"}]}
GET  /worker/notes/?commits=sha1,sha2  -> {"notes":{"sha1":"content"}}
```

The reference server is in-memory and not for production, but the contract is
small enough that a persistent private service is a weekend-sized component,
not a platform.

**Today, without the harness module.** A user of Claude Code, Cursor, Codex or
another agent git-ai supports can adopt the private profile now: install
git-ai, set the profile below, run the private notes service, and keep using
the agent as usual. Model and line attribution then sync across devices
through the service, while prompts stay in each agent's local store. The
harness module is what adds the harness's own checkpoints, the prompt vault
for harness turns, and the report/UI inside Emacs.

### What git-ai does not do

- It has no notion of a private sync policy. Its notes go to the remote being
  pushed to, or to one configured HTTP server; it does not decide that a
  remote is public and another private.
- It does not know the harness's prompts. Its note records the agent, model
  and conversation id; the prompt text lives in the agent's own store, if it
  keeps one. For the `agent-v1` preset there is no transcript and therefore
  no prompt record.
- It does not provide a harness report, a task-report section, links to
  session nodes, or a `git blame` view inside Emacs.
- Its `agent-v1` session id is derived from `tool:conversation_id`, not from
  the model. If a conversation switches models, the note's session record
  has one model. The harness has to choose the conversation id carefully (see
  "Attribution epochs" below).

## The design

### 1. The checkpoint adapter

The module registers the harness as a git-ai agent named
`emacs-agent-harness`. After a tool that wrote files, it runs:

```text
git-ai checkpoint agent-v1 --hook-input stdin
```

with a JSON event like:

```json
{
  "type": "ai_agent",
  "repo_working_dir": "/home/me/src/project",
  "edited_filepaths": ["/home/me/src/project/src/auth.ts"],
  "agent_name": "emacs-agent-harness",
  "model": "anthropic:claude-opus-4-5",
  "conversation_id": "0f3c...-session@n-42@anthropic:claude-opus-4-5"
}
```

and, around a shell command:

```json
{
  "type": "pre_shell_command",
  "repo_working_dir": "/home/me/src/project",
  "agent_name": "emacs-agent-harness",
  "model": "anthropic:claude-opus-4-5",
  "conversation_id": "0f3c...-session@n-42@anthropic:claude-opus-4-5",
  "tool_use_id": "call-7",
  "command": "npm test"
}
```

with `post_shell_command` after it. git-ai's own Bash handling computes the
diff between the pre and post states and attributes new lines to the session.

Where the events come from:

| Harness event / tool | What the module does |
|---|---|
| `tools/finished` for `write_file`, `edit_file`, `Write`, `Edit`, MCP fs writes | Emit one `ai_agent` checkpoint per call, with the call's path input and the model recorded on the tool-call node. |
| `tools/started` / `tools/finished` for `bash` | Emit pre/post shell checkpoints around the command. |
| a bash command containing `git commit` | First checkpoint the command's touched paths (or all changed paths), then run the command. This makes edits made before the command count. |
| `pre-commit` hook (optional safety net) | If a single command edits and commits, the hook reads the current attribution context and checkpoints the staged/working files just before git creates the commit. |
| `agent/tool-call` for a provider's built-in tool | Use the node's `:meta :model` and `:input` to emit a checkpoint after `agent/tool-result`; if the input does not name paths, checkpoint the working tree's changed files for the session's directory. |

The checkpoint must use the model that **requested** the tool call, not the
session's current model at the end of the call. Tool-call nodes carry
`:meta :model`; that is the value to use. If a session switched models after
sending the call, the switch belongs to the next call, not this one.

The adapter runs from the harness process, not inside the tool's sandbox. The
harness process can see the repository and the git-ai binary; the sandbox may
hide `$HOME` and therefore `~/.git-ai/bin`. For commits executed inside the
sandbox, the git-ai wrapper must be reachable: the module adds the git-ai
directory to the sandbox's readable directories and puts it first on the
command's PATH, or installs the wrapper at a system path. The module's doctor
checks this with a real commit in a temporary repository; if the wrapper is
not reachable, attribution degrades to the paths the module can checkpoint
from outside, and the report says so.

### 2. Attribution epochs: one conversation id per turn and model

git-ai's note maps lines to a session id that is stable for
`tool:conversation_id`. If the harness uses its session id directly, a
session that changes model produces one note session record with one model,
and a commit that spans several user prompts has no way to say which prompt
produced which lines.

Use an **attribution epoch** instead:

```text
conversation_id = <harness-session-id>@<prompt-node-id>@<model-epoch>
```

where `prompt-node-id` is the id of the user message that started the turn,
and `model-epoch` is a short counter that changes when the session's model
changes. The model in the checkpoint is the model of the epoch.

This gives three useful properties:

- Each git-ai session id maps to exactly one prompt node and one model.
- A mid-turn model switch creates a new epoch, so both models appear in the
  note with their own line ranges.
- A sub-agent gets its own harness session id, so its lines do not merge into
  the parent's prompt by accident.

The note's `agent_id.id` is the full conversation id (git-ai stores the raw
id, not only its hash), so the module can parse it back or look it up in its
ledger. The session id itself is `s_` plus
`sha256("emacs-agent-harness:" + conversation_id)[0..14]`.

If a tool call happens outside a turn (a timer, a merge queue, a system
maintenance action), use a synthetic epoch `system@<action>` with no prompt.
The report says "system" rather than inventing a user prompt.

### 3. The private notes service

Run git-ai with:

```json
{
  "telemetry_oss": "off",
  "prompt_storage": "local",
  "exclude_prompts_in_repositories": ["*"],
  "disable_auto_updates": true,
  "disable_version_checks": true,
  "api_base_url": "https://notes.example.internal",
  "api_key": "REDACTED-PRIVATE-NOTES-TOKEN",
  "notes_backend": {
    "kind": "http",
    "backend_url": "https://notes.example.internal"
  }
}
```

(Written by the module's setup command, with a backup of the previous
`~/.git-ai/config.json`; `api_key` may be supplied through
`GIT_AI_API_KEY` instead of the file.)

`allow_repositories` and `exclude_repositories` can narrow which repositories
git-ai tracks at all (an empty allow list means every repository). The private
service does not require narrowing: a public repository's notes are uploaded
to the private service, not to the repository. Narrow the list only if the
user does not want git-ai running in a repository at all. The `api_key` here
is a token for the private service, not a Git AI cloud key; do not run
`git ai login` or set a cloud key in private mode. Pointing `api_base_url` at
the private service as well keeps git-ai's metrics/log endpoints on that host
when a token is configured; `telemetry_oss: off` disables the OSS telemetry
channels separately.

The notes service is a small authenticated HTTP service with a SQLite table:

```sql
CREATE TABLE notes (
  commit_sha TEXT PRIMARY KEY,
  content    TEXT NOT NULL,   -- the git-ai authorship log
  device     TEXT,
  updated_at TEXT NOT NULL
);
```

and the two endpoints above. It never receives prompts, source code or commit
messages: an authorship log contains file paths, line ranges, session ids,
`agent_id` (`tool`, `id`, `model`) and the Git author identity git-ai records.
It should be reachable only over a private network (WireGuard/Tailscale, a
LAN, or a TLS reverse proxy), with a per-device API key (git-ai sends it
as `X-API-Key`; a proxy may translate a bearer token), and backed up like
any other private data.

This service is the piece that makes the mode private **and** multi-device:

- git-ai never writes `refs/notes/ai`, so `git push`, `git push --mirror`, a
  CI checkout and a public fork have nothing attribution-related to carry.
- Every device uploads its notes and fetches the notes for commits it has.
- If the service is offline, git-ai's local `notes-db` queues the upload and
  `git ai blame` still reads the local cache; nothing is lost.
- A repository that used the `git_notes` backend before the switch keeps its
  old `refs/notes/ai`. git-ai 1.7.6 has `git ai notes migrate` to upload those
  notes to the HTTP backend; after it succeeds, the doctor can remove the old
  ref (or keep it local with the push guard). Do not leave an old ref in a
  public repository.
- If a server is not wanted, see "Profile C" below.

The service can also be backed by a bare Git repository of notes instead of
SQLite, if the user prefers Git as the storage and backup mechanism. The wire
contract is the same; the implementation is a choice.

### 4. The prompt vault

Prompts are the sensitive part. Keep them out of git-ai and out of the notes
service. The harness writes a small append-only ledger:

```json
{
  "schema": "harness-attribution/1",
  "repo": "sha256:8f14e45fceea167a",
  "conversation": "0f3c...-session@n-42@anthropic:claude-opus-4-5",
  "session": "0f3c...-session",
  "turn": "n-42",
  "model": "anthropic:claude-opus-4-5",
  "provider": "anthropic",
  "prompt": "Add idempotency keys to the webhook retry path.",
  "prompt_sha256": "…",
  "at": "2026-10-29T10:12:03Z",
  "device": "laptop",
  "redacted": true
}
```

The vault is a directory the user already syncs -- a private Git repository is
the reference implementation. Layout:

```text
attribution-vault/
  devices/
    laptop/2026-10.jsonl.age
    desktop/2026-10.jsonl.age
  recipients.txt          # public keys only
  README.md
```

Each device writes only its own file(s), so two devices never conflict. The
file is encrypted with `age` to the recipients in `recipients.txt` (or with
GPG if age is not available). The private key stays on the device, mode 600,
outside the vault. A device pulls, decrypts its own files, appends its record,
re-encrypts and pushes. The Git host sees ciphertext only. If the vault is a
plain synced folder rather than Git, the same per-device layout avoids
conflicts.

Before writing a prompt to the vault, run it through the harness's existing
secret masking/redaction (`harness-secrets`, `harness-redact`). Store only
the user prompt and, optionally, a short assistant summary -- not tool output,
not the whole transcript, not system prompts. Retention is configurable; the
default can be "keep until deleted", with a `commit-attribution/prune`
command. Deleting a record from the vault does not rewrite Git history; for a
hard delete, the user can prune the vault's history with `git filter-repo` or
start a new vault.

The ledger's job is to answer "which prompt?"; it does not need to duplicate
the note. If a record is missing (a device was offline, a prompt was pruned),
the report can still show the model and session from the note and say the
prompt is unavailable.

### 5. Reports, blame and the task report

The module exposes:

| Method | What it does |
|---|---|
| `commit-attribution/status` | git-ai version, profile, notes service reachability, vault state, last error. |
| `commit-attribution/report` | For a rev range, one row per commit: models, agents, AI line counts, sessions, prompt links. |
| `commit-attribution/show` | A buffer for one commit: subject, per-file line ranges, sessions, models, prompts, links to harness session/message nodes. |
| `commit-attribution/show-prompt` | The prompt text for a session/epoch, from the vault. |
| `commit-attribution/blame` | `git ai blame --porcelain` parsed into an Emacs buffer (or a link to `magit-ai`). |
| `commit-attribution/sync` | Push/pull the vault and flush/retry the notes service; report what moved. |
| `commit-attribution/doctor` | Checks that no attribution can reach a public remote, that prompts are local, that the service is authenticated, and that the wrappers are visible. |
| `commit-attribution/configure` | Shows and applies the private git-ai profile, with a backup and a diff. |
| `commit-attribution/prune` | Deletes ledger records older than a cutoff. |

The task report gets an optional section:

```text
Model attribution (base..head)
  claude-opus-4-5   72% of AI lines   14 commits   3 sessions
  gpt-5              28%               4 commits   1 session
  Prompts: 21 linked, 2 unavailable
```

Each row can open the commit's `commit-attribution/show`; each prompt links to
the harness session/message node when the transcript is on this device, and
to the vault's prompt text otherwise.

The report is generated from two stores, not from the commit message. The
commit message stays exactly as the user wrote it (the existing `commit-msg`
module can still strip Claude trailers, which is a separate concern).

With the HTTP notes backend, read notes through git-ai's commands (or the
service's read endpoint), not through `git notes`: there is no
`refs/notes/ai` in the repository. git-ai can materialize
`refs/notes/ai-display` for `git log --notes=ai-display`; that ref is a display
artifact and is guarded like every other `refs/notes/*` ref. Before reporting,
wait for git-ai's daemon to settle (`git ai await`), so a commit made a moment
ago is not reported as unattributed while the daemon is still writing its
note.

## The optional module

Proposed source: `lisp/modules/harness-commit-attribution.el`, UI (optional):
`lisp/ui/harness-ui-commit-attribution.el`.

```elisp
(harness-define-module 'commit-attribution
  :doc "Which model and prompt wrote each commit, private and synced."
  :requires '(config worktree store session tools agent usage secrets)
  :init #'harness-commit-attribution--init
  :shutdown #'harness-commit-attribution--shutdown)
```

It loads only when enabled in `harness-enable-modules`; it does nothing in a
project that has not turned it on. The project setting mirrors `commit-msg`:
the layered variable `harness-commit-attribution` (off by default), turned on
in a project's `.dir-locals.el` or on the settings page's Project scope.

### Settings

| Setting | Default | Meaning |
|---|---|---|
| `harness-commit-attribution` | nil | Off; per project, or globally. |
| `harness-commit-attribution-backend` | `git-ai` | The only backend in phase 1; `native` is a future fallback. |
| `harness-commit-attribution-git-ai-program` | `git-ai` | Path to the CLI, for a non-PATH install. |
| `harness-commit-attribution-notes-mode` | `private-service` | `private-service`, `local`, or `private-remote` (Profile C). |
| `harness-commit-attribution-notes-url` | nil | Private notes service base URL. |
| `harness-commit-attribution-notes-token` | nil | Per-device API key (`X-API-Key`); prefer the secret store/env. |
| `harness-commit-attribution-vault` | nil | Directory or private Git remote of the prompt vault. |
| `harness-commit-attribution-device` | host name | Device id used for the vault file and notes. |
| `harness-commit-attribution-recipients` | nil | age/GPG recipients for the vault; public keys only. |
| `harness-commit-attribution-prompt-mode` | `excerpt` | `excerpt`, `full`, or `hash` (no text). |
| `harness-commit-attribution-retention-days` | nil | nil keeps until pruned; a number prunes on sync. |
| `harness-commit-attribution-private-remotes` | nil | Remote names/URLs allowed to receive `refs/notes/*` in Profile C. |
| `harness-commit-attribution-task-report` | t | Add the model-attribution section to task reports. |
| `harness-commit-attribution-include-subagents` | t | Attribute sub-agent sessions separately. |

### Lifecycle

- On `harness/started`, `harness/reloaded`, `session/created`, `session/moved`,
  `worktree/created`, and `config/changed`, run the same selected-repository
  check as `commit-msg`: is the setting on for this repository/main checkout?
  If yes, install the optional `pre-commit` safety net (with a marker) and
  record the repository; if no, remove it and the record.
- On `session/node-added` for a user message, remember the turn's prompt node.
- On `agent/tool-call`, remember `(session, call-id) -> (model, prompt,
  epoch)`.
- On `tools/finished` / `agent/tool-result`, emit checkpoints for the call.
- On `agent/turn-ended`, clear the active epoch so a later manual commit is
  not attributed to a finished turn.
- On `agent/call-usage`, record the token/cost of the epoch in the local
  ledger (for the report's cost columns; optional).
- Never block a tool call on git-ai. Checkpoints are asynchronous; a queue
  per repository preserves order. If git-ai fails, the module logs once and
  the tool result is unchanged.

### The pre-commit safety net

A `pre-commit` hook (installed only in opted-in repositories, with the
harness's marker, and never overwriting somebody else's hook) reads
`harness-attribution/context.json` under the repository's git directory
(`git rev-parse --git-dir`, a directory even in a linked worktree, where
`.git` is a file), which the module writes before a bash command that may
commit. It calls `git-ai checkpoint agent-v1` with the context's
session/model/conversation id and the staged and untracked paths. It always
exits 0. This covers the case where one shell command edits files and commits
them before the post-command checkpoint would run.

The hook needs the same git-ai binary access as the sandbox; if it cannot
reach it, it writes a line to the module's log and passes. The module's
doctor exercises this with a temporary repository. If the hook cannot be
installed (a `core.hooksPath` elsewhere, a hook somebody else wrote, a
read-only worktree), the module leaves it alone and reports that the
edit-and-commit-in-one-command case is not covered. A commit made with
`--no-verify` skips the hook; the post-command checkpoint still covers edits
made before the command, but not edits made inside it.

### The setup the module would automate

Until the module exists, the private profile is a handful of git-ai commands.
This is also the sequence `commit-attribution/configure` would show and run
(with a backup of the previous config):

```bash
git-ai config set telemetry_oss off
git-ai config set prompt_storage local
git-ai config --add exclude_prompts_in_repositories '*'
git-ai config set disable_auto_updates true
git-ai config set disable_version_checks true
git-ai config set notes_backend.kind http
git-ai config set notes_backend.backend_url https://notes.example.internal
export GIT_AI_API_KEY='<private notes token>'   # or config api_key, mode 600
```

Then check the mode with a scratch repository:

```bash
d=/tmp/attr-demo; rm -rf "$d"; mkdir -p "$d"; cd "$d"
git init -q; echo hi > a.txt; git add a.txt
git-ai checkpoint agent-v1 --hook-input stdin <<'JSON'
{"type":"ai_agent","repo_working_dir":"/tmp/attr-demo",
 "edited_filepaths":["/tmp/attr-demo/a.txt"],
 "agent_name":"emacs-agent-harness","model":"test:model",
 "conversation_id":"demo@n-1@test:model"}
JSON
git commit -qm demo
git ai blame a.txt          # emacs-agent-harness (model test:model)
git for-each-ref refs/notes # empty: the HTTP backend keeps notes out of Git
```

If `refs/notes/ai` appears after that commit, the notes backend is still
`git_notes`; fix the config before using a public remote.

## Private sync in three profiles

### Profile A -- private notes service + encrypted prompt vault (recommended)

This is the design above. It satisfies G1--G6 without a patch to git-ai and
without any attribution ref in the code repository.

- git-ai config: `notes_backend.kind = "http"`, private URL, private token;
  `telemetry_oss = "off"`; `prompt_storage = "local"`;
  `exclude_prompts_in_repositories = ["*"]`; updates/version checks off.
- Notes: one private service, per device token, SQLite or a note Git repo.
- Prompts: age-encrypted per-device JSONL in a private Git repo or synced
  folder.
- Code remote: no notes, no prompts.
- Sync: automatic via git-ai's notes worker and the vault's `pull`/`push`.

### Profile B -- local only

Same as Profile A but with no notes service and no vault remote. git-ai's
HTTP backend points at a loopback-only service (or at a local SQLite-backed
service the module starts); prompts stay in the harness's state directory. No
cross-device sync, no public leak. This is the simplest way to try the
feature before setting up a host.

### Profile C -- private Git notes remote (compatibility)

If the user does not want to run a notes service:

- `notes_backend.kind = "git_notes"`.
- `refs/notes/ai` stays in the repository.
- The module's `pre-push` guard blocks every `refs/notes/*` push to a remote
  not listed in `harness-commit-attribution-private-remotes`. The notes are
  pushed to a dedicated private remote with
  `git push private refs/notes/ai:refs/notes/ai`, and fetched/merged with
  `git fetch private` (git-ai's fetch side effect merges its tracking ref
  with `-s ours`, so devices do not overwrite each other's notes for different
  commits).

The catch: **git-ai's own note push uses `--no-verify`**. If the user runs
`git push origin` and `origin` is public, git-ai will push `refs/notes/ai` to
`origin` regardless of the guard. Profile C is therefore safe only with one
of:

1. a small upstream git-ai change adding a `notes_sync` setting --
   `"local"` (never push notes), `"private"` (push only remotes matching a
   pattern list), or `"all"` (today's behavior) -- and consulting it in
   `apply_push_side_effect`; or
2. a push gateway: `remote.origin.pushurl` points at a local bare repository
   whose `post-receive` hook forwards only `refs/heads/*` and `refs/tags/*`
   to the real public URL. git-ai's note push hits the gateway, not the
   public remote. This is reliable but surprising and changes how `git push`
   resolves `origin`; it needs careful documentation and an uninstall path;
3. making every code remote private, which defeats the point.

Profile C is useful for a user who already has a private notes remote and
understands the caveat. It is not the recommended default.

### Device enrollment

1. On the first device, `commit-attribution/configure` writes the git-ai
   private profile, creates the age key, prints its public key, and creates
   the vault's `recipients.txt`.
2. Add the public key to `recipients.txt` on every device (or have the setup
   command append it and push).
3. Create a notes-service token per device; store it in the harness's secret
   store or `~/.git-ai/config.json` mode 600.
4. On each other device, run the same setup with the same notes URL and
   vault remote; it sees the existing recipients and can decrypt the files.

Key rotation: add the new public key, remove the old one, re-encrypt the
current files, and revoke the old device's service token. Past ciphertext in
Git history remains readable by the old key; if that matters, rewrite the
vault history or start a new vault.

### Offline and conflicts

- Notes service down: git-ai queues in its local `notes-db`; `git ai blame`
  reads the cache. The module's `status` says how many notes are unsent.
- Vault remote down: the module appends locally and retries on `sync`; the
  per-device file means no merge conflict when it returns.
- Two devices make notes for the same commit (a cherry-pick): the note
  service stores one content per commit SHA; the second upload overwrites,
  or the service can merge/reject. A conflict is rare; the service should
  keep the newest and record both device ids, and the module can report
  "two devices attributed this commit". git-ai's notes themselves are a
  union of line attributions, so a merge would be better than a last-write
  win; the service can compare the `sessions` maps and union them.
- A rebase on one device changes the commit SHA; the note moves with it on
  that device, and the other device fetches the new notes by SHA. The vault
  records are keyed by conversation/turn, not commit, so they remain valid.

## Privacy and security analysis

### Leak paths and defenses

| Leak path | Defense |
|---|---|
| `git push` to a public remote | HTTP notes backend: no `refs/notes/ai` exists. Profile C: pre-push guard plus upstream `notes_sync`/gateway. |
| `git push --mirror` | HTTP mode: no new notes refs. An old `refs/notes/ai` from a `git_notes` period, or a materialized `refs/notes/ai-display`/`refs/notes/ai-remote/*`, is reported by the doctor and blocked by the guard; `git ai notes migrate` uploads the old notes, and the module can then delete the ref. |
| Public CI | A CI checkout gets neither the notes (not in the repo) nor the vault (private credentials absent). `git ai blame` in CI shows nothing unless the CI job is given the private service token. |
| Fork | A fork has commits but no notes and no prompts. Attribution stays with the user's devices. |
| Commit message | The module never writes model/prompt trailers. The message stays the user's. The existing `commit-msg` module can strip Claude trailers independently. |
| Notes service compromise | It holds commit SHAs, paths, line ranges, model/agent/session ids, not code or prompts. Use a private host, TLS, per-device tokens, and backups. |
| Vault host compromise | It holds age ciphertext; the private key is on the devices. |
| Lost device | Revoke its service token and its vault recipient; re-encrypt future vault files. Past ciphertext remains readable to the lost key -- rotate and rewrite if needed. |
| Prompt secrets | Run the existing secret masking/redaction before writing; `prompt-mode = hash` avoids storing text at all. |
| git-ai telemetry / prompt upload | `telemetry_oss: off`, `prompt_storage: local`, `exclude_prompts_in_repositories: ["*"]`, `api_base_url` on the private host, no login/cloud key (only the private service token). |
| Auto-update / version checks | `disable_auto_updates: true`, `disable_version_checks: true`; the private profile can point `api_base_url` at the notes host. |

### What is not protected

- The local root user, or anyone who can read the harness state directory,
  can read prompts and notes. This is not a defense against a compromised
  machine.
- The model provider already sees the prompt and the code it is sent.
- git-ai's note content is plaintext in the private service; it is not
  end-to-end encrypted to the devices. Encrypting note blobs at rest is a
  service-side option, not a protocol feature.
- A public commit itself reveals that code was written; the attribution is
  metadata, not a watermark. Someone who knows the model's style may guess;
  the design does not try to prevent that.

### Why not put prompts in git-ai notes?

git-ai's `prompt_storage = "notes"` stores redacted prompts in the note. With
the HTTP backend, that would put prompts in the private service, which is
simpler than a vault but weakens the separation: the notes service would then
hold the most sensitive part, and a backup or a misconfigured `git_notes`
fallback could expose it. Keeping prompts in an encrypted vault and notes in
the service gives each store the minimum it needs. `prompt_storage = "notes"`
is a reasonable alternative if the user trusts the service and wants one
store; `default` (CAS upload) is never used in private mode.

## Accuracy, granularity and limits

**Granularity.** A git-ai note gives line ranges per file and per session.
The session's `agent_id` gives the tool and model. The epoch gives one prompt
node. So:

- Commit -> models, agents, line counts: exact, from the note.
- Line -> session/model: exact, from the note.
- Line -> prompt: exact at **turn** granularity (all lines from one epoch
  share one prompt), not at "the model saw this hunk at this token"
  granularity. That is the right granularity for "which prompt produced this
  code", and it avoids storing a second line map.
- Commit -> prompt: the union of its epochs' prompts.

**A turn with several tool calls** shares one prompt; that is intended. A
turn where the model changes gets two epochs and two prompts (the same prompt
text, two models), which is also intended.

**Manual edits.** Lines a human writes between agent checkpoints are
attributed to the human (or left untracked) by git-ai's diff. The module does
not invent an AI attribution for them. If the user edits a file in Emacs
while a session is active, the next checkpoint sees the change as human.
There is no need for the harness to record "human" edits separately unless
the user wants human/AI percentages; git-ai already does.

**Edit and commit in one shell command.** The post-command checkpoint is too
late for the note. The pre-commit safety net and the "checkpoint before a
`git commit` command" rule cover the common cases; edits made *inside* the
same command before the commit are covered by the hook if it is installed
and can reach git-ai. The doctor tests this; if the hook cannot be installed,
the module warns and the report may say "unattributed lines" for that commit.
Advise agents to commit in a separate tool call.

**Squash, merge, cherry-pick, rebase.** git-ai's own rewrite logic moves the
notes. The harness's merge queue uses `git` from Emacs; it must use the
git-ai-observed git so the daemon sees the operation. The module's doctor
checks the merge queue path. A squash done on a public host (GitHub's
"Squash and merge") loses attribution because git-ai is not on that host;
the private service can still keep the original branch notes, and the
module's report for the squashed commit says "no note" unless the user runs
the attribution CI action. This is a known git-ai limitation.

**External agents.** Claude Code, Cursor, Codex and the rest can keep using
git-ai's own hooks. Their notes go to the same private service and their
models appear in the report. Their prompts are in their own stores; the
harness vault cannot see them unless the agent writes a transcript the
harness can read. The first version therefore promises prompt attribution
for harness sessions, model attribution for every git-ai-tracked agent. That
is stated in the module docs rather than silently omitted.

**Remote sessions.** A session working over TRAMP has its repository on
another host; git-ai must run there. Phase 1 records commit-level data only
if the remote has git-ai and the notes service is reachable; otherwise the
module says attribution is unavailable for that session. A phase-2 option is
to run a small git-ai helper over SSH.

**Human lines.** git-ai's `h_` keys record known human authors if an editor
integration observes them. The harness does not have an IDE integration, so
human lines are usually "untracked"; the report should say "AI lines" rather
than claim the rest is human. The percentages are of attributed lines, not of
the whole commit.

## Implementation plan

### Phase 0 -- spike (1--2 days)

- Install git-ai 1.7.6 in a scratch environment.
- Run `git ai checkpoint agent-v1` with the payload above, commit, and inspect
  `git log --show-notes=ai`; verify model and line ranges.
- Configure `notes_backend.kind = "http"` against the reference server; verify
  no `refs/notes/ai`, `git ai blame` works, and `git push --mirror` carries
  no attribution.
- Measure checkpoint latency on a medium repository; target < 20 ms per tool
  call and no perceptible commit delay.
- Decide the notes service storage (SQLite vs. note Git repo) from the
  result.

### Phase 1 -- module skeleton and doctor (3--5 days)

- Add `lisp/modules/harness-commit-attribution.el` with the module
  definition, settings, repository selection, and `status`/`doctor`/
  `configure`.
- Add `test/harness-commit-attribution-test.el` with a fake git-ai binary
  that captures payloads and a fake notes service.
- Regenerate `docs/modules/` and add the README section.
- Acceptance: off by default; enabling on a temp repo writes the config,
  installs the pre-commit hook with a marker, and removes both on disable.

### Phase 2 -- checkpoints and report (3--5 days)

- Implement the tool/event checkpoint adapter and the epoch scheme.
- Implement the local ledger (SQLite table or JSONL under the state
  directory) and `report`/`show`/`show-prompt` (prompt from the local
  session for phase 2).
- Test edit, write, bash, model switch, sub-agent, and a commit made outside
  the harness (untraced fixup).
- Acceptance: a task's commits have notes with the expected models; the
  report shows line counts and sessions; no note is written to the code
  remote.

### Phase 3 -- private service and vault (3--5 days)

- Add the persistent notes service (a small script in `scripts/` or a
  separate repository; the module only configures the URL/token).
- Implement the age/GPG vault writer, `sync`, device enrollment, retention
  and prune.
- Test two clones sharing a service and a vault; commit on A, report on B;
  service down/up; key rotation; missing prompt.
- Acceptance: cross-device report works; the public remote contains no
  `refs/notes/*`, no model string, no prompt.

### Phase 4 -- UI and task report (2--3 days)

- Add the `ui-report` section, the `commit-attribution/show` buffer, and the
  `blame` view.
- Add a settings page section and a link from the task card.
- Acceptance: a task's report names the models and prompts, and each link
  opens the right session/message or the vault's prompt.

### Phase 5 -- fallbacks and upstream (optional)

- Profile C (`git_notes` + private remote) with the guard and the caveat.
- Upstream PR to git-ai for `notes_sync` and a note-sync allowlist.
- Native commit-level fallback if git-ai is unavailable (no line-level
  claims).

### Files

| File | Change |
|---|---|
| `lisp/modules/harness-commit-attribution.el` | New module. |
| `lisp/ui/harness-ui-commit-attribution.el` | Report/settings UI (optional). |
| `test/harness-commit-attribution-test.el` | Unit/integration tests. |
| `docs/modules/commit-attribution.md` | Generated page. |
| `docs/analysis/private-commit-model-attribution-2026-10-29.md` | This design. |
| `docs/media/private-commit-attribution.png` | This diagram. |
| `scripts/attribution-notes-server` | Reference private service (optional). |
| `README.md` | A "Private commit attribution" section. |

### Tests and acceptance criteria

- **Unit:** payload shape for write/edit/bash; model from the tool-call node,
  not the session; epoch changes on model switch; sub-agent id; redaction;
  retention.
- **Integration:** temp git repo + fake git-ai that parses `agent-v1`; a
  commit gets a fake note with the expected session/model; the report reads
  it; a commit made outside the harness is picked up by the untraced fixup
  (if git-ai is installed in the test environment).
- **Privacy:** after `git push` and `git push --mirror` to a bare test
  remote, `git ls-remote` has no `refs/notes/*`, and `grep` of the bare repo's
  objects finds no prompt/model string. The notes service's database has no
  prompt column.
- **Sync:** two clones share a notes service and a vault; A commits, B
  reports; B commits, A reports; a service outage queues and recovers.
- **Failure:** git-ai missing, service unreachable, age key missing, hook
  conflict -- each yields a clear status and leaves the tool/commit
  unaffected.
- **Performance:** checkpoint p95 < 20 ms; commit latency increase < 50 ms on
  a 10k-line repo.
- **Off by default:** a session with the module loaded but the project
  setting off runs no git-ai command and writes no ledger record.

### A small code sketch

```elisp
(defun harness-commit-attribution--checkpoint (session call paths kind)
  "Send a git-ai checkpoint for CALL of SESSION that wrote PATHS."
  (let* ((model (or (plist-get (plist-get call :meta) :model)
                    (plist-get (harness-call 'session/get session) :model)))
         (epoch (harness-commit-attribution--epoch session model))
         (payload (list :type (if (eq kind 'shell-pre) "pre_shell_command"
                                (if (eq kind 'shell-post) "post_shell_command"
                                  "ai_agent"))
                        :repo_working_dir (harness-commit-attribution--root paths)
                        :edited_filepaths (and (eq kind 'edit) paths)
                        :agent_name "emacs-agent-harness"
                        :model model
                        :conversation_id epoch
                        :tool_use_id (plist-get call :id)
                        :command (and (memq kind '(shell-pre shell-post))
                                      (plist-get (plist-get call :input) :command)))))
    (harness-commit-attribution--enqueue
     (list (harness-commit-attribution--git-ai) "checkpoint" "agent-v1"
           "--hook-input" "stdin")
     (harness-json-encode payload))))
```

The real implementation uses `harness-run-command` with a per-repository
queue and a mode-600 temporary file for the JSON, not a shell string, so
prompts and paths never appear on a command line.

### Upstream patch sketch (for Profile C)

```rust
// src/config.rs
pub enum NotesSync { Local, Private, All }
// notes_sync: NotesSync (default All)
// notes_sync_remotes: Vec<Pattern> (default empty)

// src/daemon.rs, apply_push_side_effect:
match Config::get().notes_sync() {
    NotesSync::Local => return Ok(()),
    NotesSync::Private if !Config::get().notes_remote_allowed(&remote) => return Ok(()),
    _ => {}
}
```

The default keeps today's behavior; users opt into privacy. The harness
module feature-detects the setting (or a minimum version) and uses Profile C
only when it is present.

## Alternatives considered

| Alternative | Why not |
|---|---|
| **Commit trailers** (`Model: ...`, `Prompt-Id: ...`) | Public by construction, forgeable, clutters history, and survives only until someone rewrites the message. Rejected for the private goal. |
| **Native harness notes, no git-ai** | Reimplements line tracking through rebase/squash/cherry-pick, which is exactly the hard part git-ai already solves. Keep as a commit-level fallback only. |
| **git-ai Teams / cloud** | A hosted account and a third party; the user explicitly does not want to publish. Self-hosted Teams is heavier than one user needs. |
| **`prompt_storage = "notes"`** | Simpler (one store) but puts prompts in the notes service and in any fallback to git notes. Acceptable only if the service is trusted as much as the vault; not the default. |
| **One private remote per repository** | Works, but dozens of remotes, no central report, and the `--no-verify` note-push problem remains. |
| **Sync git-ai's `notes-db` SQLite** | Concurrent writes and sync conflicts; a service with an HTTP contract is cleaner. |
| **No prompts, model only** | Loses the user's main ask ("prompt attribution"). The vault is a small addition. |
| **Public attribution for some repos** | Possible later: a per-project policy that uses git notes and publishes them deliberately. The default is private; opting a repo into public attribution is an explicit exception, not a mode. |

## Decisions the user should make

1. **Where does the private notes service live?** A home server / NAS over
   Tailscale, a small VPS with TLS, or a local-only process for Profile B.
   This is the only infrastructure the design needs.
2. **Storage for the service:** SQLite (simple, queryable, backup the file) or
   a bare Git repository of notes (Git-native, easy to mirror). Either fits
   the contract.
3. **Vault encryption:** age (simple keys, good for devices) or GPG (already
   in the user's keyring). If neither is acceptable, a private Git repo of
   plaintext prompts only if the host is trusted; not recommended.
4. **Prompt retention:** full prompts, excerpts, or only hashes. The default
   proposal is redacted excerpts, kept until pruned.
5. **Scope:** harness sessions only, or every git-ai-tracked agent in the
   opted-in repositories. The recommendation is every agent for model
   attribution, harness sessions for prompt attribution.
6. **Whether to carry the upstream `notes_sync` patch** for Profile C, or
   stay on Profile A and avoid git notes entirely.

## References

- git-ai: <https://github.com/git-ai-project/git-ai> (source read at commit
  `8a6184a`, version 1.7.6).
- How git-ai works: <https://usegitai.com/docs/get-started/how-git-ai-works>.
- git-ai configuration: <https://usegitai.com/docs/get-started/configuration>.
- Git AI authorship standard v3.0.0:
  <https://github.com/git-ai-project/git-ai/blob/main/specs/git_ai_standard_v3.0.0.md>.
- In the git-ai source: `src/commands/checkpoint_agent/presets/agent_v1.rs`
  (the `agent-v1` payload), `src/git/sync_authorship.rs` (note push/fetch),
  `src/daemon.rs` (`apply_push_side_effect`, the HTTP-backend skip),
  `src/notes/reference_server.rs` (the notes-service contract),
  `src/config.rs` (`prompt_storage`, `telemetry_oss`, `notes_backend`).
- In the harness: `lisp/modules/harness-commit-msg.el` (the repository-hook
  pattern), `lisp/modules/harness-tools.el` (`tools/started`,
  `tools/finished`, `tools/file-written`), `lisp/modules/harness-agent.el`
  (`agent/tool-call`, `agent/tool-result`, tool-call `:meta :model`),
  `lisp/modules/harness-session.el` (`session/node-added`, user prompt
  nodes), `lisp/modules/harness-store.el` (SQLite), `lisp/modules/harness-secrets.el`
  and `harness-redact.el` (redaction), `lisp/modules/harness-usage.el`
  (tokens/cost).
- Existing Emacs viewer: `magit-ai`, <https://github.com/jwiegley/magit-ai>.
