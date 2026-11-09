# A failed compose command says what ran and why it failed

## What the problem was

On macOS the local voice pipeline would not start. The harness reported:

```
failed
Error: executing /opt/homebrew/bin/podman-compose -p voice-local -f /....
```

Two things are wrong with that, and they are separable.

**The reason was thrown away.** The line shown is podman's own wrapper
line: `podman compose` is a thin shim around an external provider
(`/opt/homebrew/bin/podman-compose` from Homebrew), and when the
provider exits nonzero podman prints one line naming the provider, its
argv and the exit status. It is the *last* line of the output and the
least informative one — the provider's own error came before it, and
was dropped, because the state kept the last line that looked like an
error and that line looks like one.

**The command was cut mid-path.** The one-line state was truncated at
160 characters with `...`, and the wrapper line is longer than that: it
holds the whole argv, paths and all. So the report named neither the
reason for the failure nor the command that failed.

The pipeline got no further. The failure itself is a different bug with
a different fix (below).

## What the change decides

### 1. A command's last run is remembered, whole

`harness-compose-stack-last-command` returns the last command a stack
ran: the exact argv list, the directory, the environment the stack
added, the exit status, both streams as the command wrote them, and
when it ended. It is a record, not a rendered line, so nothing about it
depends on a frame's width.

`harness-compose-stack-last-failure` keeps the start or stop that last
failed, until a later one succeeds. Without it, the `compose ps` query
that follows a failed start would find no service, read `stopped`, and
replace the failure with it — the reason would be visible for as long
as it took the page to redraw. A query is not a start and never
replaces a failure; a start still running is not one either.

### 2. The detail is the exit status and the provider's own reason

`harness-stacks--status-line` formats `exit 1 · <reason>`. The exit
status is there because a provider that exits 0 while the runtime
prints an error is a different problem from one that exits 1, and a
client cannot tell them apart from the words alone.

`harness-stacks--reason-line` picks the reason: the last line that
reads like a failure and is **not** the runtime's wrapper line; failing
that, the first such line; failing that, the last line there is. The
wrapper patterns are a small list of constants
(`harness-stacks--runtime-wrapper-patterns`) rather than a parse of
podman's format: a provider whose only complaint *is* the wrapper line
still says it, because the patterns are a preference among lines and
not a filter over them.

### 3. Nothing is cut at a width

The reason is never truncated. Cutting a failure at a column is what
made it unreadable in the first place, and any width is the wrong one:
the part past it is exactly what a reader needs, and the harness does
not know how wide the reader's frame is. Cutting was removed from three
places that each re-added it at a different width — the state's own
160-character line, the page's 72-character row, and the voice
pipeline's 240-character reason.

What is still dropped is the *progress* before the reason (a spinner,
terminal control sequences, the lines that are not the failure), because
that is not shortened information but a different line.

On the stacks page, a failed stack puts its reason on its own indented
line under the row, and the row keeps `[Start]` and `[Log]` where they
are. Putting a whole reason on the row pushed the controls off it,
which would be a row whose buttons move with every message; a short
detail such as `2 of 2 services` still says the state on its row.

### 4. The whole of it is one command away

`M-x harness-compose-stack-log` (and `[Log]` on the stacks page) shows
the exact argv as a shell command line, the directory, the environment
added, the exit status and every line of both streams. ACP clients ask
for the same text with the new `speech/log` method; `speech/status`
carries `:command`, `:directory` and `:exit` beside `:detail` and
`:reason`, so a client can name the command a failed start ran without
asking twice. The UI's pipeline line gets `[Details]`, which opens the
log.

### 5. Commands run in the stack's directory, with pipes

Two differences between Docker Compose and podman-compose are handled
here because either can be the reason a stack that worked on one
machine fails on another:

- **The directory.** Docker Compose resolves the file's relative
  volumes and build contexts from the file's directory; podman-compose
  resolves them from the working directory. Every command now runs in
  the stack's `:directory`, so the file's relative paths mean the same
  thing to both.
