# Secret files in a locked sandbox

A secret should be usable by a command without its value ever reaching the
agent.  The harness already keeps secret values out of what it stores
(`lisp/modules/harness-secrets.el` and `lisp/harness-redaction.el`) and
keeps credential directories such as `~/.aws` and `~/.npmrc` out of the
jail's reach (`lisp/modules/harness-sandbox.el`).  This feature adds the
other half: a way for a command that needs a secret to run somewhere it
can read the secret, while the agent's own commands and file tools still
cannot -- and while nothing the command prints comes back to the agent.

It is implemented as an opt-in module of the harness, `secret-sandbox`:
`lisp/modules/harness-secret-sandbox.el`, with its tests in
`test/harness-secret-sandbox-test.el`.  It is loaded like any other
module (`harness-enable-modules`, or `M-x harness-enable-module
secret-sandbox` for the running harness) and is off by default: a
harness without it offers no `run_with_secret`, no `list_secrets` and no
stage that refuses a file.  It requires `secrets`, `sandbox`, `perms`
and `session`, so enabling it brings the masking, the jail and the
prompt machinery it stands on.

Two decisions shape the page.  **Marking is declaring.**  The harness's
one list of secrets, `harness-secrets-sources`, already says where each
value is read and what it is called; being in that list is the whole
declaration, and from then on the only way to use the value is a command
in the locked sandbox.  The module adds no key, no second option and no
per-secret settings.  And **a locked command's output is not returned at
all**: masking cannot follow every transformation of a value, so the
agent gets one fixed sentence instead.  See "What marking is", "One
list, no second declaration" and "Why the output is not returned".

## What marking is

**Marking is declaring a secret.**  A secret is a reference in
`harness-secrets-sources`, or one added with `secrets/add-source`: a
file with a JSON path or a regexp, a command, an environment variable or
a literal, with an optional `:label`.  That is the entry the harness
already had; this module does not add a key to it, does not read a
second list and does not need anything said twice:

```elisp
(setq harness-secrets-sources
      '((:file "~/.config/gh/hosts.yml"
         :json-path "github.com.oauth_token"
         :label "github-token")
        (:file "~/.ssh/id_deploy"
         :regexp "\\(.+\\)"
         :label "deploy-key")
        (:command "pass show internal/api"
         :label "internal-api")))
```

With the module on, a declared secret is *marked*, and every part of
that follows from the declaration alone:

- the file tools cannot read its source: a `permission/decide` stage
  refuses, finally and in every mode, a read or a write whose paths
  touch the source (`list_dir`, `glob` and `file_info` may still say it
  exists);
- every `bash` and `elisp` command has the source hidden, so a directory
  that shows the file does not show it;
- the value is masked wherever it appears, by the same registry and the
  same filters as any other secret -- there is no second masking path;
- the only way to use the value is `run_with_secret`, one command in the
  locked sandbox after the user has approved that exact call;
- the command's output, exit status and duration are withheld from the
  agent (see "Why the output is not returned").

Marking does not put the value anywhere: the entry holds where to read
it, never the value itself.  What a run *cannot* use is a value the
agent can already read for itself: an environment variable of the
harness, which every process the harness starts inherits, or a literal
in the user's init file, which is a variable the agent can inspect.
Those are still masked like any other secret; `list_secrets` lists them
as unavailable with the reason and never offers them for a run.

## In short

