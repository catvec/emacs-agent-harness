# The session's temporary directory is the command's /tmp

## The problem

A session has a temporary directory of its own, `session/tmp-dir`
(`/var/tmp/harness-UID/ID/` by default): the tools' `:writable`, the
jail's `tmp` source, the place `session_info` names and the system
prompt points at. What a shell command honors, though, is `$TMPDIR` and,
far more often, nothing at all: `mktemp`, `echo x > /tmp/out`, a build
tool's default output dir all go to `/tmp`. Inside the sandbox `/tmp`
was a fresh tmpfs per command, so those files were written twice-over
invisible: gone when the command ended, never reachable by the next
command or by `read_file`. The agent's own habits made it worse -- it is
told to use the temporary directory, but every library it runs was
written for `/tmp`.

The directory exists, is writable and is cleaned up with the session.
The namespace boundary was the only thing that hid it from `/tmp`.

## What the change does

`sandbox/wrap` gains `:tmp DIR`: the caller's temporary directory, shown
as the command's `/tmp`, writable, and `TMPDIR=/tmp` in the environment
so that a script honoring `$TMPDIR` and one writing `/tmp` without
asking agree. The bash and elisp tools give the session's directory,
and `harness-tools-shell-sandbox-profile` carries it, so the MCP servers
and the file tools' worker see the same `/tmp` as bash.

Inside the sandbox there are then two paths to one directory: `/tmp`,
and the directory's own path, which is still bound because `session_info`
and the file tools name it. Nothing of the machine's `/tmp` is shown:
the bind replaces the private tmpfs with the session's directory, it
does not add the host's files.

### Backends

| backend | `/tmp` |
| --- | --- |
| bwrap | `--bind DIR /tmp` in place of `--tmpfs /tmp` |
| systemd-run | `-p BindPaths=DIR:/tmp -p ReadWritePaths=/tmp` in place of `PrivateTmp=yes`; its own private `/tmp` stays when a path its setting cannot hold as written leaves nothing to bind |
| MXC (macOS) | the command's private `$TMPDIR`; Seatbelt has no mount namespace and cannot write `/tmp` |
| OpenShell | the image's `/tmp`; the directory shows at its real path |

A unit gets no `PrivateTmp=` when it is given a directory: `/tmp` is the
bind and nothing else, so nothing of the machine's `/tmp` is reachable
through it, and there is no second tmpfs whose order against the bind
would matter. The unit's `/var/tmp` is then the machine's, as the rest
of the file system is for this backend, which hides only the home
directories.

### What it is not

- Not for a command that changes nothing. `:read-only` keeps the
  private empty tmpfs, so the supervising session's shell still writes
  only what it throws away.
- Not for the locked profile. A locked run must not see what the session
  left behind -- `/tmp` is exactly where a previous command could have
  left a copy of a secret -- so it keeps a private `/tmp` and refuses
  `:tmp`, as it refuses a writable directory.
- Not a wider view. `DIR` is refused, with a line in the log and the
  private `/tmp` instead of an error, when it is no local directory, is
  `/`, is or lies in `/tmp`, holds the home directory, or is, holds or
  lies in a directory the sandbox mounts its own. Each of those would
  show more than the caller gave, or undo what the sandbox keeps out of
  sight.

### The two paths

`/tmp` is a second name for a directory that is also named where it
lives. That matters in three places:

- **Mount order.** The bind over `/tmp` comes where the tmpfs did,
  before the home tmpfs and every other bind, so nothing later is
  covered by it.
- **The git registry.** The registration of a worktree the sandbox does
  not show is mounted read-only over the writable git directory. A
  scratch repository in the session's directory is now reachable at
  `/tmp` too, so the `/tmp` view joins the writable views the
  registrations are computed from (`harness-sandbox--hidden-registrations`),
  and is protected at both names.
- **Hidden paths.** The secret sandbox's `:hide` list keeps a secret
  file out of a command's sight. A path under `/tmp` now names what
  `DIR` holds at the same place: one in `DIR` is hidden where it is and
  at `/tmp/REL`; one that is not in `DIR` is left out, since `/tmp` no
  longer leads to it and hiding it would make an empty file named after
  the secret in the session's directory (`harness-sandbox--hide-paths`).

### The elisp tool's call directory

The elisp tool makes a directory per call for its code and result and
gives it as `:scratch`. It was made in the harness's own
`temporary-file-directory`, which is `/tmp` on most systems, so its
mount point would lie inside the session's `/tmp` and leave an empty
directory there after every call. It is made in the session's temporary
directory instead, when there is one: the mount point is then an
ordinary path, it is cleaned up with the session if a call dies, and it
is where the session's own files live anyway.

## Alternatives

- **A symlink.** `TMPDIR` pointing at the directory, and a symlink from
  `/tmp`: works only outside a sandbox, needs the directory to be
  writable as `/tmp` inside, and changes the host's `/tmp` or fails.
  The namespace is the tool for the job.
- **Show `DIR` at `/tmp` and nowhere else.** Fewer mounts, but the file
  tools and `session_info` name the real path; a command could not read
  what `read_file` had just written for it, and the model would have two
  vocabularies for one directory.
- **Map a directory that lies in `/tmp` too.** Its own path would then
  be inside the bind: bwrap would create the path again in the
  session's directory and mount the directory inside itself -- a tree
  that leads back into itself, which `rm -rf /tmp` and `find` walk
  twice. Refusing keeps one name for the directory.
- **`TMPDIR` only, without the mount.** What the code did before; it is
  precisely the scripts that ignore `$TMPDIR` that need the mount.

## What a reader sees

- `sandbox/wrap` documents `:tmp`, and the module's commentary says what
  the sandbox sees, that `/tmp` is private only when the caller gives no
  directory, and what MXC and OpenShell do instead.
- The bash tool's description and the elisp tool's commentary say that
  `/tmp` is the session's temporary directory there.
- The system prompt's scratch-files line no longer warns against `/tmp`:
  in a sandbox it is the directory the line recommends, and outside one
  the line's first half still holds.
- `docs/architecture.md` has the option beside the others, the
  temporary-directory section names it, and the module pages are
  generated from the source.

## What it costs

- A command of a session now shares `/tmp` with the session's other
  commands and tools. That is the point, and it is the same trust domain
  as the temporary directory itself; the private `/tmp` stays for the
  two callers that must not write or must not look.
- One more bind mount per confined command; nothing measurable.
- On a system where a session's temporary directory is configured into
  `/tmp` itself, the mapping is off (see above) and the old private
  `/tmp` stays.
