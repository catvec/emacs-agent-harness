# The trust model: what an agent can reach, and what stops it

This page states the boundary the harness relies on, the one it used to
rely on, and what each kind of tool may do.  It is the contract the
containment tests in `test/harness-containment-test.el` check.

## The boundary is the kernel, not a reading of the command

An agent can ask for a command such as

```
python3 -c 'import shutil; shutil.rmtree("/home/you/project")'
```

Nothing in its text says `rm`, names no file the harness could check,
and the code it runs can open anything the process can.  Reading a
command for its intent to decide what it may reach cannot work: it
needs a complete understanding of every program an agent may run and of
how each of them touches the file system.  A parser that refuses `rm
-rf` and allows `python3` is not a boundary; it is a suggestion.

So the harness does not decide what a command may reach by reading it.
A command, and code an agent asks to run, runs in an operating-system
sandbox with the directories of its session mounted and nothing else:

- `bash` runs its shell in the session's sandbox
  (`lisp/modules/harness-tools-shell.el`, `sandbox/wrap`).
- `elisp` runs an `emacs --batch` child in the same sandbox, never in
  the harness and never in the user's Emacs (`lisp/harness-elisp.el`).
- An MCP server the harness starts for a session runs in the same
  sandbox (`lisp/modules/harness-mcp.el`), with the same profile a
  `bash` command of that session gets.
- The file tools (`read_file`, `write_file`, `edit_file`, `list_dir`,
  `glob`, `grep`, `file_info`) are such a server, `fs`
  (`lisp/harness-mcp-fs.el`), wherever a sandbox applies to the session
  and the path is on this machine.

The profile is computed once, from the session's permission directories
(`harness-tools-shell-sandbox-profile`): its working directory and
worktree, its own temporary directory, the configured and granted
directories read-write, the read-only directories and the skills
directories read-only, and a scratch directory for the one process.
Nothing outside is shown, `$HOME` included.  The mounts are fixed when
the process starts, so a directory granted later starts a new process.

The backends are bubblewrap, `systemd-run` and MXC
(`lisp/modules/harness-sandbox.el`).  With `harness-sandbox-policy`
`required`, a session whose commands cannot be confined runs no command
at all; it never falls back to running them plainly.

That is a choice, and `preferred` is the default: where no backend is
available (macOS without MXC, a Linux with neither bubblewrap nor
`systemd-run`) or the policy is `off`, a command runs plainly, and what
stands between it and the user's files is the permission chain's reading
of it and the user's answers, a courtesy doing a boundary's work.  The
containment this page describes holds where a backend runs the command,
and `sandbox/confined-p` says whether it does; choose `required` where
it has to hold.

## Parsing still exists, as a courtesy

The harness still reads shell command lines in a few places, and none
of them is a boundary.  The one reading that stood in for the kernel is
gone: `sandbox/check-command` refused `git worktree prune` and the
commands like it by their text, and a stage of the permission chain
asked it about every `bash` call.  Both are deleted.  A command is no
longer judged by how it is spelled to keep the sandbox safe.

The worktree registry is protected by mounts instead.  Git in the
sandbox sees only the session's own worktree, so it takes every other
one for deleted, and `git worktree prune` would drop the registration
(`GIT/worktrees/NAME`) that makes those files a worktree, in a common
git directory the session can write.  So the sandbox mounts the
registration of every worktree it does not show read-only over the
writable git directory (`harness-sandbox--hidden-registrations`:
`--ro-bind` in bubblewrap, `BindReadOnlyPaths=` in `systemd-run`, a
read-only path in MXC's configuration, which no macOS host has run
yet).  Any program, spelled any way, finds those registrations
read-only, and the kernel refuses the write.  The session's own
registration, and those of the worktrees it makes inside its
directory, stay writable.  A worktree the sandbox cannot tell is
shown, or whose registration says nothing, counts as not shown.

What is left of command reading decides what to ask or say, not what a
process can reach:

- A permission prompt names the paths a command is about and offers
  lasting answers for the programs it runs, and a standing rule about
  programs or paths is matched with the same reading
  (`lisp/modules/harness-perms.el`).  A rule means what its user wrote:
  it is their decision about which calls to stop asking about.
- A few refusals and questions are hints.  A command that names a
  skills directory the sandbox does not show is refused with the way to
  read it, and one that names a project settings file and looks like
  writing it waits for the user (the access module).  The sandbox
  confines the command whether or not the reading catches it; the
  settings file a command may still write inside its own directory is
  a known limit, below.