| Question | Decision |
|---|---|
| How is a secret marked? | By declaring it, in the harness's one list of secrets.  The module adds no key, no second option and no per-secret settings: if it is a secret, the only way to use its value is the locked sandbox. |
| How does a command ask for it? | A tool of its own, `run_with_secret`, not an annotation on `bash`.  `list_secrets` names the secrets a run can use, by the label the secrets module already masks each value under; it shows no value, path or fingerprint. |
| What does the command see? | The system runtime its backend gives every sandbox, the session's worktree read-only, and one per-call file holding the named value.  No home, no state directory, no session temporary directory, no granted directory, no other secret, no capability. |
| What may it write? | Only the sandbox's private temporary directory, which is deleted when the command ends.  Nothing in the worktree; no file is returned. |
| What network may it reach? | None.  There is no setting that opens it. |
| Must the user approve? | Yes, in every mode including yolo and auto.  The auto-mode judge never decides it, a standing allow rule never bypasses it, and a non-interactive session is refused.  Each approval is for that one call; nothing is remembered. |
| What comes back? | One fixed sentence: the command ran, its output, exit status and duration are not returned.  The same sentence whether it succeeded, failed or timed out.  It is the `secret-sandbox-withheld` prompt, so a model can be sent its own wording. |
| What is the residual risk? | The agent can time the run with its own clock, and it can ask for a command whose actions the user approves.  Neither returns the value.  The user's own Emacs, the harness's memory and a modified harness are outside. |

## What exists today

**Secrets and masking.**  `harness-secrets.el` holds a registry of
values, named by where they can be read: a JSON path or regexp in a
file, an environment variable of the harness, a command's output, or a
literal typed in the user's init file.  `harness-redaction.el` reads
them, finds them in text and replaces them with a placeholder that says
the label and the first 8 hex digits of the value's SHA-256
\(`[redacted: LABEL sha256:...]`).  The masks sit in the `tools/output`
and `tools/output-text` filters, in the log, and in a
`permission/decide` stage that refuses to write a placeholder into a
file.  A result masking cannot check is withheld rather than let
through.  Values shorter than `harness-redaction-min-length` (8
characters) are not masked.

**The jail.**  `harness-sandbox.el` wraps every command the `bash` and
`elisp` tools run: read-only `/usr`, `/etc`, `/lib`, `/bin`, `/sbin`, a
fresh `/proc`, `/dev` and `/tmp`, the session's working directory
read-write, and the session's temporary directory and granted
directories as the bash tool asks.  The home directory is hidden, so
`~/.aws`, `~/.npmrc` and the like stay out of reach.  The per-call
options are `:network`, `:writable`, `:readable`, `:read-only`,
`:scratch` and `:capabilities`; `sandbox/wrap` also takes `:profile`,
`:env` and `:hide`, and `sandbox/profiles` says what the backend in
force can give.  `tools/sandbox-options` lets a module add options to
every bash and elisp command.

**Permissions.**  Every tool call passes the `permission/decide` chain
\(`lisp/modules/harness-perms.el`).  A stage can own a tool's decision,
as the directory request and the request to turn non-interactive mode
on do: it puts a `:user-only` prompt to the user and owns the call's
decision.  The module uses the same mechanism, through
`harness-perms-confirm`: a prompt only the user may answer, with
allow-once and deny-once, which yolo does not answer and which records
no rule.  Other stages can refuse a call outright; a standing deny in
`harness-perms-rules` still denies.

**The gap this fills.**  A command that has to use a secret could not
run anywhere: the agent's commands could not read the file, and the
bash tool had no way to ask for a profile that could.  The value could
not be put in the command line (it would be in the transcript and in
`ps`), and putting it in the harness's environment would show it to
every process the harness starts.

## Marking a secret

### The entry

An entry is the one the secrets module documents: a source, and an
optional `:label`.

```elisp
(:file "~/.config/gh/hosts.yml" :json-path "github.com.oauth_token" :label "github-token")
(:file "~/.ssh/id_deploy"       :regexp "\\(.+\\)"                :label "deploy-key")
(:command "pass show internal/api"                                :label "internal-api")
```

The label the agent asks for is the label the secrets module masks the
value under, and there is no second name to keep in step:

- with a `:label`, that is the label -- and, when the path or regexp
  selects several values, each keeps it with the path below the
  selection appended (`github-token.client_secret`);
- without one, a JSON path names the value by its path, a regexp by the
  file's name, an environment variable by the variable, a literal by
  `secret`, and a command's output by `command output`;