- **The streams.** Emacs gives `make-process` a pseudo-terminal unless
  told not to. A provider that reads its standard input then waits on a
  terminal that never answers, and the terminal's line editing mixes
  stderr into the progress it draws. The runner asks for `pipe`, sets
  both `:buffer` and `:stderr` (a pipe process that appends to the same
  buffer, so the order the command wrote is kept), and returns the exit
  status with both streams.

## The failure itself

The two mechanisms above are what makes any compose failure legible.
The particular failure is separate, and is an image architecture
mismatch: `ghcr.io/ggml-org/whisper.cpp:main` is published for
`linux/amd64` only, and an Apple-silicon podman machine is `linux/arm64`,
so the pull fails with

```
Error: no image found in manifest list for architecture "arm64", variant "v8", OS "linux"
```

`HARNESS_WHISPER_IMAGE` already existed to name another image and is now
documented for exactly this: an image built for the machine's
architecture. The harness does not try to paper over the mismatch — it
reports it in those words, which is the whole point.

No Mac was available to this task, so this was not reproduced on one.
What *was* reproduced is the exact report: the podman-shaped failure is
a test fixture, verbatim, including the wrapper line naming
`/opt/homebrew/bin/podman-compose`, and the tests assert the exact
detail and the exact log for it.

## What it looks like

The stacks page with a failed start, drawn from recorded state in a live
harness; the reason is whole under the row and the controls stay on it:

![The stacks page with a failed start](media/compose-failure-page.png)

The log `[Log]` opens — the exact argv, the directory, the environment,
the exit status and every line the provider wrote:

![The log of the failed command](media/compose-failure-log.png)

The voice pipeline's own line, with `[Details]` opening the same log over
ACP:

![The pipeline line with Details](media/compose-failure-pipeline.png)

## Alternatives considered

**Parse podman's output more cleverly.** No: the provider's lines are
already the best statement of the problem, and a parser would have to
follow every provider's format. Keeping the line before the wrapper,
and the whole of it, needs no knowledge of any format.

**Keep a width but make it wider.** Rejected. Wallpapering over a
truncation bug by moving the limit only moves the failure mode, and the
harness cannot know the reader's width; a client that must fit one row
truncates for the width it knows, and the log carries the rest.

**Show the log instead of a one-line detail.** A page that opens a
buffer for every stack is worse to scan than one that names the reason
and offers the log beside it.

**Run everything through `shell-command` for the shell quoting.** No:
commands stay argv lists, so no path or argument is ever re-parsed by a
shell. The log quotes the argv into a runnable line for the reader, and
nothing runs that line.

## Where the change is

| File | What it now does |
| --- | --- |
| `lisp/modules/harness-container-runtime.el` | runs a command with pipes, in a given directory, returning exit status and both streams |
| `lisp/modules/harness-stacks.el` | the last command and last failure per stack, the reason without the wrapper line and uncut, the log buffer and page control |
| `lisp/modules/harness-speech.el` | `speech/log`, and `:command`, `:directory`, `:exit` in `speech/status` |
| `lisp/ui/harness-ui-voice-providers.el` | `[Details]` on the pipeline line, asking `speech/log` |
| `docs/stacks.md`, `docs/modules/*.md` | what a failure says, and the provider differences |

## What is verified

`lisp/modules/harness-stacks-test.el` holds a podman-shaped failure
verbatim and asserts the exact detail (`exit 1 · Error: no image found
in manifest list for architecture "arm64", variant "v8", OS "linux"`),
the exact log text, that the reason is not cut, that a failed start
survives the `compose ps` query after it, that a still-running start is
not read as a failure, and the page's exact rendered rows and tooltips.
`lisp/modules/harness-container-runtime-test.el` runs real commands
through the asynchronous runner and asserts that they get pipes rather
than a terminal, run in the directory given, and report both streams
and a nonzero status. `lisp/modules/harness-speech-test.el` asserts
that a failed start names the reason and carries the exact argv, the
directory and the exit status, and that `speech/log` returns the whole
of it.
