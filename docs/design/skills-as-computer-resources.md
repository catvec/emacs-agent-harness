# Skills as resources of the computer that has them

## The problem

Skills were the harness process's own: `harness-skills.el` scanned
`harness-skills-directories` on whichever machine ran the harness,
first-wins by name, and `skill_load` read a file there.  The task
"Make harness architecture device-aware" drew the line this repository
now holds to: the harness server keeps state and runs no tool on the
machine it happens to run on, a **client** speaks ACP and keeps no
state, and a **computer** is a machine whose client runs MCP servers
for it.  A skill is a machine's local knowledge — the user's
`~/.claude/skills`, a project's `.claude/skills`, the skill a Claude
Code plugin ships — so it belongs to the computer that has it, exactly
as a git repository or a display does.

Three things were wrong once that line was drawn:

1. A session whose client runs on a laptop read the skills of the
   machine running the server.  Skills of the machine the user is
   actually on were invisible.
2. Nothing said *which* machine a skill came from, so two copies of
   `code-review` could not be told apart, and the first one found won
   silently, which differs by machine — an unreproducible answer.
3. The obvious repair, a skills directory the harness server manages
   or a git repository it clones, makes the server into the owner of
   another machine's local knowledge.  The task forbids it: a
   server-registered skills repository must not be a prerequisite, and
   there must be no parallel registry.

The task's eight acceptance criteria are: metadata and provenance with
a stable identity and a fingerprint; discovery and registration through
the existing resource lifecycle; offline and reconnect behavior; trust
and permissions; duplicate names, conflicts, versions and pinning;
retrieval over the existing transport; selection by reusable
profiles/workspaces; and meaningful regression tests.

## The decision

**One scanner, both sides.**  `lisp/harness-skills-scan.el` is a new
library, loaded before modules on both sides of the process split (it
joins `harness--library-files`).  It finds `NAME/SKILL.md` under the
documented conventions, parses the front matter, bounds every read and
computes the identity and the fingerprint.  The skills module uses it
for the harness's own machine; the computer endpoint uses it on the
machine it runs on.  There is no second scanner, so a skill is
identified the same way wherever it is found, and no second registry.

**Advertisement is the computers module's resource lifecycle.**  The
client endpoint's existing `:resources` payload (sent with
`computer/register`, `computer/attach` and `computer/update`) gains one
`:kind "skill"` resource per skill.  `harness-computers--normalise-resource`
already stores resources per computer and replaces them wholesale on
each report, so:

- registering, attaching and reporting again are the reconciliation:
  no stale entry and no duplicate can survive a report;
- a skill a computer no longer has disappears with the next report;
- removals need no new mechanism, no tombstone and no store.

A new method, `computers/update-resources (id kind resources)`, lets
one kind be replaced after a refresh the harness asked for, so a change
is seen without waiting for the client to report again.

**Identity and fingerprint.**

- `:id` is `sk-` and the first 16 hex digits of SHA-1 over
  `(root, source, origin, relative-path)`.  It names a *location on an
  owner*: it survives a rename of the skill, an edit of its content, a
  change of its description, and a reconnect, because none of those
  change the location.  A move or a rename of the directory is a
  different id — deliberately: the old id is removed by the owner's
  next report, and a reference to it says it is gone rather than
  quietly resolving to something else.
- `:fingerprint` is `fp-` and the first 32 hex digits of SHA-256 over
  the SKILL.md bytes, the sorted relative names of the supporting files
  and each file's size.  It needs no clock, so two computers compare
  their copies without trusting a modification time.
- `:version` is the front matter's `version` when it declares one;
  `:version-key` falls back to `fp-XXXXXXXX` (the fingerprint's first
  eight digits).  A pin uses either.