- The auto-mode judge, a model, reads the command line whole and says
  whether a call looks harmful.  It is a safety check for the user, not
  the reason a session stays inside its directories.
- One allow is derived from a command line: a read-only cloud query
  (`gcloud ... list`, `gsutil ls`) skips the judge in auto mode and
  when the user is away.  It does so only for a command the sandbox
  confines, so a misreading can do no more than the sandbox shows.

A permission prompt decides whether a call is worth asking about, and a
judge whether an unattended session may run it.  An answer can widen a
session's *grants* (a directory, the network, a capability), never the
sandbox's reading of the machine: a granted directory is mounted, and
nothing else is.  Every place that reads a command line, and whether it
asks, refuses or allows, is listed in
[the audit](analysis/command-parsing-audit-2026-10-24.md).

Where no backend runs the command (the case above), none of this
holds: there is no kernel to refuse, and the reading of the command and
the user's answers are all that stand between it and the user's files.
The cloud allow does not apply there; such a command goes on to the
judge or the user.  `sandbox/confined-p` says whether a directory's
commands are confined, and the policy `required` keeps the others from
running.

This is why a tool that is not itself jailed must not be able to do
what a jailed one cannot.  The tests ask the same thing through every
route: `cat` of a file outside, a Python script that reads it, a Python
script that removes a directory outside, and the `elisp` tool's child.

## The route that left the jail: free-form Lisp in the user's Emacs

The incident that prompted this model: an agent asked `bash` to run
`rm -rf dir_a`, was refused, and then called `emacs_eval` — a tool that
sent model-written Lisp to the user's live Emacs — with code that
called the harness's `worktree/remove` method.  The directory was
removed.  Every guard around `emacs_eval` (a judge model's opinion
that the code was fast, a two-second timer, `while-no-input`) constrained
*how long* the code ran, not *what it could reach*: the code ran in the
user's Emacs, outside every sandbox, with the harness's methods one
`harness-call` away.

That tool is removed, not turned off:

- `emacs_eval` and its module are gone; a call to it is a call to a
  tool that does not exist.
- The setting that enabled it (`harness-emacs-eval`) is gone.
- The endpoint request that evaluated code (`eval`), the code that
  guarded it, and the bridge that let it call harness methods
  (`harness/call`, `harness-call-fallback-function`,
  `harness-acp-call-lisp`) are gone.

Nothing else can run model-written Lisp outside the jail.  The `elisp`
tool always evaluates in the sandboxed background child, and refuses a
call that asks for the user's Emacs.

## The user's Emacs is an MCP server of typed tools

The user's Emacs cannot be put in the sandbox: it is their editor, with
their files and their init.  It is bounded the only way that works for
a program outside the jail — by what it can be asked to do:

- The Emacs lends itself to the harness as an MCP server
  (`lisp/harness-emacs-endpoint.el`).  Its tools are a fixed vocabulary
  — `buffers`, `windows`, `buffer`, `open`, `insert`, `save`,
  `describe`, `definition`, `trace`, `messages`, `snapshot` — each
  taking data or a bounded action.  None takes code, and a `tools/call`
  naming anything else is an error of the protocol.  `snapshot` reads
  the Emacs's variables and buffers as data, for the `elisp` tool to
  start from (below).
- One MCP message travels per `_harness/emacs/mcp` request on the ACP
  connection the client already has.  The harness is an ordinary MCP
  host here (`harness-mcp-attach` with an `:external` server); the core
  has no Emacs-specific request vocabulary left.
- The harness's `emacs_*` tools are brokers: they ask the MCP server
  for plain data and word it, and the permission chain decides the call
  as it decides any other.

The Emacs is the user's, so its tools can touch what the user can, which
is the danger in them.  The tools that only look (`buffers`, `buffer`,
`describe`, `definition`, `messages`, `windows`) show the user's Emacs
to the agent, which the user asked for and the chain always allows.  The
two that change something are bounded by the jail's directories, like
the file tools, although neither call names a path:

- A buffer that visits a file *is* that file: saved, it overwrites the
  file on the user's disk, as the user, outside every sandbox (the init
  file, if it is open: code at the next start).  `emacs_insert` and
  `emacs_save_buffer` name a buffer, so the jail has nothing to judge in
  the call.  They ask the Emacs which file the buffer visits, and go on
  only when the session may write that file by the jail's own rule
  (`permission/path-writable-p`: its directories and grants, links
  resolved, `..` collapsed).  The change then names that file, and the
  Emacs makes sure the buffer still visits it in the same step, so a
  buffer cannot come to visit another between the check and the change.
  A buffer that visits no file changes none.
