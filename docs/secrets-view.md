# The Secrets page of the access view

## The problem

Secret masking is on by default, but nothing in an ordinary session says
what it has done.  The source list was a command under the Tools menu,
away from the session whose output was being masked, and it listed only
the sources the user had declared.  A user could not tell a working
extension from a disabled one, or a run in which nothing matched from one
in which the matches happened somewhere else.

## What the page decides

The Secrets page is the fifth page of the existing Jail & permissions
view (`C-c h j`, then `5`).  The Overview's Details section ends with a
linked summary, `Secrets  Masking on · 2 sources · 14 masked values`, so the
state is visible without opening the page.

The page keeps three different things apart, because they answer
different questions:

- **Protection** says whether the extension is doing anything now:
  output masking on or off, the detectors in force, and whether the
  optional secret-sandbox module is loaded and hiding source files.
- **Registered sources** are harness-wide declarations: where a secret
  can be read and which values are registered.  They are the only thing
  that can make a file a secret's source and the only thing that a
  removal takes away.
- **Detected in tool output** belongs to the session in view: up to 50
  recent masking passes of this harness process, with the tool, a file
  when one can be named, time, label, fingerprint and count.

The page never presents a detected file as a registered or protected
file.  Detection is an observation; registration is a declaration, and
moving from one to the other is a deliberate action.

## What can be said about a file

Only a direct `read_file` call gives a file name that unambiguously
belongs to the output.  A `grep` path may be a directory, and a shell or
provider tool result has no reliable provenance.  The page therefore
shows `Unknown file` when it cannot name one, rather than guessing from
the call's arguments.  The read path is resolved against the real
session's working directory and host without looking up a remote home.

There is no project scan.  The note `Tool-output detection · no project
scan` prevents a reader from taking an empty list as a statement that the
project holds no secrets.  Detectors inspect text that a tool returns;
they do not walk the tree.

## Values and retention

The page receives a value-free status.  It carries source descriptions,
fingerprints and counts, never a value, a matched excerpt or the
surrounding text.  A registered source that cannot be read keeps its last
values in force for masking, so the page says `Source unreadable ·
previous values retained` rather than claiming that protection stopped.
Activity is in memory, bounded to 50 records and 100 fingerprints per
record, and is cleared when the session is deleted or the state directory
changes.  Bookkeeping is non-signalling: a telemetry failure can never
make the masking filter pass text through.

## Management

The page reuses the actions that already exist rather than adding a
second source editor:

- `[New source…]` opens `harness-secrets-add-source`, a form with the
  ways to name a source as a choice: a JSON file and path, a file and
  regexp, an environment variable or a command's output.  The fields of
  the chosen way sit under the choice, with `[Choose file…]` and
  `[Read keys…]` where they help, and a `Label` that defaults from the
  source.  `Masking` says `Harness-wide`.  Only `[Register]` sends it;
  `[Cancel]` leaves nothing, `[Registering…]` holds the form while the
  harness answers, and a failure stays on the form with its reason.  It
  refuses to store a literal or a reference that holds the value: there
  is no field for a secret.
- `[Removal…]` on a stored source asks before removing it, naming both
  consequences: masking stops, and the secret-sandbox can no longer hide
  the file.  Configuration sources stay owned by
  `harness-secrets-sources`;
- `[Sources]`, `[Redaction…]`, `[History]` and `[Settings]` lead to the
  existing full pages for the long lists, stored-secret redaction,
  redaction history and the masking settings.

## Availability and refresh

`secrets/status` is available while the module's output filters are
installed.  A disabled module keeps its methods, so the page checks the
filters and the module state rather than trusting a method's existence:
it says `Secret extension inactive` when masking is gone, and withholds
the detector list rather than presenting stale detector names.

The page follows `secrets/detected` for its own session and
`secrets/sources-changed` for every access view.  It fetches again when
the connection is replaced, including when the first response was still
in flight, and an older response can never replace a newer one.

## Alternatives considered

- **A separate secrets buffer** would have repeated the session scope,
  the access wording and the management commands, and would have been
  even easier to miss than the old Tools entry.
- **A project file scan** would either report only heuristically
  secret-looking files, which is a different and weaker promise than
  masking, or would turn every hit into a declaration, which would
  silently block files the user never registered.  Neither is what
  masking actually guarantees.
- **Putting detections in the global source list** would mix one
  session's observation with the harness-wide registry.  The page
  therefore separates them, and the source list stays about declared
  sources only.

## Shape of the change

- `lisp/modules/harness-secrets.el`: a bounded, value-free per-session
  activity record, `secrets/status`, `secrets/detected` and
  `secrets/sources-changed`.
- `lisp/modules/harness-access.el`: `access/describe` carries a
  `:secrets` status when the module is present, with no hard dependency.
- `lisp/ui/harness-ui-access.el`: the page, the Overview summary, the
  `5` key and menu entry, the asynchronous refresh, and the copy tests.
- `lisp/ui/harness-ui-secrets.el`: the new-source form, and the add and
  remove actions with their consequences, shared with the existing source
  list.
- `lisp/modules/harness-acp.el`: forwards the two new events to UI
  clients.
- `test/harness-secrets-mask-test.el`, `test/harness-access-test.el`,
  `test/harness-ui-access-test.el`, `test/harness-ui-secrets-test.el`,
  and `scripts/harness-media.el` with the `access-secrets` and
  `access-secrets-new` pictures.

## What this deliberately does not do

- It does not scan the project for secret-looking files.
- It does not turn an observed file into a registered source.
- It does not promise per-secret locked-run availability; that remains
  `list_secrets` until a later change puts it on this page.
- It does not keep detection history across harness restarts.
