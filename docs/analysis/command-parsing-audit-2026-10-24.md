# Where the harness reads a shell command line, and what each reading decides (2026-10-24)

**Question.** The sandbox used to refuse `git worktree prune` and its kin by
reading the command's text (`sandbox/check-command`, asked by a stage of the
permission chain).  A reading of text is not a boundary
([the trust model](../trust-model.md)): it cannot know what a program does with
what it is given.  So every place under `lisp/` that reads a shell command line
was looked at, to say for each what it decides, whether that is a *gate* or only
*user experience*, and what was changed.

**Answer.** Two readings were gates in effect, and both are deleted: the
sandbox's parser and the permission stage that asked it.  What they guarded, the
registrations of the worktrees a sandbox does not show, is now kept by mounts
(`harness-sandbox--hidden-registrations`): the kernel refuses the write, whatever
the command says.  One more reading was a gate and is now limited: the allow of
a read-only cloud query, which needs a command the sandbox confines.  Everything
else is user experience (it asks, words a prompt, offers or matches a rule the
user chose, or refuses what the sandbox would not show anyway) and was left as it
was.

## What counts as a gate

A **gate** is a reading whose miss lets a call do what nothing else stops and
the user did not choose: an *allow* the reading alone produced, or a *refusal*
that was the only thing between a process and something it can reach.  Reading
a command can never be a sound gate, since a program's behaviour is not in its
command line.

**User experience** is a reading that asks, words a prompt, orders the options
of an answer, shows a title, or applies a rule the user wrote or chose; or one
that refuses what the sandbox would refuse or fail on anyway, to say so before
a process starts.  A miss costs a question asked or not asked, never a path
reached.

## The readers

The shell reader itself is in `lisp/modules/harness-perms.el`
(`harness-perms--shell-tokenize`, `harness-perms--shell-ast` and the functions
that walk its tree).  It is, by its own commentary, "never a security boundary".
Nothing else under `lisp/` has a reader of the shell grammar.

| # | File: function | Reads | Decides | Gate or UX | What changed |
| ---: | :--- | :--- | :--- | :--- | :--- |
| 1 | `harness-sandbox.el`: the worktree-command parser and `sandbox/check-command` | the words `git worktree prune`, `remove`, `move`, `lock`, `unlock` in a command | refused such a command, with a hint | **Gate in effect**: it was all that stood between a sandboxed command and the registrations of the other worktrees | **Deleted**, with its constants, its refusal text and `harness-sandbox-worktree-hint`.  The registrations are mounted read-only instead |
| 2 | `harness-perms.el`: `harness-perms--sandbox-guard` (stage 7) | asked row 1 about every `bash` call | a final deny in every mode, yolo and standing rules included | **Gate in effect** | **Deleted**, with its registration, its row in the stage table, its entry in the module's shutdown and `:doc` |
| 3 | `harness-perms.el`: `harness-perms--mode-decision`, through `harness-perms--read-only-cloud-p`, `--cloud-group-p`, `--cloud-parts`, `--shell-command-starts-at-program-p` | every command of the line from the syntax tree: a cloud CLI (`gcloud`, `gsutil`), no write word, a read verb early | allows the call without the judge, in auto mode and when the user is away | **Gate** (an allow made by a reading alone) | **Limited**: it allows only a command the sandbox confines (`harness-perms--confined-p`, which asks `sandbox/confined-p` for the directory the command runs in).  An unconfined command goes on to the judge, or the user |
| 4 | `harness-perms.el`: `harness-perms--rule-matches-p`, through `harness-perms--command-rule-matches-p`, `--rule-command-patterns`, `--request-shell-commands`, and for `:path` rules `--subject-paths`, `--every-path` | the commands and the paths a line names | whether a standing rule applies: an allow rule needs every command and every outside path covered, a deny rule any one; a line the reader cannot read matches no `:commands` rule | **UX**: the rule is the user's own decision about which calls to stop asking about.  Where the command is confined, the sandbox bounds what any matched allow can do; where it is not, the reading is best effort and the trust model says so | **Unchanged on purpose**: a rule means what its user wrote |
| 5 | `harness-perms.el`: `harness-perms--command-groups`, `--command-rule-prefixes`, `--command-common-prefix`, `--shell-covers`, `--cover-ladder`, used by `harness-perms--ask` | the programs and subcommands a line runs | the covers a prompt offers a lasting answer, and which is the usual one; the `:commands` and `:covers` the prompt shows | **UX**: the user picks the cover, and what is recorded is a rule of row 4 | Unchanged |
| 6 | `harness-perms.el`: `harness-perms--command-paths`, `--named-paths`, `--with-reach`, used by `harness-perms--ask` | the words that are paths | what a prompt says the call is about (`:paths`) | **UX** | Unchanged |
| 7 | `harness-perms.el`: `harness-perms--skills-refusal`, from the jail stage | the paths a *confined* command names | a final deny, with the way to use `skill_search` and `skill_load`, for a path in a skills directory the sandbox does not show | **UX**: a refusal of what would fail inside the sandbox anyway; a miss leaves the command confined | Unchanged (it was already limited to confined commands) |
| 8 | `harness-perms.el`: `harness-perms--judge-text`, `--judge-input`, `--judge-system` (the auto-mode judge) | the call's input as JSON text, read whole by a model | allow or deny in auto mode and when the user is away; a denial is put to a user who is present | A model's opinion, not a parser, and not a boundary: it is the policy the user chose by choosing auto mode or leaving.  It answers only what nothing else decided | Unchanged.  Its prompt mentions no worktree command |
| 9 | `harness-perms.el`: `harness-perms--with-summary`, `--summary-text`, `harness-perms-describe-request` | the call's input, read by a cheap model, and its first line | a sentence and a title beside a prompt | **UX**: "never read by anything that decides a call" | Unchanged |
| 10 | `harness-access.el`: `harness-access--settings-target`, `harness-access--writes-settings-regexp`, in `harness-access--gate` (stage 4) | a regexp over the text: a command that names `.dir-locals.el` and looks like writing it | has the user confirm, in every mode; it never allows | **UX**: it only asks.  A miss leaves the call to the stages after it.  The file lies in a directory the session writes, so the sandbox lets a confined command write it either way: the known limit under "What is not covered yet" in the trust model | Unchanged |
| 11 | `harness-tools-shell.el`: the `bash` tool's `:subject`; `harness-tools-ssh.el`: `harness-tools-ssh--subject`; `harness-tools-handin.el`: `harness-tools-handin--snippet`; `harness-linking.el`: `harness-linking--call-title` | the first line of the command | a title, a subject, a snippet in a list of calls | **UX** (display) | Unchanged |
| 12 | `harness-provider-demo.el`: `harness-provider-demo--summary` | `rm`, `pip install`, `curl`, `sudo`, test runners in the command | a canned sentence, for the demo provider that stands in for a model | **UX**; it decides nothing in a real session | Unchanged |