- `open` visits a file the jail judged (the tool declares it as a path),
  with local variables restricted to the safe ones and `eval:` never
  applied, so a file an agent wrote cannot run code through the user's
  own settings.

Nothing here runs code, and the vocabulary is the whole interface.

## A copy of the user's Emacs, in the jail

The user's Emacs holds the values agents were asking for: what a
variable is, what the UI's data holds, what a buffer says.  In the
removed tool's stored calls, 190 of 817 read a variable's value and 31
more asked about variables (see
[docs/analysis/emacs-eval-usage-2026-10-23.md](analysis/emacs-eval-usage-2026-10-23.md)).
The endpoint can give a **copy** of that state without giving the Emacs:
the `snapshot` request reads variables and buffers as plain data, in
slices, each request working for about 25 ms so the user's one thread is
not held.

The `elisp` tool takes the copy as an input (`snapshot`, and `fresh` to
renew it rather than use the session's): the harness fetches it through
the endpoint, writes it in the call's `io/` directory, and the child
`emacs --batch` loads it before the code runs.  The code computes over
the user's values and changes only the copy; the user's Emacs is read,
never evaluated in, and the child cannot reach it.  Such a child runs
with `:read-only t :network nil`, whatever the session otherwise has,
and is refused (`harness-sandbox-unavailable`) where no sandbox can give
that: the copy is the user's data and must not meet an unconfined
process.

What the copy holds and what it leaves out is in lisp/harness-snapshot.el:

- every bound global variable, as plain data, and every live buffer that
  is not hidden — its mode, file, `default-directory`, point, text (up
  to 1 MB) and buffer-local values — beside `emacs-version`,
  `system-type` and the loaded features.  A value that is not data
  (a buffer, marker, window, process, function, obarray) becomes a
  readable placeholder, an oversize value a truncation marker, and a
  manifest at the end says what was left out or cut.
- credentials, by name: `harness-snapshot-withheld-regexp` (the
  auth-source caches, `plstore`, `epa-*`, the provider keys, anything
  named like a password or a token) for variables, and
  `harness-snapshot-withheld-buffers-regexp` (`.authinfo`, `.netrc`,
  `*.gpg`, `.pgpass`, `id_rsa`, a password store) for buffers.  A
  withheld variable or buffer is named in the manifest, never copied.  A
  credential-shaped key inside an alist, plist, hash table or struct is
  masked, and `process-environment` is copied entry by entry with such
  an entry's value withheld.

This is not a promise that the copy holds no secret: a name cannot tell
what a value is.  The copy goes to the model's provider like anything
else a tool returns, so the two regexps are the user's to extend.  Nor
is the copy the user's Emacs: a function is opaque data, so the code
cannot call one; hooks never run, no mode hook and no after-load
function; a window, marker, process or timer is only a description.
Nothing in the copy is written back.

## The typed tools: what the jail judges for each

The tools that are not a command take typed arguments, and a typed
argument can be checked: the permission jail (stage 10 of the
`permission/decide` chain) compares the paths a call names with the
session's directories, resolving links, and refuses or asks the user
about what lies outside.  For the file tools that comparison is the
early refusal and the prompt, and the worker is the boundary: where a
sandbox applies a call runs in a process that is shown only the session's
profile (below), so a path the comparison passed by mistake is not
there.  For the other tools in the table the declared paths are still the
boundary, so the question to ask of each is whether every place it
reaches is a path it declares.  This is what they do:

| Tool | What it reaches | Bounded by |
|---|---|---|
| `read_file`, `write_file`, `edit_file`, `file_info` | `path` | the worker's mounts (the jail refuses and asks first, links resolved) |
| `list_dir`, `grep` | `path` and below | the worker's mounts; below `path` links are not followed |
| `glob` | `path`, and a `pattern` matched below it | the worker's mounts; a pattern that is absolute outside `path`, begins with `~` or has a `..` segment is refused, and nothing behind a link out of `path` is listed |
| `bash`, `elisp` | what the sandbox shows | the kernel (above) |
| `elisp` with `snapshot` | a copy of the user's variables and buffers, in a child that can write nothing and reach no network | the kernel (`:read-only`, no network, refused without a sandbox) and the copy's construction: credentials withheld by name |
| `ssh` | another machine | that machine's own kernel and the grant of the host |
| `emacs_open` | one local file | the jail on the path; safe local variables only |
| `emacs_insert`, `emacs_save_buffer` | the file a buffer visits | `permission/path-writable-p`, checked again in the Emacs |
| `task_submit`, `spawn_agent` | a directory a new session works in | the jail on `cwd`; for a main-tree task, on the project's main checkout, which a worktree session does not hold |
| `redact_secret` | the file of a source | the jail on the file |
| `hand_in` | evidence files | the handler: inside the session's directories |
| `skill_load` | a skill's supporting file | the handler: inside the skill's directory, links resolved |
| `web_fetch` | an `http(s)` URL | the handler refuses other schemes |
| `session_move` | the session's directory | the user confirms every call |
| `task_control` | the worktree of a merged task | the board's own record, never a path from the call |
| `open_harness` (this repository's plugin) | runs a checkout's `scripts/dev.sh` and Elisp, outside the sandbox | the permission mode, as for `bash`; see below |

A call whose paths cannot be told does not pass for one with no paths:
when a tool's paths function fails, the call is refused before the chain
(`harness-tools--unjudgeable-refusal`).  Looking for the tools that were
missing from this table found three that reached places they did not
declare: `glob`'s pattern, `task_submit`'s directory, and the two Emacs
tools above.  Each is fixed and tested; "Checking it" below says how.

## The permission chain fails closed

A stage of the chain that signals an error, or returns a promise that is
rejected, refuses the call for good.  A chain of filters hands its value
on unchanged when one of its handlers fails, which is right for the ones
that only add; for this one it is not: the stages after the failed one,
the mode stage among them, then decide a call nobody checked.  When the
jail failed, that was a path no one compared with the session's
directories, allowed in yolo mode and, as a read, in every other.  Now
the denial reads "The permission check could not be completed
(harness-perms--jail failed: …)", names the stage in the decision, and
leaves the user able to approve that one call in the chat like any other
denial.  (`harness-set-filter-failure` is how a chain says what a failed
handler hands on; `harness-perms--stage-failed` is the permission
chain's.)  Several tests passed only because of the old behaviour: they
called the chain with a session it could not find.

## What is not covered yet

- **The copy of the user's Emacs.**  The `elisp` tool's `snapshot` input
  gives the model the values of the user's variables and the text of
  their buffers, with credentials withheld *by name*.  A variable whose
  name says nothing about its content is copied, and the copy goes to
  the model's provider.  The manifest names what was left out, so a
  copy can be checked, and the two withheld regexps can be extended by
  the user; a name is not a proof.
- **Where the file tools still run in the harness.**  The file tools run
  in the worker where a sandbox applies to the session.  They run in the
  harness process, behind the permission jail alone, for a path of another
  host (TRAMP), where the policy is `off` or `preferred` and no backend
  exists (the cases in which `bash` runs unconfined too), and with
  `harness-tools-fs-jail` off.  In those cases a path is compared once,
  when the call is decided, and used after, and a command running in the
  jail at the same time can change a link between the two.
  In the worker the same race can only reach what the worker is shown,
  which is the session's own directories.  What it is shown beyond them is
  decided by the permission module's own predicates, call by call: the
  harness's files, the skills directories and the files the user's Emacs
  showed a definition in (read-only; the credentials of the state directory
  are not among them), a directory the user allowed for that call alone,
  and the paths of a call the user approved after it was denied.  Those
  are narrow, and a path the jail passes by mistake is given no mount; they
  are the chain's decisions all the same, so they are as sound as its
  predicates.  The sandbox's own limits apply: the network is shared, and
  the process has its user's rights inside what it is shown.
- **`open_harness`**, the tool of this repository's own plugin, starts an
  Emacs from a checkout, running the checkout's `scripts/dev.sh` and the
  Elisp its daemon loads, as the user and outside the sandbox.  A task's
  worktree is the session's to write, so that is code the agent wrote,
  run without the kernel around it: the route that left the jail in the
  incident, in another place.  It was among the tools that need no
  approval (`harness-perms-extra-auto-allow-tools`), on the ground that it
  only starts an Emacs in a state directory of its own; it no longer is.
  It is an `exec` call decided by the mode as `bash` is, which asks in ask
  and accept-edits mode, has the judge weigh it in auto mode and for a user
  who is away, and allows it in yolo mode.  Running the instance in the
  sandbox is a project of its own: it is a GUI Emacs on the user's display,
  which a sandbox can limit in the files it touches but not in what it
  does to the other windows of an X11 display.  Plugins are the user's
  code (a project's `.dir-locals.el` loads one only once the user trusts
  it), and a tool a plugin adds reaches what the user's code reaches.
- **The Claude CLI's own tools.**  With
  `harness-provider-claude-native-tools` on (experimental, off by default)
  the CLI runs its own Bash, Read, Write, Edit, Glob and Grep in place of
  the harness's.  The permission chain still decides each call, but the
  tool is not run in the harness's sandbox; `harness-sandbox-policy`
  `required` keeps `bash` the harness's own.  Leave it off where the
  boundary matters.
- **Project settings files.**  A project's `.dir-locals.el` sets harness
  options for the sessions that work there: among them the directories
  they may reach, the sandbox policy and the permission mode
  (`lisp/modules/harness-config.el`).  The file lies in a directory those
  sessions write in, so what a session may do is partly written in a file
  it can write.  A file tool that writes one asks the user, in every mode;
  a shell command that names one and looks like it writes asks too, but
  that is a reading of the command's text, not a boundary (the access
  module says so).  This is a known limit, and it was not changed here,
  because the cure is a decision about how projects keep their settings:
  settings that widen a session kept out of files the session can write,
  or a settings file counted only as the user last saw it.  Until then,
  treat a `.dir-locals.el` that a session has changed as the session's
  own words, and review it before it merges.
- **Other sessions.**  A session may message and control others
  (`session_send`, `session_control`, `task_control`, `task_submit`), which
  then act under their own directories, not the sender's.  Those are
  `meta` calls: every mode but yolo asks about them or has the judge weigh
  them.
- **TRAMP paths** name another machine.  The sandbox does not reach
  there; the session's grant of the host and the ssh connection do.
  This is the same trust the harness had before and is not changed
  here.
- **The user's own Emacs** is outside the sandbox by design.  Its
  tools are typed and code-free, but the user's init file, their
  packages and their key bindings still run with their authority.
- **The harness's own code** runs in the harness process.  A session
  may read it (that is deliberate) and may not write it; the sandbox
  and the permission chain cover the tools that would.

## Checking it

`test/harness-containment-test.el` runs the real bwrap and skips where
it cannot start.  It checks that a `bash` command cannot read a file
outside the session's directories, that a Python script whose intent no
parser sees cannot either, that a directory outside survives both `rm
-rf` and a Python `shutil.rmtree`, that the `elisp` child sees no more
than `bash`, that no tool evaluates in the user's Emacs, and that the
Emacs's MCP server lists exactly the typed vocabulary and refuses
anything else.

It also drives the typed tools through the whole permission chain, with
a session in yolo mode, which the jail does not yield to: every file
tool refused a file outside, however it is named (absolute, with `..`,
through a link, in a pattern); the Emacs tools refused a buffer that
visits a file outside, directly or through a link; `task_submit`
refused a directory outside and a main-tree task from a worktree; and
each of them working inside, and outside once the user grants the
directory.  `test/harness-perms-test.el` checks that a failed stage
refuses the call in every mode, and `test/harness-core-test.el` the
rule that lets a chain say what a failure hands on.

`test/harness-mcp-fs-test.el` runs the file tools' worker under the real
bwrap, with the permission chain made to allow everything, so that nothing
but the kernel stands between a tool and a file outside the session's
directories.  It checks that no file tool reaches such a file, however it
is named, nor writes outside, nor changes it; that the same calls answer
alike in the worker and in the harness process (25 calls, each on a tree of
its own); where a call runs (the policy, the escape hatch, another host);
that a directory granted to the session is shown from then on; that the
extra mounts are exactly what the exemptions, a one-time grant and an
approved call call for, and that a credential, the neighbour of an
exempt file and a path nothing allowed are not shown; and that a long
output saved by the harness can be read back, an image copy is made where
the harness can read it, a written file is announced, and a worker that
dies or whose session is deleted is replaced or goes.

`test/harness-sandbox-test.el` covers the backends themselves: the
mounts, the read-only profile, the capabilities, and the registrations
of the worktrees a session does not show.  Its tests in a real bwrap
run git's worktree commands in the jail and look at what is left on
disk, so what they check is the kernel's refusal, not a message; the
module has no method left that reads a command line.
`test/harness-perms-test.el` checks that no stage of the chain reads a
command for the sandbox, and that a read-only cloud command is allowed
only where the sandbox confines it.