- two values with the same label cannot be told apart, so a run refuses
  both and asks for distinct `:label`s.  That is the one thing an entry
  may need for a run that it did not need for masking.

`list_secrets` lists one line per value, and a run names one of them.

### What a run can use

| Source | A locked run |
|---|---|
| `:file` with `:json-path` or `:regexp` | Yes.  The source file is not mounted; the one value is written to the run's own file. |
| `:command` | Yes.  The secrets module runs it when it reads the registry, and the run uses the value it resolved. |
| `:env NAME` | No.  Every process the harness starts inherits the variable, so the agent can read it with its own commands.  The reason says so. |
| `:literal STRING` | No.  The value is in `harness-secrets-sources`, a variable the agent can inspect.  The reason says so. |
| A file in the state directory | No.  The agent's own file tools can read that tree. |
| A file in a session's working or temporary directory | No, at run time.  The agent could have read it before the secret existed. |

Refusals are per value, not per list: a list with a `:command` and an
`:env` entry gives the command's value a run and lists the variable with
its reason.  None of them stops the masking.

### One value per run

A run gets exactly one value, in one file.  A JSON path that selects an
object or several strings becomes several labels, one per value, so a
file holding a token and a client secret gives the agent two labels and
no way to ask for "both".  A regexp with several matches does the same.
A source that is not there, holds nothing, or whose value is shorter
than `harness-redaction-min-length` resolves to no label at all: the
secrets module logs and shows its error, and `run_with_secret` has
nothing to run.

### One list, no second declaration

A secret is declared once: in `harness-secrets-sources`, or with
`secrets/add-source`.  That entry is both what masking reads and what a
locked run uses, so there is no "usable in the sandbox" key to add and
no settings on the entry.  Nothing has to be kept in step:

- the value is read, cached and masked by the one registry;
- the label the agent asks for is the label of the placeholder;
- the source description, the fingerprint and the error are the ones
  `secrets/sources` already reports;
- `list_secrets` is a view of the registry, not a second store;
- a run takes the value the registry already resolved
  (`harness-secrets--registry`), so a file is read once and a command
  source is run once for both uses;
- `secrets/add-source` needs no change: a source it adds is a secret
  like the ones in the option, and it becomes usable in a locked run
  once it resolves.

### Keeping the agent out

Two layers, both independent of what a command prints:

- A `permission/decide` stage at **priority 2**, before the jail, the
  mode and the judge, refuses any read or write whose `:paths` touch a
  secret's source, as named and with symbolic links followed.  The
  refusal is final and `:final t`: no approval can open it, because the
  only way to use the value is `run_with_secret`.  `list_dir`, `glob`
  and `file_info` are exempt: they may say the file exists, its size
  and its mode, but not what is in it.
- A `tools/sandbox-options` handler gives every `bash` and `elisp`
  command `:hide` with every source and every live secret directory.
  Under bwrap a hidden file is bound to `/dev/null` and a hidden
  directory covered by a tmpfs, after every other mount; systemd-run
  uses `InaccessiblePaths=`; MXC refuses when a hidden path lies under
  a directory it shows.  A command that tries to read a hidden file
  gets "Permission denied", not the contents.

Neither layer is a proof.  A backend that cannot confine commands at
all, or a source it cannot hide, leaves the file gate and the result
withholding as the guards; `secret-sandbox/status` says which backend
is in force.  The value in the harness's memory, its swap and a
debugger attached to the harness are outside either layer.

### The value and masking

Because the value is in `harness-secrets-sources`, it is masked by
`harness-secrets` exactly as it was before the module was enabled: in
tool results, notes, provider output, the log, and any other route the
module already covers.  The module adds nothing to the mask.  In
particular it does **not** add base64, hex, percent-encoded or
shell-quoted spellings of the value.  Those spellings are not a
boundary: a second base64, a cipher, a hash or a length defeats them,
and a list of spellings cannot be complete.  See "Why the output is not
returned".