### Not readers

These carry a command through and read none of its syntax:

- `harness-tools-shell--bash` and `harness-tools-ssh--run` check that the
  command is not blank and give it whole to `bash -c`, or to the remote shell.
  Neither decides anything from it.
- `harness-provider-claude--tool-input` renames the Claude CLI's `Bash` input
  to the `bash` tool's.
- The supervisor module's stage 8, the readonly module, the tasks module's
  read-only turns and the MCP host decide for `bash` or for a server by
  `sandbox/confined-p` and by the sandbox's `:read-only` profile, never by what
  a command says.
- `harness-secrets.el` and `harness-redaction.el` run a `:command` reference
  (a command the user configured to print a secret) with a timeout; it is not
  an agent's command.
- `harness-pet.el`'s `harness-pet--command-tool-regexp` matches tool *names*.
  `harness-tasks-search.el` and `harness-ui-quick-search.el` list Emacs
  commands.  `harness-mcp.el` starts a server from an argument list a function
  returns.

## The three changes

**The worktree registry, by mounts** (rows 1 and 2).  Git in the sandbox sees
only the session's own worktree, so it takes every other worktree for deleted,
and the prune command drops its registration from the common git directory,
which the session may write.  The sandbox now lists the registrations
(`GIT/worktrees/NAME`, each with a `gitdir` file naming the worktree), keeps
those of worktrees it shows (those in the working directory or in a directory
mounted writable) and the session's own, and mounts every other read-only over
the writable git directory: `--ro-bind` in bubblewrap, `BindReadOnlyPaths=` in
`systemd-run`, a read-only path in MXC's configuration.  A registration whose
`gitdir` file cannot be read counts as not shown.  `docs/architecture.md`
(sandbox section) has the details and the limits.

**The cloud allow, by confinement** (row 3).  A reading decides the *allow*, so
the allow now needs the kernel's bound behind it: `harness-perms--confined-p`.
Without a backend (or with the policy off, or in a directory the sandbox cannot
cover) the same command goes to the judge in auto mode and to the user in the
modes that ask, as every other shell command does.

**The standing rules and the judge, left alone** (rows 4 and 8).  The task was
to leave what a user's explicit standing rule means unchanged, and a rule is the
user's own decision, so rows 4 and 5 keep their meaning.  They are listed as UX
because the user chose them, and because where commands are confined the
sandbox bounds what a rule can let through.  Where commands are not confined,
the rule and the judge are what stands, as
[the trust model](../trust-model.md) says of the unconfined case; the policy
`required` keeps commands from running there.

## What a new reader of a command line may do

1. Ask, refuse with a hint, or word a prompt.  A miss then costs a question.
2. Allow only a command `sandbox/confined-p` says is confined, or only because
   the user wrote the rule.
3. Never be the only thing between a process and a path.  What a process can
   reach is decided by the mounts.

## Checked by

- `harness-perms-no-stage-reads-a-command-for-the-sandbox`: the sandbox guard
  and its filter are gone, the chain asks no `sandbox/check-command` (the test
  registers one that would refuse) and decides the worktree commands as it
  decides any other.  `harness-perms-describe-and-reload` checks the stage table
  has no stage 7.
- `harness-perms-read-only-cloud-allow-needs-a-confined-command` and
  `harness-perms-read-only-cloud-commands-need-no-judge`: the allow with and
  without confinement.
- `harness-sandbox-has-no-reading-of-command-lines`: no `sandbox/check-command`
  and no hint variable.
- `harness-sandbox-bwrap-real-worktree-commands-change-nothing` and its
  neighbours (`...-real-prune-drops-only-what-is-really-gone`,
  `...-real-granted-repository-keeps-its-registrations`): a real bubblewrap runs
  git's worktree commands and the test looks at the registrations left on disk.
  They check what the kernel refused, not what a command said.