**Names, conflicts, versions, pinning.**  Every entry carries
`:owner` (`harness`, or a computer's id), `:owner-name`, `:reference`
`OWNER/NAME`, `:pin` `OWNER/NAME@VERSION`, and `:state` (`ready`,
`offline`, `not-granted`, `unavailable`).

- A bare name resolves when exactly one owner has it, or when every
  copy shares one fingerprint — then it does not matter which one
  serves the bytes.
- Different fingerprints under one bare name are `ambiguous`, with
  every qualified reference named.  Never first-wins.
- `OWNER/NAME` names one copy.  `@VERSION` and `#FINGERPRINT` pin it.
  A pin that matches nothing is `version-mismatch` (the name exists at
  another version, and the versions that do exist are listed) or
  `missing`; **no version is ever substituted for the one asked for**.

**Retrieval over the existing transport.**  The endpoint's MCP server
gains a `skills` tool: `action` `list`, `refresh` or `read`, with `id`,
`file`, `fingerprint` and `cwd`.  The harness fetches a skill's content
when one is selected (`skills/load`, `skill_load`, `skills/expand`),
over the same authenticated MCP connection as `screenshot` or
`pointer`, with the computer named and its client bound.  The harness
keeps **no copy of a skill's content**: a disconnected computer is
listed honestly as `offline` and reading it fails, rather than serving
instructions the owner no longer has.  The fetch sends the fingerprint
the selection saw, and the owner refuses when its copy differs, so
content cannot silently become another version between selection and
retrieval.  A `:changed` flag reports the difference when the owner
does serve a newer copy.

**Trust and permissions.**  A new computer-use capability, `skills`
(`harness-skills-scan-capability`), joins
`harness-computers-capability-names` with the doc "Read the skills the
computer advertises, and no file of it."

- *Listing* needs no grant: metadata is what a computer advertises
  publicly, like its resources, and the entry says `not-granted` when
  this session's grant does not hold the computer.
- *Reading* goes through the permission gate at stage 7 like every
  other computer call (`computers/check`, capability `skills`), and the
  tool handler checks again once the owner is known.  `skill_load`'s
  `:computer` requirement is a tool-registry field, so the gate sees a
  qualified reference before the handler runs.
- Reading a skill grants nothing and runs nothing: no script, no
  install, no sandbox change.  A skill's content stays data from a
  computer, below the harness's own instructions and the user's.
- The scanner never reads a credential: the roots are the documented
  skill locations, a path that is or holds the home directory is
  refused, and containment (once links are resolved) is enforced on
  both the skill directory and each supporting file, on the owner.

**Selection by workspace and profile.**  A selection is durable intent,
a list of references (`?` prefix = optional), kept in three places:

- the harness-wide default, `harness-skills-profile`;
- a workspace's `:skills` field (`workspace/create`, `workspace/update`),
  inherited by each episode as its `:ext` `:skill-selection-inherited`;
- a session's own `:skill-selection` (set with `skills/select`), which
  overrides what the workspace put there.

`skills/selection` resolves the selection against what exists now and
returns each intent as `ready`, `missing`, `ambiguous`, `offline`,
`not-granted`, `unavailable` or `optional-missing`.  **A selection
never copies a grant**: whether a selected skill is `ready` depends on
the session's own grants and the computer's state on the spot.

**Backwards compatibility.**  The harness's own skills are the `harness`
owner and keep the old behavior exactly: the same `harness-skills-directories`
defaults, a project's skill shadowing a global one of the same name, the
plugins' last, and bare names still loading them.  A harness with no
computer registered is a working chat with its own skills; a session
needs no registration to use them.  `/name` and `@skill:name` expansion
still works synchronously for the harness's own skills and returns a
promise when a referenced skill belongs to a computer.

## Alternatives considered

**A server-side skills repository or directory the harness manages.**
The task's explicit prohibition.  It also puts the server in the path
of another machine's local knowledge, needs a push/sync story, and
cannot see a skill the user just wrote on their laptop.

**A separate skills registry beside the computers module.**  A table of
`(computer, skill)` records, its own reconcile on reconnect, its own
store.  It would duplicate the resource lifecycle, drift from it (the
resource list is what the computers page shows), and make "the
computer's resources" mean two things.  Using the existing `:resources`
payload costs one `:kind` and gets reconciliation, persistence,
`computers/changed`, the access view and the page for free.

**A content cache on the harness.**  It would make an offline computer
readable, and it is the one thing the task ought not to allow quietly:
cached instructions would be followed as if they were the owner's
current ones, with no way for the user to see the difference.  The
design refuses to cache and says `offline` instead.

**First-wins with a qualification only in the listing** (the old
behavior, extended).  Cheap, and wrong: which copy a bare name reads
would depend on registration order.

**A `:skills` capability that is implied by `exec` or `files`.**  A
computer that can run programs can of course read its own skill
directories, but the capability is what the *session's grant* names, so
bundling it into another capability would hand out skill reading to
every session that was granted a shell.  A separate capability keeps
the grant meaningful.

## Shape of the change

- `lisp/harness-skills-scan.el` (new library): entries, containment,
  front matter parsing and bounded diagnostics, the supporting-file
  scan, identity, fingerprint, version, `read`, `scan`, `sort`,
  `summary`, `properties`; the bounds as defcustoms
  (`-max-skills`, `-max-file-bytes`, `-max-files`, `-max-files-bytes`,
  `-max-file-read-bytes`, `-max-depth`, `-plugins-directory`).
- `lisp/harness-skills-scan-test.el` (new): the scanner alone — front
  matter and fallbacks, malformed metadata isolated and bounded,
  identity across rename and move, fingerprint sensitivity, containment
  and the home refusal, the file bounds.
- `lisp/harness-computer-endpoint.el`: `require`s the scanner; the
  `skill` resources in `--resources`; the `skills` capability in
  `--capabilities`; the `skills` MCP tool with `list`, `refresh` and
  `read`; the per-cwd scan cache and its mtime stamp; the option
  `harness-computer-endpoint-skill-roots` (nil = documented
  conventions), `-skill-plugins`, `-skill-project`.
- `lisp/modules/harness-skills.el`: rewritten around the two owners —
  the harness's own entries from the scanner and the computers' from
  `computer/resources`; `skills/list|search|load|refresh|directories|
  expand|selection|select`; the resolution and conflict rules; the
  tools `skill_search` and `skill_load`; the prompt index that names
  qualified references and what cannot be read now.
- `lisp/modules/harness-computers.el`: the `skills` capability and its
  doc; `computers/update-resources`.
- `lisp/modules/harness-workspace.el`: `:skills` on the workspace and
  in each episode's `:ext`.
- `docs/modules/skills.md`, `docs/modules/computers.md`,
  `docs/modules/README.md`: regenerated from the sources.
- `docs/architecture.md`: the skills section gains the owner,
  capability, transport and selection contracts.

Tests: `lisp/harness-skills-scan-test.el` (10), new tests in
`lisp/harness-computer-endpoint-test.el` (advertisement, containment,
the `skills` tool over MCP, refresh), a new
`lisp/modules/harness-skills-computers-test.el` (16: registering and
reconciling, refresh, conflicts, pinning, offline and reconnect, trust,
selection), and the rewritten `lisp/modules/harness-skills-test.el`.