The ordinary mask is still worth having: it keeps the value itself out
of what a command or a tool prints elsewhere, and out of what is
stored.  It is defence in depth for the value, not the thing that makes
a locked run safe.

## Asking for a locked run

### The tool

```
run_with_secret(secret: string, command: string, timeout?: integer)
```

- `secret` is a label from `list_secrets`.  An unknown label is an
  error whose hint lists the labels; it never falls back to another
  secret.
- `command` is one shell command line, run by `bash -c` in the session's
  working directory.  The directory is mounted read-only; a command
  that needs to write uses the private temporary directory (`$TMPDIR`).
- `timeout` defaults to 120 seconds and is capped at 600, whatever the
  call asks.  The whole process group is killed on timeout.
- The handler writes the value to the per-call file, asks
  `sandbox/wrap` for the locked profile, runs the command, and returns
  **one fixed sentence**.  Nothing the command printed, no exit status
  and no duration is part of the result, whether it succeeded, failed
  or timed out.

The fixed sentence is:

> The command ran in the locked sandbox.  Its output, exit status and
> duration are not returned to you.

A failure to *start* -- an unknown label, a value a locked run cannot
use, a source the session could already read, no backend that can give
the locked profile, masking turned off -- is an error before the command
runs, and its message names the reason.  Those errors say nothing about
the value.

### The file the command gets

A locked run does not mount the source file.  The harness reads the one
value and writes it to a fresh directory made for the call, mode 0700,
holding one file, mode 0600, named `secret`.  That directory is the only
secret thing the sandbox shows; the source file is not mounted at all,
so a JSON file with other keys does not hand them to the command.  The
directory is created under the system temporary directory -- never in
the worktree, the state directory or the session's temporary directory
-- bound read-only at its own path, and deleted when the command ends,
times out or fails.  The path is random; while the call runs every
other command hides it, and the file tools refuse any path that touches
it.

The command finds the value at:

- `$HARNESS_SECRET_FILE`: the file, read-only, holding the value as
  UTF-8 without a newline added.
- `$HARNESS_SECRET_LABEL`: the label.

There is no variable named after the secret's own name: the value is
never put in the host's environment, on a command line or in `ps`.

### What a run is for

Use it for what the command does, not to learn anything it prints.  A
deploy, a push, a request that needs the credential: the agent can
cause it, the user approves it, and the result says only that it ran.
A command that prints the value cannot pass it back, because nothing it
prints is returned.

If the user needs the output, they run the command themselves.  That is
the trade that makes the guarantee structural; the alternative --
returning output and hoping to mask every transformation -- is the one
this design rejects.

## The locked sandbox

### The interface

`lisp/modules/harness-sandbox.el` has per-call options and profiles:

- `sandbox/wrap` takes `:profile`, `default` (today's behaviour) or
  `locked`.  A backend implements the profile or signals
  `harness-sandbox-unavailable`; an unsupported profile is never
  silently downgraded to `default`.
- `sandbox/profiles` returns what the backend in force enforces:
  `(:backend BACKEND :profiles (default locked) :hide t :why TEXT)`.
  A caller can ask before it prompts the user.  `:why` says what stands
  in the way when `locked` is missing.
- `:env` (an alist) is the locked profile's whole environment: `PATH`,
  `HOME` (the sandbox's `/tmp`), `TMPDIR`, `HARNESS_SANDBOX`, `LANG`,
  `TERM`, and whatever the caller adds, including
  `HARNESS_SECRET_FILE` and `HARNESS_SECRET_LABEL`.  The harness's own
  environment is never passed on; bwrap clears it with `--clearenv`.
- `:hide` hides paths a backend would otherwise show.
- A locked command is `:read-only` by construction: the worktree and
  every other path are read-only, only the private temporary directory
  is writable, no `:writable` entry is accepted and no capability is
  given.  A caller's `:scratch` is not used.
- A locked command has no network.  There is no option to open one:
  the module does not declare hosts, and no backend in the harness can
  limit a command to a host list, so there is nothing to ask for.

The profile is enforced by the backend, not by the new module alone: a
locked run whose backend cannot give it does not run, whatever
`harness-sandbox-policy` says.  Like the existing `:read-only` option,
it fails closed for `off`, no backend and a remote directory.

The OpenShell backend (t-6jc6w85v, session 16d2b2bd) was asked about
this interface on 2026-11-04 and answered that the shape fits: a sandbox
sees host paths only as bind mounts, its network policy is
deny-by-default with per-sandbox host and port rules (optionally per
binary), and it creates one sandbox per command.  Its answer also asked
for the `sandbox/profiles` method and for `wrap` to signal on an
unsupported profile, both of which are here.  The backend is in the
harness now, but this change does not implement the locked profile
there: `sandbox/profiles` says so, and a locked run refuses rather than
fall back to a wider view.  Its network policy could carry a host
allowlist later, as no other backend can; nothing in this change asks
for one.

### What a locked command sees

| | |
|---|---|
| Read | The backend's own system runtime (`/usr`, `/etc`, `/lib`, `/bin`, `/sbin`, `/proc` and `/dev` under bwrap; the image's userland under OpenShell; MXC's baseline on macOS), the session's working directory read-only, and the one per-call secret directory read-only. |
| Write | The sandbox's private temporary directory only.  The worktree, the home directory, the state directory, the session's temporary directory and every granted directory are read-only or absent. |
| Network | None. |
| Capabilities | None.  `:capabilities` is refused, not passed on. |
| Environment | The minimal list above.  The harness's environment, with its other credentials, is not visible. |
| Lifetime | One process group, killed at the timeout or on cancellation; the secret directory is deleted; the private temporary directory goes with the sandbox. |

Why the worktree is readable: a tool that uses a secret usually needs
the project around it (`package.json`, a config file, a lock file).
Reading it adds no exposure the agent does not already have.  Writing it
would let a command leave a derived value -- a token in a build artifact,
say -- where the agent could read it later; so the worktree is read-only,
and the command's only writable place is the private temporary
directory, which nothing reads after the command ends.

### Backends

| Backend | Locked profile | Why |
|---|---|---|
| bwrap | Yes | The namespaces give the minimal read set, the private `/tmp` and `--unshare-net`; `:hide` binds a file to `/dev/null` or covers a directory with a tmpfs after every other mount. |
| systemd-run | No | Its `ProtectSystem=strict` shows the whole root read-only; hiding all but a few paths means building an allowlist out of `InaccessiblePaths=` and binds, which is a separate piece of work.  It signals for `:profile 'locked` rather than run with a wider view. |
| MXC (macOS) | Yes | Seatbelt is already an allowlist; the backend denies the network for a locked command and refuses when a hidden path lies under a directory it shows.  Its builder is tested on the config it makes; a real MXC run is tested only on macOS. |
| OpenShell | No | Its sandbox would fit (bind mounts, a deny-by-default network), but this change does not implement the profile for it; it signals for `:profile 'locked` rather than run with a wider view. |
| none / `off` / remote | No | A locked run fails closed.  A remote working directory would need the same sandbox on the other host; this design does not pretend the local jail reaches it. |

The backend matrix is what `sandbox/profiles` reports, so the module can
refuse before it prompts, with a reason naming what would work.

## Why the output is not returned

A locked run returns no output.  Masking one could not be made complete:
a command can print the value as base64 of base64, enciphered, hashed,
one character per line, a length, a hash or an exit status, and no list
of spellings covers every transformation.  A command line cannot be
inspected either: `python script.py` can print the value and looks like
nothing.  So the module attempts neither: a locked run's stdout, stderr,
exit status and duration are dropped before the result is made.

The agent gets one fixed sentence, the same whether the command printed
the value, printed a hash of it, failed with status 1 or was killed at
its timeout.  It is the prompt `secret-sandbox-withheld` in the prompt
library (`docs/prompts.md`), so a model may be sent a wording of its own
through `harness-prompt-overrides`; its default is
`harness-secret-sandbox--withheld-default`.  There is no channel in the
result for a transformation to travel through, so the number of
transformations does not matter:

```sh
cat "$HARNESS_SECRET_FILE"                     # nothing comes back
cat "$HARNESS_SECRET_FILE" | base64             # nothing comes back
cat "$HARNESS_SECRET_FILE" | base64 | base64    # nothing comes back
cat "$HARNESS_SECRET_FILE" | openssl enc -aes-256-cbc -k key   # nothing
cat "$HARNESS_SECRET_FILE" | wc -c              # nothing comes back
cat "$HARNESS_SECRET_FILE" | sha256sum          # nothing comes back
python script.py                                # nothing comes back
```

The tests run the first six under a real bwrap and assert that every
result is the same fixed sentence with the same `:meta`: no value, no
base64, no length, no hash, no exit status, no duration.

**Then what is the boundary?**  Four structural controls, none of which
depends on reading the command's output:

1. **The user approves the exact command, once**, in every mode.  The
   approval is for what the command does, not for what it prints,
   because it prints nothing the agent sees.
2. **The network is off.**  A command cannot send the value anywhere.
3. **The worktree is read-only and the private temporary directory is
   deleted.**  A command cannot leave a derived value where the agent
   can read it later.
4. **The source is hidden from every other command and denied to the
   file tools.**  The agent's own `cat` cannot read it, and neither can
   a command that tries a path it knows.

**What remains.**  The agent can time the run: it can read the clock
with its own commands before and after, and a command whose duration
depends on the value is a timing channel.  The result carries no
duration, and every run is approved, but the clock is outside this
module.  It can also ask for a command whose side effects the user
approves, and it can learn whatever the user chooses to tell it.  These
are the honest limits of running a command rather than reading a value.

## The prompt

The module adds a `permission/decide` stage at priority 21, after the
mode and the user's standing rules (20) and before the auto-mode judge
\(30).  For every other tool it passes the decision on.  For
`run_with_secret` it uses `harness-perms-confirm`, which means:

- A standing *deny* rule at 20, and a supervisor's denial at 8, still
  deny.  A standing allow rule at 20 does not bypass the prompt: the
  call still waits for the user.
- In `ask`, `accept-edits`, `auto` and `yolo` alike, the stage puts a
  `:user-only` prompt to the user.  The mode's allow (yolo) and the
  judge never decide it; the judge does not see the call at all.  A
  switch to yolo does not answer the prompt.
- In a non-interactive session there is nobody to answer: the call is
  denied final, with a hint that the user is away and that a secret is
  involved.
- The prompt shows the exact command, the label, the source description
  and the fingerprint, and the working directory.  It says that the
  network is off and that the output, exit status and duration will be
  withheld.

Before the prompt the stage refuses a run the module cannot make:
masking off, a backend without the locked profile, an unknown label, a
value no locked run can use, or a source inside the session's own
directories.  Those refusals are final and say what is missing; the
user is not asked to approve a run that cannot work.

### In the access view

The Secrets group of the jail details page is stage 5.  It will list
each secret with its label, fingerprint, source description, last use
and an error, with no values and no reveal action.
`secret-sandbox/secrets` is the method behind it; the prompts stay in
the chat, and this change does not edit
`lisp/ui/harness-ui-access.el`.

## Tests

`test/harness-secret-sandbox-test.el` covers:

| What | Test |
|---|---|
| Declaring a secret is the whole marking: the entry is untouched, the value is masked under its label, and the tool offers it. | `harness-secret-sandbox-marks-a-secret-in-the-one-list` |
| A value no run can use is listed with the reason and never offered; the reasons name no value. | `lists-only-labels-it-can-use` |
| Two values with one label cannot be asked for. | `a-label-names-one-secret` |
| A source that cannot be read has no label to ask for. | `a-source-that-cannot-be-read-has-no-label` |
| A state-directory source is refused when listed, and at run time when the state directory changed. | `refuses-a-source-in-the-state-directory` |
| Every output is withheld: the value, base64, base64 of base64, hex, `wc -c`, `sha256sum`, an exit status and a timeout give the same sentence and the same `:meta`. | `withholds-every-output` |
| The sentence is the registry's prompt, and a model's override of it is what that model gets. | `the-result-is-a-registered-prompt` |
| No encoded-spelling machinery, no second option and no declaration state of the module's own exist. | `nothing-transformed-is-masked` |
| The file tools are refused, finally; the listing tools may name the file. | `file-tools-cannot-read-a-source` |
| Every command hides the sources and the live directory. | `every-command-hides-the-sources` |
| Every use prompts, even in yolo, with allow-once and deny-once and no remembered answer. | `the-user-approves-every-use` |
| A standing rule cannot open a secret. | `a-standing-rule-cannot-open-a-secret` |
| Non-interactive, masking off, no backend and an unknown label deny without a prompt. | `nobody-can-answer-is-a-denial` |
| The run method refuses what it cannot use. | `run-refuses-what-it-cannot-use` |
| The tool runs through the prompt and `list_secrets` shows no path or value. | `the-tool-runs-through-the-prompt` |
| The locked profile is asked for: `--clearenv`, `--unshare-net`, no capability, the hidden source, the 0700/0600 secret file. | `locked-profile-is-asked-for` |
| The hide layer works under real bwrap (with a control run that reads the value without it). | `a-shell-command-cannot-read-a-source` |
| The module is off by default. | `is-off-by-default` |

`test/harness-sandbox-test.el` adds the profile tests:
`sandbox/profiles` per backend, the bwrap arguments of the locked
profile, the locked profile failing closed, and the MXC builder's
refusal to hide a path it shows.  A real MXC run is tested only on
macOS.

## What is built, and what is not

| Stage | What it does | State |
|---|---|---|
| 1. Denying the agent | The priority-2 file-tool deny, the `tools/sandbox-options` `:hide` handler, `secret-sandbox/secrets` and `secret-sandbox/status`, `list_secrets`. | Done. |
| 2. The locked profile | `sandbox/wrap`'s `:profile`, `:env` and `:hide`; `sandbox/profiles`; bwrap implements `locked`; MXC implements it; systemd-run signals; the module makes the per-call directory and runs through `secret-sandbox/run`. | Done. |
| 3. Output withheld | stdout, stderr, the exit status and the duration are dropped; the result is one fixed sentence; a masking failure cannot leak because there is no output to mask; the run refuses when masking is off, since the value's other routes still need it. | Done. |
| 4. The request tool and the prompt | `run_with_secret` with its schema, description, subject and handler; the priority-21 stage through `harness-perms-confirm`, allow-once/deny-once, the non-interactive denial, the backend and source pre-checks. | Done. |
| 5. The access view | The Secrets group in the jail details page: label, fingerprint, source, last use, an error. | Not done.  It waits for t-tizx77bw; `secret-sandbox/secrets` returns the data, and this change does not edit `lisp/ui/harness-ui-access.el`. |
| 6. Tests, docs and the whole check | The tests above, the module page, the README link, this page. | Done. |

Order mattered and still does: masking before the tool, and the profile
before either.  A version that shipped the tool first would have had a
window in which a model could use a secret before the file deny existed;
one that shipped a profile without the deny would have had a window in
which the source is readable by the file tools.

## Related work

- **t-6jc6w85v, "Add NVIDIA OpenShell jail sandbox support"** (session
  16d2b2bd).  It adds a backend whose sandbox is a container with
  deny-by-default network policies and host-only bind mounts, and it is
  in the harness.  The `sandbox/profiles` and `:profile 'locked` shape
  were checked with that session; OpenShell does not implement the
  locked profile in this change, and a locked run refuses it.
- **t-tizx77bw, "Redesign task jail details page and fix
  add-directory"** (branch `task/the-task-jail-and-permissions-tizx77bw`,
  session 01562847).  It rewrote the access view as Overview, Tools,
  Rules and Judgements, with the settings grouped on the Overview.  The
  Secrets group goes in that Overview; this change does not edit
  `lisp/ui/harness-ui-access.el`.
- **t-01d747f0, secret handling** (done).  This builds on its
  references, its registry and its masking, and adds nothing to them:
  the list it keeps is the list this module reads.

## The open questions, answered

1. **Does `harness-sandbox.el` already support a second, narrower
   profile per command?**  It did not; it now does: `:profile`, `:env`,
   `:hide` and `sandbox/profiles`, additive to the three backend
   builders and failing closed where a backend cannot give the profile.
2. **Can an agent still infer a secret through side channels?**  Not
   through anything the command prints or returns: that is the point of
   withholding the whole result.  It can still *time* the run with its
   own clock, and it can learn whatever the user tells it; those are
   the residual channels of running a command at all.
3. **Is a per-secret network allowlist enough, or should the default be
   no network?**  The answer is no network, and there is nothing to
   declare: the module does not name hosts, a locked run has none, and
   no backend in the harness can enforce a host list.  A backend that
   can -- OpenShell -- would add the option when it implements the
   profile; until then an option would be a promise nothing keeps.
4. **Does the design need a backend interface for OpenShell?**  Yes, the
   small one now in place: `:profile`, `:env`, `:hide` and
   `sandbox/profiles`, with an unsupported profile signalling rather
   than downgrading.
5. **How do secret grants appear on the redesigned jail details page?**
   As a Secrets group in the Overview's Settings: label, fingerprint,
   source description, last use and an error.  No values, no reveal
   action; the prompts stay in the chat.  `secret-sandbox/secrets`
   returns the data; the UI is stage 5.
6. **Is a per-call approval, with no remembered answer, the right
   default?**  Yes.  The command's effect is what the user decides on;
   the output never reaches the agent, so the approval does not depend
   on reading it.  A `:allow` list of exact commands is the path for
   unattended use; it is not implemented.
7. **What happens when a secret is declared but the sandbox cannot run
   it?**  `list_secrets` lists it as unavailable with the reason and
   `run_with_secret` refuses before the prompt.  Declaring a secret does
   not depend on a backend: the masking works without one, and the
   locked run refuses rather than fall back to a wider sandbox.

## Limits worth knowing

- **A command the user approves acts for the user.**  It can deploy,
  push or call an API with the secret.  That is what the tool is for;
  the output and the result are not returned, but the effect is real.
- **Timing is outside the result.**  A command whose duration depends
  on the value is a timing channel: the agent can compare its own clock
  before and after.  The result carries no duration, and every run is
  approved; the clock is not something this module controls.
- **No backend, no shell guarantee.**  With the sandbox policy `off`,
  no backend, or a remote directory, a normal bash command can read a
  source that lies in a path it can see; the value itself is masked
  from the result, but a transformed value is not.
  `secret-sandbox/status` says so, and `run_with_secret` refuses.
- **The agent can read a variable or a literal.**  A secret kept in the
  harness's environment or typed into `harness-secrets-sources` is in
  reach of the agent's own `bash` and `elisp` calls; masking is what
  protects it, and a locked run refuses it rather than pretend
  otherwise.  Keep a secret a command must use in a file or behind a
  command.
- **The user's Emacs is another process.**  Its environment, buffers,
  minibuffer history and the files it opens are outside this module;
  `emacs_eval` runs there, and masking is the backstop for its output.
- **The harness's memory holds the values.**  Swap, a core dump, a
  debugger attached to the harness, or a modified harness are outside.
- **Unlink is not a wipe.**  The per-call file is short-lived and 0600,
  but its bytes may persist on disk until overwritten.
- **A plugin or a module can do anything.**  This protects against the
  agent, not against code the user installed.
- **A `:command` source is the user's command.**  It runs in the
  harness's own environment when the registry reads it, not in the
  locked sandbox; keep it a command that prints the value and nothing
  else.
